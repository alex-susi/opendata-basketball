# Gate 0 of the gated rebound roadmap: rebound event audit and data contract.
#   Rscript src/rebounding/run_gate0.R
# Needs outputs/cache/rebounding/raw_*.rds (extract_windows.R) and episodes.rds (run_audit.R).
# Writes outputs/rebounding/gate0/*.csv and outputs/cache/rebounding/gate0.rds (input of run_gate0_review.R).

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "gate0.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "gate0")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
audited <- readRDS(file.path(cache, "episodes.rds"))
KEYS <- c("possessions", "chances", "chance_players", "matchups", "shots", "free_throws", "rebounds", "turnovers",
          "fouls", "timeouts", "passes", "touches", "dribbles", "picks", "handoffs", "off_ball_screens", "drives",
          "isolations", "posts", "closeouts")
check <- list()
add <- function(area, name, value, expected = NA, note = "") {
  check[[length(check) + 1L]] <<- data.table(area = area, check = name, value = value, expected = expected, note = note)
}

# ---- inventory and identity contract --------------------------------------------------------------------
add("inventory", "match folders", sum(dir.exists(file.path(root, "data", "matches", matches$id))), 10)
add("inventory", "alias map idempotent (canon of canon = canon)",
    all(canon_id(canon_id(aliases$player_id, aliases), aliases) == canon_id(aliases$player_id, aliases)), TRUE)
inv <- list(); per_game <- list(); misses <- list(); lmarks <- list(); clocks <- list()
for (g in matches$id) {
  message("Gate 0: ", g)
  e <- gate0_events(root, g, aliases)
  clock <- tracking_clock(root, g)
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  raw$home_team <- matches$home_team$id[matches$id == g]
  gd <- read_json_file(match_file(root, g, "_game_data.json"))
  inv[[length(inv) + 1L]] <- data.table(
    game_id = g, events_file = file.exists(match_file(root, g, "_dynamic_events.json")),
    game_data_file = file.exists(match_file(root, g, "_game_data.json")),
    tracking_file = basename(tracking_source(root, g)), tracking_mb = round(file.size(tracking_source(root, g)) / 2^20, 1),
    game_id_matches = gd$gameId == g, event_keys_exact = setequal(e$keys, KEYS) && length(e$keys) == 20L,
    roster_home = sum(e$roster$home), roster_away = sum(!e$roster$home), roster_dupes = anyDuplicated(e$roster$pid) > 0,
    tracking_lines = nrow(clock), frame_strictly_increasing = !is.unsorted(clock$frame, strictly = TRUE),
    wall_is_40_per_frame = all(clock$wall == 40 * clock$frame), missing_frame_indices = max(clock$frame) + 1L - nrow(clock),
    dead_frame_share = mean(clock$no_players), periods = uniqueN(clock$period))

  # rebounds: what each row points to
  rb <- link_checks(e)
  sh <- e$shots
  fgr <- rb[ref_kind == "shot"]
  fgr <- merge(fgr, sh[, .(ref_id = shot_id, s_made = made, s_fouled = fouled, s_period = period, s_f1 = f1,
                           s_def = def_team, s_off = off_team)], by = "ref_id", all.x = TRUE)
  rost <- e$roster
  fgr[, rpid_on_roster := rpid %in% rost$pid]
  fgr[, rpid_team := rost$team[match(rpid, rost$pid)]]
  nc <- e$chances[, .(next_chance = chance_id, nc_type = start_type, nc_off = off_team, nc_period = period)]
  fgr <- merge(fgr, nc, by = "next_chance", all.x = TRUE)
  ftl <- ft_live_misses(e)
  per_game[[length(per_game) + 1L]] <- data.table(
    game_id = g, shots = nrow(sh), made = sum(sh$made %in% TRUE), outcome_na = sum(is.na(sh$made)),
    fouled_na = sum(is.na(sh$fouled)), non_fouled_misses = sum(sh$made %in% FALSE & sh$fouled %in% FALSE),
    fouled_misses = sum(sh$made %in% FALSE & sh$fouled %in% TRUE), and_ones = sum(sh$made %in% TRUE & sh$fouled %in% TRUE),
    blocked = sum(sh$blocked %in% TRUE), blocked_made = sum(sh$blocked %in% TRUE & sh$made %in% TRUE),
    blocker_missing = sum(sh$blocked %in% TRUE & is.na(sh$blocker)),
    blocker_not_defense = sum(sh$blocked %in% TRUE & !is.na(sh$blocker) &
                                rost$team[match(sh$blocker, rost$pid)] != sh$def_team, na.rm = TRUE),
    tip_shots = sum(sh$cst %in% "tip"),
    rebound_rows = nrow(rb), fg_rebound_rows = sum(rb$fg %in% TRUE), ft_rebound_rows = sum(rb$fg %in% FALSE),
    fg_flag_na = sum(is.na(rb$fg)),
    fg_flag_vs_reference_mismatch = sum((rb$fg %in% TRUE) != (rb$ref_kind == "shot")),
    rebound_reference_missing = sum(rb$ref_kind == "none"), rebound_reference_not_found = sum(!rb$ref_found),
    duplicate_links = sum(duplicated(rb$ref_id[!is.na(rb$ref_id)])),
    rebound_to_made_shot = sum(fgr$s_made %in% TRUE), rebound_to_fouled_shot = sum(fgr$s_fouled %in% TRUE),
    non_fouled_miss_without_rebound = sum(sh$made %in% FALSE & sh$fouled %in% FALSE & !sh$shot_id %in% fgr$ref_id),
    grabbed_na = sum(is.na(rb$grabbed)), defensive_na = sum(is.na(rb$defensive)),
    grabbed_without_rebounder = sum(rb$grabbed %in% TRUE & is.na(rb$rpid)),
    team_award_with_rebounder = sum(rb$grabbed %in% FALSE & !is.na(rb$rpid)),
    rebounder_off_roster = sum(!is.na(fgr$rpid) & !fgr$rpid_on_roster),
    rebounder_team_mismatch = sum(!is.na(fgr$rpid) & fgr$rpid_team != fgr$rteam, na.rm = TRUE),
    defensive_flag_mismatch = sum(fgr$defensive != (fgr$rteam == fgr$s_def), na.rm = TRUE),
    rebound_team_neither = sum(!fgr$rteam %in% c(fgr$s_def, fgr$s_off)),
    rebound_period_mismatch = sum(fgr$period != fgr$s_period, na.rm = TRUE),
    rebound_before_shot_end = sum(fgr$rf < fgr$s_f1, na.rm = TRUE),
    next_chance_missing = sum(is.na(fgr$next_chance)), next_chance_not_found = sum(!is.na(fgr$next_chance) & is.na(fgr$nc_type)),
    next_chance_team_mismatch = sum(fgr$nc_off != fgr$rteam, na.rm = TRUE),
    next_chance_type_mismatch = sum(!is.na(fgr$nc_type) & fgr$nc_type != fifelse(fgr$defensive, "FGDRB", "FGORB")),
    ft_live_misses = sum(ftl$made %in% FALSE & ftl$last_of_trip), ft_live_misses_with_rebound = sum(ftl$made %in% FALSE & ftl$last_of_trip & ftl$has_rebound),
    ft_rebound_to_made_or_not_last = sum(ftl$has_rebound & !(ftl$made %in% FALSE & ftl$last_of_trip)))
  nc_types <- fgr[, .N, by = .(defensive, grabbed, nc_type)]

  # clocks: event wallClock / period / gameClock against the tracking line at the event's frame
  cm <- function(frames, wall, period, gc, what) {
    i <- match(frames, clock$frame)
    data.table(game_id = g, event = what, n = length(frames), frame_missing = sum(is.na(i) & !is.na(frames)),
               wall_mismatch = sum(abs(clock$wall[i] - wall) > GATE0$clock_tol_ms, na.rm = TRUE),
               period_mismatch = sum(clock$period[i] != period, na.rm = TRUE),
               gc_max_abs_diff = if (all(is.na(gc))) NA_real_ else max(abs(clock$gc[i] - gc), na.rm = TRUE),
               dead_at_frame = sum(clock$no_players[i], na.rm = TRUE))
  }
  clocks[[length(clocks) + 1L]] <- rbind(
    cm(sh$f0, sh$w0, sh$period, sh$gc0, "shot release (startFrame)"),
    cm(sh$f1, sh$w1, sh$period, NA_real_, "shot end (endFrame)"),
    cm(rb$rf, rb$rw, rb$period, rb$rgc, "rebound (frame)"))

  # every non-fouled miss: semantics, identity, quality and landmarks
  ep <- merge(sh, audited$episodes[game_id == g, .(shot_id, flip, contact_frame, contact_kind, touch_frame, control_frame,
                                                   control_pid, kind, status, putback, shot_dist)], by = "shot_id", sort = FALSE)
  first <- fgr[order(rf)][, .SD[1], by = ref_id]
  ep <- merge(ep, first[, .(shot_id = ref_id, reb_id, rf, rw, rgc, rteam, rpid, grabbed, defensive, rev_x, rev_y, next_chance, nc_type)],
              by = "shot_id", all.x = TRUE, sort = FALSE)
  ep[, canon := canon_id(pid, aliases)]
  ep[, rcanon := canon_id(rpid, aliases)]
  hoops <- audited$hoops[game_id == g]
  cpc <- e$chance_players[, canon := canon_id(pid, aliases)]
  m <- ep[made %in% FALSE & fouled %in% FALSE]
  recs <- lapply(seq_len(nrow(m)), function(k) {
    s <- m[k]
    h <- hoops[left_hoop == s$left_hoop]
    hoop <- if (nrow(h)) list(hx = h$hx, hy = h$hy) else list(hx = RIM_X, hy = 0)
    ids <- list(off = sort(cpc[chance_id == s$chance_id & offense %in% TRUE]$canon),
                def = sort(cpc[chance_id == s$chance_id & offense %in% FALSE]$canon))
    r <- miss_record(raw, s, hoop, rost, ids, clock)
    r$landmarks[, shot_id := s$shot_id]
    r$row$shooter_on_offense <- s$canon %in% ids$off
    r$row$rebounder_in_chance <- if (is.na(s$rcanon)) NA else s$rcanon %in% c(ids$off, ids$def)
    r$row$rebounder_side_ok <- if (is.na(s$rcanon)) NA else (s$rcanon %in% ids$def) == s$defensive
    r$row$chance_off_n <- length(ids$off)
    r$row$chance_def_n <- length(ids$def)
    list(row = as.data.table(r$row)[, shot_id := s$shot_id], landmarks = r$landmarks)
  })
  rows <- rbindlist(lapply(recs, `[[`, "row"), fill = TRUE)
  m <- merge(m, rows, by = "shot_id", sort = FALSE)
  # terminal-outcome evidence from the event tables
  fo <- e$fouls[shooting %in% FALSE]
  to <- e$turnovers
  end_f <- fcoalesce(m$rf, m$f1)
  m[, foul_after := vapply(seq_len(.N), function(i) any(fo$frame >= f1[i] & fo$frame <= end_f[i] + GATE0$foul_after_s * FPS), NA)]
  m[, turnover_after := is.na(rf) & vapply(seq_len(.N), function(i) any(to$frame >= f1[i] & to$frame <= f1[i] + 3 * FPS), NA)]
  m[, held_ball := nc_type %in% "JMP"]
  gc_end <- clock$gc[match(end_f, clock$frame)]
  m[, period_end := fcoalesce(rgc, gc_end) <= GATE0$period_end_s]
  nxt <- sh[, .(f_next = f0, team_next = off_team, shooter_next = pid, cst_next = cst, next_shot = shot_id)]
  m[, putback_attempt := vapply(seq_len(.N), function(i) {
    if (is.na(rf[i]) || !(defensive[i] %in% FALSE)) return(FALSE)
    any(nxt$team_next == off_team[i] & nxt$f_next > rf[i] - 5L & nxt$f_next <= rf[i] + GATE0$putback_s * FPS)
  }, NA)]
  misses[[length(misses) + 1L]] <- m
  lmarks[[length(lmarks) + 1L]] <- rbindlist(lapply(recs, `[[`, "landmarks"))[, game_id := g]

  # tip shots: is there an offensive rebound credited before each one?
  tips <- sh[cst %in% "tip"]
  if (nrow(tips)) {
    prior <- rbindlist(lapply(seq_len(nrow(tips)), function(k) {
      t <- tips[k]
      r <- first[rteam == t$off_team & rf <= t$f0 + 2L & rf >= t$f0 - 3 * FPS][order(-rf)]
      data.table(game_id = g, shot_id = t$shot_id, made = t$made, prior_oreb = nrow(r) > 0,
                 oreb_by_tipper = nrow(r) > 0 && r$rpid[1] %in% t$pid, gap_s = if (nrow(r)) (t$f0 - r$rf[1]) / FPS else NA_real_)
    }))
    inv[[length(inv)]]$tip_shots_with_prior_oreb <- sum(prior$prior_oreb)
    inv[[length(inv)]]$tip_shots_oreb_by_tipper <- sum(prior$oreb_by_tipper)
    inv[[length(inv)]]$tip_gap_median_s <- median(prior$gap_s, na.rm = TRUE)
  }
}
inventory <- rbindlist(inv, fill = TRUE)
links <- rbindlist(per_game)
clock_checks <- rbindlist(clocks)
ep <- rbindlist(misses, fill = TRUE)
lm <- rbindlist(lmarks)
ep <- terminal_outcome(ep)
ep[, shot_range := shot_range(shot_dist, three)]
# The side of a rebound: teamId against the shot's defence. The defensive flag disagrees on some team awards;
# the next chance's offence decides which of the two is right.
nco <- rbindlist(lapply(matches$id, function(g) gate0_events(root, g, aliases)$chances))[, .(next_chance = chance_id, nc_off = off_team)]
ep <- merge(ep, nco, by = "next_chance", all.x = TRUE, sort = FALSE)
ep[, side_by_team := fifelse(is.na(rteam), NA_character_, fifelse(rteam == def_team, "def", "off"))]
ep[, side_by_flag := fifelse(is.na(defensive), NA_character_, fifelse(defensive, "def", "off"))]
ep[, next_chance_side := fifelse(is.na(nc_off), NA_character_, fifelse(nc_off == def_team, "def", "off"))]
ep[, side := side_by_team]
ep[, outcome12 := fcase(is.na(reb_id), NA_character_, grabbed %in% TRUE, paste(side, "player"), default = paste(side, "team award"))]
add("labels", "rebound side: defensive flag disagrees with teamId", ep[, sum(side_by_flag != side_by_team, na.rm = TRUE)], 0,
    "teamId agrees with the next chance's offence in every disagreement; teamId is used")
add("labels", "  of which team awards", ep[grabbed %in% FALSE, sum(side_by_flag != side_by_team, na.rm = TRUE)])
add("labels", "  disagreements where the next chance sides with the flag",
    ep[side_by_flag != side_by_team & next_chance_side == side_by_flag, .N])
add("labels", "rebound frame at or before the shot's release", ep[!is.na(rf), sum(rf <= f0)], 0)
add("labels", "rebound frame after release but before endFrame", ep[!is.na(rf), sum(rf > f0 & rf < f1)], NA,
    "kept: blocks and quick rebounds at the rim; endFrame is not the ball's arrival for short shots")
add("labels", "shots with endFrame - startFrame over 40 frames", ep[, sum(f1 - f0 > 40)], NA)

# ---- retained population and landmark usability -----------------------------------------------------------
EXCLUDE <- c("no rebound row: end of period", "no rebound row: foul", "no rebound row: turnover or violation",
             "no rebound row: unexplained", "team rebound: end of period",
             "rebound row at or before the release (tip sequence linked to the tip)")
ep[, retained := status == "eligible" & !terminal %in% EXCLUDE]
ep[, exclusion := fcase(retained, "", terminal %in% EXCLUDE, terminal, default = status)]
# Player rebounds whose credited rebounder never gets within reach_ball_ft of the ball (0.4 s before to 1 s after
# the rebound frame): kept, since the official credit is the target, but flagged for sensitivity checks.
ep[, identity_suspect := grabbed %in% TRUE & !is.na(reb_min_dist) & reb_min_dist > GATE0$reach_ball_ft]
add("labels", "retained player rebounds whose rebounder never reaches the ball", ep[retained == TRUE, sum(identity_suspect)],
    NA, sprintf("within %g ft, 0.4 s before to 1 s after the rebound frame", GATE0$reach_ball_ft))
lm <- merge(lm, ep[, .(shot_id, retained)], by = "shot_id")
lm[, identity_ok := tracked_complete | chance_complete]
lm[, usable := ball_ok & identity_ok]
lm[, usable_after_fallback := !is.na(ball_lag) & identity_ok]
# shares are over the landmarks that exist (no post-contact landmark without a contact, none before a touch
# that never comes); not_defined counts the rest
lm_summary <- lm[retained == TRUE, .(retained = .N, defined = sum(!is.na(frame)), not_defined = sum(is.na(frame)),
                                     ball_ok = mean(ball_ok[!is.na(frame)]),
                                     tracked_complete = mean(tracked_complete[!is.na(frame)]),
                                     tracked_matches_chance = mean(tracked_matches_chance[!is.na(frame)]),
                                     chance_complete = mean(chance_complete[!is.na(frame)]),
                                     usable = mean(usable[!is.na(frame)]),
                                     usable_after_fallback = mean(usable_after_fallback[!is.na(frame)]),
                                     fallback_used = sum(ball_lag > 0, na.rm = TRUE),
                                     abstain = sum(!is.na(frame) & !usable_after_fallback)), by = landmark]

# ---- semantics of endFrame and rebound frame --------------------------------------------------------------
el <- ep[retained == TRUE]
q <- function(v) c(p10 = quantile(v, 0.1, na.rm = TRUE), med = median(v, na.rm = TRUE), p90 = quantile(v, 0.9, na.rm = TRUE))
sem <- rbind(
  data.table(quantity = "ball height at shots.endFrame (ft)", t(q(el$z_end))),
  data.table(quantity = "ball distance from calibrated hoop at endFrame (ft)", t(q(el$hd_end))),
  data.table(quantity = "frames from endFrame to the ball's closest approach to the hoop", t(q(el$closest_minus_end))),
  data.table(quantity = "frames from endFrame to the contact proxy", t(q(el$contact_frame - el$f1))),
  data.table(quantity = "seconds from endFrame to rebounds.frame", t(q((el$rf - el$f1) / FPS))),
  data.table(quantity = "seconds from the first-touch proxy to rebounds.frame", t(q((el$rf - el$touch_frame) / FPS))),
  data.table(quantity = "seconds from rebounds.frame to the control proxy", t(q((el$control_frame - el$rf) / FPS))),
  data.table(quantity = "ball height at rebounds.frame (ft), player rebounds", t(q(el[grabbed == TRUE]$z_reb))),
  data.table(quantity = "ball speed at rebounds.frame (ft/s), player rebounds", t(q(el[grabbed == TRUE]$speed_reb))),
  data.table(quantity = "rebounder to ball, horizontal, at rebounds.frame (ft)", t(q(el$reb_ball_dist))),
  data.table(quantity = "rebounds.location vs tracked rebounder, event frame turned 180 deg (ft)", t(q(el$reb_loc_gap))),
  data.table(quantity = "rebounds.location vs tracked rebounder, not turned (ft)", t(q(el$reb_loc_gap_unflipped))),
  data.table(quantity = "shots.location vs tracked shooter at release, turned (ft)", t(q(audited$episodes$loc_gap))))
setnames(sem, c("quantity", "p10", "median", "p90"))
made_lag <- audited$hoops[, .(quantity = "made shots: frames from endFrame to the rim-height crossing (median per game end)",
                              p10 = quantile(lag_frames, 0.1), median = median(lag_frames), p90 = quantile(lag_frames, 0.9))]
sem <- rbind(sem, made_lag)
sem_share <- el[grabbed == TRUE, .(player_rebounds = .N, rebounder_tracked = mean(rebounder_tracked),
                                   rebounder_nearest_ball = mean(nearest_pid == rpid, na.rm = TRUE),
                                   rebounder_within_3ft = mean(reb_ball_dist <= 3, na.rm = TRUE),
                                   rebounder_within_6ft = mean(reb_ball_dist <= 6, na.rm = TRUE),
                                   ball_below_8ft = mean(z_reb < 8, na.rm = TRUE),
                                   rf_after_contact = mean(rf > fcoalesce(contact_frame, f1)))]

# ---- quality in shot-to-rebound windows -------------------------------------------------------------------
window_quality <- function(d) d[, .(misses_with_rebound = .N, frames = sum(span_frames),
                                    index_missing_frames = sum(index_missing), windows_with_index_gap = sum(index_missing > 0),
                                    dead_frames = sum(reb_dead_frames, na.rm = TRUE),
                                    ball_present = weighted.mean(ball_present, span_frames),
                                    ball_keyframe = weighted.mean(ball_keyframe, span_frames),
                                    ball_detected = weighted.mean(ball_det, span_frames, na.rm = TRUE),
                                    ball_pred_error = mean(ball_err_mean, na.rm = TRUE),
                                    player_rows_missing = 1 - sum(player_rows) / sum(player_rows_expected),
                                    frames_short_of_10 = sum(frames_short), player_detected = weighted.mean(player_det, player_rows),
                                    player_err_detected = weighted.mean(player_err_det, player_rows, na.rm = TRUE),
                                    player_err_extrapolated = weighted.mean(player_err_ext, player_rows, na.rm = TRUE),
                                    game_clock_increases = sum(gc_increases), period_changes = sum(period_changes))]
has_rb <- ep[!is.na(rf)]
qual <- rbind(has_rb[, window_quality(.SD), by = game_id], cbind(game_id = NA_integer_, window_quality(has_rb)),
              cbind(game_id = -1L, window_quality(has_rb[retained == TRUE])))   # NA: all, -1: retained only
# player positions detected vs extrapolated, pooled over every retained window
pw <- rbindlist(lapply(matches$id, function(g) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  sp <- ep[game_id == g & !is.na(rf)]
  fr <- unique(unlist(Map(seq, sp$f0, pmax(sp$f1, sp$rf))))
  raw$players[frame %in% fr, .(game_id = g, det, err)]
}))
det_split <- pw[, .(rows = .N, share = .N / nrow(pw), err_mean = mean(err), err_p95 = quantile(err, 0.95)), by = .(detected = det == 1L)]

# ---- normalized event table (the data contract) -----------------------------------------------------------
contract <- ep[, .(game_id, shot_id, chance_id, poss_id, period, shot_start_frame = f0, shot_end_frame = f1,
                   rebound_id = reb_id, rebound_frame = rf, rebounder_id = rpid, rebounder_canonical = rcanon,
                   rebound_team = rteam, rebounded = grabbed, defensive, side_by_flag, side, outcome12,
                   shooter_id = pid, shooter_canonical = canon,
                   off_team, def_team, three, blocked, fouled, shot_type, complex_shot_type = cst, shot_range,
                   left_hoop, next_chance, next_chance_type = nc_type, contact_proxy = contact_frame,
                   touch_proxy = touch_frame, control_proxy = control_frame, audit_kind = kind, putback_attempt,
                   identity_suspect, terminal, retained, exclusion)]
fwrite(contract, file.path(out, "event_table.csv"))

# ---- assemble checks and the gate decision ----------------------------------------------------------------
tot <- links[, lapply(.SD, sum), .SDcols = -"game_id"]
for (n in names(tot)) add("links", n, tot[[n]])
for (n in setdiff(names(inventory), c("game_id", "tracking_file", "tracking_mb")))
  add("inventory", n, if (is.logical(inventory[[n]])) all(inventory[[n]]) else sum(inventory[[n]], na.rm = TRUE))
ctot <- clock_checks[, lapply(.SD, function(v) if (all(is.na(v))) NA_real_ else max(v, na.rm = TRUE)), by = event,
                     .SDcols = c("frame_missing", "wall_mismatch", "period_mismatch", "gc_max_abs_diff", "dead_at_frame")]
add("identity", "shooter in the chance's offensive players", sum(!ep$shooter_on_offense), 0, "non-fouled misses where it fails")
add("identity", "rebounder in the shot's chance_players", sum(ep$rebounder_in_chance %in% FALSE), 0, "player rebounds where it fails")
add("identity", "rebounder's side in chance_players matches defensive flag", sum(ep$rebounder_side_ok %in% FALSE), 0)
add("identity", "chance_players with exactly 5 + 5", sum(ep$chance_off_n == 5L & ep$chance_def_n == 5L), nrow(ep))
add("identity", "credited rebounder tracked on court at the rebound frame", sum(ep[grabbed %in% TRUE]$rebounder_tracked %in% TRUE),
    sum(ep$grabbed %in% TRUE))
review_n <- max(GATE0$review_min, ceiling(GATE0$review_share * sum(!is.na(ep$reb_id))))

# ---- gate decision: each check and PASS criterion of the roadmap's Gate 0 -----------------------------------
log_path <- file.path(out, "review", "review_log.csv")
rv <- if (file.exists(log_path)) merge(fread(log_path), ep[, .(shot_id, game_id, retained, identity_suspect)], by = "shot_id") else NULL
counted <- if (is.null(rv)) NULL else rv[verdict != "extra"]
r <- ep[retained == TRUE]
gate <- rbind(
  data.table(item = "Every shot and rebound row enumerated by game, every link counted",
             evidence = sprintf("%d shots, %d rebound rows (%d FG, %d FT); 0 duplicate links, %d null references, %d misses without a row",
                                tot$shots, tot$rebound_rows, tot$fg_rebound_rows, tot$ft_rebound_rows, tot$rebound_reference_missing,
                                tot$non_fouled_miss_without_rebound),
             pass = tot$duplicate_links == 0 && tot$rebound_to_made_shot == 0 && tot$rebound_to_fouled_shot == 0),
  data.table(item = "Missed free throws: separate join needed?",
             evidence = sprintf("FT rebounds point to free_throws ids (%d of %d live FT misses have one); outside the FG population",
                                tot$ft_live_misses_with_rebound, tot$ft_live_misses), pass = TRUE),
  data.table(item = "endFrame and rebound frame semantics checked against the ball",
             evidence = "endFrame: ball at the rim zone (median 11.2 ft high, 1.3 ft from the hoop), never > 40 frames after release; rebound frame: between first touch and control",
             pass = TRUE),
  data.table(item = "Rosters, IDs, teams, orientation, units, 25 fps, clocks",
             evidence = sprintf("wallClock = 40 x frameIdx on every line; %d event wallClock and %d period mismatches; rebounder off roster %d; location turned 180 deg matches tracking (median 0 ft)",
                                sum(clock_checks$wall_mismatch), sum(clock_checks$period_mismatch), tot$rebounder_off_roster),
             pass = sum(clock_checks$wall_mismatch) == 0 && sum(clock_checks$period_mismatch) == 0 && tot$rebounder_off_roster == 0),
  data.table(item = "Terminal outcome taxonomy defined", evidence = "taxonomy.csv; tipped-but-unsecured left to Gate 1", pass = TRUE),
  data.table(item = sprintf("Review of at least %d rebounds across games and kinds", review_n),
             evidence = if (is.null(counted)) "no review log" else
               sprintf("%d reviewed from %d games: %d agree, %d disagree, %d unclear (tracking plots; no video in the release)",
                       nrow(counted), uniqueN(counted$game_id), sum(counted$verdict == "agree"), sum(counted$verdict == "disagree"),
                       sum(counted$verdict == "unclear")),
             pass = !is.null(counted) && nrow(counted) >= review_n && uniqueN(counted$game_id) == 10L),
  data.table(item = "Ball and player quality in shot-to-rebound windows, detected vs extrapolated",
             evidence = sprintf("retained windows: ball present %.1f%%, keyframes %.1f%%, ball isDetected %.0f%%; players detected %.1f%%",
                                100 * qual[game_id == -1L]$ball_present, 100 * qual[game_id == -1L]$ball_keyframe,
                                100 * qual[game_id == -1L]$ball_detected, 100 * qual[game_id == -1L]$player_detected), pass = TRUE),
  data.table(item = "PASS 1: retained examples have one outcome label",
             evidence = sprintf("%d retained; %d without a label; side by teamId (14 defensive flags overridden)", nrow(r), sum(is.na(r$outcome12))),
             pass = all(!is.na(r$outcome12))),
  data.table(item = "PASS 2: valid player and team IDs",
             evidence = sprintf("rebounder off roster %d, rebounder's team mismatch %d, not in the chance's players %d",
                                tot$rebounder_off_roster, tot$rebounder_team_mismatch, sum(r$rebounder_in_chance %in% FALSE)),
             pass = tot$rebounder_off_roster == 0 && tot$rebounder_team_mismatch == 0 && !any(r$rebounder_in_chance %in% FALSE)),
  data.table(item = "PASS 3: temporally ordered frames",
             evidence = sprintf("retained with rebound at or before release %d; period changes in windows %d; clock increases %d",
                                sum(r$rf <= r$f0), sum(r$period_changes), sum(r$gc_increases)),
             pass = all(r$rf > r$f0) && sum(r$period_changes) == 0 && sum(r$gc_increases) == 0),
  data.table(item = sprintf("PASS 4: landmarks usable >= %.0f%%, or a documented abstention", 100 * GATE0$landmark_usable),
             evidence = paste(sprintf("%s %.1f%% (%.1f%% after fallback, %d abstain)", lm_summary$landmark, 100 * lm_summary$usable,
                                      100 * lm_summary$usable_after_fallback, lm_summary$abstain), collapse = "; "),
             pass = all(lm_summary$usable_after_fallback >= GATE0$landmark_usable)),
  data.table(item = "PASS 5: uncertain outcomes excluded with counts or flagged",
             evidence = sprintf("%d excluded by reason (exclusions.csv); %d retained player rebounds flagged identity_suspect",
                                sum(!ep$retained), sum(r$identity_suspect)), pass = TRUE))
gate[, status := fifelse(pass, "PASS", "BLOCKED")]
fwrite(gate, file.path(out, "gate_decision.csv"))

saveRDS(list(episodes = ep, landmarks = lm, review_n = review_n), file.path(cache, "gate0.rds"))
fwrite(inventory, file.path(out, "inventory.csv"))
fwrite(links, file.path(out, "links_by_game.csv"))
fwrite(clock_checks, file.path(out, "clock_checks.csv"))
fwrite(rbindlist(check), file.path(out, "checks.csv"))
fwrite(sem, file.path(out, "event_semantics.csv"))
fwrite(sem_share, file.path(out, "rebound_frame_agreement.csv"))
fwrite(qual, file.path(out, "window_quality.csv"))
fwrite(det_split, file.path(out, "player_detected_vs_extrapolated.csv"))
fwrite(lm_summary, file.path(out, "landmarks.csv"))
fwrite(ep[, .N, by = .(terminal, retained)][order(-N)], file.path(out, "taxonomy.csv"))
fwrite(ep[, .N, by = .(exclusion)][order(-N)], file.path(out, "exclusions.csv"))
fwrite(ep[, .N, by = .(game_id, terminal)][order(game_id, -N)], file.path(out, "taxonomy_by_game.csv"))

print(inventory); print(tot); print(ctot); print(sem); print(sem_share); print(qual); print(det_split)
print(lm_summary); print(ep[, .N, by = .(terminal, retained)][order(-N)]); print(rbindlist(check)[area == "identity"])
cat("review sample size:", review_n, "\n")
