# Step 08: causal player velocity, movement forecasts and limits, arrival times, the height envelope and margins.

source(file.path(here, "R", "player_motion.R"))
source(file.path(here, "R", "reach.R"))
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$step08
rp <- modifyList(cfg$reach, list(v_max = 24))

# two players over 40 frames: one at constant velocity (3, -2) ft/s, one standing; player 2 extrapolated after frame 120
moving <- function() {
  f <- 100:139
  tt <- (f - 100) / FPS
  rbind(data.table(frame = f, pid = 1L, x = 10 + 3 * tt, y = 5 - 2 * tt, det = 1L),
        data.table(frame = f, pid = 2L, x = 30, y = 0, det = as.integer(f <= 120)))
}

test_that("causal velocity is exact on straight-line motion, flags extrapolation and ignores later frames", {
  v <- causal_velocity(moving(), cfg$velocity$window_frames, cfg$velocity$min_detected)
  expect_equal(v[pid == 1 & frame == 120, c(vx, vy)], c(3, -2), tolerance = 1e-9)
  expect_true(all(is.na(v[pid == 1 & frame < 105]$vx)))             # window not full yet
  expect_equal(v[pid == 2 & frame == 130]$vel_from, "extrapolated")
  expect_equal(v[pid == 2 & frame == 130]$speed, 0)
  later <- moving()[frame > 120 & pid == 1, x := x + 50]
  v2 <- causal_velocity(later, cfg$velocity$window_frames, cfg$velocity$min_detected)
  expect_equal(v2[pid == 1 & frame == 120, c(vx, vy)], c(3, -2), tolerance = 1e-9)
  gap <- moving()[!(pid == 1 & frame == 117)]
  v3 <- causal_velocity(gap, cfg$velocity$window_frames, cfg$velocity$min_detected)
  expect_true(is.na(v3[pid == 1 & frame == 118]$vx))               # a missing frame breaks the window
  expect_equal(v[pid == 1 & frame == 130]$accel, 0, tolerance = 1e-9)
})

test_that("movement forecasts: limits of the damped model and the bounds", {
  f <- forecast_position(0, 0, 10, 0, 0.5, "damped", 1e-6)
  expect_equal(f$x, 5, tolerance = 1e-5)                             # tiny damping is constant velocity
  f <- forecast_position(0, 0, 10, 0, 0.5, "damped", 2)
  expect_equal(f$x, 10 * (1 - exp(-1)) / 2)
  expect_equal(forecast_position(1, 2, 9, 9, 3, "stationary")[c("x", "y")], list(x = 1, y = 2))
  b <- forecast_position(0, 0, 40, 0, 1, "bounded", 1e-6, vmax = 24)
  expect_lte(b$x, 24 + 1e-9)
  lim <- estimate_limits(data.table(det = 1L, speed = 1:1000 / 40, accel = 1:1000 / 20))
  expect_equal(lim$v_max, unname(quantile(1:1000 / 40, 0.995)))
  set.seed(2)
  n <- 400
  tau <- sample(c(0.2, 0.4, 0.6, 1), n, TRUE)
  vx <- rnorm(n, 0, 8)
  vy <- rnorm(n, 0, 8)
  k <- (1 - exp(-3 * tau)) / 3
  rows <- data.table(x = 0, y = 0, vx = vx, vy = vy, tau = tau, tx = vx * k + rnorm(n, 0, 0.2), ty = vy * k + rnorm(n, 0, 0.2))
  expect_equal(select_damping(rows, c(1, 2, 3, 5))$lambda, 3)
})

test_that("arrival time: reaction first, then straight at top speed to the catch radius", {
  expect_equal(arrival_time(0, 0, 0, 0, 1, 0, rp), rp$reaction_s)    # already within the catch radius
  expect_equal(arrival_time(0, 0, 0, 0, 14, 0, rp), rp$reaction_s + (14 - rp$catch_radius_ft) / 24)
  expect_lt(arrival_time(0, 0, 10, 0, 14, 0, rp), arrival_time(0, 0, -10, 0, 14, 0, rp))
})

test_that("the height envelope: no jump, a jump, or out of reach; a ball above everyone is not intercepted", {
  expect_equal(height_cost(c(7, 10, 12), rp), c(0, rp$takeoff_s, Inf))
  st <- data.table(pid = 1:3, off = c(TRUE, FALSE, TRUE), x = c(40, 36, 20), y = c(0, 2, 10), vx = 0, vy = 0)
  high <- data.table(frame = 101:110, bx = 40, by = 0, z = 12.5)
  m <- player_margins(st, high, 100L, rp)
  expect_true(all(m$margin == -Inf) && all(is.na(m$first_feasible)))
  low <- data.table(frame = 101:125, bx = 40, by = 0, z = seq(11, 6, length.out = 25))
  m <- player_margins(st, low, 100L, rp)
  expect_gt(m[pid == 1]$margin, m[pid == 2]$margin)
  expect_gt(m[pid == 2]$margin, m[pid == 3]$margin)
  expect_true(!is.na(m[pid == 1]$first_feasible))
  # rotating the court about any point leaves every margin unchanged
  th <- 1.1
  rot <- function(x, y) list(x = cos(th) * x - sin(th) * y, y = sin(th) * x + cos(th) * y)
  r1 <- rot(st$x, st$y)
  rv <- rot(st$vx, st$vy)
  r2 <- rot(low$bx, low$by)
  m2 <- player_margins(copy(st)[, `:=`(x = r1$x, y = r1$y, vx = rv$x, vy = rv$y)], copy(low)[, `:=`(bx = r2$x, by = r2$y)], 100L, rp)
  expect_equal(m2$margin, m$margin, tolerance = 1e-9)
})
