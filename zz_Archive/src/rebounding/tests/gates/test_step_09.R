# Gate 09 of the rebounding manual: dynamic rebound probabilities. Reads the outputs of run_step09.R; settings come
# from config/experiment.yaml (step09, fixed before any real-data run; step03 rules C3a and C3b).

source(file.path(here, "R", "folds.R"))
source(file.path(here, "R", "metrics.R"))
source(file.path(here, "R", "reference_baselines.R"))
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step09
s9 <- file.path(root, "outputs", "rebounding", "step09")
el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
checks <- fread(file.path(s9, "checks.csv"))
pred <- fread(file.path(s9, "dynamic_oof.csv.gz"), colClasses = list(character = "outcome_id"))

test_that("every prediction is finite, non-negative and normalised, with player and team terms consistent", {
  expect_true(all(check_predictions(pred, choice_sets(el), cfg$step03$metrics$sum_tol * 10)$ok))
  expect_true(checks[grepl("P\\(OREB\\)", check)]$pass)
  expect_setequal(unique(pred$time_point), unlist(th$times))
})

test_that("particle sampling is stable and confidence does not collapse when the ball is seen less", {
  st <- fread(file.path(s9, "particle_stability.csv"))
  expect_setequal(st$run, c("second seed", "twice the particles"))
  expect_true(checks[grepl("particle draws stable", check)]$pass)
  expect_true(checks[grepl("half the ball frames are dropped", check)]$pass)
})

test_that("a causal replay never reads frames after the requested frame", {
  expect_true(checks[grepl("predict_rebound replays", check)]$pass)
  expect_true(checks[grepl("Step 03 design freeze", check)]$pass)
})

test_that("comparisons use the same games, labels and times, with per-game results and class and time calibration", {
  expect_true(checks[grepl("same episodes and time points", check)]$pass)
  cmp <- fread(file.path(s9, "comparisons.csv"))
  expect_true(all(c("C3a (confirmatory)", "C3b (confirmatory)") %in% cmp$test))
  expect_true(all(c("drop_one_max", "worst_game_diff", "games_better") %in% names(cmp)))
  expect_equal(uniqueN(fread(file.path(s9, "c3_by_game.csv"))$game_id), 10L)
  s <- fread(file.path(s9, "scores_summary.csv"))
  expect_true(all(c("ece", "team_log_loss") %in% names(s)))
  g <- fread(file.path(s9, "calibration_groups.csv"))
  expect_setequal(unique(g$time_point), unlist(th$times))
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "09_model_comparison.md")))
})
