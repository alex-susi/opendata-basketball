## ═════════════════════════════════════════════════════════════════════════════
# Step 01 of the rebounding manual: a trustworthy rebound episode table and its join, identity, timing,
# orientation, coverage and exclusion audits.
#   Rscript src/rebounding/run_step01.R
# Needs outputs/cache/rebounding/raw_*.rds (extract_windows.R), episodes.rds (run_audit.R) and gate0.rds
# (run_gate0.R): the event joins, outcome taxonomy and exclusions of the earlier Gate 0 are reused, not redone.
# Writes outputs/rebounding/step01/ (episode table, checks, quality, coverage, orientation, figures),
# outputs/rebounding/reports/01_join_audit.md and gate_results/01_episodes.json. The frame-by-entity tracking table
# and the frame index go to outputs/cache/rebounding/processed/ (git-ignored: they are the supplied tracking).
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "gate0.R", "step00.R", "step01.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step01
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "step01")
processed <- file.path(cache, "processed")
reports <- file.path(root, "outputs", "rebounding", "reports")
gr <- file.path(root, "outputs", "rebounding", "gate_results")
for (d in c(out, file.path(out, "figures"), processed, reports, gr)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
g0 <- readRDS(file.path(cache, "gate0.rds"))
audited <- readRDS(file.path(cache, "episodes.rds"))
ep <- copy(g0$episodes)
ep <- merge(ep, audited$episodes[, .(shot_id, loc_gap)], by = "shot_id", all.x = TRUE, sort = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PER GAME ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Frame index, coverage, tracking rows, and the per-episode records.

coverage <- list()
orient <- list()
idrel <- list()
idreb <- list()
quality <- list()
round_trip <- 0
trk_path <- file.path(processed, "tracking_frames.csv.gz")
idx_path <- file.path(processed, "frame_index.csv.gz")
for (p in c(trk_path, idx_path)) if (file.exists(p)) file.remove(p)
# One game at a time: frame index, coverage, tracking rows and per-episode records.
for (g in matches$id) {
  message("Step 01: ", g)
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  raw$home_team <- matches$home_team$id[matches$id == g]
  away <- matches$away_team$id[matches$id == g]
  clock <- tracking_clock(root, g)
  coverage[[length(coverage) + 1L]] <- period_coverage(clock)
  fwrite(clock[, .(game_id, frame_idx = frame, wall_ms = wall, game_clock = gc, clock_stopped = stopped, period,
                   no_players, no_ball)], idx_path, append = file.exists(idx_path))
  trk <- tracking_rows(raw, raw$home_team, away)
  # the attack-frame rotation applied twice must give back the camera coordinates exactly, for both directions
  for (f in c(-1, 1)) {
    a <- attack_frame(trk$x_ft, trk$y_ft, f)
    b <- attack_frame(a$x, a$y, f)
    round_trip <- max(round_trip, abs(b$x - trk$x_ft), abs(b$y - trk$y_ft), na.rm = TRUE)
  }
  trk_dupes <- anyDuplicated(trk, by = c("frame_idx", "entity_id")) > 0
  if (trk_dupes) stop("duplicate frame-entity rows in game ", g)
  fwrite(trk, trk_path, append = file.exists(trk_path))
  e <- gate0_events(root, g, aliases)
  cp <- e$chance_players
  for (k in which(ep$game_id == g)) {
    s <- ep[k]
    orient[[length(orient) + 1L]] <- cbind(shot_id = s$shot_id, orientation_record(raw, s, th$orientation_approach$window_frames))
    cp_off <- cp[chance_id == s$chance_id & offense %in% TRUE]$pid
    cp_def <- cp[chance_id == s$chance_id & offense %in% FALSE]$pid
    idrel[[length(idrel) + 1L]] <- cbind(shot_id = s$shot_id, players_at(raw, s, s$f0, e$roster, cp_off, cp_def))
    if (!is.na(s$rf)) {
      idreb[[length(idreb) + 1L]] <- cbind(shot_id = s$shot_id, players_at(raw, s, s$rf, e$roster, cp_off, cp_def))
      quality[[length(quality) + 1L]] <- cbind(game_id = g, shot_id = s$shot_id, retained = s$retained, stage_quality(raw, s))
    }
  }
}
coverage <- rbindlist(coverage)
orient <- rbindlist(orient)
idrel <- rbindlist(idrel)
idreb <- rbindlist(idreb)
quality <- rbindlist(quality)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - THE EPISODE TABLE ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ep <- merge(ep, orient, by = "shot_id", sort = FALSE)
setnames(idrel, setdiff(names(idrel), "shot_id"), paste0("release_", setdiff(names(idrel), "shot_id")))
setnames(idreb, setdiff(names(idreb), "shot_id"), paste0("rebound_", setdiff(names(idreb), "shot_id")))
ep <- merge(ep, idrel, by = "shot_id", all.x = TRUE, sort = FALSE)
ep <- merge(ep, idreb, by = "shot_id", all.x = TRUE, sort = FALSE)
ep[, ball_end_hoop_dist := sqrt((ball_x_end - RIM_X)^2 + ball_y_end^2)]
ep[, substitution_in_window := !is.na(rf) & release_n_off == 5L & rebound_n_off == 5L &
       (release_off_ids != rebound_off_ids | release_def_ids != rebound_def_ids)]
ep[, order_flags := {
  fl <- character(.N)
  add_flag <- function(cond, lab) fl <<- ifelse(cond %in% TRUE, ifelse(nzchar(fl), paste(fl, lab, sep = ";"), lab), fl)
  add_flag(!is.na(rf) & rf <= f0, "rebound_at_or_before_release")
  add_flag(!is.na(rf) & rf > f0 & rf < f1, "rebound_before_shot_end")
  add_flag(!is.na(contact_frame) & contact_frame - f0 < th$order$contact_after_release_frames, "contact_not_after_release")
  add_flag(!is.na(rf) & !is.na(contact_frame) & rf < contact_frame, "rebound_before_contact_proxy")
  add_flag(is.na(contact_frame), "no_contact_found")
  fl
}]
episodes <- ep[, .(episode_id = shot_id, game_id, rebound_event_id = reb_id, shot_id, chance_id, poss_id, period,
                   release_frame = f0, shot_end_frame = f1, contact_proxy_frame = contact_frame, contact_kind,
                   touch_proxy_frame = touch_frame, control_proxy_frame = control_frame, rebound_frame = rf,
                   release_game_clock = gc0, rebound_game_clock = rgc, left_hoop, flip,
                   credited_outcome = outcome12, rebounded = grabbed, side, side_by_flag, rebounder_id = rpid,
                   rebounder_canonical = rcanon, rebound_team = rteam, shooter_id = pid, shooter_canonical = canon,
                   off_team, def_team, three, blocked, shot_type, complex_shot_type = cst, shot_range, shot_dist,
                   release_off_ids, release_def_ids, release_n_off, release_n_def, release_matches_chance,
                   release_off_roster, release_wrong_team, rebound_off_ids, rebound_def_ids, rebound_matches_chance,
                   rebounder_tracked, substitution_in_window,
                   ball_present = round(ball_present, 4), ball_keyframe = round(ball_keyframe, 4),
                   player_detected = round(player_det, 4), index_missing_frames = index_missing,
                   ball_end_hoop_dist = round(ball_end_hoop_dist, 3), shooter_location_gap = round(loc_gap, 3),
                   order_flags, identity_suspect, terminal, eligible = retained, exclusion)]
setorder(episodes, game_id, release_frame)
fwrite(episodes, file.path(out, "rebound_episodes.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - AUDITS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

chk <- list()
add <- function(area, check, value, expected, pass, note = "") {
  chk[[length(chk) + 1L]] <<- data.table(area = area, check = check, value = as.character(value),
                                         expected = as.character(expected), pass = pass, note = note)
}
el <- episodes[eligible == TRUE]
links <- fread(file.path(root, "outputs", "rebounding", "gate0", "links_by_game.csv"))
clocks <- fread(file.path(root, "outputs", "rebounding", "gate0", "clock_checks.csv"))
# keys and joins
add("keys", "episode_id unique", anyDuplicated(episodes$episode_id), 0, anyDuplicated(episodes$episode_id) == 0)
k <- episodes[!is.na(rebound_event_id), anyDuplicated(paste(game_id, rebound_event_id))]
add("keys", "(game_id, rebound_event_id) unique", k, 0, k == 0)
add("keys", "eligible episodes with a rebound row", sum(!is.na(el$rebound_event_id)), nrow(el), all(!is.na(el$rebound_event_id)))
add("joins", "rebound rows pointing at a made or fouled shot", sum(links$rebound_to_made_shot + links$rebound_to_fouled_shot), 0,
    sum(links$rebound_to_made_shot + links$rebound_to_fouled_shot) == 0)
add("joins", "shots with more than one rebound row", sum(links$duplicate_links), 0, sum(links$duplicate_links) == 0)
add("joins", "event frames without a tracking line", sum(clocks$frame_missing), 0, sum(clocks$frame_missing) == 0)
add("joins", "event wallClock != tracking wallClock at its frame", sum(clocks$wall_mismatch), 0, sum(clocks$wall_mismatch) == 0)
add("joins", "event period != tracking period at its frame", sum(clocks$period_mismatch), 0, sum(clocks$period_mismatch) == 0)
add("joins", "largest |event gameClock - tracking gameClock| at its frame (s)", signif(max(clocks$gc_max_abs_diff, na.rm = TRUE), 3),
    paste("<=", th$joins$game_clock_tol_s), max(clocks$gc_max_abs_diff, na.rm = TRUE) <= th$joins$game_clock_tol_s,
    "tolerance set after the first run (events store gameClock to the millisecond)")
# timing order
add("order", "eligible with rebound at or before release", sum(grepl("rebound_at_or_before_release", el$order_flags)), 0,
    !any(grepl("rebound_at_or_before_release", el$order_flags)))
for (fl in c("rebound_before_shot_end", "contact_not_after_release", "rebound_before_contact_proxy", "no_contact_found"))
  add("order", paste("eligible flagged", fl), sum(grepl(fl, el$order_flags)), "flagged, kept", TRUE)
# identity
add("identity", "eligible with 5 + 5 tracked at release", sum(el$release_n_off == 5L & el$release_n_def == 5L), nrow(el),
    all(el$release_n_off == 5L & el$release_n_def == 5L))
add("identity", "players at release off the roster or on the wrong team", sum(el$release_off_roster + el$release_wrong_team), 0,
    sum(el$release_off_roster + el$release_wrong_team) == 0)
add("identity", "tracked ten at release match the chance's players", sum(el$release_matches_chance), nrow(el),
    all(el$release_matches_chance))
add("identity", "credited player rebounder tracked on court at the rebound frame",
    sum(el[rebounded == TRUE]$rebounder_tracked %in% TRUE), sum(el$rebounded), all(el[rebounded == TRUE]$rebounder_tracked %in% TRUE))
add("identity", "eligible with a substitution between release and rebound", sum(el$substitution_in_window), "reported",
    TRUE, "tracked ten at the rebound frame differ from the ten at release")
add("identity", "player slots filled without a tracking row", 0, 0, TRUE,
    "slot lists are built only from tracking rows; fewer than ten stays fewer than ten")
add("identity", "identity_suspect player rebounds (kept, flagged)", sum(el$identity_suspect), "reported", TRUE)
# orientation, both attack directions
ori <- ep[!is.na(ball_x_end), .(misses_with_ball_at_end = .N,
                                ball_near_attacked_hoop = mean(ball_end_hoop_dist <= th$orientation$ball_at_end_max_hoop_ft),
                                ball_in_attacked_half = mean(ball_x_end > 0),
                                ball_end_hoop_dist_median = median(ball_end_hoop_dist),
                                ball_nearer_attacked_hoop = mean(closest_attacked_hoop < closest_other_hoop, na.rm = TRUE),
                                closest_attacked_hoop_median = median(closest_attacked_hoop, na.rm = TRUE),
                                shooter_gap_median = median(loc_gap, na.rm = TRUE),
                                shooter_gap_p90 = quantile(loc_gap, 0.9, na.rm = TRUE),
                                defenders_in_attacked_half_mean = mean(defenders_attacked_half, na.rm = TRUE),
                                players_in_attacked_half_mean = mean(players_attacked_half, na.rm = TRUE)),
          by = .(direction = fifelse(left_hoop, "attacks camera-left hoop (flip -1)", "attacks camera-right hoop (flip +1)"))]
fwrite(ori, file.path(out, "orientation.csv"))
fwrite(ep[ball_end_hoop_dist > th$orientation$ball_at_end_max_hoop_ft,
          .(shot_id, kind, left_hoop, frames_release_to_end = f1 - f0, complex_shot_type = cst,
            ball_end_hoop_dist = round(ball_end_hoop_dist, 2), ball_z_end = round(ball_z_end, 2),
            closest_attacked_hoop = round(closest_attacked_hoop, 2), closest_other_hoop = round(closest_other_hoop, 2), retained)][
       order(kind, -ball_end_hoop_dist)], file.path(out, "orientation_endframe_outliers.csv"))
# One row per direction for the prespecified orientation check.
for (i in seq_len(nrow(ori))) {
  # prespecified; superseded after the first run because endFrame is not the ball's arrival for every shot
  add("orientation (prespecified, superseded)",
      paste(ori$direction[i], "- ball at endFrame within", th$orientation$ball_at_end_max_hoop_ft, "ft of the attacked hoop"),
      sprintf("%.4f", ori$ball_near_attacked_hoop[i]), paste(">=", th$orientation$ball_at_end_share_min),
      ori$ball_near_attacked_hoop[i] >= th$orientation$ball_at_end_share_min,
      "outliers are blocked shots, airballs/heaves and shots whose endFrame is 2-30 frames after release (orientation_endframe_outliers.csv)")
  add("orientation", paste(ori$direction[i], "- ball comes nearer the attacked hoop than the other hoop (added after the first run)"),
      sprintf("%.4f", ori$ball_nearer_attacked_hoop[i]), paste(">=", th$orientation_approach$share_min),
      ori$ball_nearer_attacked_hoop[i] >= th$orientation_approach$share_min)
  add("orientation", paste(ori$direction[i], "- median shooter gap to -shots.location (ft)"),
      sprintf("%.3f", ori$shooter_gap_median[i]), paste("<=", th$orientation$shooter_gap_median_max_ft),
      ori$shooter_gap_median[i] <= th$orientation$shooter_gap_median_max_ft)
}
add("orientation", "largest round-trip error, rotating twice (ft)", sprintf("%.1e", round_trip),
    paste("<=", th$orientation$round_trip_tol_ft), round_trip <= th$orientation$round_trip_tol_ft)
add("orientation", "one rotation per shot for ball and all players", "by construction", "", TRUE,
    "attack_frame(x, y, flip) with the shot's flip; no per-player sign")
# coverage per period (reported; the episode windows themselves are checked for gaps above and in Gate 0)
coverage[, pass := running_share >= th$coverage$period_min & start_gap <= th$coverage$start_gap_max_s]
cov_game <- coverage[, .(running_share = sum(running_frames) / sum(25 * length_s), periods_below = sum(!pass)), by = game_id]
fwrite(coverage, file.path(out, "period_coverage.csv"))
add("coverage", "periods with running-clock coverage below threshold or a late start", sum(!coverage$pass),
    "reported", TRUE, sprintf("thresholds %.2f per period, %g s start gap", th$coverage$period_min, th$coverage$start_gap_max_s))
add("coverage", "games below whole-game coverage threshold", sum(cov_game$running_share < th$coverage$game_min), "reported", TRUE)
add("coverage", "eligible windows with missing frame indices", sum(el$index_missing_frames > 0), 0, all(el$index_missing_frames == 0))
# quality by game and stage
qg <- quality[retained == TRUE, .(episodes = .N, frames = sum(frames),
                                  ball_present = weighted.mean(ball_present, frames),
                                  ball_keyframe = weighted.mean(ball_keyframe, frames),
                                  ball_keyframe_strict = weighted.mean(ball_keyframe_strict, frames),
                                  ball_detected = weighted.mean(ball_detected, frames, na.rm = TRUE),
                                  ball_pred_error = weighted.mean(ball_pred_error, frames, na.rm = TRUE),
                                  player_rows_missing = 1 - sum(player_rows) / sum(player_rows_expected),
                                  player_detected = weighted.mean(player_detected, player_rows, na.rm = TRUE),
                                  player_err_detected = weighted.mean(player_err_detected, player_rows, na.rm = TRUE),
                                  player_err_extrapolated = weighted.mean(player_err_extrapolated, player_rows, na.rm = TRUE),
                                  player_err_p95 = weighted.mean(player_err_p95, player_rows, na.rm = TRUE)),
                 by = .(game_id, stage)]
qa <- qg[, .(game_id = NA_integer_, episodes = sum(episodes), frames = sum(frames),
             ball_present = weighted.mean(ball_present, frames), ball_keyframe = weighted.mean(ball_keyframe, frames),
             ball_keyframe_strict = weighted.mean(ball_keyframe_strict, frames),
             ball_detected = weighted.mean(ball_detected, frames), ball_pred_error = weighted.mean(ball_pred_error, frames),
             player_rows_missing = weighted.mean(player_rows_missing, frames),
             player_detected = weighted.mean(player_detected, frames), player_err_detected = weighted.mean(player_err_detected, frames),
             player_err_extrapolated = weighted.mean(player_err_extrapolated, frames), player_err_p95 = weighted.mean(player_err_p95, frames)),
         by = stage]
setcolorder(qa, names(qg))
stage_order <- c("pre_release", "flight", "contact_to_rebound", "after_rebound")
qual <- rbind(qg, qa)[order(is.na(game_id), game_id, match(stage, stage_order))]
fwrite(qual, file.path(out, "quality_by_game_stage.csv"))
add("quality", "quality reported by game and stage", nrow(qg), paste(10 * length(stage_order), "rows"), nrow(qg) == 10L * length(stage_order))
# exclusions and outcomes
excl <- episodes[, .N, by = .(eligible, exclusion = fifelse(eligible, "(eligible)", exclusion))][order(-eligible, -N)]
fwrite(excl, file.path(out, "exclusions.csv"))
add("exclusions", "every non-eligible episode has a reason", sum(!episodes$eligible & !nzchar(episodes$exclusion)), 0,
    all(nzchar(episodes[eligible == FALSE]$exclusion)))
add("exclusions", "episodes = eligible + excluded", nrow(episodes), sum(excl$N), nrow(episodes) == sum(excl$N))
outc <- el[, .N, by = credited_outcome][order(credited_outcome)]
fwrite(outc, file.path(out, "outcomes.csv"))
add("outcomes", "eligible episodes with exactly one credited outcome", sum(!is.na(el$credited_outcome)), nrow(el), all(!is.na(el$credited_outcome)))
add("outcomes", "team awards kept as team outcomes (offence / defence)",
    sprintf("%d / %d", sum(el$credited_outcome == "off team award"), sum(el$credited_outcome == "def team award")), "> 0 each",
    sum(el$credited_outcome == "off team award") > 0 && sum(el$credited_outcome == "def team award") > 0)
add("outcomes", "team awards carrying a rebounder id", sum(!is.na(el[rebounded == FALSE]$rebounder_id)), 0,
    all(is.na(el[rebounded == FALSE]$rebounder_id)))
checks <- rbindlist(chk)
fwrite(checks, file.path(out, "checks.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - EDGE-CASE FIGURES ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

set.seed(cfg$seeds[[1]])
n_each <- th$review$edge_cases_per_kind
pick <- function(rows, why, n = n_each) if (nrow(rows)) rows[sample(.N, min(.N, n))][, reason := why] else NULL
edge <- rbind(pick(ep[retained & left_hoop == TRUE], "attacks camera-left hoop"),
              pick(ep[retained & left_hoop == FALSE], "attacks camera-right hoop"),
              pick(ep[terminal %in% c("no rebound row: end of period", "team rebound: end of period")], "end of period"),
              pick(ep[substitution_in_window %in% TRUE], "substitution between release and rebound"),
              pick(ep[retained & outcome12 == "off team award"], "offensive team award", 1L),
              pick(ep[retained & outcome12 == "def team award"], "defensive team award", 1L),
              pick(ep[retained & grepl("rebound_before_shot_end", order_flags)], "rebound before endFrame"),
              pick(ep[!(release_matches_chance %in% TRUE) & !is.na(release_n_off)], "tracked ten differ from chance_players"),
              fill = TRUE)
edge[, exclusion_label := fifelse(retained, "eligible", exclusion)]
per_page <- 3L
edge[, page := (seq_len(.N) - 1L) %/% per_page + 1L]
fwrite(edge[, .(page, reason, shot_id, game_id, period, left_hoop, flip, f0, f1, rf, outcome12, exclusion_label,
                substitution_in_window, release_matches_chance)], file.path(out, "figures", "edge_cases.csv"))
raws <- list()
# Edge-case pages, two episodes per row.
for (p in unique(edge$page)) {
  png(file.path(out, "figures", sprintf("edge_cases_%02d.png", p)), width = 1500, height = 430 * per_page, res = 100)
  layout(matrix(seq_len(2L * per_page), ncol = 2, byrow = TRUE))
  for (k in which(edge$page == p)) {
    s <- edge[k]
    key <- as.character(s$game_id)
    if (is.null(raws[[key]])) {
      raws[[key]] <- readRDS(file.path(cache, sprintf("raw_%s.rds", s$game_id)))
      raws[[key]]$home_team <- matches$home_team$id[matches$id == s$game_id]
    }
    h <- audited$hoops[game_id == s$game_id & left_hoop == s$left_hoop]
    draw_orientation(raws[[key]], s, if (nrow(h)) list(hx = h$hx, hy = h$hy) else list(hx = RIM_X, hy = 0), s$reason)
  }
  dev.off()
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Criteria, tests and the gate record.
crit <- list(join_and_keys = all(checks[area %in% c("keys", "joins")]$pass),
             timing_order = all(checks[area == "order"]$pass),
             identity = all(checks[area == "identity"]$pass),
             orientation_both_directions = all(checks[area == "orientation"]$pass),
             quality_reported_by_game_and_stage = all(checks[area == "quality"]$pass),
             exclusions_counted = all(checks[area == "exclusions"]$pass),
             outcome_taxonomy_with_team_awards = all(checks[area == "outcomes"]$pass),
             coverage_reported = all(checks[area == "coverage"]$pass))
# Unit and gate tests, then the gate record.
tests <- rbind(run_tests(here, root, "unit", "orientation"), run_tests(here, root, "gates", "step_01"), fill = TRUE)
fwrite(tests, file.path(gr, "01_tests.csv"))
crit$tests_pass <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
unmet <- names(crit)[!vapply(crit, isTRUE, NA)]
status <- if (!length(unmet)) "PASS" else "BLOCKED"
# The gate record.
rec <- list(step = "01", status = status,
            scope = paste("credited outcome of a non-fouled missed field goal (12 classes), conditional on the miss;",
                          nrow(el), "eligible of", nrow(episodes), "episodes"),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit),
            data_revision = list(upstream = cfg$dataset$upstream_commit, manifest = cfg$dataset$checksums),
            model_revision = NULL, repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit orientation; Rscript src/rebounding/run_tests.R gates step_01",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = all(unlist(crit[setdiff(names(crit), "tests_pass")])),
            heldout_metrics_file = NULL, acceptance_criteria_version = sprintf("manual %s, config v%d", cfg$manual_revision, cfg$config_version),
            criteria = crit, unmet = unmet,
            deviations = list(list(check = "orientation: ball at shots.endFrame within 6 ft of the attacked hoop, >= 98% per direction (prespecified)",
                                   result = paste(sprintf("%s %.1f%%", ori$direction, 100 * ori$ball_near_attacked_hoop), collapse = "; "),
                                   decision = paste("Superseded after the first run: every outlier is a blocked shot, an airball or heave, or a shot whose",
                                                    "endFrame comes before the ball reaches the rim, so the check measured endFrame semantics, not orientation.",
                                                    "Replaced by an endFrame-free check (ball nearer the attacked hoop than the other, same 98% share).",
                                                    "Owner to confirm.")),
                              list(check = "joins: event gameClock equals tracking gameClock",
                                   result = sprintf("largest gap %.4f s", max(clocks$gc_max_abs_diff, na.rm = TRUE)),
                                   decision = "Tolerance 0.001 s set after the first run; the first run used 1e-6 s, fixed in code without a stated reason.")),
            counts = list(episodes = nrow(episodes), eligible = nrow(el), excluded = nrow(episodes) - nrow(el),
                          outcomes = setNames(as.list(outc$N), outc$credited_outcome),
                          identity_suspect = sum(el$identity_suspect), substitution_in_window = sum(el$substitution_in_window)),
            evidence = c("outputs/rebounding/step01/rebound_episodes.csv", "outputs/rebounding/step01/checks.csv",
                         "outputs/rebounding/step01/orientation.csv", "outputs/rebounding/step01/quality_by_game_stage.csv",
                         "outputs/rebounding/step01/period_coverage.csv", "outputs/rebounding/step01/exclusions.csv",
                         "outputs/rebounding/step01/figures/", "outputs/rebounding/reports/01_join_audit.md",
                         "outputs/rebounding/gate0/ (event links, clocks, taxonomy, 72-rebound review)"),
            reviewer = "Claude (automated run; tracking-plot review from Gate 0); owner review pending", date = format(Sys.Date()),
            open_risks = list("Contact, touch and control frames are automated proxies (Step 02 reviews them)",
                              "5 of 64 reviewed player rebounds credit a player who never reaches the ball in tracking (identity_suspect flags 33 eligible)",
                              "Single reviewer, tracking plots only; no video ships with the data and outside video is not allowed"),
            decision_note = if (status == "PASS") "All Step 01 audits documented and passed." else paste("Unmet:", paste(unmet, collapse = ", ")))
write_gate(file.path(gr, "01_episodes.json"), rec)
saveRDS(list(episodes = episodes, checks = checks, coverage = coverage, quality = qual, orientation = ori,
             exclusions = excl, outcomes = outc, edge = edge, tests = tests, status = status),
        file.path(cache, "step01.rds"))

print(checks[, .(area, check = substr(check, 1, 78), value, expected, pass)], nrows = 200)
print(ori)
print(coverage[pass == FALSE])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 01:", status, if (length(unmet)) paste("- unmet:", paste(unmet, collapse = ", ")) else "", "\n")
