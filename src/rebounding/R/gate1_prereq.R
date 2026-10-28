# Checks a path-departure detector for contacts and touches depends on, run before Gate 1 of the gated rebound
# roadmap: does free flight fall at gravity, how large is the leftover noise, how regular are the vendor's
# measured frames, is the interpolation test sound, how far apart are ball and players, and where is the floor.
# Ball positions are the rotated raw track of audit.R (offense attacking +x, ball frame); players are rotated
# tracking positions. Requires geometry.R, audit.R (ball_track), bundle.R (to_player_frame).

FLIGHT_SKIP <- 2L        # frames after release before the ball is taken to be free of the hand
FLIGHT_STOP <- 2L        # frames before contact (or the shot's end) where the free-flight segment stops
FLIGHT_MIN_KEYS <- 6L    # measured frames a segment needs to be fitted

#' One shot's free flight from release to just before contact: a quadratic in time per axis, fitted to the
#' vendor's measured frames only. Returns the fitted accelerations, residual spreads and per-frame residuals.
flight_fit <- function(raw, s, stop_frame) {
  w <- ball_track(raw$frames, s, s$f0 + FLIGHT_SKIP - 1L, stop_frame + 1L)
  k <- w[frame >= s$f0 + FLIGHT_SKIP & frame <= stop_frame & !is.na(x) & !(interp %in% TRUE)]
  if (nrow(k) < FLIGHT_MIN_KEYS || anyNA(w[frame >= s$f0 + FLIGHT_SKIP & frame <= stop_frame]$x)) return(NULL)
  t <- (k$frame - mean(k$frame)) / FPS
  fit <- function(v) lm.fit(cbind(1, t, t^2), v)
  fx <- fit(k$x); fy <- fit(k$y); fz <- fit(k$z)
  n <- nrow(k)
  sdr <- function(f) sqrt(sum(f$residuals^2) / (n - 3))
  # the same height curve with gravity fixed: how much worse is it than the free fit?
  zg <- k$z + 0.5 * GRAVITY * t^2
  fg <- lm.fit(cbind(1, t), zg)
  res <- data.table(frame = k$frame, rx = fx$residuals, ry = fy$residuals, rz = fz$residuals, berr = k$berr, z = k$z)
  list(row = data.table(shot_id = s$shot_id, game_id = s$game_id, left_hoop = s$left_hoop, made = s$made, n_keys = n,
                        span_s = diff(range(k$frame)) / FPS, z_max = max(k$z),
                        g_fit = -2 * fz$coefficients[3], ax_fit = 2 * fx$coefficients[3], ay_fit = 2 * fy$coefficients[3],
                        sd_x = sdr(fx), sd_y = sdr(fy), sd_z = sdr(fz),
                        sd_z_fixed_g = sqrt(sum(fg$residuals^2) / (n - 2)), berr_mean = mean(k$berr)),
       residuals = res[, shot_id := s$shot_id])
}

#' Gaps between consecutive measured (non-interpolated) ball frames in one window, with whether the gap ends
#' near the rim (within 3 ft of the calibrated hoop horizontally and above 8 ft). `tol` is the midpoint tolerance
#' that marks a frame as interpolated (audit.R uses 0.015 ft).
keyframe_gaps <- function(raw, s, from, to, hoop, tol = 0.015) {
  w <- ball_track(raw$frames, s, from, to)
  w[, interp := abs(x - (shift(x) + shift(x, -1L)) / 2) < tol & abs(z - (shift(z) + shift(z, -1L)) / 2) < tol]
  w <- w[!is.na(x)]
  k <- w[!(interp %in% TRUE)]
  if (nrow(k) < 2L) return(NULL)
  data.table(game_id = s$game_id, shot_id = s$shot_id, gap = diff(k$frame), parity = k$frame[-1] %% 2L,
             near_rim = (sqrt((k$x[-1] - hoop$hx)^2 + (k$y[-1] - hoop$hy)^2) < 3 & k$z[-1] > 8))
}

#' How far each tracked ball frame is from the midpoint of its two neighbours, per axis (the interpolation test
#' of audit.R uses x and z with a 0.015 ft tolerance).
midpoint_deviation <- function(raw, s, from, to) {
  w <- raw$frames[frame >= from & frame <= to][order(frame)]
  ok <- !is.na(w$bx) & !is.na(shift(w$bx)) & !is.na(shift(w$bx, -1L)) &
    shift(w$frame) == w$frame - 1L & shift(w$frame, -1L) == w$frame + 1L
  mid <- function(v) abs(v - (shift(v) + shift(v, -1L)) / 2)
  data.table(game_id = s$game_id, dx = mid(w$bx), dy = mid(w$by), dz = mid(w$bz))[ok %in% TRUE]
}

#' Ball to credited rebounder, horizontally, in the raw ball frame and shifted to the player frame, from the
#' contact (or the shot's end) to 0.4 s after the rebound frame; plus the first-touch rule on both.
reach_geometry <- function(raw, s, hoop) {
  start <- fcoalesce(s$contact_frame, s$f1)
  w <- ball_track(raw$frames, s, start, s$rf + 10L)[!is.na(x)]
  if (!nrow(w)) return(NULL)
  pf <- to_player_frame(w$x - hoop$hx, w$y - hoop$hy, w$z, hoop)
  w[, c("xp", "yp") := .(pf$x, pf$y)]
  pl <- window_players(raw, s, w$frame)
  j <- merge(pl[, .(frame, pid, px, py)], w[, .(frame, x, y, z, xp, yp, interp)], by = "frame")
  j[, d_raw := sqrt((px - x)^2 + (py - y)^2)]
  j[, d_cor := sqrt((px - xp)^2 + (py - yp)^2)]
  first_touch <- function(d) {
    near <- j[j[, .I[which.min(get(d))], by = frame]$V1][order(frame)]
    hit <- near[get(d) <= TOUCH_DIST & z <= REACH_Z]
    if (nrow(hit)) hit$frame[1] else NA_integer_
  }
  r <- j[pid == s$rpid]
  at_rf <- r[frame == s$rf]
  best <- if (nrow(r)) r[which.min(d_cor)] else NULL
  data.table(shot_id = s$shot_id, game_id = s$game_id, defensive = s$defensive,
             d_raw_rf = if (nrow(at_rf)) at_rf$d_raw else NA_real_, d_cor_rf = if (nrow(at_rf)) at_rf$d_cor else NA_real_,
             z_rf = if (nrow(at_rf)) at_rf$z else NA_real_,
             min_d_raw = if (nrow(r)) min(r$d_raw) else NA_real_, min_d_cor = if (nrow(r)) min(r$d_cor) else NA_real_,
             z_at_min = if (!is.null(best)) best$z else NA_real_,
             touch_raw = first_touch("d_raw"), touch_cor = first_touch("d_cor"))
}

#' Local minima of ball height on measured frames after contact: floor bounces (and dribbles), with the drop
#' that led into each.
floor_minima <- function(raw, s, hoop) {
  start <- fcoalesce(s$contact_frame, s$f1)
  w <- ball_track(raw$frames, s, start, s$rf + WINDOW_AFTER)[!is.na(x) & !(interp %in% TRUE)]
  if (nrow(w) < 7L) return(NULL)
  i <- which(w$z < 2.5 & w$z <= shift(w$z) & w$z <= shift(w$z, -1L) & shift(w$z, 3L) >= w$z + 1.5)
  if (!length(i)) return(NULL)
  data.table(game_id = s$game_id, shot_id = s$shot_id, z = w$z[i], frame = w$frame[i], berr = w$berr[i])
}
