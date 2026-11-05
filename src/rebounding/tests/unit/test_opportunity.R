# Step 10: opportunity, its decomposition, the response onset, roles and shrinkage on synthetic cases.

for (f in c("player_motion.R", "reach.R", "opportunity_value.R", "response.R", "positioning.R")) source(file.path(here, "R", f))
rp <- list(reaction_s = 0.2, catch_radius_ft = 2, standing_reach_ft = 8.5, jump_reach_ft = 11, takeoff_s = 0.25, v_max = 15)
sig <- 0.45
B <- data.table(bx = RIM_X - 3 + rnorm(50, 0, 0.5), by = rnorm(50, 0, 0.5), z = 0, frame = 150L)

test_that("opportunity is a probability, high next to the ball and low far from it", {
  st <- data.table(pid = 1:3, x = c(RIM_X - 3, RIM_X - 15, RIM_X - 60), y = 0, vx = 0, vy = 0)
  q <- opportunity(st, 100L, B, rp, sig)
  expect_true(all(q$Q >= 0 & q$Q <= 1))
  expect_gt(q$Q[1], 0.95); expect_lt(q$Q[3], 0.05); expect_true(q$Q[1] > q$Q[2] && q$Q[2] > q$Q[3])
  q2 <- opportunity(st, 140L, B, rp, sig)                     # less time left: less opportunity
  expect_true(all(q2$Q <= q$Q + 1e-12))
})

test_that("the decomposition separates movement from information and adds up", {
  s_r <- data.table(pid = 1:2, x = c(RIM_X - 15, RIM_X - 15), y = c(0, 5), vx = 0, vy = 0)
  s_t <- copy(s_r)[pid == 1, x := RIM_X - 8]                  # player 1 moved toward the ball, player 2 stood still
  B_t <- copy(B)[, `:=`(bx = bx - 6, frame = 140L)]
  d <- decompose_opportunity(s_r, 100L, s_t, 120L, s_r, B, B_t, rp, sig)
  # absolute times: standing still loses access as the clock runs; moving toward the ball loses less
  expect_gt(d[pid == 1]$move, d[pid == 2]$move); expect_lt(d[pid == 2]$move, 0)
  expect_lt(abs(d[pid == 2]$move - (opportunity(s_r[2], 120L, B, rp, sig)$Q - opportunity(s_r[2], 100L, B, rp, sig)$Q)), 1e-12)
  expect_equal(d$total, d$move + d$info + d$interaction, tolerance = 1e-12)
  same <- decompose_opportunity(s_r, 100L, s_r, 100L, s_r, B, B, rp, sig)
  expect_equal(same$move, c(0, 0)); expect_equal(same$info, c(0, 0))
  base <- decompose_opportunity(s_r, 100L, s_t, 120L, s_t, B, NULL, rp, sig)
  expect_equal(base$vs_baseline, c(0, 0))                     # moving exactly as forecast earns nothing extra
  expect_true(all(is.na(base$info)))
})

test_that("the damped state follows Step 08's forecast and decays the velocity", {
  st <- data.table(pid = 1L, x = 0, y = 0, vx = 10, vy = 0)
  d <- damped_state(st, 1, 0.5, 30)
  expect_equal(d$x, 10 * (1 - exp(-0.5)) / 0.5); expect_equal(d$vx, 10 * exp(-0.5))
})

test_that("response onset: timed for a player who starts toward the ball, not for one already moving or moving away", {
  rs <- list(toward_ft_s = 6, rise_ft_s = 3, sustain_frames = 5)
  f <- 100:140; tt <- pmax(0, (f - 110) / FPS)
  v <- rbind(data.table(frame = f, pid = 1L, x = 20 + 10 * tt, y = 0, vx = fifelse(f >= 110, 10, 0), vy = 0),
             data.table(frame = f, pid = 2L, x = 20 + 9 * (f - 100) / FPS, y = 3, vx = 9, vy = 0),
             data.table(frame = f, pid = 3L, x = 20 - 8 * tt, y = -3, vx = fifelse(f >= 110, -8, 0), vy = 0))
  r <- response_onset(v, 100L, 140L, c(40, 0), rs)
  expect_equal(r[pid == 1]$response, "response"); expect_equal(r[pid == 1]$onset_s, 10 / FPS, tolerance = 1e-9)
  expect_equal(r[pid == 2]$response, "already moving"); expect_true(is.na(r[pid == 2]$onset_s))
  expect_equal(r[pid == 3]$response, "no response")
})

test_that("roles at release and empirical-Bayes shrinkage", {
  st <- data.table(pid = 1:10, off = rep(c(TRUE, FALSE), each = 5),
                   x = RIM_X - c(20, 4, 35, 15, 12, 2, 18, 10, 25, 14), y = c(0, 2, 0, 10, -8, 0, 1, 5, -10, -12))
  r <- assign_roles(st, 1L)
  expect_equal(r[pid == 1]$role, "offence: shooter"); expect_equal(r[pid == 2]$role, "offence: nearest the hoop")
  expect_equal(r[pid == 3]$role, "offence: safety"); expect_equal(r[pid == 6]$role, "defence: rim protector")
  expect_equal(r[pid == 7]$role, "defence: shooter's defender")
  set.seed(3)
  noise <- data.table(mean = rnorm(40, 0, 0.1), within_var = 0.25, n = 25)          # no real differences
  expect_lt(mean(eb_shrink(noise)$weight), 0.3)
  real <- data.table(mean = rnorm(40, 0, 1), within_var = 0.25, n = 25)
  expect_gt(mean(eb_shrink(real)$weight), 0.9)
  gm <- group_means(data.table(game_id = rep(1:5, each = 10), g = "a", v = rnorm(50)), "v", "g", 200L, 1L)
  expect_true(gm$lo <= gm$mean && gm$mean <= gm$hi)
})
