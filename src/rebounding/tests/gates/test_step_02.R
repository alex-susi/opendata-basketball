# Gate 02 of the rebounding manual: contact-state labels and their reliability. Reads the outputs of run_step02.R;
# thresholds come from config/experiment.yaml (step02), fixed before the held-aside subset was opened.

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
ag <- cfg$step02$agreement
step02 <- file.path(root, "outputs", "rebounding", "step02")
s01 <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))
auto <- fread(file.path(step02, "auto_summary.csv"), na.strings = c("", "NA"))
smp <- fread(file.path(step02, "review", "sample.csv"))
freeze <- jsonlite::fromJSON(file.path(step02, "detector_freeze.json"))

test_that("every eligible episode has automated labels, and every labelled sequence is in time order", {
  expect_setequal(auto$episode_id, s01[eligible == TRUE]$episode_id)
  expect_equal(anyDuplicated(auto$episode_id), 0L)
  expect_true(all(is.na(auto$sequence_problems) | !nzchar(auto$sequence_problems)))
  ep <- merge(auto, s01[, .(episode_id, release_frame)], by = "episode_id")
  expect_true(all(ep$first_rim_or_board_frame > ep$release_frame, na.rm = TRUE))
  expect_true(all(ep$first_player_contact_frame > ep$release_frame, na.rm = TRUE))
  # every touch, tip and control is labelled or explicitly unknown
  expect_true(all(auto$first_contact_type %in% c("tip", "catch", "block", "UNKNOWN", "none")))
  expect_true(all(auto$terminal %in% c("control", "held_ball", "out_of_bounds", "unresolved")))
  expect_true(all(auto$contact_kind %in% c("rim", "board", "rim_or_board", "none", "UNKNOWN")))
})

test_that("the review sample has two disjoint subsets and the held-aside one was drawn after the labeler froze", {
  expect_equal(nrow(smp[subset == "dev"]), nrow(smp[subset == "heldout"]))
  expect_length(intersect(smp[subset == "dev"]$shot_id, smp[subset == "heldout"]$shot_id), 0L)
  expect_true(all(smp$shot_id %in% s01[eligible == TRUE]$episode_id))
  expect_equal(sha256_file(file.path(here, "R", "contact_states.R")), freeze$contact_states_sha256)
  expect_equal(sha256_file(file.path(step02, "auto_summary.csv")), freeze$auto_summary_sha256)
  frozen <- as.POSIXct(freeze$frozen_at, format = "%Y-%m-%dT%H:%M:%S")
  pages <- list.files(file.path(step02, "review"), "^heldout_[0-9]+\\.png$", full.names = TRUE)
  expect_gt(length(pages), 0L)
  expect_true(all(file.mtime(pages) > frozen))
})

test_that("agreement is computed with the prespecified tolerances, respecting 25 Hz frames", {
  tab <- fread(file.path(step02, "agreement.csv"))
  expect_true(all(c("contact", "first touch", "touch type", "control", "tip chain") %in% tab$type))
  expect_true(any(tab$measure == sprintf("frame within %d", ag$frame_tol_contact)))
  expect_true(any(tab$measure == sprintf("frame within %d", ag$frame_tol_player)))
  expect_true(all(tab[!is.na(ci_low)]$ci_low <= tab[!is.na(ci_low)]$value + 1e-9))
  dec <- fread(file.path(step02, "agreement_decisions.csv"))
  expect_true(all(dec$status %in% c("PASS", "BLOCKED")))
})

test_that("ball height is stratified by tip, catch and control, with detection quality", {
  h <- fread(file.path(step02, "ball_height_by_touch_type.csv"))
  expect_true(all(c("tip", "catch", "control") %in% h$type))
  expect_true(all(c("detected", "extrapolated or unknown") %in% h$actor_detected))
  expect_true(all(h$median > 0 & h$median < 15))
})

test_that("the contract file keeps observed contacts and reviewer labels apart from landing points", {
  ce <- fread(file.path(root, "outputs", "rebounding", "annotations", "contact_events.csv"), na.strings = c("", "NA"))
  expect_true(all(c("episode_id", "frame_idx", "kind", "actor_id", "confidence", "ball_z_ft", "review_status") %in% names(ce)))
  expect_false(any(grepl("landing", ce$kind)))
  expect_true(all(ce[labeler == "reviewer1"]$episode_id %in% smp[subset == "heldout"]$shot_id))
  expect_true(any(ce$review_status == "automated") && any(grepl("reviewed", ce$review_status)))
})

test_that("a false-positive and an ambiguous case are drawn from the tracking", {
  cases <- fread(file.path(step02, "figures", "cases.csv"))
  expect_setequal(cases$case, c("false_positive", "ambiguous"))
  expect_true(all(file.exists(file.path(step02, "figures", paste0(cases$case, ".png")))))
})
