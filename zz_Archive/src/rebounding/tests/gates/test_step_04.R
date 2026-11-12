# Gate 04 of the rebounding manual: the static rebounding model. Reads the outputs of run_step04.R; rules come from
# config/experiment.yaml (step03 decision rules, step04 settings), fixed before any fit.

source(file.path(here, "R", "folds.R"))
source(file.path(here, "R", "metrics.R"))
source(file.path(here, "R", "reference_baselines.R"))
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step04
s4 <- file.path(root, "outputs", "rebounding", "step04")
el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
choice <- choice_sets(el)
labels <- episode_labels(el)
pred <- fread(file.path(s4, "static_oof.csv.gz"), colClasses = list(character = "outcome_id"))
checks <- fread(file.path(s4, "checks.csv"))

test_that("exactly one credited outcome per choice set, team awards as their own outcomes", {
  expect_equal(nrow(merge(labels, choice, by = c("episode_id", "outcome_id"))), nrow(el))
  expect_setequal(unique(pred[!outcome_id %in% c("team_off", "team_def"), .N, by = .(time_point, episode_id)]$N), 10L)
  expect_equal(pred[outcome_id %in% c("team_off", "team_def"), .N, by = .(time_point, episode_id)][, unique(N)], 2L)
})

test_that("probabilities are valid and do not depend on candidate order, court direction or units", {
  expect_true(all(check_predictions(pred, choice, th3$metrics$sum_tol * 10)$ok))   # CSV keeps 15 significant digits
  expect_setequal(unique(pred$time_point), unlist(th$times))
  for (k in c("reordering candidate rows", "metres", "mirroring the court")) expect_true(checks[grepl(k, check)]$pass, info = k)
})

test_that("feature generation and fitting use the training games only, with the same code for test games", {
  for (k in c("scalers and fits use exactly", "labels are altered", "labels are flipped", "planted test-label leak",
              "Step 03 design freeze", "reproduces every prediction"))
    expect_true(checks[grepl(k, check)]$pass, info = k)
  lam <- fread(file.path(s4, "lambda_selection.csv"))
  expect_true(all(lam[, sum(selected), by = .(time_point, outer_fold)]$V1 == 1L))
  expect_true(all(lam$lambda %in% unlist(th$clogit$lambda_grid)))
  fa <- fread(file.path(root, "outputs", "rebounding", "step03", "fold_assignment.csv"))
  j <- merge(unique(pred[, .(episode_id, outer_fold)]), fa[, .(episode_id, f = outer_fold)], by = "episode_id")
  expect_true(all(j$outer_fold == j$f))
})

test_that("the logit is compared with every baseline using per-game log loss and calibration", {
  c1 <- fread(file.path(s4, "c1_by_reference.csv"))
  c1_refs <- unlist(th3$confirmatory[[which(vapply(th3$confirmatory, `[[`, "", "id") == "C1")]]$references)
  expect_setequal(c1$reference, c1_refs)
  expect_equal(c1$pass, c1$hi < 0 & c1$drop_one_max < 0)
  pg <- fread(file.path(s4, "paired_by_game.csv"))
  expect_true(all(c("game_id", "mean_diff") %in% names(pg)) && uniqueN(pg$game_id) == 10L)
  expect_true(all(file.exists(file.path(s4, c("calibration_classwise.csv", "calibration_groups.csv", "oreb_calibration.csv")))))
  s <- fread(file.path(s4, "scores_summary.csv"))
  expect_true(all(c("static_clogit", th3$baselines$models) %in% s[time_point == "release"]$model))
})

test_that("top-1 is measured once per rebound and the OREB model is scored against the constant rate", {
  s <- fread(file.path(s4, "scores_summary.csv"))
  expect_equal(s[time_point == "release" & model == "static_clogit"]$episodes, nrow(el))
  expect_true(checks[grepl("top-1 counted once", check)]$pass)
  o <- fread(file.path(s4, "oreb_oof.csv"))
  expect_equal(nrow(o), nrow(el))
  expect_true(all(o$p_off > 0 & o$p_off < 1))
  expect_true(checks[grepl("constant OREB reference equals", check)]$pass)
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "04_static_model.md")))
})
