# Gate 01 of the rebounding manual: join, identity, timing, orientation and exclusion audits of the rebound episode
# table. Reads the outputs of run_step01.R; thresholds come from config/experiment.yaml (step01), fixed beforehand.

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step01
step01 <- file.path(root, "outputs", "rebounding", "step01")
ep <- fread(file.path(step01, "rebound_episodes.csv"), na.strings = c("", "NA"))   # fwrite writes NA as empty
el <- ep[eligible == TRUE]
checks <- fread(file.path(step01, "checks.csv"))

test_that("every eligible episode has a unique key and a valid shot association", {
  expect_equal(anyDuplicated(ep$episode_id), 0L)
  expect_equal(ep[!is.na(rebound_event_id), anyDuplicated(paste(game_id, rebound_event_id))], 0L)
  expect_true(all(!is.na(el$rebound_event_id)))
  expect_true(all(el$episode_id == el$shot_id))
  expect_true(all(startsWith(el$rebound_event_id, "rebound-")))
  expect_true(all(checks[area %in% c("keys", "joins")]$pass))
})

test_that("release, contact and rebound are in order, or carry an explicit flag", {
  expect_true(all(el$rebound_frame > el$release_frame))
  late <- el[!is.na(contact_proxy_frame) & rebound_frame < contact_proxy_frame]
  expect_true(all(grepl("rebound_before_contact_proxy", late$order_flags)))
  early <- el[rebound_frame < shot_end_frame]
  expect_true(all(grepl("rebound_before_shot_end", early$order_flags)))
})

test_that("player ids match the roster and the on-court players at release, with documented exceptions", {
  expect_true(all(el$release_n_off == 5L & el$release_n_def == 5L))
  expect_equal(sum(el$release_off_roster + el$release_wrong_team), 0L)
  expect_true(all(el$release_matches_chance))
  expect_true(all(el[rebounded == TRUE]$rebounder_tracked))
  expect_equal(lengths(strsplit(el$release_off_ids, ";")), rep(5L, nrow(el)))
  expect_equal(lengths(strsplit(el$release_def_ids, ";")), rep(5L, nrow(el)))
})

test_that("court orientation is right in both attack directions", {
  ori <- fread(file.path(step01, "orientation.csv"))
  expect_equal(nrow(ori), 2L)
  # the prespecified endFrame check was superseded after the first run (see config step01.orientation_approach)
  expect_true(all(ori$ball_nearer_attacked_hoop >= th$orientation_approach$share_min))
  expect_true(all(ori$shooter_gap_median <= th$orientation$shooter_gap_median_max_ft))
  expect_true(all(checks[area == "orientation"]$pass))
  expect_setequal(unique(el$flip), c(-1, 1))
  expect_true(all(el$flip == ifelse(el$left_hoop, -1, 1)))
})

test_that("ball and player availability and detection quality are reported by game and stage", {
  q <- fread(file.path(step01, "quality_by_game_stage.csv"))
  expect_setequal(unique(q$stage), c("pre_release", "flight", "contact_to_rebound", "after_rebound"))
  expect_equal(q[!is.na(game_id), uniqueN(game_id)], 10L)
  expect_true(all(c("ball_present", "ball_keyframe", "ball_detected", "ball_pred_error", "player_detected",
                    "player_err_detected", "player_err_extrapolated") %in% names(q)))
  expect_true(file.exists(file.path(step01, "period_coverage.csv")))
})

test_that("every exclusion is counted by cause and team-only rebounds stay team outcomes", {
  ex <- fread(file.path(step01, "exclusions.csv"))
  expect_equal(sum(ex$N), nrow(ep))
  expect_true(all(nzchar(ep[eligible == FALSE]$exclusion)))
  expect_setequal(unique(el$credited_outcome), c("off player", "def player", "off team award", "def team award"))
  expect_true(all(is.na(el[rebounded == FALSE]$rebounder_id)))
  expect_true(all(el[rebounded == FALSE]$credited_outcome %in% c("off team award", "def team award")))
})

test_that("edge cases are drawn, including both attack directions and the end of a period", {
  edge <- fread(file.path(step01, "figures", "edge_cases.csv"))
  expect_true(all(c("attacks camera-left hoop", "attacks camera-right hoop", "end of period") %in% edge$reason))
  expect_true(all(file.exists(file.path(step01, "figures", sprintf("edge_cases_%02d.png", unique(edge$page))))))
})
