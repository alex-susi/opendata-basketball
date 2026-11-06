# Step 06 of the rebounding manual: a causal Kalman filter for the ball's position and velocity. State
# (x, y, z, vx, vy, vz) in the attack frame, feet and seconds; constant velocity with gravity as a known input on z and
# white-noise acceleration q on every axis; dt from actual frame differences, so gaps and filled frames are crossed
# in one prediction. Settings: config/experiment.yaml (step06). The filter equations follow the standard linear
# Kalman filter (Joseph-form update), as in rlabbe/filterpy and Kalman-and-Bayesian-Filters-in-Python (MIT; ideas,
# written independently in R).
#
# Online use: at frame t the filter has used only observations usable by t (Step 03: measured frame f from f + 1)
# and is predicted to t. predict_state() and update_state() are the step interfaces; run_filter() replays a track.
# Requires geometry.R (FPS).

H_OBS <- cbind(diag(3), matrix(0, 3, 3))

transition <- function(dt) { Fm <- diag(6); Fm[cbind(1:3, 4:6)] <- dt; Fm }
gravity_offset <- function(dt, g) c(0, 0, -0.5 * g * dt^2, 0, 0, -g * dt)
process_cov <- function(dt, q) {
  b <- q * matrix(c(dt^3 / 3, dt^2 / 2, dt^2 / 2, dt), 2)
  Q <- matrix(0, 6, 6)
  for (a in 1:3) Q[c(a, a + 3), c(a, a + 3)] <- b
  Q
}

#' A new state from the first observation: position observed, velocity diffuse.
#' @param par list(r = per-axis observation sd, g, q, v_sd).
filter_init <- function(frame, z, par) {
  list(frame = frame, m = c(z, 0, 0, 0), P = diag(c(par$r^2, rep(par$v_sd^2, 3))), n_obs = 1L, loglik = 0)
}

#' Predict the state forward to `frame` (no change when it is not later).
predict_state <- function(state, frame, par) {
  dt <- (frame - state$frame) / FPS
  if (dt <= 0) return(state)
  Fm <- transition(dt)
  state$m <- as.vector(Fm %*% state$m) + gravity_offset(dt, par$g)
  state$P <- Fm %*% state$P %*% t(Fm) + process_cov(dt, par$q)
  state$frame <- frame
  state
}

#' Update with one measured position at the state's frame (Joseph form, so P stays symmetric positive definite).
#' Adds the innovation's Gaussian log-likelihood and its normalised squared size (NIS) to the state.
update_state <- function(state, z, par) {
  R <- diag(par$r^2)
  nu <- z - state$m[1:3]
  S <- state$P[1:3, 1:3] + R
  Si <- solve(S)
  K <- state$P[, 1:3] %*% Si
  IKH <- diag(6) - K %*% H_OBS
  state$m <- state$m + as.vector(K %*% nu)
  state$P <- IKH %*% state$P %*% t(IKH) + K %*% R %*% t(K)
  state$P <- (state$P + t(state$P)) / 2
  nis <- as.numeric(t(nu) %*% Si %*% nu)
  state$last_nis <- nis
  state$loglik <- state$loglik - 0.5 * (nis + log(det(S)) + 3 * log(2 * pi))
  state$n_obs <- state$n_obs + 1L
  state
}

#' Forecast of the observed position h frames after the state's frame: mean and covariance (including observation
#' noise, so it is the predictive distribution of the next measurement).
forecast_state <- function(state, h, par) {
  s <- predict_state(state, state$frame + h, par)
  list(mean = s$m[1:3], cov = s$P[1:3, 1:3] + diag(par$r^2))
}

#' Replay one ball track causally. `obs`: measured frames (frame, x, y, z, usable_from). At every origin frame t in
#' `origins` the state has used exactly the observations with usable_from <= t and is predicted to t.
#' @return list(states = list per origin (NULL before the first observation), innov = data.table of updates).
run_filter <- function(obs, origins, par) {
  obs <- obs[order(frame)]
  st <- NULL; k <- 1L; out <- vector("list", length(origins)); inn <- list()
  for (j in seq_along(origins)) {
    t <- origins[j]
    while (k <= nrow(obs) && obs$usable_from[k] <= t) {
      z <- c(obs$x[k], obs$y[k], obs$z[k])
      if (is.null(st)) st <- filter_init(obs$frame[k], z, par) else {
        st <- update_state(predict_state(st, obs$frame[k], par), z, par)
        inn[[length(inn) + 1L]] <- data.table(frame = obs$frame[k], nis = st$last_nis, n_obs = st$n_obs)
      }
      k <- k + 1L
    }
    out[j] <- list(if (is.null(st)) NULL else predict_state(st, t, par))   # [[<- NULL would drop the element
  }
  list(states = out, innov = rbindlist(inn), loglik = if (is.null(st)) 0 else st$loglik)
}

#' Simple forecasts from the last two usable measured positions before origin t (Step 06 baselines).
baseline_forecasts <- function(obs, t, h, g) {
  u <- obs[usable_from <= t][order(frame)]
  if (nrow(u) < 2L) return(NULL)
  a <- u[.N - 1L]; b <- u[.N]
  dt <- (b$frame - a$frame) / FPS; tau <- (t + h - b$frame) / FPS
  v <- c(b$x - a$x, b$y - a$y, b$z - a$z) / dt
  p <- c(b$x, b$y, b$z)
  vz_end <- v[3] - g * dt / 2                                  # a difference quotient is the velocity at the midpoint
  list(persistence = p, constant_velocity = p + v * tau,
       gravity_only = c(p[1:2] + v[1:2] * tau, p[3] + vz_end * tau - 0.5 * g * tau^2))
}

#' Covariance health: finite, symmetric, smallest eigenvalue.
cov_health <- function(P) {
  c(finite = all(is.finite(P)), symmetric = max(abs(P - t(P))) < 1e-9, min_eig = min(eigen(P, symmetric = TRUE, only.values = TRUE)$values))
}
