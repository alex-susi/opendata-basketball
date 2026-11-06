# Gate 08 of the rebounding manual: player movement and reachability. Reads the outputs of run_step08.R; settings come
# from config/experiment.yaml (step08, fixed before any real-data run; step03 rules).

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step08
s8 <- file.path(root, "outputs", "rebounding", "step08")
checks <- fread(file.path(s8, "checks.csv"))

test_that("movement respects speed limits learned from training games, and velocities are causal", {
  for (k in c("speed limit plausible", "above the training v_max", "later frames are corrupted", "training games only"))
    expect_true(checks[grepl(k, check)]$pass, info = k)
  lim <- fread(file.path(s8, "limits_and_damping_by_fold.csv"))
  expect_equal(nrow(lim), 10L)
  expect_true(all(lim$lambda %in% unlist(th$movement$damping_grid_per_s)))
})

test_that("static and damped-velocity forecasts stay as comparison baselines, by horizon and stratum", {
  e <- fread(file.path(s8, "movement_errors.csv"))
  expect_setequal(unique(e$model), c("stationary", "constant_velocity", "damped", "bounded"))
  expect_setequal(unique(e$horizon), unlist(th$movement$horizons_frames))
  cmp <- fread(file.path(s8, "paired_movement.csv"))
  expect_equal(cmp$superior, cmp$hi < 0 & cmp$drop_one_max < 0)
  expect_true(any(grepl("extrapolated", fread(file.path(s8, "movement_by_stratum.csv"))$stratum)))
})

test_that("sensitivity to reaction delay, height, jump timing, position error and missing frames is reported", {
  r <- fread(file.path(s8, "reach_summary.csv"))
  expect_true(all(c("base", "position error 1 ft", "half the ball frames") %in% r$variant))
  expect_true(any(grepl("^reaction", r$variant)) && any(grepl("^jump reach", r$variant)) && any(grepl("^takeoff", r$variant)))
  expect_true(all(c("feasible_mean", "earliest_arriver_changes") %in% names(r)))
})

test_that("first touch, first control and credit are kept apart; a ball out of reach is never intercepted", {
  r <- fread(file.path(s8, "reach_summary.csv"))
  expect_true(all(c("credited_feasible", "auto_first_feasible") %in% names(r)))
  expect_true(checks[grepl("above every player's reach", check)]$pass)
  expect_true(grepl("BLOCKED", th$status))
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "08_reachability.md")))
})
