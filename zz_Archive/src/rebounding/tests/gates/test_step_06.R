# Gate 06 of the rebounding manual: the causal ball filter. Reads the outputs of run_step06.R; settings come from
# config/experiment.yaml (step06, fixed before any real-data run; step03 uncertainty).

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step06
s6 <- file.path(root, "outputs", "rebounding", "step06")
checks <- fread(file.path(s6, "checks.csv"))

test_that("online prediction at t does not depend on later frames, and the run reproduces", {
  expect_true(checks[grepl("online state at t identical", check)]$pass)
  expect_true(checks[grepl("re-running fold 1", check)]$pass)
  expect_true(checks[grepl("Step 03 design freeze", check)]$pass)
})

test_that("covariance stays finite and positive; parameters come from training games only", {
  expect_true(checks[grepl("covariance finite", check)]$pass)
  expect_true(checks[grepl("training games' free segments", check)]$pass)
  p <- fread(file.path(s6, "parameters_by_fold.csv"))
  expect_equal(nrow(p), 10L)
  expect_true(all(p$q %in% unlist(th$q_grid)))
  expect_true(all(p$g > 0 & p$r_x > 0 & p$r_y > 0 & p$r_z > 0))
})

test_that("innovations and predictive coverage are reported on held-out games, by detection quality", {
  cv <- fread(file.path(s6, "coverage.csv"))
  expect_setequal(unique(cv$level), unlist(th$decision$coverage_levels))
  expect_true(all(c(as.character(unlist(th$evaluation$horizons_frames)), "all") %in% cv$horizon))
  st <- fread(file.path(s6, "by_stratum.csv"))
  expect_true(any(grepl("measured share", st$stratum)) && any(grepl("predError", st$stratum)))
  expect_true(nrow(fread(file.path(s6, "innovations.csv"))) > 0)
})

test_that("forecast errors are reported by horizon against the simple forecasts, with contacts tagged apart", {
  e <- fread(file.path(s6, "errors_by_horizon.csv"))
  expect_setequal(unique(e$model), c("kalman", "persistence", "constant_velocity", "gravity_only"))
  expect_setequal(unique(e$horizon), unlist(th$evaluation$horizons_frames))
  expect_true(file.exists(file.path(s6, "errors_crossing_contact.csv")))
  cmp <- fread(file.path(s6, "paired_vs_gravity_only.csv"))
  expect_equal(nrow(cmp), length(unlist(th$evaluation$horizons_frames)))
  expect_equal(cmp$non_inferior, cmp$hi < th$decision$margin_ft)
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "06_filter_diagnostics.md")))
})
