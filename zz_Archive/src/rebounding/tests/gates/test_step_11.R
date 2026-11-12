# Gate 11 of the rebounding manual: geometric obstruction and box-out validity. Reads the outputs of run_step11.R;
# settings come from config/experiment.yaml (step11, fixed before any real-data run).

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step11
s11 <- file.path(root, "outputs", "rebounding", "step11")
checks <- fread(file.path(s11, "checks.csv"))

test_that("pairwise geometry passes mirroring, rotation, zero-distance, perturbation and target checks on real data", {
  for (k in c("mirroring", "rotating", "finite", "one-foot moves: mean", "one-foot moves: share", "target sensitivity"))
    expect_true(checks[grepl(k, check)]$pass, label = k)
  pe <- fread(file.path(s11, "perturbation.csv"))
  expect_setequal(pe$time_point, unlist(th$times))
  expect_true(all(pe$pairing_changed <= th$perturbation$max_pairing_change))
})

test_that("obstruction is measured before the rebound and no future outcome defines a predictor", {
  expect_true(checks[grepl("frames <= t", check)]$pass)
  expect_true(checks[grepl("planted future", check)]$pass)
  expect_true(checks[grepl("labels are altered", check)]$pass)
})

test_that("the candidate is compared with Step 04 on the same episodes, and the keep rule is applied as written", {
  expect_true(checks[grepl("reproduces its held-out", check)]$pass)
  expect_true(checks[grepl("same episodes", check)]$pass)
  cmp <- fread(file.path(s11, "comparison.csv"))
  expect_setequal(cmp$time_point, unlist(th$times))
  expect_setequal(cmp$metric, c("ll", "team_ll"))
  m <- cfg$step03$decision$non_inferiority_margin_nats
  expect_equal(cmp$non_inferior, cmp$hi < m)
  expect_equal(cmp$superior, cmp$hi < 0 & cmp$drop_one_max < 0)
  expect_equal(cmp$ece_ok, cmp$ece_candidate <= cmp$ece_reference + cfg$step03$decision$calibration_ece_margin)
})

test_that("collection, team chance and obstruction contribution are separate quantities that add up", {
  cs <- fread(file.path(s11, "contribution_split.csv.gz"))
  expect_true(all(c("collection", "team_secures", "contrib_own", "contrib_mates", "contrib_team") %in% names(cs)))
  expect_lt(max(abs(cs$contrib_team - cs$contrib_own - cs$contrib_mates)), 1e-9)
  expect_true(all(cs$collection <= cs$team_secures + 1e-12))
  # a player who blocks nobody contributes nothing
  z <- cs[blocking_opp == 0]
  if (nrow(z)) expect_lt(max(abs(z$contrib_team)), 1e-9)
})

test_that("box-out detection is not claimed without independent labels; the review sample is blind and stratified", {
  # (the gate record is written after these tests run, so the report is checked instead)
  rep <- readLines(file.path(root, "outputs", "rebounding", "reports", "11_boxout_validity.md"))
  expect_true(any(grepl("box-out detection and box-out ability stay BLOCKED", rep, fixed = TRUE)))
  smp <- fread(file.path(s11, "review", "sample.csv"))
  expect_equal(uniqueN(smp$episode_id), nrow(smp))
  expect_true(all(table(smp$stratum) <= th$labels$per_stratum))
  sheet <- fread(file.path(s11, "review", "reviewer_heldout.csv"), colClasses = "character")
  expect_false(any(c("stratum", "o_br", "o_rb", "b", "r") %in% names(sheet)))   # the sheet does not reveal the proxy
  expect_true(file.exists(file.path(root, "outputs", "rebounding", "reports", "11_boxout_validity.md")))
})
