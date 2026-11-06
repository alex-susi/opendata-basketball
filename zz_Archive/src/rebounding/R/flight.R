# Ball flight: launch prior, filters, contact models and their forecasts (framework sections 1, 6, 13).
#
# All positions here are in the hoop-relative ball frame (bundle.R): the calibrated hoop centre is (0, 0) at
# height RIM_Z, the offense attacks +x. Times are seconds after the release frame (shots.startFrame).
# Only keyframes enter a filter: about half of the delivered ball positions are exact midpoints of their
# neighbours (linear interpolation by the vendor) and carry no new information.
# Requires geometry.R and the C++ functions of cpp/ball.cpp (load_ball_cpp()).

N_PARTICLES <- 400L
ARRIVE_DZ <- 0.75        # ft above rim height at which a descending ball "arrives" at the basket (launch prior)
LAUNCH_K <- 40L          # nearest shots by distance in the launch prior
HORIZONS <- c(0.2, 0.4, 0.6, 1.0)
LEVELS <- c(0.5, 0.8, 0.9)
NU <- 4                  # Student-t degrees of freedom of the particle filter's observation model
R_FLOOR <- 0.2^2         # ft^2: least observation variance. The delivered track is smoothed, so maximum likelihood
                         # alone puts all the noise into the process and none into the observations

#' Compile and load cpp/ball.cpp. Rtools is added to PATH when it is installed in its default place.
load_ball_cpp <- function(here, cache) {
  rt <- "C:/rtools44"
  if (dir.exists(rt) && !nzchar(Sys.which("g++")))
    Sys.setenv(PATH = paste(file.path(rt, "usr", "bin"), file.path(rt, "x86_64-w64-mingw32.static.posix", "bin"),
                            Sys.getenv("PATH"), sep = .Platform$path.sep))
  dir.create(file.path(cache, "cpp"), recursive = TRUE, showWarnings = FALSE)
  Rcpp::sourceCpp(file.path(here, "cpp", "ball.cpp"), cacheDir = file.path(cache, "cpp"), env = globalenv())
}

#' Physical parameters: FIBA geometry plus the fitted or default contact and floor values.
phys_par <- function(...) {
  modifyList(list(g = GRAVITY, ball_r = BALL_R, rim_r = RIM_R, rim_tube = RIM_TUBE, rim_z = RIM_Z,
                  board_dx = BOARD_X - RIM_X, board_hw = BOARD_HALF_W, board_z0 = BOARD_Z0, board_z1 = BOARD_Z1,
                  z_floor = 1.1, e_floor = 0.7, mu_floor = 0.85, e_rim_lo = 0.25, e_rim_hi = 0.6, rim_jitter = 0.35,
                  rim_fric = 0.8, e_board = 0.6, board_fric = 0.85, sigma_a = 3, end_x = COURT_HALF_L - RIM_X,
                  side_y = COURT_HALF_W, h = 0.005, contacts = 1L), list(...))
}

# ---- episode times ---------------------------------------------------------------------------------

#' Event times of a bundle in seconds after release: contact, first possible touch, rebound, control proxy.
bundle_times <- function(b) {
  s <- b$shot
  rel <- function(f) if (is.na(f)) NA_real_ else (f - s$f0) / FPS
  list(contact = rel(s$contact_frame), touch = rel(s$touch_frame), rebound = rel(s$rf), control = rel(s$control_frame),
       bounce = rel(s$bounce_frame), end = rel(s$f1))
}

#' Keyframe observations strictly after release and no later than t_to.
key_obs <- function(b, t_to = Inf, t_from = 0) b$ball[key == TRUE & t > t_from + 1e-9 & t <= t_to + 1e-9]

# ---- launch prior ----------------------------------------------------------------------------------

#' One row per tracked attempt (made or missed): release point, distance, time until the ball comes down
#' through ARRIVE_DZ above rim height, and where it is then along and across the line of the shot.
#' @param tracks list(t, x, y, z) per shot in the hoop-relative frame (release at t = 0).
launch_row <- function(tr) {
  if (nrow(tr) < 8L || !any(tr$t == 0)) return(NULL)
  r0 <- tr[t == 0]
  ap <- which.max(tr$z[seq_len(min(nrow(tr), 50L))])
  after <- tr[seq(ap, nrow(tr))]
  i <- which(after$z <= RIM_Z + ARRIVE_DZ)
  if (!length(i) || i[1] < 2L) return(NULL)
  i <- i[1]
  a <- (after$z[i - 1] - (RIM_Z + ARRIVE_DZ)) / (after$z[i - 1] - after$z[i])
  ax <- after$x[i - 1] + a * (after$x[i] - after$x[i - 1])
  ay <- after$y[i - 1] + a * (after$y[i] - after$y[i - 1])
  at <- after$t[i - 1] + a * (after$t[i] - after$t[i - 1])
  d <- sqrt(r0$x^2 + r0$y^2)
  ux <- -r0$x / d
  uy <- -r0$y / d
  data.table(dist = d, z0 = r0$z, T = at, long = ax * ux + ay * uy, lat = -ax * uy + ay * ux)
}

#' Initial particles at release: the observed release point and a launch velocity that brings the ball to
#' an aim point sampled, with its flight time, from the LAUNCH_K tracked attempts nearest in distance.
launch_particles <- function(lib, r0, n, seed) {
  set.seed(seed)
  d <- sqrt(r0$x^2 + r0$y^2)
  near <- lib[order(abs(dist - d))][seq_len(min(.N, LAUNCH_K))]
  pick <- near[sample(.N, n, replace = TRUE)]
  ux <- -r0$x / d
  uy <- -r0$y / d
  long <- pick$long + rnorm(n, 0, 0.15)
  lat <- pick$lat + rnorm(n, 0, 0.15)
  Tt <- pmax(0.2, pick$T * (1 + (d - pick$dist) * 0.012) + rnorm(n, 0, 0.02))
  ax <- long * ux - lat * uy
  ay <- long * uy + lat * ux
  az <- RIM_Z + ARRIVE_DZ
  x0 <- r0$x + rnorm(n, 0, 0.1)
  y0 <- r0$y + rnorm(n, 0, 0.1)
  z0 <- r0$z + rnorm(n, 0, 0.1)
  cbind(x0, y0, z0, (ax - x0) / Tt, (ay - y0) / Tt, (az - z0 + 0.5 * GRAVITY * Tt^2) / Tt)
}

# ---- particle filter forecasts ----------------------------------------------------------------------

#' Posterior particles at time t_chk from the launch prior and every keyframe up to t_chk.
#' @param miss Keep only particles whose simulated future does not go through the hoop (a miss scenario).
pf_at <- function(b, t_chk, par, sig, lib, n = N_PARTICLES, seed = 1L) {
  r0 <- b$ball[which.min(abs(t))]
  S0 <- launch_particles(lib, r0, n, seed)
  ob <- key_obs(b, t_chk)
  if (!nrow(ob)) return(list(S = advance_states(S0, t_chk, par, seed), loglik = numeric(0)))
  r <- pf_run(S0, ob$t, as.matrix(ob[, .(x, y, z)]), sig, NU, t_chk, par, seed)
  list(S = r$S, loglik = r$loglik)
}

#' States of particles after dt seconds of simulation (positions and velocities).
advance_states <- function(S, dt, par, seed) {
  if (dt <= 1e-6) return(S)
  a <- sim_paths(S, c(dt - 0.02, dt), par, seed)
  n <- nrow(S)
  p1 <- matrix(a$pos[, c(1, 3, 5)], n)
  p2 <- matrix(a$pos[, c(2, 4, 6)], n)
  cbind(p2, (p2 - p1) / 0.02 + matrix(c(0, 0, -0.5 * GRAVITY * 0.02), n, 3, byrow = TRUE))
}

#' Future positions of particles at horizons after the checkpoint, keeping only miss scenarios where the
#' simulated ball does not drop through the hoop (resampled back to the original count).
forecast_paths <- function(S, times, par, seed, miss = TRUE) {
  out <- sim_paths(S, times, par, seed)
  keep <- if (miss) which(!out$made) else seq_len(nrow(S))
  if (!length(keep)) keep <- seq_len(nrow(S))
  idx <- if (length(keep) < nrow(S)) keep[sample.int(length(keep), nrow(S), replace = TRUE)] else keep
  T <- length(times)
  list(x = out$pos[idx, seq_len(T), drop = FALSE], y = out$pos[idx, T + seq_len(T), drop = FALSE],
       z = out$pos[idx, 2 * T + seq_len(T), drop = FALSE], made_share = mean(out$made),
       t_out = out$t_out[idx], contacts = out$contacts[idx], t_contact = out$t_contact[idx], S = S[idx, , drop = FALSE])
}

# ---- scoring ------------------------------------------------------------------------------------------

#' Score one observed position against a forecast cloud (n x 3) with Gaussian observation error R (diag):
#' log predictive density of the mixture, error of the cloud's mean, highest-density coverage at LEVELS and
#' the 90% horizontal radius around the cloud's median.
score_cloud <- function(X, y, R) {
  X <- X[is.finite(rowSums(X)), , drop = FALSE]
  n <- nrow(X)
  if (n < 20L || !all(is.finite(y))) return(NULL)
  sd <- sqrt(R)
  dens <- function(P) {
    # mixture density at each row of P, log scale
    l <- matrix(0, nrow(P), n)
    for (k in 1:3) l <- l + outer(P[, k], X[, k], function(a, b) dnorm(a, b, sd[k], log = TRUE))
    m <- apply(l, 1, max)
    m + log(rowMeans(exp(l - m)))
  }
  ly <- dens(matrix(y, 1))
  draws <- X + matrix(rnorm(3 * n, 0, rep(sd, each = n)), n)
  ld <- dens(draws[seq_len(min(n, 200L)), , drop = FALSE])
  cov <- vapply(LEVELS, function(a) ly >= quantile(ld, 1 - a), NA)
  mx <- colMeans(X)
  hx <- median(X[, 1]); hy <- median(X[, 2])
  c(logscore = ly, err = sqrt(sum((mx - y)^2)), err_xy = sqrt(sum((mx[1:2] - y[1:2])^2)),
    setNames(as.numeric(cov), paste0("cover", LEVELS * 100)),
    radius90 = unname(quantile(sqrt((X[, 1] - hx)^2 + (X[, 2] - hy)^2), 0.9)))
}

#' The keyframe nearest each horizon after the checkpoint, if it falls before the first possible touch
#' (a touched ball no longer follows any no-touch model) and before the rebound.
targets_for <- function(b, t_chk, tm) {
  stop_at <- min(c(tm$touch, tm$rebound, Inf), na.rm = TRUE)
  ob <- key_obs(b, Inf, t_chk)
  rbindlist(lapply(HORIZONS, function(h) {
    k <- ob[abs(t - (t_chk + h)) <= 0.041]
    if (!nrow(k) || k$t[1] >= stop_at) return(NULL)
    k[1][, .(h = h, t, x, y, z)]
  }))
}

# ---- Gaussian baselines -----------------------------------------------------------------------------

#' Constant velocity, ballistic least squares and Kalman forecasts at t_chk from keyframes up to t_chk.
#' Each returns a mean and a covariance per horizon; the two simple ones take their spread from training
#' residuals (`spread`: per model, horizon and axis RMS).
gaussian_forecasts <- function(b, t_chk, horizons, kf, spread = NULL) {
  ob <- key_obs(b, t_chk, max(-1, t_chk - 0.4))
  ob0 <- b$ball[t <= t_chk + 1e-9]
  ob <- rbind(ob0[t == 0], ob)
  if (nrow(ob) < 3L) return(NULL)
  last <- ob[.N]
  out <- list()
  # constant velocity over the last 0.16 s
  rec <- ob[t >= last$t - 0.17]
  if (nrow(rec) >= 2L) {
    v <- c(diff(range(rec$x)) * sign(rec$x[.N] - rec$x[1]), diff(range(rec$y)) * sign(rec$y[.N] - rec$y[1]),
           diff(range(rec$z)) * sign(rec$z[.N] - rec$z[1])) / (rec$t[.N] - rec$t[1])
    out$cv <- lapply(horizons, function(h) list(m = c(last$x, last$y, last$z) + v * (t_chk + h - last$t)))
  }
  # ballistic fit to the last 0.4 s with gravity fixed
  if (nrow(ob) >= 4L) {
    tt <- ob$t - t_chk
    fx <- lm.fit(cbind(1, tt), ob$x)$coefficients
    fy <- lm.fit(cbind(1, tt), ob$y)$coefficients
    fz <- lm.fit(cbind(1, tt), ob$z + 0.5 * GRAVITY * tt^2)$coefficients
    out$ballistic <- lapply(horizons, function(h) list(m = c(fx[1] + fx[2] * h, fy[1] + fy[2] * h,
                                                           fz[1] + fz[2] * h - 0.5 * GRAVITY * h^2)))
  }
  # Kalman filter over every keyframe since release
  all <- rbind(ob0[t == 0], key_obs(b, t_chk))
  if (nrow(all) >= 3L) {
    P0 <- diag(c(0.25, 400))
    ax <- list(c("x", 0, kf$r_xy), c("y", 0, kf$r_xy), c("z", -GRAVITY, kf$r_z))
    out$kalman <- lapply(horizons, function(h) {
      res <- lapply(ax, function(a) {
        col <- a[[1]]
        kf_axis(all$t, all[[col]], as.numeric(a[[2]]), c(all[[col]][1], 0), P0, kf$q, as.numeric(a[[3]]), t_chk + h)
      })
      list(m = vapply(res, function(r) r$m[1], 0), v = vapply(res, function(r) r$P[1, 1], 0))
    })
  }
  if (!is.null(spread)) for (mod in c("cv", "ballistic")) if (!is.null(out[[mod]])) {
    out[[mod]] <- Map(function(f, h) { f$v <- spread[model == mod & horizon == h, c(sx, sy, sz)]^2; f }, out[[mod]], horizons)
  }
  out
}

#' Draw a cloud from a Gaussian forecast so every model is scored by score_cloud().
gauss_cloud <- function(f, n = 300L) {
  cbind(rnorm(n, f$m[1], sqrt(f$v[1])), rnorm(n, f$m[2], sqrt(f$v[2])), rnorm(n, f$m[3], sqrt(f$v[3])))
}

# ---- fitting ----------------------------------------------------------------------------------------

#' Kalman process and observation noise by maximum predictive likelihood on pre-contact flight.
fit_kf_noise <- function(bundles) {
  segs <- lapply(bundles, function(b) {
    tm <- bundle_times(b)
    stop_at <- min(c(tm$contact, tm$touch, 1.2), na.rm = TRUE) - 0.04
    rbind(b$ball[t == 0], key_obs(b, stop_at))
  })
  segs <- segs[vapply(segs, nrow, 0L) >= 6L]
  nll <- function(lp) {
    q <- exp(lp[1]); rxy <- R_FLOOR + exp(lp[2]); rz <- R_FLOOR + exp(lp[3])
    P0 <- diag(c(0.25, 400))
    -sum(vapply(segs, function(o) {
      lx <- kf_axis(o$t, o$x, 0, c(o$x[1], 0), P0, q, rxy, max(o$t))$loglik
      ly <- kf_axis(o$t, o$y, 0, c(o$y[1], 0), P0, q, rxy, max(o$t))$loglik
      lz <- kf_axis(o$t, o$z, -GRAVITY, c(o$z[1], 0), P0, q, rz, max(o$t))$loglik
      sum(c(lx, ly, lz)[-c(1, 2, length(lx) + 1, length(lx) + 2, 2 * length(lx) + 1, 2 * length(lx) + 2)])
    }, 0))
  }
  o <- optim(c(log(20), log(0.05), log(0.05)), nll, method = "Nelder-Mead", control = list(maxit = 200))
  list(q = exp(o$par[1]), r_xy = R_FLOOR + exp(o$par[2]), r_z = R_FLOOR + exp(o$par[3]), nll = o$value, n_segments = length(segs))
}

#' Floor contact: effective floor height of the reconstructed ball centre, vertical restitution and
#' horizontal speed retained, from ballistic fits either side of observed bounces.
fit_floor <- function(bundles) {
  rows <- rbindlist(lapply(bundles, function(b) {
    tm <- bundle_times(b)
    if (is.na(tm$bounce)) return(NULL)
    pre <- key_obs(b, tm$bounce - 0.02, tm$bounce - 0.3)
    post <- key_obs(b, tm$bounce + 0.3, tm$bounce + 0.02)
    if (nrow(pre) < 3L || nrow(post) < 3L) return(NULL)
    fit <- function(o) {
      tt <- o$t - tm$bounce
      list(z = lm.fit(cbind(1, tt), o$z + 0.5 * GRAVITY * tt^2)$coefficients,
           x = lm.fit(cbind(1, tt), o$x)$coefficients, y = lm.fit(cbind(1, tt), o$y)$coefficients)
    }
    a <- fit(pre); c2 <- fit(post)
    # height and time where the falling and the rising parabolas meet
    f <- function(tt) (a$z[1] + a$z[2] * tt) - (c2$z[1] + c2$z[2] * tt)
    tt <- if (abs(a$z[2] - c2$z[2]) > 1e-6) (c2$z[1] - a$z[1]) / (a$z[2] - c2$z[2]) else 0
    tt <- max(-0.08, min(0.08, tt))
    data.table(z_hit = a$z[1] + a$z[2] * tt - 0.5 * GRAVITY * tt^2, vz_in = a$z[2] - GRAVITY * tt,
               vz_out = c2$z[2] - GRAVITY * tt, vh_in = sqrt(a$x[2]^2 + a$y[2]^2), vh_out = sqrt(c2$x[2]^2 + c2$y[2]^2))
  }))
  rows <- rows[vz_in < -5 & vz_out > 0]
  list(z_floor = median(rows$z_hit), e_floor = median(-rows$vz_out / rows$vz_in),
       mu_floor = min(1, median(rows$vh_out / pmax(rows$vh_in, 1))), n_bounces = nrow(rows))
}

#' Mean log predictive density of post-contact keyframes (up to 0.6 s after contact, before any touch)
#' from the particle filter's state at the contact time, for one set of contact parameters.
contact_score <- function(bundles, par, sig, lib, n = 300L) {
  vals <- vapply(seq_along(bundles), function(i) {
    b <- bundles[[i]]
    tm <- bundle_times(b)
    if (is.na(tm$contact)) return(NA_real_)
    t_chk <- tm$contact - 0.04
    tg <- targets_for(b, t_chk, tm)
    if (!nrow(tg)) return(NA_real_)
    st <- pf_at(b, t_chk, par, sig, lib, n, seed = i)
    fp <- forecast_paths(st$S, tg$t - t_chk, par, seed = 1000L + i)
    mean(vapply(seq_len(nrow(tg)), function(k) {
      X <- cbind(fp$x[, k], fp$y[, k], fp$z[, k])
      sc <- score_cloud(X, c(tg$x[k], tg$y[k], tg$z[k]), c(sig[1]^2, sig[1]^2, sig[2]^2))
      if (is.null(sc)) NA_real_ else sc[["logscore"]]
    }, 0), na.rm = TRUE)
  }, 0)
  mean(vals, na.rm = TRUE)
}

#' Empirical contact library: incoming velocity (Kalman, pre-contact keyframes) and outgoing velocity
#' (ballistic fit to 0.08-0.4 s after contact) of training episodes, in the frame of the incoming direction.
contact_library <- function(bundles, kf) {
  rbindlist(lapply(bundles, function(b) {
    tm <- bundle_times(b)
    if (is.na(tm$contact)) return(NULL)
    stop_at <- min(c(tm$touch, tm$rebound, tm$contact + 0.4), na.rm = TRUE)
    post <- key_obs(b, stop_at, tm$contact + 0.06)
    if (nrow(post) < 4L) return(NULL)
    pre <-rbind(b$ball[t == 0], key_obs(b, tm$contact - 0.04))
    vin <- vapply(c("x", "y"), function(col) coef(lm(pre[t >= tm$contact - 0.3][[col]] ~ pre[t >= tm$contact - 0.3]$t))[2], 0)
    vzin <- coef(lm(I(z + 0.5 * GRAVITY * t^2) ~ t, data = pre[t >= tm$contact - 0.3]))[2] - GRAVITY * tm$contact
    tt <- post$t - tm$contact
    vx <- lm.fit(cbind(1, tt), post$x)$coefficients
    vy <- lm.fit(cbind(1, tt), post$y)$coefficients
    vz <- lm.fit(cbind(1, tt), post$z + 0.5 * GRAVITY * tt^2)$coefficients
    ang <- atan2(vin[2], vin[1])
    rotv <- function(a, b2) c(cos(-ang) * a - sin(-ang) * b2, sin(-ang) * a + cos(-ang) * b2)
    vi <- rotv(vin[1], vin[2])
    vo <- rotv(vx[2], vy[2])
    po <- rotv(vx[1], vy[1])
    data.table(kind = b$shot$contact_kind, dist = b$shot$shot_dist, vin_h = vi[1], vin_z = vzin,
               vout_a = vo[1], vout_c = vo[2], vout_z = vz[2], px_a = po[1], px_c = po[2], pz = vz[1])
  }))
}

#' Particles just after contact drawn from the empirical library: the Kalman position at contact, and an
#' outgoing velocity from the 30 training contacts nearest in incoming speed, shot distance and contact kind,
#' turned to this shot's incoming direction.
empirical_contact_particles <- function(b, t_c, kf, lib_c, n = N_PARTICLES, seed = 1L) {
  set.seed(seed)
  pre <- rbind(b$ball[t == 0], key_obs(b, t_c))
  if (nrow(pre) < 4L) return(NULL)
  g <- gaussian_forecasts(b, t_c, 1e-3, kf)$kalman
  if (is.null(g)) return(NULL)
  g <- g[[1]]
  rec <- pre[t >= t_c - 0.3]
  vin <- c(coef(lm(x ~ t, rec))[2], coef(lm(y ~ t, rec))[2])
  ang <- atan2(vin[2], vin[1])
  vh <- sqrt(sum(vin^2))
  knd <- b$shot$contact_kind
  cand <- lib_c[kind == knd]
  if (nrow(cand) < 30L) cand <- lib_c
  dd <- (cand$vin_h - vh)^2 / 9 + (cand$dist - b$shot$shot_dist)^2 / 36
  near <- cand[order(dd)][seq_len(min(.N, 30L))]
  pick <- near[sample(.N, n, replace = TRUE)]
  va <- pick$vout_a; vc <- pick$vout_c
  cbind(g$m[1] + rnorm(n, 0, sqrt(g$v[1])), g$m[2] + rnorm(n, 0, sqrt(g$v[2])), g$m[3] + rnorm(n, 0, sqrt(g$v[3])),
        cos(ang) * va - sin(ang) * vc, sin(ang) * va + cos(ang) * vc, pick$vout_z)
}
