# Step 02, labeler v2: per-frame tracking features for a hidden Markov model of the ball after a missed shot.
# One row per frame at 25 Hz from release + skip_after_release to the credited rebound + window_after_rebound. Ball
# features are computed on measured ball frames only; filled-in (midpoint) frames and frames without a ball keep NA,
# which the model treats as missing. Settings: config/experiment.yaml (step02_v2$features, step02$detector).
# Requires geometry.R, audit.R, bundle.R, contact_states.R (contact_track, arc_predict, window_players).

HMM_FEATURES <- c("z", "vz", "log_resid", "log_hspeed", "log_hoop", "log_near", "log_gap", "log_relspeed",
                  "log_dv", "turn_deg", "speed_ratio", "v_to_hoop", "board_face")

#' Velocity at time t0 from measured points (x, y linear; z ballistic with fixed g). Needs at least two points.
fit_velocity <- function(t, x, y, z, t0, g) {
  X <- cbind(1, t - t0)
  bx <- qr.solve(X, x)
  by <- qr.solve(X, y)
  bz <- qr.solve(X, z + 0.5 * g * (t - t0)^2)
  c(bx[2], by[2], bz[2])
}

#' Per-frame features of one episode. Returns a data.table with frame, the HMM_FEATURES, the nearest and second
#' nearest player (id, offence flag, detected flag) and the ball position, for decoding.
episode_features <- function(raw, s, hoop, th, fv) {
  last <- s$rf + th$window_after_rebound
  start <- s$f0 + th$skip_after_release
  tr <- contact_track(raw, s, s$f0, last, hoop, th$keyframe_tol_ft)
  g <- th$g_track_ft_s2
  off <- fv$log_offsets
  k <- tr[key == TRUE]
  n <- nrow(k)
  feat <- data.table(frame = k$frame)
  # Velocities from local arc fits, and each keyframe's residual against the arc through its neighbours.
  if (n >= 2L * fv$dv_keys + 1L) {
    vel <- t(vapply(seq_len(n), function(i) {
      idx <- max(1L, i - fv$smooth_keys):min(n, i + fv$smooth_keys)
      if (length(idx) < 3L) return(rep(NA_real_, 3))
      fit_velocity(k$t[idx], k$x[idx], k$y[idx], k$z[idx], k$t[i], g)
    }, numeric(3)))
    resid <- vapply(seq_len(n), function(i) {
      if (i <= 3L) return(NA_real_)
      idx <- max(1L, i - fv$resid_keys):(i - 1L)
      p <- arc_predict(k$t[idx], k$x[idx], k$y[idx], k$z[idx], k$t[i], g)
      sqrt((p[1] - k$x[i])^2 + (p[2] - k$y[i])^2 + (p[3] - k$z[i])^2)
    }, 0)
    dvm <- t(vapply(seq_len(n), function(i) {
      b <- (i - fv$dv_keys):i
      a <- i:(i + fv$dv_keys)
      if (b[1] < 1L || a[length(a)] > n) return(rep(NA_real_, 3))
      vb <- fit_velocity(k$t[b], k$x[b], k$y[b], k$z[b], k$t[i], g)
      va <- fit_velocity(k$t[a], k$x[a], k$y[a], k$z[a], k$t[i], g)
      sb <- sqrt(sum(vb^2))
      sa <- sqrt(sum(va^2))
      c(sqrt(sum((va - vb)^2)), acos(pmin(1, pmax(-1, sum(va * vb) / max(1e-9, sa * sb)))) * 180 / pi,
        log(sa + off$hspeed) - log(sb + off$hspeed))
    }, numeric(3)))
    dx <- k$x - hoop$hx
    dy <- k$y - hoop$hy
    dh <- sqrt(dx^2 + dy^2)
    feat[, `:=`(z = k$z, vz = vel[, 3], log_resid = log(resid + off$resid),
                log_hspeed = log(sqrt(vel[, 1]^2 + vel[, 2]^2) + off$hspeed), log_hoop = log(dh + off$hoop),
                log_dv = log(dvm[, 1] + off$dv), turn_deg = dvm[, 2], speed_ratio = dvm[, 3],
                v_to_hoop = -(vel[, 1] * dx + vel[, 2] * dy) / pmax(dh, 0.1),
                board_face = pmin(fv$board_clip_ft[2], pmax(fv$board_clip_ft[1], (BOARD_X - RIM_X) - dx)),
                bvx = vel[, 1], bvy = vel[, 2], xp = k$xp, yp = k$yp, hoop_ft = dh)]
  } else feat[, (c(HMM_FEATURES, "bvx", "bvy", "xp", "yp", "hoop_ft")) := NA_real_]
  # players: nearest two to the ball (player frame), with velocity from neighbouring frames
  pl <- window_players(raw, s, unique(c(k$frame - 1L, k$frame, k$frame + 1L)))
  setorder(pl, pid, frame)
  pl[, c("pvx", "pvy") := .((shift(px, -1L) - shift(px)) * FPS / 2, (shift(py, -1L) - shift(py)) * FPS / 2), by = pid]
  j <- merge(pl[frame %in% k$frame, .(frame, pid, off, det, px, py, pvx, pvy)],
             feat[, .(frame, xp, yp, bvx, bvy)], by = "frame")
  j[, d := sqrt((px - xp)^2 + (py - yp)^2)]
  setorder(j, frame, d)
  nr <- j[, .(near_id = pid[1], near_off = off[1], near_det = det[1], near_ft = d[1],
              second_id = if (.N > 1L) pid[2] else NA_integer_, second_ft = if (.N > 1L) d[2] else NA_real_,
              rel = sqrt((bvx[1] - pvx[1])^2 + (bvy[1] - pvy[1])^2)), by = frame]
  feat <- merge(feat, nr, by = "frame", all.x = TRUE)
  feat[, `:=`(log_near = log(near_ft + off$near), log_gap = log(pmax(0, second_ft - near_ft) + off$gap),
              log_relspeed = log(rel + off$relspeed))]
  # the 25 Hz grid: every frame in the window, measured-frame features only
  grid <- data.table(frame = start:last)
  feat <- merge(grid, feat[frame >= start], by = "frame", all.x = TRUE)
  feat[, `:=`(shot_id = s$shot_id, game_id = s$game_id, rel_frame = frame - s$f0)]
  feat[]
}
