# Step 06 of the rebounding manual: the ball filter's parameters, learned from the training games' free-flight
# segments only: per-axis observation noise r (scatter of measured positions around a quadratic arc fitted to each
# segment), the track's own downward acceleration g, and the process noise q chosen from a grid by the training
# innovation log-likelihood. Settings: config/experiment.yaml (step06). Requires ball_filter.R and geometry.R.

#' Quadratic arc per axis through a segment's measured frames: residuals and the fitted downward acceleration.
arc_fit <- function(seg) {
  tt <- (seg$frame - seg$frame[1]) / FPS
  X <- cbind(1, tt, tt^2)
  res <- sapply(c("x", "y", "z"), function(a) as.vector(seg[[a]] - X %*% qr.solve(X, seg[[a]])))
  bz <- qr.solve(X, seg$z)
  list(res = matrix(res, ncol = 3, dimnames = list(NULL, c("x", "y", "z"))), g = -2 * bz[3], span = max(tt))
}

#' Observation noise and gravity from training segments (each a data.table of measured frames: frame, x, y, z).
#' r pools the arc residuals with 3 fitted coefficients per axis per segment; g is the median fitted downward
#' acceleration over segments of at least `min_span` seconds.
estimate_noise <- function(segments, min_span = 0.4) {
  fits <- lapply(segments, arc_fit)
  ok <- vapply(segments, nrow, 0L) >= 5L
  res <- do.call(rbind, lapply(fits[ok], `[[`, "res"))
  dof <- nrow(res) - 3L * sum(ok)
  spans <- vapply(fits, `[[`, 0, "span"); gs <- vapply(fits, `[[`, 0, "g")
  list(r = sqrt(colSums(res^2) / dof), g = median(gs[spans >= min_span]), n_segments = sum(ok), n_obs = nrow(res),
       n_g = sum(spans >= min_span))
}

#' Total innovation log-likelihood of a parameter set over training segments (every observation after the first).
segments_loglik <- function(segments, par) {
  sum(vapply(segments, function(s) {
    o <- s[, .(frame, x, y, z, usable_from = frame)]
    run_filter(o, max(o$frame), par)$loglik
  }, 0))
}

#' Fit every learned parameter on the training segments: r and g first, then q by maximum likelihood over the grid
#' (ties to the smaller q).
fit_ball_params <- function(segments, q_grid, v_sd) {
  nz <- estimate_noise(segments)
  ll <- vapply(q_grid, function(q) segments_loglik(segments, list(r = nz$r, g = nz$g, q = q, v_sd = v_sd)), 0)
  q <- q_grid[which(ll == max(ll))[1]]
  list(par = list(r = nz$r, g = nz$g, q = q, v_sd = v_sd), q_loglik = data.table(q = q_grid, loglik = ll), noise = nz)
}
