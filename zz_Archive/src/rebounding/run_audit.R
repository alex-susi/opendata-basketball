# Step 1 of the rebounding framework: audit episodes, targets and ball tracking before any model is fitted.
#   Rscript src/rebounding/run_audit.R
# Needs outputs/cache/rebounding/raw_*.rds from extract_windows.R.
# Writes outputs/rebounding/audit/*.csv and outputs/cache/rebounding/episodes.rds.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "geometry.R"))
source(file.path(here, "R", "extract.R"))
source(file.path(here, "R", "audit.R"))

root <- find_repo_root()
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "audit")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
raws <- lapply(matches$id, function(g) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  raw$home_team <- matches$home_team$id[matches$id == g]
  raw
})

hoops <- hoop_calibration(raws)
fwrite(hoops, file.path(out, "hoop_calibration.csv"))
fwrite(rbindlist(lapply(raws, held_offset)), file.path(out, "held_ball_offset.csv"))

ep <- rbindlist(lapply(raws, function(raw) {
  message("Auditing ", raw$shots$game_id[1])
  episode_audit(raw, hoops)
}), fill = TRUE)
ep <- classify_episodes(ep)
cp <- rbindlist(lapply(raws, `[[`, "chance_players"))
counts <- audit_counts(ep, cp)
fwrite(counts, file.path(out, "counts.csv"))

# ball track quality over each game's shot windows
interp <- rbindlist(lapply(raws, function(raw) {
  fr <- raw$frames[order(frame)]
  mid <- abs(fr$bx - (shift(fr$bx) + shift(fr$bx, -1L)) / 2) < 0.015 & abs(fr$bz - (shift(fr$bz) + shift(fr$bz, -1L)) / 2) < 0.015
  live <- !is.na(fr$bx)
  data.table(game_id = raw$shots$game_id[1], window_frames = nrow(fr), ball_present = mean(live),
             ball_detected = mean(fr$bdet[live] > 0), ball_pred_error = mean(fr$berr[live]),
             ball_pred_error_p95 = quantile(fr$berr[live], 0.95), ball_z_below_zero = mean(fr$bz[live] < 0),
             ball_z_p01 = quantile(fr$bz[live], 0.01), midpoint_share = mean(mid[live], na.rm = TRUE),
             player_detected = mean(raw$players$det), player_pred_error = mean(raw$players$err),
             player_pred_error_extrapolated = mean(raw$players$err[raw$players$det == 0L]))
}))
fwrite(interp, file.path(out, "tracking_quality.csv"))
fwrite(rbindlist(lapply(raws, `[[`, "index_gaps")), file.path(out, "frame_index_gaps.csv"))

by_game <- ep[, .(shots = .N, made = sum(made), fouled_misses = sum(!made & fouled), misses = sum(!made & !fouled),
                  rebound_rows = sum(n_reb), team_awards = sum(grabbed %in% FALSE), unpaired = sum(!made & !fouled & n_reb == 0L),
                  blocked = sum(!made & !fouled & blocked), eligible = sum(status == "eligible"),
                  poor_ball = sum(status == "miss, poor ball coverage"),
                  contact_found = sum(status == "eligible" & contact_kind != "none", na.rm = TRUE),
                  control_found = sum(status == "eligible" & !is.na(control_frame)),
                  control_matches_rebounder = sum(status == "eligible" & control_pid == rpid, na.rm = TRUE),
                  median_ball_cover = median(ball_cover, na.rm = TRUE),
                  median_shooter_vs_event_ft = median(loc_gap, na.rm = TRUE)), by = game_id]
fwrite(by_game, file.path(out, "by_game.csv"))

el <- ep[status == "eligible"]
timing <- el[, .(n = .N,
                 contact_minus_end_s = median((contact_frame - f1) / FPS, na.rm = TRUE),
                 control_minus_rebound_s = median((control_frame - rf) / FPS, na.rm = TRUE),
                 control_minus_rebound_p10 = quantile((control_frame - rf) / FPS, 0.1, na.rm = TRUE),
                 control_minus_rebound_p90 = quantile((control_frame - rf) / FPS, 0.9, na.rm = TRUE),
                 touch_minus_rebound_s = median((touch_frame - rf) / FPS, na.rm = TRUE),
                 control_player_agrees = mean(control_pid == rpid, na.rm = TRUE),
                 control_team_agrees = mean(control_off == !defensive, na.rm = TRUE),
                 rebound_after_contact_s = median((rf - fcoalesce(contact_frame, f1)) / FPS, na.rm = TRUE),
                 deflection_deg = median(deflect_deg, na.rm = TRUE),
                 floor_bounce_share = mean(!is.na(bounce_frame)),
                 untouched_bounce_share = mean(!is.na(bounce_frame) & bounce_near > 4 &
                                                 (is.na(control_frame) | control_frame > bounce_frame)),
                 bounce_z_median = median(bounce_z, na.rm = TRUE)),
             by = .(kind)]
fwrite(timing, file.path(out, "timeline_by_kind.csv"))
fwrite(ep[, .N, by = .(status, outcome)][order(status, outcome)], file.path(out, "population.csv"))
fwrite(review_sample(ep), file.path(out, "review_sample.csv"))
keep <- setdiff(names(ep), c("sx_cam", "sy_cam", "rx_cam", "ry_cam"))
fwrite(ep[, ..keep], file.path(out, "episodes.csv"))
saveRDS(list(episodes = ep, hoops = hoops), file.path(cache, "episodes.rds"))

print(counts)
print(by_game)
print(timing)
print(interp)
print(hoops)
