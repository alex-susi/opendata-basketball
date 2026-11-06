# Gate 10 of the rebounding manual: positioning and movement measures. Reads the outputs of run_step10.R; settings come
# from config/experiment.yaml (step10, fixed before any real-data run).

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step10
s10 <- file.path(root, "outputs", "rebounding", "step10")
checks <- fread(file.path(s10, "checks.csv"))
pm <- fread(file.path(s10, "opportunity_movement.csv.gz"))

test_that("movement uses one reference distribution and the decomposition identity holds", {
  expect_true(checks[grepl("decomposition adds up", check)]$pass)
  expect_true(checks[grepl("same reference distribution", check)]$pass)
  d <- pm[!is.na(total)]
  expect_lt(max(abs(d$total - d$move - d$info - d$interaction)), 1e-9)
  expect_lt(max(abs(d$move - (d$q_later_ref - d$q_release_ref))), 1e-9)
})

test_that("response onsets are checked under smoothing, threshold and tracking-error variants", {
  st <- fread(file.path(s10, "response_stability.csv"))
  expect_true(all(c("window 4", "window 10", "threshold 5 ft/s", "threshold 8 ft/s", "position error 1 ft") %in% st$variant))
  # owner deviation 2026-11-05: threshold variants judged on class change only; window and position error on both
  thr <- grepl("^threshold", st$variant)
  expect_equal(st$stable, st$class_changed <= 0.2 & (thr | is.na(st$median_onset_shift_frames) | st$median_onset_shift_frames <= 3))
  expect_true(all(c("response", "already moving", "no response") %in% pm$response))
  cv <- fread(file.path(s10, "response_onset_curve.csv"))
  expect_setequal(unique(cv$threshold_ft_s), unlist(th$response$threshold_curve))
  # a player timed at two thresholds never reaches the higher bar earlier (shares can move either way: a higher bar
  # also takes players out of "already moving")
  ro <- fread(file.path(s10, "response_onsets.csv.gz"))[variant %in% c("base", "threshold 8 ft/s") & response == "response"]
  w <- dcast(ro, episode_id + pid ~ variant, value.var = "onset_s")[!is.na(base) & !is.na(`threshold 8 ft/s`)]
  expect_gt(nrow(w), 0)
  expect_true(all(w$`threshold 8 ft/s` >= w$base - 1e-9))
})

test_that("roles and exposure are reported; player claims follow the prespecified rule", {
  r <- fread(file.path(s10, "by_role.csv"))
  expect_true(all(c("defence: rim protector", "offence: shooter", "offence: safety") %in% r$role))
  ex <- fread(file.path(s10, "exposure_by_player_game.csv"))
  expect_true(all(c("pid", "game_id", "episodes") %in% names(ex)))
  sp <- fread(file.path(s10, "player_split_by_game.csv"))
  expect_true(all(c("a", "b", "na", "nb") %in% names(sp)))
  pe <- fread(file.path(s10, "player_effects_shrunk.csv"))
  expect_true(all(pe$n >= th$effects$player_min_episodes))
  expect_true(all(abs(pe$shrunk) <= abs(pe$mean) + 1e-12))           # shrinkage never moves a mean away from zero
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "10_movement_attribution.md")))
})
