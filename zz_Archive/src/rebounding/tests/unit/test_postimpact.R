# Step 07: physics, contacts, the particle filter, analog transitions and forecast scoring on synthetic cases.

source(file.path(here, "R", "physics.R"))
source(file.path(here, "R", "particle_filter.R"))
ph <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$step07$physics
C1 <- function(n, e = 0.5, mu = 0) list(e_rim = rep(e, n), mu_rim = rep(mu, n), e_board = rep(e, n), mu_board = rep(mu, n))

test_that("free flight: gravity is exact under RK4, drag converges with the step, Magnus has the right direction", {
  X <- matrix(c(-15, 0, -3), 1)
  V <- matrix(c(18, 1, 14), 1)
  s <- rk4_step(X, V, 0.5, 28.2)
  expect_equal(as.vector(s$X), c(-15 + 9, 0.5, -3 + 7 - 0.5 * 28.2 * 0.25), tolerance = 1e-12)
  expect_equal(as.vector(s$V), c(18, 1, 14 - 14.1), tolerance = 1e-12)
  run <- function(dt) {
    x <- X
    v <- V
    for (i in seq_len(round(0.8 / dt))) {
      r <- rk4_step(x, v, dt, 28.2, drag = 0.002)
      x <- r$X
      v <- r$V
    }
    as.vector(x)
  }
  ref <- run(0.0005)
  e1 <- sqrt(sum((run(0.04) - ref)^2))
  e2 <- sqrt(sum((run(0.01) - ref)^2))
  expect_lt(e2, 1e-6)
  expect_lt(e2, e1)
  expect_lt(run(0.01)[1], -15 + 18 * 0.8)                    # drag slows the ball
  a <- accel(matrix(c(10, 0, 0), 1), 0, omega = matrix(c(0, 1, 0), 1), km = 0.01)
  expect_equal(as.vector(a), c(0, 0, -0.1))                   # (0,1,0) x (10,0,0) = (0,0,-10)
})

test_that("hoop-relative coordinates round-trip and the fixtures sit where FIBA puts them", {
  P <- matrix(c(30, 2, 9, 41, -1, 10), 2, byrow = TRUE)
  hoop <- c(41.1, -0.3, RIM_Z)
  expect_equal(from_hoop(to_hoop(P, hoop), hoop), P)
  expect_equal(BOARD_X - RIM_X, 0.375 * FT_PER_M, tolerance = 1e-9)
})

test_that("contacts: rim, board and floor reverse the normal velocity, keep the ball on the surface, never add speed", {
  ph0 <- ph
  # straight down onto the top of the ring
  X <- matrix(c(RIM_R, 0, BALL_R + RIM_TUBE - 0.01), 1)
  V <- matrix(c(0, 0, -10), 1)
  co <- collide(X, V, C1(1, e = 0.5), ph0)
  expect_equal(co$hit, "RIM")
  expect_equal(as.vector(co$V), c(0, 0, 5), tolerance = 1e-9)
  expect_equal(sqrt(sum((co$X - c(RIM_R, 0, 0))^2)), BALL_R + RIM_TUBE, tolerance = 1e-9)
  # into the board face, then beside it
  bx <- BOARD_X - RIM_X
  co <- collide(matrix(c(bx - BALL_R + 0.05, 0, 1), 1), matrix(c(8, 2, 3), 1), C1(1, e = 0.6, mu = 0.2), ph0)
  expect_equal(co$hit, "BACKBOARD")
  expect_equal(as.vector(co$V), c(-4.8, 1.6, 2.4), tolerance = 1e-9)
  co <- collide(matrix(c(bx - BALL_R + 0.05, BOARD_HALF_W + 1, 1), 1), matrix(c(8, 0, 0), 1), C1(1), ph0)
  expect_equal(co$hit, "")
  co <- collide(matrix(c(-5, 0, ph0$floor_z_ft - RIM_Z - 0.02), 1), matrix(c(3, 0, -12), 1), C1(1), ph0)
  expect_equal(co$hit, "FLOOR")
  expect_equal(co$V[3], 12 * ph0$floor_restitution)
  # random contacts never add speed
  set.seed(4)
  n <- 2000
  X <- cbind(runif(n, -1.3, 1.3), runif(n, -1.3, 1.3), runif(n, -0.5, 0.5))
  V <- matrix(rnorm(3 * n, 0, 10), n)
  C <- list(e_rim = runif(n), mu_rim = runif(n), e_board = runif(n), mu_board = runif(n))
  co <- collide(X, V, C, ph0)
  expect_true(all(sqrt(rowSums(co$V^2)) <= sqrt(rowSums(V^2)) + 1e-9))
})

test_that("a clean swish meets nothing and a front-rim shot bounces back out", {
  sw <- simulate_balls(matrix(c(-0.05, 0, 3), 1), matrix(c(0.1, 0, 0), 1), C1(1), 0.6, 28.2, ph)
  expect_equal(sum(sw$contacts), 0)
  fr <- simulate_balls(matrix(c(-2, 0, 0.6), 1), matrix(c(6, 0, -1), 1), C1(1, e = 0.6), 0.5, 28.2, ph)   # into the front of the ring
  expect_gt(fr$contacts[, "RIM"], 0)
  expect_lt(fr$X[1, 1], 0)                                     # ended in front of the hoop
})

test_that("the two-point state is exact on a parabola", {
  f <- 100:110
  tt <- (f - 100) / FPS
  obs <- data.table(frame = f, x = 20 + 18 * tt, y = 1 - tt, z = 8 + 14 * tt - 0.5 * 28.2 * tt^2, usable_from = f + 1L)
  st <- two_point_state(obs, 106L, 28.2)
  expect_equal(st$frame, 105L)
  expect_equal(st$v, c(18, -1, 14 - 28.2 * 5 / FPS), tolerance = 1e-9)
})

test_that("particle weights stay normalised, resampling follows them, and seeds are local", {
  w <- c(0.5, 0.25, 0.125, 0.125)
  expect_equal(tabulate(systematic_resample(w, 0.1), 4), c(2L, 1L, 1L, 0L))   # draws at 0.1, 0.35, 0.6, 0.85
  big <- systematic_resample(rep(c(0.7, 0.3) / 500, c(500, 500)), 0.0005)
  expect_equal(mean(big <= 500), 0.7, tolerance = 0.01)
  expect_equal(ess(rep(0.25, 4)), 4)
  expect_equal(ess(c(1, 0, 0, 0)), 1)
  set.seed(1)
  a <- runif(1)
  set.seed(1)
  with_seed(99, runif(5))
  b <- runif(1)
  expect_identical(a, b)
  set.seed(3)
  f <- 100:125
  tt <- (f - 100) / FPS
  obs <- data.table(frame = f, x = RIM_X - 6 + 10 * tt, y = 0.2, z = 12 + 2 * tt - 0.5 * 28.2 * tt^2, usable_from = f + 1L)
  st <- two_point_state(obs, 103L, 28.2)
  pf <- pf_init(st, c(RIM_X, 0, RIM_Z), ph, c(0.08, 0.07, 0.14))
  for (k in 103:115) {
    pf <- pf_advance(pf, k, 28.2, ph)
    pf <- pf_update(pf, unlist(obs[frame == k, .(x, y, z)]), ph)
  }
  lg <- rbindlist(pf$log)
  expect_true(all(abs(lg$weight_sum - 1) < 1e-9))
  expect_true(all(lg$ess <= ph$particles + 1e-9))
  mu <- colSums(from_hoop(pf$X, pf$hoop) * pf$w)
  expect_equal(unname(mu), unname(unlist(obs[frame == 115, .(x, y, z)])), tolerance = 0.15)
})

test_that("mixture scores: a single Gaussian matches the formula and the coverage rank is calibrated", {
  X <- matrix(c(1, 2, 3), 1)
  sd <- c(0.5, 0.4, 0.3)
  s <- score_mixture(c(1.2, 1.9, 3.1), X, 1, sd, 200L, 1L)
  expect_equal(unname(s["nll"]), -sum(dnorm(c(1.2, 1.9, 3.1), c(1, 2, 3), sd, log = TRUE)), tolerance = 1e-12)
  set.seed(8)
  Xm <- matrix(rnorm(30), 10)
  w <- rep(0.1, 10)
  us <- vapply(1:300, function(i) {
    j <- sample.int(10, 1)
    y <- Xm[j, ] + rnorm(3) * sd
    score_mixture(y, Xm, w, sd, 300L, i)["u"]
  }, 0)
  expect_equal(mean(us <= 0.5), 0.5, tolerance = 0.08)
  expect_equal(mean(us <= 0.9), 0.9, tolerance = 0.05)
})

test_that("analog forecasts take the nearest training states, mirrored ones included", {
  rows <- data.table(offset = 0, horizon = 5, px = c(-2, 3, 8), py = c(1, 1, 1), pz = 1, vx = 5, vy = c(2, 2, 2), vz = -3,
                     dx = c(1, 2, 3), dy = c(0.5, 0.5, 0.5), dz = -1)
  al <- analog_library(rows)
  expect_equal(nrow(al$lib), 6L)
  st <- list(p = c(RIM_X - 2, -1, RIM_Z + 1), v = c(5, -2, -3))      # the mirror image of the first row
  f <- analog_forecast(al, st, 0, 5, c(RIM_X, 0, RIM_Z), 1L, c(0.1, 0.1, 0.1))
  expect_equal(as.vector(f$X), st$p + c(1, -0.5, -1))
})
