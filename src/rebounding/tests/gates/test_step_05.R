# Gate 05 of the rebounding manual: the release-time spatial prior. Reads the outputs of run_step05.R; settings come
# from config/experiment.yaml (step05, fixed before any fit; step03 decision rules).

source(file.path(here, "R", "spatial_prior.R"))
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step05
s5 <- file.path(root, "outputs", "rebounding", "step05")
el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
checks <- fread(file.path(s5, "checks.csv"))
sc <- fread(file.path(s5, "spatial_oof.csv.gz"))

test_that("the density is normalised over the allowed domain in feet", {
  for (k in c("sums to 1", "positive and finite", "maps exist for every", "cell area")) expect_true(checks[grepl(k, check)]$pass, info = k)
  g <- spatial_grid(th$domain)
  expect_equal(c(min(g$xe), max(g$xe)), c(0, 46)); expect_equal(c(min(g$ye), max(g$ye)), c(-25, 25))
})

test_that("held-out coverage of the prespecified regions is reported with intervals, by shot range and game", {
  for (f in c("coverage.csv", "coverage_by_shot_range.csv", "coverage_by_game.csv")) {
    d <- fread(file.path(s5, f))
    expect_true(all(c("coverage", "lo", "hi", "level") %in% names(d)), info = f)
    expect_setequal(unique(d$level), unlist(th$scores$coverage_levels))
    expect_true(all(d$lo <= d$coverage & d$coverage <= d$hi), info = f)
  }
  expect_equal(uniqueN(fread(file.path(s5, "coverage_by_game.csv"))$game_id), 10L)
})

test_that("proper scores are compared with the pooled prior under the frozen rule, and sharpness alone cannot pass", {
  cmp <- fread(file.path(s5, "paired_comparisons.csv"))
  expect_true(all(c("pooled_kde uniform", "side_range_kde pooled_kde") %in% cmp[confirmatory == TRUE, paste(candidate, reference)]))
  expect_equal(cmp$superior, cmp$hi < 0 & cmp$drop_one_max < 0)
  s <- fread(file.path(s5, "scores_summary.csv"))
  expect_setequal(s$model, SPATIAL_MODELS)
  expect_true(all(c("area_80", "coverage_0.8") %in% names(s)))
})

test_that("subgroups are reported and team awards stay outside the location target", {
  t <- fread(file.path(s5, "spatial_targets.csv"))
  expect_equal(nrow(t), nrow(el))
  expect_true(all(is.na(t[rebounded == FALSE]$cell)))
  expect_true(all(!is.na(t[rebounded == TRUE]$cell)))
  sub <- fread(file.path(s5, "by_subgroup.csv"))
  expect_true(all(c("low tracking quality", "identity_suspect") %in% sub$subgroup))
  expect_true(any(grepl("^shot range", sub$subgroup)))
})

test_that("the realised location is never an input at release, and the run reproduces", {
  expect_true(checks[grepl("never reach their own maps", check)]$pass)
  expect_true(checks[grepl("fitted on exactly its training", check)]$pass)
  expect_true(checks[grepl("reproduces every score", check)]$pass)
  expect_equal(uniqueN(sc$episode_id), sum(el$rebounded))
  expect_true(all(file.exists(file.path(s5, "figures", c("05_heatmaps_all_games.png", "05_heldout_examples.png")))))
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "05_spatial_prior.md")))
})
