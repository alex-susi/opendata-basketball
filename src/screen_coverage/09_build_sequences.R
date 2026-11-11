# Screen coverage, step 9: movement histories for the time-aware transformer.
#   Rscript src/screen_coverage/09_build_sequences.R
#
# Needs 02_per_frame.R and 03_build_tokens.R first (same 1,464 screens and frame rows).
#
# For every scored screen, each of its ten players is described at every frame from 3.6 s before the screen tag to
# 1 s after it. The model (10_train_seq_transformer.R) then reads, for a prediction at frame t, each player's values at
# t, t-0.2 s, ..., t-1.6 s (nine steps): his last 1.6 s. Nothing after t is ever used.
#
# The ten players: rows 1-4 are the ball handler, screener, handler's defender and screener's defender; rows 5-7 the
# other attackers and 8-10 the other defenders on the floor at the tag (their order does not matter to the model).
#
# Per player and frame (positions in the site's frame, offense attacking the hoop at +40.8 ft):
#   x, y               court position (ft). y, rel_y, rel_h_y and vy are mirrored at training time so that the
#                      screener is on the y >= 0 side at the prediction frame
#   rel_x, rel_y       position relative to the screener at the same frame
#   rel_h_x, rel_h_y   position relative to the ball handler (the screener's row traces the path of his approach)
#   hoop_dist, lvl     distance from the hoop; that minus the screener's (+ = above the screen, - = below)
#   vx, vy, speed      velocity over the last 0.2 s (ft/s)
#   accel              change in speed over the last 0.2 s (ft/s per s): speeding up (+) or slowing down (-)
#   turn               change of direction over the last 0.2 s (degrees; 0 when he is nearly still)
#   lvl_v              how fast his level is changing (ft/s)
#   lvl_hold           seconds he has stayed on the same side of the screener's level (above, level within 0.5 ft,
#                      or below), capped at 1.6 s: "Jefferson was high, then started sliding"
#   present            1 if tracked in the screen's possession at that frame (missing players get zeros)
# Screen-level context per prediction frame (memory of contact, all visible on the court):
#   hs_min             the closest the ball handler has been to the screener over the last 2 s (ft)
#   since_hs_min       seconds since that closest moment (0 = they are closest now)
#   plus time to act, the defense's earlier calls (logs) and closeness, as for the other transformers
#
# Writes outputs/cache/screen_coverage/sequences.rds.

suppressPackageStartupMessages(library(data.table))
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")

FPS <- 25
STEP <- 5L                       # 0.2 s between history steps (and the velocity lag)
BASE_OFFS <- -90:25              # frames relative to the tag at which features are stored
POS_OFFS <- (min(BASE_OFFS) - 2L * STEP):max(BASE_OFFS)
HOLD_CAP <- 1.6
DEAD <- 0.5
HOOP_X <- (14 - 1.575) * 3.28084
FEATS <- c("x", "y", "rel_x", "rel_y", "rel_h_x", "rel_h_y", "hoop_dist", "lvl", "vx", "vy", "speed", "accel",
           "turn", "lvl_v", "lvl_hold", "present")
FLIP <- c("y", "rel_y", "rel_h_y", "vy")

L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
TK <- readRDS(file.path(cache_dir, "tokens.rds"))
P <- L$P; X <- L$X
NS <- nrow(P)
# roster per screen: the four of the screen, then the other attackers and defenders on the floor at the tag
r0 <- which(X$off == 0L)
roster <- matrix(NA_integer_, NS, 10L)
roster[X$idx[r0], ] <- TK$ids[r0, ]
stopifnot(!anyNA(roster))

pos_at <- function(B, frames, ids) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_, poss = NA_character_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    hit <- B$P[.(frames[miss] + d, ids[miss]), .(x, y, poss), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y, poss = hit$poss)]
  }
  out
}

NP <- length(POS_OFFS)
PX <- PY <- array(NA_real_, c(NS, NP, 10L))
for (g in unique(P$game_id)) {
  B <- readRDS(file.path(root, "outputs", "cache", "explore", sprintf("bundle_%d.rds", g)))
  s <- which(P$game_id == g)
  q <- CJ(k = seq_along(s), o = seq_len(NP), j = 1:10)
  hit <- pos_at(B, P$f0[s][q$k] + POS_OFFS[q$o], roster[cbind(s[q$k], q$j)])
  ok <- !is.na(hit$x) & hit$poss == P$poss[s][q$k]
  PX[cbind(s[q$k], q$o, q$j)] <- fifelse(ok, hit$x, NA_real_)
  PY[cbind(s[q$k], q$o, q$j)] <- fifelse(ok, hit$y, NA_real_)
}

hoop <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)
NB <- length(BASE_OFFS)
base <- array(0, c(NS, NB, 10L, length(FEATS)), dimnames = list(NULL, NULL, NULL, FEATS))
at <- function(A, o) A[, match(o, POS_OFFS), , drop = TRUE]          # [screens, 10] at offset o
sgn_prev <- hold <- matrix(0, NS, 10L)
for (b in seq_len(NB)) {
  o <- BASE_OFFS[b]
  x <- at(PX, o); y <- at(PY, o); x1 <- at(PX, o - STEP); y1 <- at(PY, o - STEP); x2 <- at(PX, o - 2L * STEP); y2 <- at(PY, o - 2L * STEP)
  sx <- x[, 2]; sy <- y[, 2]; hx <- x[, 1]; hy <- y[, 1]
  vx <- (x - x1) / (STEP / FPS); vy <- (y - y1) / (STEP / FPS); sp <- sqrt(vx^2 + vy^2)
  vx1 <- (x1 - x2) / (STEP / FPS); vy1 <- (y1 - y2) / (STEP / FPS); sp1 <- sqrt(vx1^2 + vy1^2)
  turn <- acos(pmin(1, pmax(-1, (vx * vx1 + vy * vy1) / pmax(sp * sp1, 1e-6)))) * 180 / pi
  turn[is.na(sp) | is.na(sp1) | sp < 1 | sp1 < 1] <- 0
  lvl <- hoop(x, y) - hoop(sx, sy); lvl1 <- hoop(x1, y1) - hoop(x1[, 2], y1[, 2])
  sg <- ifelse(lvl > DEAD, 1, ifelse(lvl < -DEAD, -1, 0))
  hold <- ifelse(!is.na(sg) & sg == sgn_prev, pmin(HOLD_CAP, hold + 1 / FPS), 0)
  sgn_prev <- ifelse(is.na(sg), 99, sg)
  present <- !is.na(x) & !is.na(x1) & !is.na(x2)
  vals <- list(x = x, y = y, rel_x = x - sx, rel_y = y - sy, rel_h_x = x - hx, rel_h_y = y - hy, hoop_dist = hoop(x, y),
               lvl = lvl, vx = vx, vy = vy, speed = sp, accel = (sp - sp1) / (STEP / FPS), turn = turn,
               lvl_v = (lvl - lvl1) / (STEP / FPS), lvl_hold = hold)
  for (f in names(vals)) { v <- vals[[f]]; v[!present | is.na(v)] <- 0; base[, b, , f] <- v }
  base[, b, , "present"] <- as.numeric(present)
}
cat(sprintf("Players present over the stored frames: screen four %.1f%%, other six %.1f%%\n",
            100 * mean(base[, , 1:4, "present"]), 100 * mean(base[, , 5:10, "present"])))

# memory of contact, per prediction row: closest handler-screener distance over the last 2 s, and how long ago
dhs <- sqrt((PX[, , 1] - PX[, , 2])^2 + (PY[, , 1] - PY[, , 2])^2)        # [screens, NP]
mem <- t(vapply(seq_len(nrow(X)), function(r) {
  k <- match(X$off[r], POS_OFFS); w <- dhs[X$idx[r], (k - 50L):k]
  if (all(is.na(w))) return(c(NA_real_, NA_real_))
  m <- which.min(w); c(w[m], (length(w) - m) / FPS)
}, numeric(2)))
ctx <- cbind(TK$ctx[, c("tta_now", paste0("lsf_", 1:5), "closeness")], hs_min = mem[, 1], since_hs_min = mem[, 2])
ctx[is.na(ctx[, "hs_min"]), "hs_min"] <- X$d_hs[is.na(ctx[, "hs_min"])]
ctx[is.na(ctx[, "since_hs_min"]), "since_hs_min"] <- 0
stopifnot(!anyNA(ctx), !anyNA(base))
saveRDS(list(base = base, base_offs = BASE_OFFS, step = STEP, feats = FEATS, flip = FLIP, ctx = ctx, roster = roster),
        file.path(cache_dir, "sequences.rds"))
cat("Sequences:", paste(dim(base), collapse = " x "), "(screens x frames x players x features); context:",
    paste(colnames(ctx), collapse = ", "), "\n")
