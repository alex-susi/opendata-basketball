# Step 00: a deterministic synthetic run. The same seed must give bit-identical synthetic scenes and summaries,
# and a different seed must not, so a later result can always be regenerated from its logged seed.

synthetic_scenes <- function(n, seed) {
  set.seed(seed, kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
  shots <- data.table::data.table(shot = seq_len(n), flip = sample(c(-1, 1), n, replace = TRUE),
                                  sx = runif(n, 15, 45), sy = runif(n, -24, 24))
  players <- shots[rep(seq_len(n), each = 10L)][, `:=`(slot = rep(1:10, n), x = rnorm(10L * n, 25, 10), y = rnorm(10L * n, 0, 8))]
  players[, `:=`(ax = flip * x, ay = flip * y)]
  players[, hoop_dist := sqrt((ax - 40.76)^2 + ay^2)]
  list(shots = shots, players = players,
       summary = players[, .(nearest = slot[which.min(hoop_dist)], mean_dist = mean(hoop_dist)), by = shot])
}

test_that("a fixed seed reproduces synthetic scenes bit for bit", {
  seed <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$seeds[[1]]
  a <- synthetic_scenes(200L, seed)
  b <- synthetic_scenes(200L, seed)
  expect_identical(a, b)
  expect_identical(digest::digest(a$summary, algo = "sha256"), digest::digest(b$summary, algo = "sha256"))
  expect_false(identical(a$summary, synthetic_scenes(200L, seed + 1L)$summary))
})

test_that("every configured seed is a distinct integer", {
  seeds <- unlist(yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$seeds)
  expect_true(length(seeds) >= 1L)
  expect_true(all(seeds == round(seeds)))
  expect_equal(anyDuplicated(seeds), 0L)
})
