# Step 10 of the rebounding manual: opportunity quality and its decomposition. Q_i(state; B) is a player's expected
# chance of reaching the ball over a ball distribution B (particles with an absolute frame, a floor position and a
# height): the mean over particles of a logistic in his arrival margin (Step 08 rule), as in the Spearman-style
# control probability of LaurieOnTracking's probability_intercept_ball (MIT, adapted). Because times are absolute, one
# distribution can be scored from two player states, which separates movement from information. Settings:
# config/experiment.yaml (step10). Requires geometry.R (FPS), reach.R (arrival_time, height_cost).

#' Q of every player at frame t0 against particles (bx, by, z, frame).
opportunity <- function(st, t0, parts, rp, sigma) {
  avail <- (parts$frame - t0) / FPS
  M <- vapply(seq_len(nrow(parts)), function(k)
    avail[k] - arrival_time(st$x, st$y, st$vx, st$vy, parts$bx[k], parts$by[k], rp) - height_cost(parts$z[k], rp),
              numeric(nrow(st)))
  M <- matrix(M, nrow = nrow(st))
  P <- 1 / (1 + exp(-pi / sqrt(3) / sigma * M))
  data.table(pid = st$pid, Q = rowMeans(P))
}

#' Movement / information decomposition of one episode's players.
#' @param s_r,s_t player states (pid, x, y, vx, vy) at release frame t_r and later frame t_t; s_base the damped
#'   "ignores the ball" forecast of s_r at t_t; B_ref the reference distribution, B_t the updated one (or NULL).
#' @return pid, Q values and total, move, info, interaction, vs_baseline (info and interaction NA without B_t).
decompose_opportunity <- function(s_r, t_r, s_t, t_t, s_base, B_ref, B_t, rp, sigma) {
  q <- function(st, t0, B, nm) setnames(opportunity(st, t0, B, rp, sigma), "Q", nm)
  d <- Reduce(function(a, b) merge(a, b, by = "pid"),
              list(q(s_r, t_r, B_ref, "q_release_ref"), q(s_t, t_t, B_ref, "q_later_ref"), q(s_base, t_t, B_ref, "q_baseline_ref")))
  if (!is.null(B_t) && nrow(B_t)) {
    d <- Reduce(function(a, b) merge(a, b, by = "pid"), list(d, q(s_r, t_r, B_t, "q_release_upd"), q(s_t, t_t, B_t, "q_later_upd")))
  } else d[, c("q_release_upd", "q_later_upd") := NA_real_]
  d[, `:=`(move = q_later_ref - q_release_ref, info = q_release_upd - q_release_ref, total = q_later_upd - q_release_ref,
           vs_baseline = q_later_ref - q_baseline_ref)]
  d[, interaction := total - move - info]
  d[]
}

#' The damped forecast of a player state over tau seconds (Step 08): position by forecast_position(), velocity
#' damped by exp(-lambda tau).
damped_state <- function(st, tau, lambda, vmax) {
  f <- forecast_position(st$x, st$y, st$vx, st$vy, tau, "damped", lambda, vmax)
  data.table(pid = st$pid, x = f$x, y = f$y, vx = st$vx * exp(-lambda * tau), vy = st$vy * exp(-lambda * tau))
}
