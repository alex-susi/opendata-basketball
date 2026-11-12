# Step 02: the contact-state labeler on synthetic tracks with known contacts, touches and control.

source(file.path(here, "R", "bundle.R"))
source(file.path(here, "R", "contact_states.R"))
th <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$step02$detector
G <- th$g_track_ft_s2
hoop <- list(hx = RIM_X, hy = 0)   # no calibration offset: the ball and player frames coincide

# A shot from (20, 0, 8) ft that meets the rim at frame 25 (1.0 s), bounces back out and is caught by defender 2
# standing at the point where it comes down to chest height; the ball then stays with him.
synthetic_episode <- function(fill_midpoints = FALSE) {
  f <- 0:110
  t <- f / FPS
  vx <- (RIM_X - 1.1 - 20) / 1.0
  vz <- (10.6 - 8 + 0.5 * G)
  x <- 20 + vx * t
  z <- 8 + vz * t - 0.5 * G * t^2
  after <- f > 25
  t2 <- t[after] - 1.0
  x[after] <- (RIM_X - 1.1) - 8 * t2
  z[after] <- 10.6 + 6 * t2 - 0.5 * G * t2^2
  catch_f <- 25 + 20
  held <- f >= catch_f
  px2 <- (RIM_X - 1.1) - 8 * 0.8
  x[held] <- px2
  z[held] <- 5
  if (fill_midpoints) {
    odd <- which(f %% 2 == 1 & f > 0 & f < max(f))
    x[odd] <- (x[odd - 1] + x[odd + 1]) / 2
    z[odd] <- (z[odd - 1] + z[odd + 1]) / 2
  }
  frames <- data.table(frame = f, bx = x, by = 0, bz = z, berr = 1, bspeed = 0)
  ppos <- data.table(pid = 1:10, home = rep(c(TRUE, FALSE), each = 5),
                     x = c(20, 10, 12, 14, 16, px2, 10, 12, 14, 16), y = c(0, 15, -15, 18, -18, 0, 15, -15, 18, -18))
  ppos[6, pid := 2L]
  ppos[2, pid := 6L]
  players <- ppos[, .(frame = f, x, y, det = 1L, err = 1), by = .(pid, home)]
  raw <- list(frames = frames, players = players, home_team = 100L)
  s <- data.table(shot_id = "synthetic", game_id = 1L, f0 = 0L, f1 = 24L, rf = 50L, flip = 1, off_team = 100L,
                  pid = 1L, rpid = 2L)
  list(raw = raw, s = s, catch_f = catch_f)
}

test_that("a ballistic arc is predicted exactly and a pure arc never breaks", {
  t <- seq(0, 1, by = 0.04)
  z <- 7 + 18 * t - 0.5 * G * t^2
  p <- arc_predict(t[1:6], 3 * t[1:6], -t[1:6], z[1:6], t[10], G)
  expect_equal(unname(p[1, ]), c(3 * t[10], -t[10], z[10]), tolerance = 1e-9)
  tr <- data.table(frame = 0:25, t = t, x = 3 * t, y = 0, z = z)[, key := TRUE]
  expect_equal(nrow(segment_breaks(tr, th, 0.65, 0L)), 0L)
})

test_that("the rim contact, the catch and control are found at the right frames and in order", {
  # With and without filled frames.
  for (fill in c(FALSE, TRUE)) {
    e <- synthetic_episode(fill)
    r <- episode_contact_states(e$raw, e$s, hoop, th, 0.65)
    sm <- r$summary
    expect_true(sm$contact_kind %in% CONTACT_KINDS)
    expect_lte(abs(sm$first_rim_or_board_frame - 25L), 2L)
    expect_equal(sm$first_contact_player_id, 2L)
    expect_equal(sm$first_contact_type, "catch")
    expect_lte(abs(sm$first_player_contact_frame - e$catch_f), 3L)
    expect_equal(sm$controller_id, 2L)
    expect_lte(abs(sm$first_control_frame - e$catch_f), 3L)
    expect_equal(sm$terminal, "control")
    expect_equal(sm$ball_center_z_at_control, 5, tolerance = 0.6)
    expect_length(sequence_problems(sm, 0L), 0L)
    expect_true(all(diff(r$events$frame) >= 0))
  }
})

test_that("filled-in midpoints are not treated as measured frames", {
  e <- synthetic_episode(TRUE)
  tr <- contact_track(e$raw, e$s, 0L, 60L, hoop, th$keyframe_tol_ft)
  expect_false(any(tr[frame %in% seq(3, 21, 2)]$key))
  expect_true(all(tr[frame %in% seq(2, 20, 2)]$key))
})

test_that("a low bounce away from everyone is a floor bounce, not a player touch", {
  f <- 0:30
  t <- f / FPS
  # falling from 4 ft at 15 ft/s to the floor at frame 10, then rising again
  z <- c(4 - 15 * t[1:11] - 0.5 * G * t[1:11]^2, NA)[1:11]
  zb <- z[11]
  t2 <- t[12:31] - t[11]
  z <- c(z, zb + 12 * t2 - 0.5 * G * t2^2)
  tr <- data.table(frame = f, t = t, x = 2 * t, y = 0, z = z, xp = 2 * t, yp = 0)[, key := TRUE]
  br <- segment_breaks(tr, th, 0.65, 0L)
  expect_gte(nrow(br), 1L)
  near <- data.table(frame = integer(), pid = integer(), off = logical(), px = numeric(), py = numeric(),
                     det = integer(), err = numeric(), d = numeric())
  k <- classify_break(br[1], tr, near, hoop, th)
  expect_equal(k$kind, "floor")
})

test_that("sequence checks flag control before the first touch and labels after the ball went out", {
  sm <- data.table(first_rim_or_board_frame = 30L, first_player_contact_frame = 50L, first_contact_type = "tip",
                   first_control_frame = 45L, out_of_bounds_frame = NA_integer_)
  expect_true("control_before_first_touch" %in% sequence_problems(sm, 0L))
  sm2 <- copy(sm)[, `:=`(first_control_frame = 60L, out_of_bounds_frame = 55L)]
  expect_true("control_after_out_of_bounds" %in% sequence_problems(sm2, 0L))
  sm3 <- copy(sm)[, first_control_frame := 60L]
  expect_length(sequence_problems(sm3, 0L), 0L)
})
