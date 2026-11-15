## ═════════════════════════════════════════════════════════════════════════════
# Lane geometry for the screen-coverage experiments (added 2026-11-15, runbook "Roll, pop, and drive lanes").
#
# Pure functions: no tracking reads, no web code. 07_test_lane_geometry.R checks them on hand-made cases; the
# sequence builder (02_build_sequences.R --variant=B|C) and the past-only test call the same code.
#   segment_distances()   distance from points to a finite segment, and the raw projection along it
#                         (0 = segment start, 1 = segment end). The same math as seg_dist() in
#                         web/scripts/explore/common.R, but NA for an unusable segment instead of a tiny floor.
#   roll_lane_features()  for each stored frame and each of the three off-ball defenders (roster rows 8-10): his gap
#                         to the screener-to-rim segment at that frame, how much that gap shrank over the last 0.2 s
#                         (both gaps measured against the CURRENT segment), validity, and the audit values
#                         (projection, nearest point)
#   roll_lane_base()      the model channels [screens, frames, 10, k]: raw values, 0 where not valid
#   pop_option()          the screener's best pop spot beyond the arc at one frame: move, catch gap, pass gap
#   drive_options()       the handler's direct lane and the screen-side / reject routes at one frame: the on-ball
#                         defender's gap and the nearest off-ball defender's gap on each
## ═════════════════════════════════════════════════════════════════════════════

# The three roll-lane channels, in the order they are appended to the movement features.
ROLL_FEATS <- c("roll_distance_ft", "roll_closing_fps", "roll_lane_valid")
ROLL_ROWS <- 8:10                 # off-ball defenders in the ten-player roster of 02_build_sequences.R
ROLL_MIN_LEN2 <- 1e-12            # squared segment length below which the segment counts as unusable





## ═════════════════════════════════════════════════════════════════════════════
## 01 - POINT TO SEGMENT -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Distance from points (point_x, point_y) to the finite segment (start)-(end), the raw projection u along it
#' (unclipped: below 0 is behind the start, above 1 beyond the end) and the nearest point on the segment. Scalars or
#' equal-length vectors. NA wherever an input is missing or the segment has (near) zero length.
segment_distances <- function(point_x, point_y, start_x, start_y, end_x, end_y) {
  segment_x <- end_x - start_x
  segment_y <- end_y - start_y
  length_squared <- segment_x^2 + segment_y^2
  valid_length <- is.finite(length_squared) & length_squared > ROLL_MIN_LEN2
  length_squared[!valid_length] <- NA_real_
  # Project onto the segment, clip to its ends, and measure to the clipped point.
  projection <- ((point_x - start_x) * segment_x +
                 (point_y - start_y) * segment_y) / length_squared
  fraction <- pmin(1, pmax(0, projection))
  nearest_x <- start_x + fraction * segment_x
  nearest_y <- start_y + fraction * segment_y
  distance <- sqrt((point_x - nearest_x)^2 + (point_y - nearest_y)^2)
  valid <- is.finite(projection) & is.finite(distance)
  distance[!valid] <- NA_real_
  projection[!valid] <- NA_real_
  nearest_x[!valid] <- NA_real_
  nearest_y[!valid] <- NA_real_
  list(distance = distance, projection = projection, nearest_x = nearest_x, nearest_y = nearest_y)
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - ROLL LANE PER STORED FRAME ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Roll-lane values from the positions PX, PY [screens, pos_offs, 10] (ten_player_positions) and the movement
#' features' `present` flag [screens, base_offs, 10] (sequence_base). At each stored frame o the segment runs from the
#' screener (row 2) at o to the rim (HOOP_X, 0). For each off-ball defender (rows 8-10):
#'   distance   his gap to that segment at o (ft)
#'   closing    (gap of his position `step` frames earlier - gap now) / (step / FPS), both against the segment at o:
#'              + = he moved toward the current lane
#'   valid      TRUE when he is present (tracked at o and the two 0.2 s steps before), the screener is tracked at o,
#'              and both gaps exist
#'   projection raw u of his position at o (0 = screener, 1 = rim), nearest_x / nearest_y the closest lane point
#' Returns a list of [screens, base_offs, 10] arrays (NA outside rows 8-10 and wherever not valid).
roll_lane_features <- function(PX, PY, present, pos_offs = SEQ_POS_OFFS, base_offs = SEQ_BASE_OFFS, step = SEQ_STEP,
                               rows = ROLL_ROWS) {
  ns <- dim(PX)[1]
  nb <- length(base_offs)
  blank <- function() array(NA_real_, c(ns, nb, 10L))
  out <- list(distance = blank(), closing = blank(), valid = array(FALSE, c(ns, nb, 10L)), projection = blank(),
              nearest_x = blank(), nearest_y = blank())
  at <- function(A, o) matrix(A[, match(o, pos_offs), ], ns, 10L)            # [screens, 10] at offset o
  for (b in seq_along(base_offs)) {
    o <- base_offs[b]
    x <- at(PX, o)
    y <- at(PY, o)
    x1 <- at(PX, o - step)
    y1 <- at(PY, o - step)
    # The current segment: screener at o to the rim. Both gaps use it.
    for (j in rows) {
      now <- segment_distances(x[, j], y[, j], x[, 2], y[, 2], HOOP_X, 0)
      before <- segment_distances(x1[, j], y1[, j], x[, 2], y[, 2], HOOP_X, 0)
      ok <- present[, b, j] == 1 & is.finite(now$distance) & is.finite(before$distance)
      out$valid[, b, j] <- ok
      out$distance[, b, j] <- ifelse(ok, now$distance, NA_real_)
      out$closing[, b, j] <- ifelse(ok, (before$distance - now$distance) / (step / FPS), NA_real_)
      out$projection[, b, j] <- ifelse(ok, now$projection, NA_real_)
      out$nearest_x[, b, j] <- ifelse(ok, now$nearest_x, NA_real_)
      out$nearest_y[, b, j] <- ifelse(ok, now$nearest_y, NA_real_)
    }
  }
  out
}

#' The variant's channels `extra` appended after the movement features of `base` [screens, frames, 10, SEQ_FEATS]
#' (sequence_base), from the same positions PX, PY. Returns the extended base and the roll_lane_features() values
#' (NULL when `extra` is empty, in which case `base` is returned untouched).
append_lane_channels <- function(base, PX, PY, extra) {
  if (!length(extra)) return(list(base = base, rl = NULL))
  present <- array(base[, , , "present"], dim(base)[1:3])
  rl <- roll_lane_features(PX, PY, present)
  add <- roll_lane_base(rl, extra)
  feats <- c(dimnames(base)[[4]], extra)
  full <- array(0, c(dim(base)[1:3], length(feats)), dimnames = list(NULL, NULL, NULL, feats))
  full[, , , seq_len(dim(base)[4])] <- base
  full[, , , dim(base)[4] + seq_along(extra)] <- add
  list(base = full, rl = rl)
}

#' Model channels [screens, base_offs, 10, length(feats)] from roll_lane_features() output `rl`: distance, closing
#' and the validity flag, raw (standardisation happens in training), 0 wherever the slot is not valid. `feats` picks
#' the channels of the variant (B: all three; C: distance and validity).
roll_lane_base <- function(rl, feats = ROLL_FEATS) {
  d <- dim(rl$distance)
  arr <- array(0, c(d, length(feats)), dimnames = list(NULL, NULL, NULL, feats))
  src <- list(roll_distance_ft = rl$distance, roll_closing_fps = rl$closing, roll_lane_valid = rl$valid * 1)
  for (f in feats) {
    v <- src[[f]]
    v[!rl$valid | is.na(v)] <- 0
    arr[, , , f] <- v
  }
  arr
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - POP AND DRIVE OPTIONS AT ONE FRAME (runbook section 4) -----------------
## ═════════════════════════════════════════════════════════════════════════════

# Court (site frame, offense attacking +x, ft) and the option settings. Roster rows as in 02_build_sequences.R:
# 1 handler, 2 screener, 3 handler's defender, 4 screener's defender, 5-7 other attackers, 8-10 other defenders.
LANE_HALF_L <- 14 * 3.28084
LANE_HALF_W <- 7.5 * 3.28084
LANE_THREE_R <- 6.75 * 3.28084
LANE_THREE_Y <- 6.6 * 3.28084
POP_ANGLES <- c(-45, -20, 20, 45)  # degrees from the rim toward half court: wing, slot, slot, wing
POP_REACH <- 10                    # ft the screener may move to a spot
POP_OCCUPIED <- 5                  # ft: a spot with another attacker this close is taken
POP_PASS_CAP <- 15                 # ft: pass gap when no defender lies along the pass
DRIVE_STEP <- 5                    # ft toward the rim before a route bends
DRIVE_OFFSET <- 3                  # ft to the side of the straight lane
DRIVE_SIDE_MIN <- 1                # ft: below this the screener's side is unknown

#' The four pop spots, 1 ft beyond the arc. Fixed points, checked once to be in bounds and beyond the arc.
pop_spots <- function() {
  a <- POP_ANGLES * pi / 180
  s <- data.table(spot = seq_along(a), x = HOOP_X - (LANE_THREE_R + 1) * cos(a), y = (LANE_THREE_R + 1) * sin(a))
  dx <- HOOP_X - s$x
  beyond <- ifelse(dx <= sqrt(LANE_THREE_R^2 - LANE_THREE_Y^2), abs(s$y) >= LANE_THREE_Y, sqrt(dx^2 + s$y^2) >= LANE_THREE_R)
  stopifnot(all(beyond), all(s$x > 0 & s$x < LANE_HALF_L & abs(s$y) < LANE_HALF_W))
  s
}

#' The screener's pop option at one frame for n rows, from positions px, py [n, 10] (NA = not tracked). Spots within
#' POP_REACH ft of the screener and with no other attacker within POP_OCCUPIED ft are candidates; each gets the
#' nearest of the five defenders to the spot (catch gap) and the smallest perpendicular gap of a defender strictly
#' inside the pass from the handler to the spot (pass gap, POP_PASS_CAP when none). The kept spot has the largest
#' min(catch, pass); ties go to the shorter move, then the larger catch gap. Unknown when any of the ten is missing.
pop_option <- function(px, py) {
  n <- nrow(px)
  sp <- pop_spots()
  known <- rowSums(is.na(px) | is.na(py)) == 0
  ns <- nrow(sp)
  move <- catch <- pass <- matrix(NA_real_, n, ns)
  occ <- matrix(NA, n, ns)
  for (k in seq_len(ns)) {
    move[, k] <- sqrt((px[, 2] - sp$x[k])^2 + (py[, 2] - sp$y[k])^2)
    att <- sapply(c(1, 5, 6, 7), function(j) sqrt((px[, j] - sp$x[k])^2 + (py[, j] - sp$y[k])^2))
    occ[, k] <- rowSums(matrix(att, n) <= POP_OCCUPIED) > 0
    dd <- sapply(c(3, 4, 8, 9, 10), function(j) sqrt((px[, j] - sp$x[k])^2 + (py[, j] - sp$y[k])^2))
    catch[, k] <- apply(matrix(dd, n), 1, min)
    gp <- sapply(c(3, 4, 8, 9, 10), function(j) {
      s <- segment_distances(px[, j], py[, j], px[, 1], py[, 1], sp$x[k], sp$y[k])
      ifelse(!is.na(s$projection) & s$projection > 0 & s$projection < 1, s$distance, Inf)
    })
    pass[, k] <- pmin(POP_PASS_CAP, apply(matrix(gp, n), 1, min))
  }
  ok <- known & move <= POP_REACH & !occ
  ok[is.na(ok)] <- FALSE
  # Best candidate: largest min(catch, pass), then shorter move, then larger catch gap.
  best <- vapply(seq_len(n), function(i) {
    cand <- which(ok[i, ])
    if (!length(cand)) return(NA_integer_)
    cand[order(-pmin(catch[i, cand], pass[i, cand]), move[i, cand], -catch[i, cand])][1]
  }, NA_integer_)
  at <- cbind(seq_len(n), best)
  data.table(pop_known = known, pop_available = !is.na(best), pop_spot = best, pop_move = move[at], pop_catch = catch[at],
             pop_pass = pass[at], pop_n_reachable = rowSums(known & move <= POP_REACH, na.rm = TRUE),
             pop_n_occupied = rowSums(known & move <= POP_REACH & occ, na.rm = TRUE))
}

#' The handler's drive options at one frame for n rows, from positions px, py [n, 10]. Direct lane: handler to rim;
#' the handler's defender's gap (on-ball) and the smallest gap among the three off-ball defenders (help), plus the
#' screener's defender's gap and the on-ball defender's projection for audits. Routes: from the handler H, DRIVE_STEP
#' ft (at most half the way) toward the rim, then DRIVE_OFFSET ft to either side, then the rim. The route on the
#' screener's side of the straight lane is screen-side, the other the reject; unknown when the screener is within
#' DRIVE_SIDE_MIN ft of the lane's line. Per route: the on-ball defender's gap to the first leg and the smallest help
#' gap to either leg; valid when the bend is in bounds and the needed players are tracked.
drive_options <- function(px, py) {
  n <- nrow(px)
  need <- c(1, 3, 8, 9, 10)
  known <- rowSums(is.na(px[, need, drop = FALSE]) | is.na(py[, need, drop = FALSE])) == 0
  hx <- px[, 1]
  hy <- py[, 1]
  gap <- function(j, ax, ay, bx, by) segment_distances(px[, j], py[, j], ax, ay, bx, by)
  help_min <- function(f) apply(matrix(sapply(8:10, f), n), 1, min)
  on <- gap(3, hx, hy, HOOP_X, 0)
  direct_help <- help_min(function(j) gap(j, hx, hy, HOOP_X, 0)$distance)
  known <- known & !is.na(on$distance)
  # The two bends: unit direction (ex, ey) to the rim, its normal (nx, ny), and the screener's side of the lane.
  len <- sqrt((HOOP_X - hx)^2 + hy^2)
  ex <- (HOOP_X - hx) / len
  ey <- -hy / len
  nx <- -ey
  ny <- ex
  st <- pmin(DRIVE_STEP, len / 2)
  side <- (px[, 2] - hx) * nx + (py[, 2] - hy) * ny
  side_known <- known & !is.na(side) & abs(side) >= DRIVE_SIDE_MIN
  route <- function(sg) {
    wx <- hx + st * ex + sg * DRIVE_OFFSET * nx
    wy <- hy + st * ey + sg * DRIVE_OFFSET * ny
    inb <- !is.na(wx) & wx >= 0 & wx <= LANE_HALF_L & abs(wy) <= LANE_HALF_W
    onb <- gap(3, hx, hy, wx, wy)$distance
    hl <- help_min(function(j) pmin(gap(j, hx, hy, wx, wy)$distance, gap(j, wx, wy, HOOP_X, 0)$distance))
    list(onball = onb, help = hl, inb = inb)
  }
  rp <- route(1)
  rmn <- route(-1)
  scr_plus <- !is.na(side) & side > 0
  pick <- function(a, b) ifelse(scr_plus, a, b)
  scr <- list(onball = pick(rp$onball, rmn$onball), help = pick(rp$help, rmn$help), inb = pick(rp$inb, rmn$inb))
  rej <- list(onball = pick(rmn$onball, rp$onball), help = pick(rmn$help, rp$help), inb = pick(rmn$inb, rp$inb))
  scr_valid <- side_known & scr$inb & !is.na(scr$onball) & !is.na(scr$help)
  rej_valid <- side_known & rej$inb & !is.na(rej$onball) & !is.na(rej$help)
  na_if <- function(v, ok) ifelse(ok, v, NA_real_)
  data.table(drv_known = known, drv_direct_onball = na_if(on$distance, known), drv_direct_help = na_if(direct_help, known),
             drv_direct_onball_proj = na_if(on$projection, known), drv_direct_sd = gap(4, hx, hy, HOOP_X, 0)$distance,
             drv_side_known = side_known, drv_side_ft = side,
             drv_screen_valid = scr_valid, drv_screen_onball = na_if(scr$onball, scr_valid), drv_screen_help = na_if(scr$help, scr_valid),
             drv_reject_valid = rej_valid, drv_reject_onball = na_if(rej$onball, rej_valid), drv_reject_help = na_if(rej$help, rej_valid))
}
