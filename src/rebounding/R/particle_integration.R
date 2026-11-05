# Step 09 of the rebounding manual: ball particles and each player's access to them at one information time. At
# release the particles are draws from the Step 05 release-time map of the credited location; at rim + 0.2 s they are
# draws from the Step 07 empirical analog forecast of the ball 0.4 s later. Access is the Step 08 arrival margin.
# Both ball inputs are exploratory (Steps 05 and 07 BLOCKED); only the integrated probabilities are judged.
# Settings: config/experiment.yaml (step09). Requires geometry.R, bundle.R (to_player_frame), spatial_prior.R,
# physics.R (two_point_state), particle_filter.R (analog_forecast), reach.R.

ACCESS_FEATURES <- c("access_margin", "best_access")

#' K particles from a release-time map: cells drawn with their probabilities, uniform within the cell; height 0.
particles_from_map <- function(M, grid, K) {
  i <- sample.int(length(M), K, replace = TRUE, prob = as.vector(M))
  h <- grid$area^0.5
  data.table(k = seq_len(K), bx = grid$px[i] + runif(K, -h / 2, h / 2), by = grid$py[i] + runif(K, -h / 2, h / 2), z = 0)
}

#' K particles from an analog forecast (ball frame positions, weights, kernel sd), moved to the player frame.
particles_from_analog <- function(a, K, hoop) {
  i <- sample.int(nrow(a$X), K, replace = TRUE, prob = a$w)
  X <- a$X[i, , drop = FALSE] + matrix(rnorm(3 * K), ncol = 3) %*% diag(a$sd)
  pf <- to_player_frame(X[, 1] - hoop[1], X[, 2] - hoop[2], X[, 3], list(hx = hoop[1], hy = hoop[2]))
  data.table(k = seq_len(K), bx = pf$x, by = pf$y, z = X[, 3])
}

#' Access of every player to every particle: margin = available time - arrival - height cost, clipped; and whether the
#' player has the largest margin for that particle. `st`: pid, x, y, vx, vy at the information time.
access_features <- function(st, parts, avail, rp, clip = 1.5) {
  if (is.null(parts) || !nrow(parts)) return(NULL)
  d <- CJ(i = seq_len(nrow(st)), k = parts$k)
  d[, `:=`(pid = st$pid[i], m = avail - arrival_time(st$x[i], st$y[i], st$vx[i], st$vy[i], parts$bx[k], parts$by[k], rp) -
                              height_cost(parts$z[k], rp))]
  d[, access_margin := pmin(clip, pmax(-clip, m))]
  d[, best_access := as.numeric(is.finite(m) & m == max(m)), by = k]   # nobody is best when nobody can reach it
  d[, .(pid, k, access_margin, best_access)]
}
