## ═════════════════════════════════════════════════════════════════════════════
# Past-only inputs for the screen-coverage models (added 2026-11-12).
#
# Every input of a prediction at frame t must be computable from what had happened by frame t. This file holds the
# pieces that read tracking or event labels, so that 01_logistic_baseline.R (logistic baseline),
# 02_build_sequences.R (live transformer) and the check in 05_test_past_only.R all use the same rules:
#   pos_past()             a player's position at a frame, or if that frame is missing the latest of the MAX_GAP
#                          frames BEFORE it (never after); `gap` says how far back it came from, NA = missing
#   so_far_shares()        the defense's earlier calls in this game, counted only once readable (KNOWN_AFTER frames
#                          after their tag) by the prediction frame, shrunk toward an even split worth PRIOR_W screens
#                          (no other game's calls are used)
#   four_player_features() the logistic models' four-player measures at a frame
#   other_six()            the other three attackers and three defenders in the screen's possession at a frame
#   ten_player_positions(), sequence_base(), contact_memory(), seq_history()
#                          the live transformer's movement histories
#
# One premise is NOT past-only and is kept on purpose: the screen itself (which four players, and that it happens)
# comes from the tag. Every result reads "given that this screen is coming, with these four players".
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages(library(data.table))

# Version tag stored with every cache built under these rules; loaders refuse files built under other rules.
PAST_ONLY_RULES <- "past-only v2 (2026-11-12): backward fill <= 2 frames; so far = calls readable 1 s after tag, even-split prior"
FPS <- 25
MAX_GAP <- 2L                  # frames a missing position may be filled from, looking back only (0.08 s)
KNOWN_AFTER <- 25L             # frames after its tag before a screen's call counts as known (1 s)
PRIOR_W <- 5                   # weight of the even-split prior, in screens
HOOP_X <- (14 - 1.575) * 3.28084
hoop_dist <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - POSITIONS AND THE DEFENSE'S CALLS SO FAR -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Position of each (frame, player) pair from the bundle's tracking table B$P: the exact frame, else the latest of the
#' `max_gap` frames before it. Returns x, y, poss and gap (0 = exact, 1..max_gap = frames back, NA = missing).
pos_past <- function(B, frames, ids, max_gap = MAX_GAP) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_, poss = NA_character_, gap = NA_integer_)
  # Look at the frame itself, then one frame back, then two.
  for (back in 0:max_gap) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    q_frame <- frames[miss] - back
    q_id <- ids[miss]
    hit <- B$P[.(q_frame, q_id), .(x, y, poss), nomatch = NA]
    got <- !is.na(hit$x)
    out[miss[got], `:=`(x = hit$x[got], y = hit$y[got], poss = hit$poss[got], gap = back)]
  }
  out
}

#' The defense's "so far" shares at each prediction row. `screens`: every five-call screen (game_id, def_team, f0,
#' call), tracked or not. `rows`: prediction rows (game_id, def_team, f0 of the row's own screen, frame). A screen
#' counts for a row when it is the same defense in the same game, was tagged before the row's screen, and its call
#' was readable by the row's frame (tag + known_after <= frame). Returns a [rows x calls] matrix:
#' (counts + prior_w / n_calls) / (screens counted + prior_w), with the screens counted per row as attribute
#' "n_counted".
so_far_shares <- function(screens, rows, calls, known_after = KNOWN_AFTER, prior_w = PRIOR_W) {
  S <- data.table(game_id = screens$game_id, def_team = screens$def_team, s_f0 = screens$f0,
                  known = screens$f0 + known_after, k = match(screens$call, calls))
  Q <- data.table(r = seq_len(nrow(rows)), game_id = rows$game_id, def_team = rows$def_team, q_f0 = rows$f0,
                  q_frame = rows$frame)
  hit <- S[Q, on = .(game_id, def_team, s_f0 < q_f0, known <= q_frame), .(r = i.r, k = x.k), nomatch = NULL,
           allow.cartesian = TRUE]
  n <- matrix(0, nrow(rows), length(calls))
  # Count each row's readable earlier calls, then shrink toward the even split.
  if (nrow(hit)) {
    tab <- hit[, .N, by = .(r, k)]
    n[cbind(tab$r, tab$k)] <- tab$N
  }
  out <- (n + prior_w / length(calls)) / (rowSums(n) + prior_w)
  attr(out, "n_counted") <- rowSums(n)
  out
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - THE LOGISTIC MODELS' FOUR-PLAYER MEASURES ------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' The four players' measures for screens `p` (id, poss, H, S, BD, SD) at frames `at` (one per screen): positions at
#' the frame and `vlag` frames earlier. `tracked` is TRUE when all eight positions exist in the screen's possession;
#' `n_filled` counts how many of the eight came from an earlier frame. Clocks come from the exact frame only.
four_player_features <- function(B, p, at, vlag) {
  roles <- c(H = "H", S = "S", BD = "BD", SD = "SD")
  now <- lapply(roles, function(r) pos_past(B, at, p[[r]]))
  bef <- lapply(roles, function(r) pos_past(B, at - vlag, p[[r]]))
  ok <- Reduce(`&`, lapply(c(now, bef), function(h) !is.na(h$x) & !is.na(h$poss) & h$poss == p$poss))
  n_filled <- Reduce(`+`, lapply(c(now, bef), function(h) as.integer(!is.na(h$gap) & h$gap > 0L)))
  # Level: distance from the hoop minus the screener's; dd: distance between two of the four.
  lv <- function(Q, r) hoop_dist(Q[[r]]$x, Q[[r]]$y) - hoop_dist(Q$S$x, Q$S$y)
  dd <- function(Q, a, b) sqrt((Q[[a]]$x - Q[[b]]$x)^2 + (Q[[a]]$y - Q[[b]]$y)^2)
  q_frame <- at
  fr <- B$Fr[.(q_frame), .(sc, gc), nomatch = NA]
  data.table(id = p$id, tracked = ok, n_filled = n_filled,
             d_hs = dd(now, "H", "S"), d_bd = dd(now, "H", "BD"), d_sd = dd(now, "H", "SD"), d_def = dd(now, "BD", "SD"),
             bd_lvl = lv(now, "BD"), sd_lvl = lv(now, "SD"), h_lvl = lv(now, "H"), s_hoop = hoop_dist(now$S$x, now$S$y),
             bd_lvl_v = (lv(now, "BD") - lv(bef, "BD")) / (vlag / FPS),
             sd_lvl_v = (lv(now, "SD") - lv(bef, "SD")) / (vlag / FPS),
             sc_now = fr$sc, gc_now = fr$gc, frame = at)
}

#' The other three attackers and three defenders in each screen's possession at frames `at` (one per screen of `p`:
#' poss, H, S, BD, SD), from the exact frame or the latest of the MAX_GAP frames before it that has all six. Each
#' group is ordered by distance to the screener. Returns a [screens x 6] id matrix (attackers, then defenders; NA if
#' not found).
other_six <- function(B, p, at, max_gap = MAX_GAP) {
  ids <- matrix(NA_integer_, nrow(p), 6L)
  S0 <- pos_past(B, at, p$S)
  left <- seq_len(nrow(p))
  for (back in 0:max_gap) {
    if (!length(left)) break
    q <- data.table(i = left, frame = at[left] - back, q_poss = p$poss[left],
                    e1 = p$H[left], e2 = p$S[left], e3 = p$BD[left], e4 = p$SD[left])
    h <- B$P[q, on = "frame", nomatch = 0L, allow.cartesian = TRUE]
    h <- h[poss == q_poss & pid != e1 & pid != e2 & pid != e3 & pid != e4]
    ok <- h[, .(n_off = sum(off), n_def = sum(!off)), by = i][n_off == 3L & n_def == 3L]$i
    # Order each group by distance to the screener and fill the six slots.
    found <- h[i %in% ok]
    if (nrow(found)) {
      found[, ds := sqrt((x - S0$x[i])^2 + (y - S0$y[i])^2)]
      found[, slot := fifelse(off, 0L, 3L) + frank(ds, ties.method = "first"), by = .(i, off)]
      ids[cbind(found$i, found$slot)] <- found$pid
    }
    left <- setdiff(left, ok)
  }
  ids
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - THE LIVE TRANSFORMER'S MOVEMENT HISTORIES ------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# History settings: 0.2 s steps, stored frames -3.6 s to +1 s, the level "hold" cap and dead zone, and the features.
SEQ_STEP <- 5L
SEQ_BASE_OFFS <- -90:25
SEQ_POS_OFFS <- (min(SEQ_BASE_OFFS) - 2L * SEQ_STEP):max(SEQ_BASE_OFFS)
SEQ_HOLD_CAP <- 1.6
SEQ_DEAD <- 0.5
SEQ_FEATS <- c("x", "y", "rel_x", "rel_y", "rel_h_x", "rel_h_y", "hoop_dist", "lvl", "vx", "vy", "speed", "accel",
               "turn", "lvl_v", "lvl_hold", "present")
SEQ_FLIP <- c("y", "rel_y", "rel_h_y", "vy")

#' Positions [screens, offsets, players] for screens `p` (f0, poss) and their ten-player `roster` [screens x 10], at
#' every offset of `pos_offs`. A position counts only while the player is in the screen's possession.
ten_player_positions <- function(B, p, roster, pos_offs = SEQ_POS_OFFS) {
  ns <- nrow(p)
  PX <- PY <- array(NA_real_, c(ns, length(pos_offs), 10L))
  q <- CJ(k = seq_len(ns), o = seq_along(pos_offs), j = 1:10)
  hit <- pos_past(B, p$f0[q$k] + pos_offs[q$o], roster[cbind(q$k, q$j)])
  ok <- !is.na(hit$x) & hit$poss == p$poss[q$k]
  PX[cbind(q$k, q$o, q$j)] <- fifelse(ok, hit$x, NA_real_)
  PY[cbind(q$k, q$o, q$j)] <- fifelse(ok, hit$y, NA_real_)
  list(PX = PX, PY = PY)
}

#' Per-frame movement features [screens, base_offs, 10, SEQ_FEATS] from positions, each built from the positions at
#' that frame, 0.2 s and 0.4 s earlier. lvl_hold carries over from frame to frame, so frames are visited in order;
#' nothing at a frame depends on a later one. Values of absent players are zero, with present = 0.
sequence_base <- function(PX, PY, pos_offs = SEQ_POS_OFFS, base_offs = SEQ_BASE_OFFS, step = SEQ_STEP) {
  ns <- dim(PX)[1]
  base <- array(0, c(ns, length(base_offs), 10L, length(SEQ_FEATS)), dimnames = list(NULL, NULL, NULL, SEQ_FEATS))
  at <- function(A, o) matrix(A[, match(o, pos_offs), ], ns, 10L)            # [screens, 10] at offset o
  sgn_prev <- hold <- matrix(0, ns, 10L)
  for (b in seq_along(base_offs)) {
    o <- base_offs[b]
    x <- at(PX, o)
    y <- at(PY, o)
    x1 <- at(PX, o - step)
    y1 <- at(PY, o - step)
    x2 <- at(PX, o - 2L * step)
    y2 <- at(PY, o - 2L * step)
    # Reference points: the screener (row 2) and the ball handler (row 1).
    sx <- x[, 2]
    sy <- y[, 2]
    hx <- x[, 1]
    hy <- y[, 1]
    # Velocity over the last 0.2 s and the 0.2 s before it, for the speed change and the turning angle.
    vx <- (x - x1) / (step / FPS)
    vy <- (y - y1) / (step / FPS)
    sp <- sqrt(vx^2 + vy^2)
    vx1 <- (x1 - x2) / (step / FPS)
    vy1 <- (y1 - y2) / (step / FPS)
    sp1 <- sqrt(vx1^2 + vy1^2)
    turn <- acos(pmin(1, pmax(-1, (vx * vx1 + vy * vy1) / pmax(sp * sp1, 1e-6)))) * 180 / pi
    turn[is.na(sp) | is.na(sp1) | sp < 1 | sp1 < 1] <- 0
    # Level relative to the screener; hold counts how long each player has stayed on one side of it.
    lvl <- hoop_dist(x, y) - hoop_dist(sx, sy)
    lvl1 <- hoop_dist(x1, y1) - hoop_dist(x1[, 2], y1[, 2])
    sg <- ifelse(lvl > SEQ_DEAD, 1, ifelse(lvl < -SEQ_DEAD, -1, 0))
    hold <- ifelse(!is.na(sg) & sg == sgn_prev, pmin(SEQ_HOLD_CAP, hold + 1 / FPS), 0)
    sgn_prev <- ifelse(is.na(sg), 99, sg)
    # A player is present only when all three positions exist.
    present <- !is.na(x) & !is.na(x1) & !is.na(x2)
    vals <- list(x = x, y = y, rel_x = x - sx, rel_y = y - sy, rel_h_x = x - hx, rel_h_y = y - hy, hoop_dist = hoop_dist(x, y),
                 lvl = lvl, vx = vx, vy = vy, speed = sp, accel = (sp - sp1) / (step / FPS), turn = turn,
                 lvl_v = (lvl - lvl1) / (step / FPS), lvl_hold = hold)
    for (f in names(vals)) {
      v <- vals[[f]]
      v[!present | is.na(v)] <- 0
      base[, b, , f] <- v
    }
    base[, b, , "present"] <- as.numeric(present)
  }
  base
}

#' Memory of contact for prediction rows (screen index `idx` into PX/PY, offset `off`): the closest the handler and
#' screener have been over the last `window` frames up to and including the row's frame, and how many seconds ago.
#' NA when neither was tracked in that span.
contact_memory <- function(PX, PY, idx, off, pos_offs = SEQ_POS_OFFS, window = 50L) {
  dhs <- matrix(sqrt((PX[, , 1] - PX[, , 2])^2 + (PY[, , 1] - PY[, , 2])^2), dim(PX)[1])     # [screens, offsets]
  t(vapply(seq_along(idx), function(r) {
    k <- match(off[r], pos_offs)
    w <- dhs[idx[r], (k - window):k]
    if (all(is.na(w))) return(c(NA_real_, NA_real_))
    m <- which.min(w)
    c(w[m], (length(w) - m) / FPS)
  }, numeric(2)))
}

#' Model input [rows, 10, k_steps, features] for prediction rows (screen `idx`, offset `off`): each player's stored
#' features at the row's frame, 0.2 s earlier, ..., (k_steps - 1) x 0.2 s earlier, mirrored so the screener is on the
#' y >= 0 side at the row's frame. `flat` is matrix(base, nrow = screens x frames) and `ns` the number of screens.
seq_history <- function(flat, ns, idx, off, k_steps, base_offs = SEQ_BASE_OFFS, step = SEQ_STEP) {
  nf <- ncol(flat) / 10L
  fi <- match(SEQ_FLIP, SEQ_FEATS)
  yi <- match("y", SEQ_FEATS)
  b0 <- match(off, base_offs)
  bb <- outer(b0, (seq_len(k_steps) - 1L) * step, `-`)              # [n, k] stored-frame index per step
  rows <- (bb - 1L) * ns + idx
  a <- flat[as.vector(rows), , drop = FALSE]                          # [n * k, 10 * nf] (n varies fastest)
  arr <- array(a, c(length(idx), k_steps, 10L, nf))
  sg <- ifelse(arr[, 1, 2, yi] < 0, -1, 1)
  for (f in fi) arr[, , , f] <- arr[, , , f] * sg
  aperm(arr, c(1, 3, 2, 4))
}
