# Gate 07 of the rebounding manual: forecasts after the ball reaches the rim. Reads the outputs of run_step07.R;
# settings come from config/experiment.yaml (step07, fixed before any real-data run; step03 rules).

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step07
s7 <- file.path(root, "outputs", "rebounding", "step07")
checks <- fread(file.path(s7, "checks.csv"))

test_that("particle weights sum to one and the effective sample size and degeneracy are monitored", {
  expect_true(checks[grepl("weights sum to 1", check)]$pass)
  expect_true(checks[grepl("effective sample size monitored", check)]$pass)
  d <- fread(file.path(s7, "particle_diagnostics.csv"))
  expect_true(all(c("mean_ess_share", "resampled_share", "degenerate_share") %in% names(d)))
})

test_that("Monte Carlo stability is measured with a second seed and twice the particles", {
  st <- fread(file.path(s7, "mc_stability.csv"))
  expect_setequal(st$run, c("second seed", "twice the particles"))
  expect_true(all(st$targets > 0))
  expect_equal(st$stable, st$mean_abs_diff < 0.05 & abs(st$mean_diff) < 0.02)
})

test_that("rim, board and unclear examples are drawn and classified, or marked unvalidated", {
  ex <- fread(file.path(s7, "examples.csv"))
  expect_gte(nrow(ex), 4L)
  expect_true(all(grepl("unvalidated", ex$label_status)))
  expect_true(file.exists(file.path(s7, "figures", "07_examples.png")))
})

test_that("held-out coverage and proper scores are compared with the empirical transitions under fixed rules", {
  cv <- fread(file.path(s7, "coverage.csv"))
  expect_setequal(unique(cv$model), c("gravity_gauss", "empirical", "physics"))
  expect_setequal(unique(cv$level), unlist(th$scores$coverage_levels))
  cmp <- fread(file.path(s7, "paired_comparisons.csv"))
  expect_true(all(c("empirical gravity_gauss", "physics empirical") %in% paste(cmp$candidate, cmp$reference)))
  expect_equal(cmp$superior, cmp$hi < 0 & cmp$drop_one_max < 0)
  expect_true(checks[grepl("same targets", check)]$pass)
})

test_that("no later contact or rebound location reaches an earlier forecast; hoops come from training games", {
  expect_true(checks[grepl("later frames are corrupted", check)]$pass)
  expect_true(checks[grepl("training games' made shots", check)]$pass)
  expect_true(checks[grepl("Step 03 design freeze", check)]$pass)
  expect_true(grepl("BLOCKED by the manual", th$decision$physics))
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "07_collision_audit.md")))
})
