# Step 06: the causal ball filter and its learned parameters on synthetic flights with known gravity and noise.

source(file.path(here, "R", "ball_filter.R"))
source(file.path(here, "R", "ball_noise.R"))

# A flight from (20, 3, 7) ft with velocity (20, -2, 15) ft/s under downward acceleration g, sampled at 25 Hz, with
# Gaussian noise of sd r per axis on the measured positions.
flight <- function(n = 30L, g = 28.3, r = c(0, 0, 0), seed = 1L, f0 = 100L) {
  set.seed(seed)
  f <- f0 + 0:(n - 1L); tt <- (f - f0) / FPS
  data.table(frame = f, x = 20 + 20 * tt + rnorm(n, 0, r[1]), y = 3 - 2 * tt + rnorm(n, 0, r[2]),
             z = 7 + 15 * tt - 0.5 * g * tt^2 + rnorm(n, 0, r[3]), usable_from = f + 1L)
}
par0 <- list(r = c(0.01, 0.01, 0.01), g = 28.3, q = 0.01, v_sd = 50)

test_that("gravity pulls z down at the configured rate and a noise-free arc is tracked exactly", {
  s <- predict_state(list(frame = 0L, m = c(0, 0, 10, 0, 0, 0), P = diag(6)), 25L, par0)
  expect_equal(s$m[3], 10 - 0.5 * 28.3)                     # one second later
  expect_equal(s$m[6], -28.3)
  o <- flight()
  r <- run_filter(o, max(o$frame) + 1L, par0)
  st <- r$states[[1]]
  tt <- (max(o$frame) + 1L - 100L) / FPS
  expect_equal(st$m[1:3], c(20 + 20 * tt, 3 - 2 * tt, 7 + 15 * tt - 0.5 * 28.3 * tt^2), tolerance = 1e-3)
  expect_equal(st$m[4:6], c(20, -2, 15 - 28.3 * tt), tolerance = 1e-2)
  b <- baseline_forecasts(o, 110L, 5L, 28.3)
  t5 <- (115L - 100L) / FPS
  expect_equal(b$gravity_only, c(20 + 20 * t5, 3 - 2 * t5, 7 + 15 * t5 - 0.5 * 28.3 * t5^2), tolerance = 1e-9)
  expect_equal(b$persistence, unname(unlist(o[frame == 109L, .(x, y, z)])))
})

test_that("crossing a gap in one prediction equals several single-frame predictions", {
  st <- list(frame = 0L, m = c(1, 2, 9, 10, -3, 6), P = diag(c(0.1, 0.1, 0.1, 4, 4, 4)))
  p <- list(r = c(0.2, 0.1, 0.3), g = 28.3, q = 30, v_sd = 50)
  a <- predict_state(st, 3L, p)
  b <- predict_state(predict_state(predict_state(st, 1L, p), 2L, p), 3L, p)
  expect_equal(a$m, b$m, tolerance = 1e-12)
  expect_equal(a$P, b$P, tolerance = 1e-12)
  expect_identical(predict_state(st, 0L, p), st)                # no time, no change
})

test_that("units and the attack-frame rotation carry through the filter", {
  o <- flight(r = c(0.2, 0.1, 0.3))
  p <- list(r = c(0.2, 0.1, 0.3), g = 28.3, q = 30, v_sd = 50)
  a <- run_filter(o, 125L, p)$states[[1]]
  m <- 0.3048
  om <- copy(o)[, `:=`(x = x * m, y = y * m, z = z * m)]
  pm <- list(r = p$r * m, g = p$g * m, q = p$q * m^2, v_sd = p$v_sd * m)
  b <- run_filter(om, 125L, pm)$states[[1]]
  expect_equal(b$m, a$m * m, tolerance = 1e-9)
  expect_equal(b$P, a$P * m^2, tolerance = 1e-9)
  orot <- copy(o)[, `:=`(x = -x, y = -y)]                     # the 180-degree turn of Step 01
  c2 <- run_filter(orot, 125L, p)$states[[1]]
  expect_equal(c2$m, a$m * c(-1, -1, 1, -1, -1, 1), tolerance = 1e-9)
})

test_that("the state at t is the same whether or not later frames are in the data", {
  o <- flight(r = c(0.2, 0.1, 0.3), n = 40L)
  p <- list(r = c(0.2, 0.1, 0.3), g = 28.3, q = 30, v_sd = 50)
  for (t in c(105L, 117L, 130L)) {
    full <- run_filter(o, t, p)$states[[1]]
    cut <- run_filter(o[usable_from <= t], t, p)$states[[1]]
    poisoned <- copy(o)[usable_from > t, z := z + 50]
    pois <- run_filter(poisoned, t, p)$states[[1]]
    expect_identical(full$m, cut$m); expect_identical(full$P, cut$P); expect_identical(full$m, pois$m)
  }
})

test_that("covariance stays finite, symmetric and positive, and grows without observations", {
  o <- flight(r = c(0.2, 0.1, 0.3), n = 40L)[frame %% 3 != 0 | frame < 110]   # drop some frames
  p <- list(r = c(0.2, 0.1, 0.3), g = 28.3, q = 30, v_sd = 50)
  r <- run_filter(o, 101:140, p)
  h <- t(vapply(Filter(Negate(is.null), r$states), function(s) cov_health(s$P), numeric(3)))
  expect_true(all(h[, "finite"] == 1) && all(h[, "symmetric"] == 1) && all(h[, "min_eig"] > -1e-9))
  st <- r$states[[length(r$states)]]
  tr <- vapply(1:10, function(k) sum(diag(predict_state(st, st$frame + k, p)$P)), 0)
  expect_true(all(diff(tr) > 0))
})

test_that("noise, gravity and process noise are recovered from synthetic training flights", {
  segs <- lapply(1:60, function(i) flight(n = 25L, r = c(0.2, 0.1, 0.3), seed = i)[, .(frame, x, y, z)])
  nz <- estimate_noise(segs)
  expect_equal(unname(nz$r), c(0.2, 0.1, 0.3), tolerance = 0.12)
  expect_equal(nz$g, 28.3, tolerance = 0.05)
  fit <- fit_ball_params(segs, c(1, 30, 1000), 50)
  expect_true(fit$par$q %in% c(1, 30))                        # true acceleration noise is zero: the large q loses
  # normalised innovations of a correctly specified filter average about 3 (three observed axes)
  r <- run_filter(flight(n = 200L, r = c(0.2, 0.1, 0.3), seed = 99)[, usable_from := frame + 1L], 400L, fit$par)
  expect_equal(mean(r$innov[n_obs > 4]$nis), 3, tolerance = 0.25)
})

test_that("origins before the first usable observation return an empty state in their own position", {
  o <- flight(n = 10L, f0 = 100L)
  r <- run_filter(o, c(95L, 99L, 101L, 105L), par0)
  expect_length(r$states, 4L)
  expect_null(r$states[[1]]); expect_null(r$states[[2]])
  expect_equal(r$states[[3]]$frame, 101L); expect_equal(r$states[[4]]$frame, 105L)
})
