# Gate 03 of the rebounding manual: frozen evaluation design, reference baselines and scoring harness. Reads the
# outputs of run_step03.R; settings come from config/experiment.yaml (step03), fixed before any baseline was scored.

source(file.path(here, "R", "folds.R"))
source(file.path(here, "R", "metrics.R"))
source(file.path(here, "R", "reference_baselines.R"))
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step03
step03 <- file.path(root, "outputs", "rebounding", "step03")
el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(file.path(step03, "fold_assignment.csv"))
pred <- fread(file.path(step03, "reference_baselines.csv.gz"), colClasses = list(character = "outcome_id"))
leak <- fread(file.path(step03, "leakage_checks.csv"))
choice <- choice_sets(el)
labels <- episode_labels(el)

test_that("every rebound is in exactly one outer test fold, and its game never in that fold's training", {
  expect_setequal(fa$episode_id, el$episode_id)
  expect_equal(anyDuplicated(fa$episode_id), 0L)
  expect_equal(fa[, uniqueN(game_id), by = outer_fold]$V1, rep(1L, 10))
  expect_true(all(check_folds(fa)$pass))
  dates <- as.character(fa[order(outer_fold), game_date[1], by = outer_fold]$V1)
  expect_equal(dates, sort(dates))   # fold k is the k-th game by date
  prov <- unique(pred[, .(time_point, outer_fold, test_game, n_train)])
  pts <- fread(file.path(step03, "prediction_points.csv"))[defined == TRUE]
  for (i in seq_len(nrow(prov))) {
    ids <- pts[time_point == prov$time_point[i]]$episode_id
    expect_equal(prov$n_train[i], nrow(fa[episode_id %in% ids & outer_fold != prov$outer_fold[i]]))
    expect_equal(prov$test_game[i], fa[outer_fold == prov$outer_fold[i]]$game_id[1])
  }
})

test_that("baseline probabilities are finite, normalised, on the episode's choice set and from training games only", {
  v <- check_predictions(pred, choice, th$metrics$sum_tol * 10)   # CSV keeps 15 significant digits
  expect_true(all(v$ok))
  expect_setequal(unique(pred$model), c(BASELINES, "selected_reference"))
  expect_true(all(leak[grepl("training games|labels are altered", check)]$pass))
})

test_that("a planted future-only feature and an altered test label make the leakage checks fail", {
  expect_true(leak[grepl("planted test-label leak", check)]$pass)
  expect_true(leak[grepl("planted future-only feature", check)]$pass)
  expect_true(leak[grepl("poisoning", check)]$pass)
  expect_true(leak[grepl("after their information time", check)]$pass)
})

test_that("re-running with the same settings reproduces the predictions; no unlogged choice", {
  cached <- readRDS(file.path(root, "outputs", "cache", "rebounding", "step03_features.rds"))
  tp <- "release"
  r <- fold_predictions(cached$features[time_point == tp], labels, fa, choice, th$baselines$smoothing, th$metrics$prob_floor)
  a <- r$pred[, .(model, episode_id, outcome_id, p = probability)]
  b <- pred[time_point == tp, .(model, episode_id, outcome_id, q = probability)]
  j <- merge(a, b, by = c("model", "episode_id", "outcome_id"))
  expect_equal(nrow(j), nrow(a))
  expect_equal(nrow(j), nrow(b))
  expect_lt(max(abs(j$p - j$q)), 1e-12)
  sel <- fread(file.path(step03, "baseline_selection.csv"))
  expect_equal(sel[selected == TRUE, .N, by = .(time_point, outer_fold)][, unique(N)], 1L)
  expect_true(all(leak[grepl("reproduces", check)]$pass))
  fz <- jsonlite::fromJSON(file.path(step03, "design_freeze.json"))
  expect_equal(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th))))
  for (f in names(fz$code_sha256)) expect_equal(fz$code_sha256[[f]], sha256_file(file.path(here, "R", f)), info = f)
  expect_equal(fz$predictions_sha256, sha256_file(file.path(step03, "reference_baselines.csv.gz")))
})

test_that("team and player outcomes and exclusions are defined once for every model", {
  sc <- fread(file.path(step03, "scores_episode.csv.gz"))
  eps <- sc[, .(eps = paste(sort(episode_id), collapse = ",")), by = .(model, time_point)][, uniqueN(eps), by = time_point]
  expect_true(all(eps$V1 == 1L))
  expect_true(all(sc$episode_id %in% el$episode_id))
  expect_true(all(labels$outcome_id %in% choice$outcome_id))
  expect_equal(sum(labels$outcome_id %in% c("team_off", "team_def")), sum(!el$rebounded))
  expect_true(all(sc[model == "side_prior", .(d = abs(mean(p_off) - mean(y_off))), by = time_point]$d < 0.1))
})

test_that("scores, per-game paired differences, calibration and the report exist for the confirmatory times", {
  s <- fread(file.path(step03, "scores_summary.csv"))
  for (tp in unlist(th$confirmatory_times)) expect_setequal(s[time_point == tp]$model, c(BASELINES, "selected_reference"))
  cmp <- fread(file.path(step03, "paired_comparisons.csv"))
  expect_true(all(c("boot_lo", "boot_hi", "game_t_lo", "game_t_hi", "drop_one_max", "worst_game") %in% names(cmp)))
  expect_false(any(cmp$confirmatory))
  expect_true(nrow(fread(file.path(step03, "paired_by_game.csv"))) > 0)
  expect_true(all(file.exists(file.path(step03, c("calibration_classwise.csv", "calibration_team.csv", "population_by_game.csv")))))
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "03_evaluation_design.md")))
  expect_true(all(c("C1", "C2", "C3a", "C3b") %in% vapply(th$confirmatory, `[[`, "", "id")))
  c1 <- th$confirmatory[[which(vapply(th$confirmatory, `[[`, "", "id") == "C1")]]
  expect_setequal(unlist(c1$references), c(BASELINES, "selected_reference"))   # config v3: beat every baseline
  expect_true(exists("decide_against"))
})
