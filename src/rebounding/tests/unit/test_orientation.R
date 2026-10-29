# Step 01: the camera-to-attack-frame transform on synthetic positions, in both attack directions.

test_that("rotating twice restores the camera coordinates exactly, for both directions", {
  set.seed(1)
  x <- runif(1000, -47, 47)
  y <- runif(1000, -25, 25)
  for (f in c(-1, 1)) {
    a <- attack_frame(x, y, f)
    b <- attack_frame(a$x, a$y, f)
    expect_identical(b$x, x)
    expect_identical(b$y, y)
  }
})

test_that("the attacked hoop lands at +x in both directions", {
  left <- attack_frame(-RIM_X, 0, -1)    # offence attacks the camera-left hoop
  right <- attack_frame(RIM_X, 0, 1)     # offence attacks the camera-right hoop
  expect_equal(c(left$x, left$y), c(RIM_X, 0))
  expect_equal(c(right$x, right$y), c(RIM_X, 0))
})

test_that("the transform is a rotation, not a reflection: handedness and distances survive", {
  set.seed(2)
  p <- matrix(runif(30, -20, 20), ncol = 2)   # 15 points: e.g. ball and players of one frame
  signed_area <- function(m) (m[2, 1] - m[1, 1]) * (m[3, 2] - m[1, 2]) - (m[3, 1] - m[1, 1]) * (m[2, 2] - m[1, 2])
  a <- attack_frame(p[, 1], p[, 2], -1)
  q <- cbind(a$x, a$y)
  expect_equal(as.matrix(dist(q)), as.matrix(dist(p)))
  for (i in 1:13) expect_equal(sign(signed_area(q[i:(i + 2), ])), sign(signed_area(p[i:(i + 2), ])))
  # a reflection (x only) would flip handedness; the check above would catch it
  r <- cbind(-p[, 1], p[, 2])
  expect_false(isTRUE(all.equal(sign(signed_area(r[1:3, ])), sign(signed_area(p[1:3, ])))))
})

test_that("one flip per shot: every entity of a frame gets the same rotation", {
  ents <- data.table::data.table(entity = c("ball", 1:10), x = seq(-30, 30, length.out = 11), y = seq(10, -10, length.out = 11))
  a <- attack_frame(ents$x, ents$y, -1)
  expect_equal(a$x, -ents$x)
  expect_equal(a$y, -ents$y)
  expect_error(attack_frame(1, 1, 0))
})

test_that("period coverage counts running frames against 25 x period length", {
  clock <- data.table::data.table(game_id = 1L, period = rep(c(1L, 5L), c(25L * 600L, 25L * 150L)),
                                  gc = c(seq(600, 0.04, by = -0.04), seq(300, 150.04, by = -0.04)),
                                  stopped = FALSE, no_players = FALSE)
  cv <- period_coverage(clock)
  expect_equal(cv[period == 1L]$running_share, 1)
  expect_equal(cv[period == 5L]$running_share, 0.5)
  expect_equal(cv[period == 1L]$start_gap, 0)
  expect_equal(cv$length_s, c(600, 300))
})
