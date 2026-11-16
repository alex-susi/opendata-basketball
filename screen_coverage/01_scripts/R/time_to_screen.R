# Step 1 of the two-step coverage model (owner, 2026-11-15): how long until the screen, from past frames only.
# Used by 17_time_to_screen.R. The target is the time until the pick frame (picks.frame, the dashed Pick line), in
# seconds; negative once the pick frame has passed.
#
# Inputs at a prediction frame use the cached movement array (02_build_sequences.R) at that frame, 0.2 s and 0.4 s
# earlier, for the ball handler (row 1) and the screener (row 2), plus the context columns already given to the live
# model (time to act, contact memory). Two physics estimates:
#   stop   time for the screener to stop if he keeps slowing at the same rate: speed / deceleration. 0 when he is
#          already nearly still; capped (and flagged 0) when he is moving and not slowing.
#   meet   time for the handler-screener gap to close to the typical gap at the pick frame, solving
#          gap - contact gap = closing speed x t + 1/2 x closing acceleration x t^2 for the first positive t; capped
#          (and flagged 0) when there is no positive solution (not closing, or already past).

suppressPackageStartupMessages(library(data.table))

TTS_CAP <- 3              # seconds: the value given when an equation has no answer, and the most either can say
TTS_STILL <- 2            # ft/s: a screener slower than this counts as already set (stop time 0)
TTS_SLOWING <- -1         # ft/s^2: deceleration needed before the stop equation is used
TTS_QUANTILES <- c(0.1, 0.5, 0.9)
TTS_PHYSICS <- c("t_stop", "stop_ok", "t_meet", "meet_ok")
TTS_LEARNED <- c("t_q50", "t_spread")

#' Per-row inputs for step 1 (rows of X: screen `idx`, frame offset `off`), from the sequence cache SQ. Physics
#' estimates are added separately (tts_physics), since the meet equation needs a contact gap set from training games.
tts_inputs <- function(SQ, idx, off) {
  B <- SQ$base
  bo <- SQ$base_offs
  step <- SQ$step
  fps <- 25
  g <- function(o, j, v) B[cbind(idx, match(o, bo), j, match(v, SQ$feats))]
  gap <- function(o) {
    ok <- g(o, 1, "present") == 1 & g(o, 2, "present") == 1
    ifelse(ok, sqrt((g(o, 1, "x") - g(o, 2, "x"))^2 + (g(o, 1, "y") - g(o, 2, "y"))^2), NA_real_)
  }
  # Speed away from the hoop (+) or toward it (-).
  hoop_x <- (14 - 1.575) * 3.28084
  radial <- function(o, j) {
    x <- g(o, j, "x")
    y <- g(o, j, "y")
    -((hoop_x - x) * g(o, j, "vx") - y * g(o, j, "vy")) / pmax(sqrt((hoop_x - x)^2 + y^2), 1e-6)
  }
  d0 <- gap(off)
  d1 <- gap(off - step)
  d2 <- gap(off - 2L * step)
  close_v <- (d1 - d0) / (step / fps)
  close_v1 <- (d2 - d1) / (step / fps)
  ctx <- SQ$ctx
  data.table(gap = d0, close_v = close_v, close_a = (close_v - close_v1) / (step / fps),
             s_speed = g(off, 2, "speed"), s_accel = g(off, 2, "accel"), s_speed_02 = g(off - step, 2, "speed"),
             s_rad = radial(off, 2), h_speed = g(off, 1, "speed"), h_accel = g(off, 1, "accel"), h_rad = radial(off, 1),
             s_present = g(off, 2, "present"), h_present = g(off, 1, "present"),
             tta_now = ctx[, "tta_now"], hs_min = ctx[, "hs_min"], since_hs_min = ctx[, "since_hs_min"])
}

#' The two physics estimates for rows `D` (tts_inputs) with the contact gap `contact_ft`.
tts_physics <- function(D, contact_ft) {
  # Stop: speed / deceleration while slowing; 0 when already nearly still; capped when moving and not slowing.
  sp <- D$s_speed
  ac <- D$s_accel
  still <- D$s_present == 1 & sp < TTS_STILL
  slowing <- D$s_present == 1 & !still & ac < TTS_SLOWING
  t_stop <- ifelse(still, 0, ifelse(slowing, pmin(TTS_CAP, sp / -ac), TTS_CAP))
  # Meet: first positive root of 1/2 a t^2 + v t - (gap - contact) = 0.
  rest <- D$gap - contact_ft
  v <- D$close_v
  a <- D$close_a
  root <- rep(NA_real_, nrow(D))
  done <- !is.na(rest) & rest <= 0
  root[done] <- 0
  lin <- !done & !is.na(rest) & !is.na(a) & abs(a) < 1e-6 & v > 0
  root[lin] <- rest[lin] / v[lin]
  quad <- !done & !lin & !is.na(rest) & !is.na(a) & abs(a) >= 1e-6
  disc <- v^2 + 2 * a * rest
  r1 <- (-v + sqrt(pmax(disc, 0))) / a
  r2 <- (-v - sqrt(pmax(disc, 0))) / a
  first <- function(p, q) {
    p[!is.finite(p) | p <= 0] <- Inf
    q[!is.finite(q) | q <= 0] <- Inf
    pmin(p, q)
  }
  rq <- first(r1, r2)
  ok_q <- quad & disc >= 0 & is.finite(rq)
  root[ok_q] <- rq[ok_q]
  meet_ok <- !is.na(root) & root <= TTS_CAP
  data.table(t_stop = t_stop, stop_ok = as.numeric(still | slowing), t_meet = ifelse(meet_ok, root, TTS_CAP),
             meet_ok = as.numeric(meet_ok))
}

#' Fit the learned step 1 (xgboost, three quantiles of the time until the pick frame) on rows `tr` of the input table
#' `F` with targets `y`; returns a function predicting [n x 2]: the median and the 10-90% spread.
tts_fit <- function(F, y, tr, nrounds = 300L) {
  d <- xgboost::xgb.DMatrix(as.matrix(F[tr]), label = y[tr], missing = NA)
  m <- xgboost::xgb.train(params = list(objective = "reg:quantileerror", quantile_alpha = TTS_QUANTILES, max_depth = 4,
                                        eta = 0.05, subsample = 0.8, colsample_bynode = 0.8, min_child_weight = 20,
                                        nthread = 2),
                          data = d, nrounds = nrounds, verbose = 0)
  function(rows) {
    p <- predict(m, xgboost::xgb.DMatrix(as.matrix(F[rows]), missing = NA))
    p <- t(apply(p, 1, sort))     # quantiles can cross; keep them ordered
    cbind(t_q50 = p[, 2], t_spread = p[, 3] - p[, 1], t_q10 = p[, 1], t_q90 = p[, 3])
  }
}
