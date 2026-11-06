# Step 07 of the rebounding manual: forecasts of the ball after it reaches the rim. Three models share one scoring
# rule: a Gaussian around the gravity-only forecast (gravity_gauss), empirical analog transitions (empirical), and a
# particle filter running the physics of physics.R (physics). Settings: config/experiment.yaml (step07). Resampling
# and effective sample size follow filterpy's monte_carlo module and the Kalman book's particle-filter chapter (MIT;
# ideas, written independently in R).
# Requires geometry.R, physics.R.

#' Run `expr` with its own random stream and leave the caller's stream untouched.
with_seed <- function(seed, expr) {
  old <- if (exists(".Random.seed", envir = globalenv())) get(".Random.seed", envir = globalenv()) else NULL
  on.exit(if (is.null(old)) rm(".Random.seed", envir = globalenv()) else assign(".Random.seed", old, envir = globalenv()))
  set.seed(seed)
  expr
}

ess <- function(w) 1 / sum(w^2)

#' Systematic resampling: indices of n draws, one uniform offset u0 in [0, 1/n).
systematic_resample <- function(w, u0 = runif(1) / length(w)) {
  n <- length(w)
  pos <- u0 + (seq_len(n) - 1) / n
  pmin(findInterval(pos, cumsum(w) / sum(w)) + 1L, n)
}

# ---- physics particle filter ---------------------------------------------------------------------------------------

#' Particles from the two-point state: positions with observation noise, velocities with velocity_sd, contact
#' parameters from their priors; equal weights. Positions are hoop-relative.
pf_init <- function(st, hoop, ph, r) {
  n <- ph$particles
  X <- cbind(st$p[1] - hoop[1] + rnorm(n, 0, r[1]), st$p[2] - hoop[2] + rnorm(n, 0, r[2]), st$p[3] - hoop[3] + rnorm(n, 0, r[3]))
  V <- cbind(st$v[1] + rnorm(n, 0, ph$velocity_sd_ft_s), st$v[2] + rnorm(n, 0, ph$velocity_sd_ft_s), st$v[3] + rnorm(n, 0, ph$velocity_sd_ft_s))
  list(X = X, V = V, C = draw_contact_params(n, ph), w = rep(1 / n, n), frame = st$frame, hoop = hoop,
       contacts = matrix(0L, n, 3, dimnames = list(NULL, c("RIM", "BACKBOARD", "FLOOR"))), log = list())
}

#' Move every particle to `frame`.
pf_advance <- function(pf, frame, g, ph) {
  t <- (frame - pf$frame) / FPS
  if (t <= 0) return(pf)
  s <- simulate_balls(pf$X, pf$V, pf$C, t, g, ph)
  pf$X <- s$X; pf$V <- s$V; pf$contacts <- pf$contacts + s$contacts; pf$frame <- frame
  pf
}

#' Weight by one observed position (at the particles' frame), normalise, and resample with roughening when the
#' effective sample size falls below resample_below x particles.
pf_update <- function(pf, z, ph) {
  zr <- z - pf$hoop
  ll <- rowSums(dnorm(sweep(pf$X, 2, zr), 0, ph$weight_sd_ft, log = TRUE))
  lw <- log(pf$w) + ll
  w <- exp(lw - max(lw)); w <- w / sum(w)
  e <- ess(w); resampled <- FALSE
  if (e < ph$resample_below * length(w)) {
    i <- systematic_resample(w)
    pf$X <- pf$X[i, , drop = FALSE]; pf$V <- pf$V[i, , drop = FALSE]; pf$contacts <- pf$contacts[i, , drop = FALSE]
    pf$C <- lapply(pf$C, `[`, i)
    pf$V <- pf$V + matrix(rnorm(length(pf$V), 0, ph$roughen_sd_ft_s), ncol = 3)
    w <- rep(1 / length(w), length(w)); resampled <- TRUE
  }
  pf$w <- w
  pf$log[[length(pf$log) + 1L]] <- data.table(frame = pf$frame, ess = e, resampled = resampled, weight_sum = sum(w))
  pf
}

#' Weighted particle positions (attack frame) h frames after `frame`, from a copy of the filter.
pf_forecast <- function(pf, frame, g, ph) {
  f <- pf_advance(pf, frame, g, ph)
  list(X = from_hoop(f$X, pf$hoop), w = f$w, contacts = f$contacts)
}

# ---- empirical analog transitions ----------------------------------------------------------------------------------

#' Library rows from one episode: the state at each origin (position relative to its hoop, two-point velocity, offset
#' since the trigger) and the displacement from the last usable measured position to each measured frame at the given
#' leads (frames after the origin; the column is called horizon).
analog_rows <- function(obs, origins, offsets, horizons, rebound_frame, hoop, g) {
  meas <- obs[measured == TRUE]
  rbindlist(lapply(seq_along(origins), function(j) {
    t <- origins[j]; st <- two_point_state(obs, t, g)
    if (is.null(st)) return(NULL)
    rbindlist(lapply(horizons, function(h) {
      tg <- meas[frame == t + h & frame < rebound_frame]
      if (!nrow(tg)) return(NULL)
      data.table(offset = offsets[j], horizon = h, tau = (t + h - st$frame) / FPS,
                 px = st$p[1] - hoop[1], py = st$p[2] - hoop[2], pz = st$p[3] - hoop[3],
                 vx = st$v[1], vy = st$v[2], vz = st$v[3], dx = tg$x - st$p[1], dy = tg$y - st$p[2], dz = tg$z - st$p[3])
    }))
  }))
}

#' The library with every row's mirror image (y -> -y), and the feature scales.
analog_library <- function(rows) {
  mir <- copy(rows)[, `:=`(py = -py, vy = -vy, dy = -dy)]
  lib <- rbind(rows, mir)
  feats <- c("px", "py", "pz", "vx", "vy", "vz", "offset")
  list(lib = lib, feats = feats, scale = vapply(feats, function(f) max(sd(lib[[f]]), 1e-6), 0))
}

#' Analog forecast: the k nearest library states for this horizon; positions = last position + their displacements;
#' kernel sd per axis = Silverman bandwidth of those displacements plus the observation noise.
analog_forecast <- function(al, st, offset, h, hoop, k, r) {
  L <- al$lib[horizon == h]
  q <- c(st$p - hoop, st$v, offset)
  d <- sqrt(rowSums(sweep(sweep(as.matrix(L[, al$feats, with = FALSE]), 2, q), 2, al$scale, `/`)^2))
  nn <- L[order(d)[seq_len(min(k, nrow(L)))]]
  D <- as.matrix(nn[, .(dx, dy, dz)])
  bw <- 1.06 * apply(D, 2, sd) * nrow(D)^(-1 / 5)
  list(X = sweep(D, 2, st$p, `+`), w = rep(1 / nrow(D), nrow(D)), sd = sqrt(bw^2 + r^2))
}

# ---- scoring a forecast cloud ---------------------------------------------------------------------------------------

#' Log density of points Y (m x 3) under a weighted Gaussian mixture with centres X, weights w and per-axis sd.
mixture_logdens <- function(Y, X, w, sd) {
  Y <- matrix(Y, ncol = 3)
  L <- matrix(log(w), nrow(Y), nrow(X), byrow = TRUE) - sum(log(sd)) - 1.5 * log(2 * pi)
  for (a in 1:3) L <- L - 0.5 * (outer(Y[, a], X[, a], `-`) / sd[a])^2
  m <- apply(L, 1, max)
  m + log(rowSums(exp(L - m)))
}

#' Negative log density and mean error only (no draws), for repeated runs.
score_quick <- function(y, X, w, sd) {
  mu <- colSums(X * w) / sum(w)
  c(nll = -mixture_logdens(y, X, w, sd), err = sqrt(sum((mu - y)^2)))
}

#' Scores of one target y (length 3) under a mixture: negative log density per cubic foot, highest-density rank u
#' (share of draws at least as dense as the target; covered at level L when u <= L), energy score and mean error.
#' Draws use their own seed, so scoring never moves the filter's random stream.
score_mixture <- function(y, X, w, sd, n_draw, seed) {
  Z <- with_seed(seed, {
    i <- sample.int(nrow(X), n_draw, replace = TRUE, prob = w)
    X[i, , drop = FALSE] + matrix(rnorm(3 * n_draw), ncol = 3) %*% diag(sd)
  })
  ly <- mixture_logdens(y, X, w, sd); lz <- mixture_logdens(Z, X, w, sd)
  half <- seq_len(n_draw %/% 2)
  es <- mean(sqrt(rowSums(sweep(Z, 2, y)^2))) - 0.5 * mean(sqrt(rowSums((Z[half, , drop = FALSE] - Z[-half, , drop = FALSE][half, , drop = FALSE])^2)))
  mu <- colSums(X * w) / sum(w)
  c(nll = -ly, u = mean(lz >= ly), energy = es, err = sqrt(sum((mu - y)^2)))
}
