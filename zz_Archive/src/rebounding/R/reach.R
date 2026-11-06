# Step 08 of the rebounding manual: who could reach the ball, and how early. Arrival time follows the pitch-control
# rule of LaurieOnTracking's simple_time_to_intercept (MIT, adapted): keep the current velocity for the reaction
# time, then run straight at v_max; here the player only has to get within the catch radius of the ball's floor
# position. Height is a broad envelope, never the tracked player z (always 0): a ball at or below the standing reach
# needs no jump, one up to the jump reach needs the takeoff time as well, and one above it cannot be reached.
# Settings: config/experiment.yaml (step08$reach). Requires geometry.R, audit.R (ball_track, hoop_dist), extract.R.

#' Seconds until a player (position p, velocity v; vectors over players) can be within the catch radius of a
#' target floor point.
arrival_time <- function(px, py, vx, vy, tx, ty, rp) {
  rx <- px + vx * rp$reaction_s; ry <- py + vy * rp$reaction_s
  rp$reaction_s + pmax(0, sqrt((tx - rx)^2 + (ty - ry)^2) - rp$catch_radius_ft) / rp$v_max
}

#' Extra time a ball height needs: 0 up to the standing reach, the takeoff time up to the jump reach, Inf above.
height_cost <- function(z, rp) fifelse(z <= rp$standing_reach_ft, 0, fifelse(z <= rp$jump_reach_ft, rp$takeoff_s, Inf))

#' Margins of every player against a ball path from origin t: for each player and path frame f, the time the ball is
#' there minus the player's arrival (with the height cost). A player's margin is the best over the path, with the
#' frame it happens at and the first frame the margin is non-negative.
#' @param st players at t: pid, off, x, y, vx, vy. @param path ball frames: frame, bx, by (player frame), z.
player_margins <- function(st, path, t, rp) {
  if (!nrow(path)) return(st[, .(pid, off, margin = -Inf, best_frame = NA_integer_, first_feasible = NA_integer_)])
  avail <- (path$frame - t) / FPS
  M <- vapply(seq_len(nrow(path)), function(k)
    avail[k] - arrival_time(st$x, st$y, st$vx, st$vy, path$bx[k], path$by[k], rp) - height_cost(path$z[k], rp),
    numeric(nrow(st)))
  M <- matrix(M, nrow = nrow(st))
  best <- apply(M, 1, max)
  data.table(pid = st$pid, off = st$off, margin = best,
             best_frame = path$frame[apply(M, 1, which.max)],
             first_feasible = vapply(seq_len(nrow(st)), function(i) { j <- which(M[i, ] >= 0)[1]; if (is.na(j)) NA_integer_ else path$frame[j] }, 0L))
}

#' Point where every made shot crosses rim height on the way down (attack frame), per camera end (audit.R's
#' hoop_calibration, kept per shot so folds can pool their own training games).
made_crossings <- function(raw, g) {
  sh <- raw$shots[made == TRUE & !is.na(f0) & !is.na(f1)]
  rbindlist(lapply(seq_len(nrow(sh)), function(k) {
    s <- sh[k]; w <- ball_track(raw$frames, s, s$f0, s$f1 + MADE_AFTER)
    if (nrow(w) < 5L) return(NULL)
    i <- which(w$z[-1] < RIM_Z & w$z[-nrow(w)] >= RIM_Z & hoop_dist(w$x[-1], w$y[-1]) < 4)
    if (!length(i)) return(NULL)
    i <- i[1]; a <- (w$z[i] - RIM_Z) / (w$z[i] - w$z[i + 1])
    data.table(game_id = g, left_hoop = s$left_hoop, x = w$x[i] + a * (w$x[i + 1] - w$x[i]), y = w$y[i] + a * (w$y[i + 1] - w$y[i]))
  }))
}
