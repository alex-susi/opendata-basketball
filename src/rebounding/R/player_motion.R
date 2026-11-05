# Step 08 of the rebounding manual: player velocity from positions up to t only, short-range movement forecasts
# (stationary, constant velocity, damped velocity, damped with speed and displacement bounds) and the speed and
# acceleration limits they respect. Settings: config/experiment.yaml (step08). Velocity smoothing follows the idea
# of LaurieOnTracking's Metrica_Velocities.py (MIT) but uses a trailing window, because a centred filter would read
# frames after t. The damped extrapolation follows ReboundingPrediction's derived.py idea (no licence; written
# independently). Requires geometry.R (FPS).

#' Causal velocity of every player at every frame: least-squares slope of x and y on time over the last `window`
#' frames up to that frame. Detected positions only when at least `min_det` of them are in the window; otherwise all
#' positions, flagged. Frames whose window is broken by a gap get NA.
#' @param pl one episode's rows: frame, pid, x, y, det.
causal_velocity <- function(pl, window, min_det) {
  d <- pl[order(pid, frame)]
  d[, t := (frame - min(frame)) / FPS]              # centred on the window's start: no cancellation in the sums
  roll <- function(v) frollsum(v, window, align = "right")
  d[, `:=`(span_ok = (frame - shift(frame, window - 1L)) == window - 1L), by = pid]
  for (w in c("all", "det")) {
    d[, wt := if (w == "all") 1 else as.numeric(det == 1L)]
    d[, paste0(c("n_", "st_", "sx_", "sy_", "stt_", "stx_", "sty_"), w) := {
      .(roll(wt), roll(wt * t), roll(wt * x), roll(wt * y), roll(wt * t^2), roll(wt * t * x), roll(wt * t * y))
    }, by = pid]
  }
  slope <- function(n, st, sv, stt, stv) (n * stv - st * sv) / (n * stt - st^2)
  d[, use_det := n_det >= min_det]
  d[, `:=`(vx = fifelse(use_det, slope(n_det, st_det, sx_det, stt_det, stx_det), slope(n_all, st_all, sx_all, stt_all, stx_all)),
           vy = fifelse(use_det, slope(n_det, st_det, sy_det, stt_det, sty_det), slope(n_all, st_all, sy_all, stt_all, sty_all)))]
  d[span_ok %in% FALSE | is.na(span_ok), c("vx", "vy") := NA_real_]
  d[, `:=`(speed = sqrt(vx^2 + vy^2), vel_from = fifelse(use_det, "detected", "extrapolated"))]
  d[, c("ax", "ay", "a_ok") := .((vx - shift(vx, window)) / (window / FPS), (vy - shift(vy, window)) / (window / FPS),
                                 (frame - shift(frame, window)) == window), by = pid]
  d[!(a_ok %in% TRUE), c("ax", "ay") := NA_real_]
  d[, accel := sqrt(ax^2 + ay^2)]
  d[, .(frame, pid, x, y, det, vx, vy, speed, accel, vel_from)]
}

MOVE_MODELS <- c("stationary", "constant_velocity", "damped", "bounded")

#' Forecast positions tau seconds ahead under one movement model (vectors over players).
forecast_position <- function(x, y, vx, vy, tau, model, lambda = 2, vmax = Inf) {
  switch(model,
    stationary = list(x = x, y = y),
    constant_velocity = list(x = x + vx * tau, y = y + vy * tau),
    damped = { k <- (1 - exp(-lambda * tau)) / lambda; list(x = x + vx * k, y = y + vy * k) },
    bounded = {
      sp <- sqrt(vx^2 + vy^2); s <- pmin(1, vmax / pmax(sp, 1e-9))
      k <- (1 - exp(-lambda * tau)) / lambda
      dx <- vx * s * k; dy <- vy * s * k; dd <- sqrt(dx^2 + dy^2); c2 <- pmin(1, vmax * tau / pmax(dd, 1e-9))
      list(x = x + dx * c2, y = y + dy * c2)
    },
    stop("unknown movement model ", model))
}

#' Speed and acceleration limits: high quantiles over detected frames with a valid causal velocity.
estimate_limits <- function(v, q = 0.995) {
  d <- v[det == 1L & !is.na(speed)]
  list(v_max = unname(quantile(d$speed, q)), a_max = unname(quantile(d[!is.na(accel)]$accel, q)), n = nrow(d))
}

#' Damping rate with the smallest mean forecast error over training rows (origin states and targets).
#' @param rows x, y, vx, vy, tau, tx, ty.
select_damping <- function(rows, grid) {
  e <- vapply(grid, function(l) { f <- forecast_position(rows$x, rows$y, rows$vx, rows$vy, rows$tau, "damped", l)
    mean(sqrt((f$x - rows$tx)^2 + (f$y - rows$ty)^2)) }, 0)
  list(lambda = grid[which(e == min(e))[1]], errors = data.table(lambda = grid, mean_error = e))
}
