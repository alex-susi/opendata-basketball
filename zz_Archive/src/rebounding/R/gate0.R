# Gate 0 of the gated rebound roadmap (Rebound_Probability_Model_Verbatim_and_Roadmap, Part III): rebound event
# audit and data contract, run before any model of that roadmap.
#
# Events are read straight from the delivered files so that every shot, rebound, free throw and foul row is
# enumerated with its raw values (nulls kept as NA). Tracking comes from two places: every line's clock header
# (frameIdx, wallClock, gameClock, period, dead-frame flag) streamed from the raw file, and the cached shot
# windows of extract.R for ball and player positions with isDetected / predError. Contact, touch and control
# frames are the automated proxies of audit.R (episodes.rds); Gate 1 is where they get reviewed.
# Requires data.R (play viewer), geometry.R, extract.R, audit.R.

# Thresholds fixed before the checks were run (2026-10-28). Gate 0 has no held-out evaluation; these only
# decide PASS / BLOCKED.
GATE0 <- list(
  landmark_usable = 0.95,   # retained prediction landmarks with a usable ball and a complete identity set
  review_min = 30L,         # rebounds reviewed: at least this many ...
  review_share = 0.10,      # ... or this share of the candidate rebounds, whichever is larger
  ball_recent = 2L,         # a usable ball: tracked at the landmark and a keyframe in the 2 frames up to it
  clock_tol_ms = 0L,        # event wallClock must equal the tracking wallClock at its frame
  oob_margin = 0.5,         # ft past the lines before a ball counts as out of court
  putback_s = 1,            # an offensive shot this soon after an offensive rebound is a put-back attempt
  foul_after_s = 1,         # a non-shooting foul between the shot's end and this long after the rebound
  period_end_s = 1,         # game clock at or under this at the rebound: end of period
  fallback_frames = 5L,     # added after the first run: a landmark may move back this far to a usable ball
  reach_ball_ft = 3         # added after the review: a credited rebounder never this close to the ball is suspect
)

#' A logical field that keeps missing values as NA (lgl_field in data.R turns them into FALSE).
lgl_na <- function(recs, name) vapply(recs, function(r) if (is.null(r[[name]])) NA else as.logical(r[[name]]), NA)

#' The frame's clock header for every line of a tracking file, plus whether the frame is dead time.
tracking_clock <- function(root, g) {
  lines <- readLines(tracking_source(root, g), warn = FALSE)
  head <- substr(lines, 1L, 200L)
  pat <- '^\\{"frameIdx": ([0-9]+), "wallClock": ([0-9]+), "gameClock": ([-0-9.eE]+|null), "gameClockStopped": (true|false), "period": ([0-9]+)'
  m <- regmatches(head, regexec(pat, head))
  if (any(lengths(m) != 6L)) stop("Unexpected tracking header in game ", g)
  m <- do.call(rbind, m)
  data.table(game_id = g, frame = as.integer(m[, 2]), wall = as.numeric(m[, 3]),
             gc = suppressWarnings(as.numeric(m[, 4])), stopped = m[, 5] == "true", period = as.integer(m[, 6]),
             no_players = grepl('"homePlayers": [], "awayPlayers": []', head, fixed = TRUE),
             no_ball = grepl('"ball": {}', lines, fixed = TRUE))
}

#' Every event row Gate 0 needs from one game, with raw ids and nulls preserved.
gate0_events <- function(root, g, aliases) {
  ev <- read_json_file(match_file(root, g, "_dynamic_events.json"))
  gd <- read_json_file(match_file(root, g, "_game_data.json"))
  roster <- rbind(data.table(pid = int_field(gd$homeTeam$players, "playerId"), team = gd$homeTeam$teamId, home = TRUE),
                  data.table(pid = int_field(gd$awayTeam$players, "playerId"), team = gd$awayTeam$teamId, home = FALSE))
  roster[, c("game_id", "canon") := .(g, canon_id(pid, aliases))]
  xy <- function(recs, f, k) vapply(recs, function(r) as.numeric(r[[f]][[k]] %||% NA), 0)
  sh <- data.table(game_id = g, shot_id = chr_field(ev$shots, "id"), chance_id = chr_field(ev$shots, "chanceId"),
                   poss_id = chr_field(ev$shots, "possessionId"), period = int_field(ev$shots, "period"),
                   f0 = int_field(ev$shots, "startFrame"), f1 = int_field(ev$shots, "endFrame"),
                   w0 = num_field(ev$shots, "startWallClock"), w1 = num_field(ev$shots, "endWallClock"),
                   gc0 = num_field(ev$shots, "startGameClock"), pid = int_field(ev$shots, "shooterId"),
                   off_team = int_field(ev$shots, "offTeamId"), def_team = int_field(ev$shots, "defTeamId"),
                   made = lgl_na(ev$shots, "outcome"), fouled = lgl_na(ev$shots, "fouled"),
                   three = lgl_na(ev$shots, "three"), blocked = lgl_na(ev$shots, "blocked"),
                   blocker = int_field(ev$shots, "blockerId"), shot_type = chr_field(ev$shots, "shotType"),
                   cst = chr_field(ev$shots, "complexShotType"), ev_x = xy(ev$shots, "location", 1L),
                   ev_y = xy(ev$shots, "location", 2L))
  rb <- data.table(game_id = g, reb_id = chr_field(ev$rebounds, "id"), ref_id = chr_field(ev$rebounds, "shotId"),
                   chance_id = chr_field(ev$rebounds, "chanceId"), period = int_field(ev$rebounds, "period"),
                   rf = int_field(ev$rebounds, "frame"), rw = num_field(ev$rebounds, "wallClock"),
                   rgc = num_field(ev$rebounds, "gameClock"), rteam = int_field(ev$rebounds, "teamId"),
                   rpid = int_field(ev$rebounds, "rebounderId"), fg = lgl_na(ev$rebounds, "fgReb"),
                   grabbed = lgl_na(ev$rebounds, "rebounded"), defensive = lgl_na(ev$rebounds, "defensive"),
                   rev_x = xy(ev$rebounds, "location", 1L), rev_y = xy(ev$rebounds, "location", 2L),
                   region = chr_field(ev$rebounds, "region"), next_chance = chr_field(ev$rebounds, "nextChanceId"))
  ft <- data.table(game_id = g, ft_id = chr_field(ev$free_throws, "id"), chance_id = chr_field(ev$free_throws, "chanceId"),
                   frame = int_field(ev$free_throws, "frame"), foul_id = chr_field(ev$free_throws, "foulId"),
                   shot_id = chr_field(ev$free_throws, "shotId"), off_team = int_field(ev$free_throws, "offTeamId"),
                   made = lgl_na(ev$free_throws, "outcome"))
  fo <- data.table(game_id = g, foul_id = chr_field(ev$fouls, "id"), chance_id = chr_field(ev$fouls, "chanceId"),
                   frame = int_field(ev$fouls, "frame"), shooting = lgl_na(ev$fouls, "shooting"),
                   foul_type = chr_field(ev$fouls, "foulType"), shot_id = chr_field(ev$fouls, "shotId"),
                   technical = lgl_na(ev$fouls, "isTechnical"))
  ch <- data.table(game_id = g, chance_id = chr_field(ev$chances, "id"), period = int_field(ev$chances, "period"),
                   start_type = chr_field(ev$chances, "startType"), outcome = chr_field(ev$chances, "outcome"),
                   off_team = int_field(ev$chances, "offTeamId"), c0 = int_field(ev$chances, "startFrame"),
                   c1 = int_field(ev$chances, "endFrame"))
  to <- data.table(game_id = g, chance_id = chr_field(ev$turnovers, "id"), frame = int_field(ev$turnovers, "frame"),
                   off_team = int_field(ev$turnovers, "offTeamId"))
  poss <- data.table(poss_id = chr_field(ev$possessions, "id"), left_hoop = lgl_na(ev$possessions, "leftHoop"))
  sh <- merge(sh, poss, by = "poss_id", all.x = TRUE, sort = FALSE)
  cp <- data.table(game_id = g, chance_id = chr_field(ev$chance_players, "chanceId"),
                   pid = int_field(ev$chance_players, "playerId"), offense = lgl_na(ev$chance_players, "offense"))
  list(keys = names(ev), shots = sh, rebounds = rb, free_throws = ft, fouls = fo, chances = ch, turnovers = to,
       chance_players = cp, roster = roster)
}

#' Rebound rows by what they point at, and every link failure Gate 0 counts.
link_checks <- function(e) {
  rb <- e$rebounds
  rb[, ref_kind := fcase(startsWith(ref_id, "shot-"), "shot", startsWith(ref_id, "free_throw-"), "free throw",
                         is.na(ref_id), "none", default = "other")]
  rb[, ref_found := fifelse(ref_kind == "shot", ref_id %in% e$shots$shot_id,
                            fifelse(ref_kind == "free throw", ref_id %in% e$free_throws$ft_id, FALSE))]
  rb[]
}

#' Missed free throws that leave the ball live (the last attempt of a trip) and whether a rebound row follows.
ft_live_misses <- function(e) {
  ft <- copy(e$free_throws)[order(frame)]
  ft[, last_of_trip := frame == max(frame), by = .(fkey = fcoalesce(foul_id, ft_id))]
  rb <- e$rebounds[fg %in% FALSE]
  ft[, has_rebound := ft_id %in% rb$ref_id]
  ft[]
}

#' Players tracked at chosen frames of a game: count per side, roster agreement and the canonical id sets.
tracked_identity <- function(raw, roster, frames) {
  pl <- raw$players[frame %in% frames]
  pl <- merge(pl, roster[, .(pid, r_home = home, canon)], by = "pid", all.x = TRUE)
  pl[, .(n_home = sum(home), n_away = sum(!home), n_unique = uniqueN(pid),
         off_roster = sum(is.na(r_home)), wrong_side = sum(!is.na(r_home) & r_home != home),
         home_ids = list(sort(canon[home])), away_ids = list(sort(canon[!home])),
         det_share = mean(det == 1L)), by = frame]
}

#' A usable ball observation at landmark frame f: tracked at f and a vendor keyframe (not an interpolated
#' midpoint) within the GATE0$ball_recent frames up to f.
ball_usable <- function(track, f) {
  if (is.na(f)) return(NA)
  at <- track[frame == f]
  if (!nrow(at) || is.na(at$x)) return(FALSE)
  recent <- track[frame <= f & frame >= f - GATE0$ball_recent & !is.na(x)]
  any(!(recent$interp %in% TRUE))
}

#' Abstention rule for a landmark without a usable ball: how many frames back (up to GATE0$fallback_frames) the
#' latest frame with a usable ball is. NA means the forecast at that landmark abstains.
ball_lag <- function(track, f) {
  if (is.na(f)) return(NA_integer_)
  for (k in 0:GATE0$fallback_frames) if (isTRUE(ball_usable(track, f - k))) return(k)
  NA_integer_
}

#' One missed shot's Gate 0 record: event semantics against the ball track, identity at the rebound frame and
#' at each landmark, ball/player quality over release-to-rebound, and terminal-outcome evidence.
#' @param s One row of the shot table (with the rebound joined and the audit's proxies).
#' @param hoop Calibrated ball-frame hoop centre for the shot's end.
miss_record <- function(raw, s, hoop, roster, cp_ids, clock) {
  last <- if (!is.na(s$rf)) max(s$rf, s$f1) else s$f1
  w <- ball_track(raw$frames, s, s$f0 - 5L, min(s$f0 + WINDOW_MAX, last + WINDOW_AFTER))
  w[, hd := sqrt((x - hoop$hx)^2 + (y - hoop$hy)^2)]
  out <- list()
  at <- function(f, col) if (is.na(f) || !nrow(w[frame == f])) NA_real_ else w[frame == f][[col]]
  # shots.endFrame against the ball: height, distance from the calibrated hoop, and the closest approach
  out$z_end <- at(s$f1, "z")
  out$hd_end <- at(s$f1, "hd")
  fl <- w[frame >= s$f0 & frame <= s$f1 + 15L & !is.na(hd) & z > RIM_Z - 3]
  out$closest_minus_end <- if (nrow(fl)) fl$frame[which.min(fl$hd)] - s$f1 else NA_real_
  # rebounds.frame against the ball and the credited rebounder
  if (!is.na(s$rf)) {
    out$z_reb <- at(s$rf, "z")
    out$speed_reb <- at(s$rf, "bspeed")
    out$ball_tracked_reb <- !is.na(out$z_reb)
    bx <- at(s$rf, "x"); by <- at(s$rf, "y")
    out$ball_oob_reb <- !is.na(bx) && (abs(bx) > COURT_HALF_L + GATE0$oob_margin | abs(by) > COURT_HALF_W + GATE0$oob_margin)
    post <- w[frame >= s$f1 & frame <= s$rf + 12L & !is.na(x)]
    out$ball_oob_window <- nrow(post) > 0 &&
      any(abs(post$x) > COURT_HALF_L + GATE0$oob_margin | abs(post$y) > COURT_HALF_W + GATE0$oob_margin)
    out$dead_at_reb <- clock[frame == s$rf]$no_players %in% TRUE
    pl <- window_players(raw, s, s$rf)
    if (nrow(pl) && !is.na(bx)) {
      pl[, d := sqrt((px - bx)^2 + (py - by)^2)]
      out$nearest_pid <- pl$pid[which.min(pl$d)]
      out$nearest_off <- pl$off[which.min(pl$d)]
      out$reb_ball_dist <- if (!is.na(s$rpid) && s$rpid %in% pl$pid) pl[pid == s$rpid]$d[1] else NA_real_
    }
    if (nrow(pl) && !is.na(s$rpid) && s$rpid %in% pl$pid) {
      r <- pl[pid == s$rpid][1]
      # rebounds.location is in the event frame (shooting team's hoop at -x): tracked, rotated = -event
      out$reb_loc_gap <- sqrt((r$px + s$rev_x)^2 + (r$py + s$rev_y)^2)
      out$reb_loc_gap_unflipped <- sqrt((r$px - s$rev_x)^2 + (r$py - s$rev_y)^2)
    }
    out$rebounder_tracked <- !is.na(s$rpid) && s$rpid %in% pl$pid
    # does the credited rebounder ever get to the ball, from 0.4 s before the rebound frame to 1 s after?
    if (!is.na(s$rpid)) {
      near <- merge(window_players(raw, s, (s$rf - 10L):(s$rf + 25L))[pid == s$rpid, .(frame, px, py)],
                    w[!is.na(x), .(frame, x, y)], by = "frame")
      out$reb_min_dist <- if (nrow(near)) min(sqrt((near$px - near$x)^2 + (near$py - near$y)^2)) else NA_real_
    }
    out$reb_dead_frames <- sum(clock[frame >= s$f0 & frame <= s$rf]$no_players)
  }
  # quality between release and rebound (or the shot's end when there is no rebound row)
  span <- s$f0:last
  seen <- w[frame %in% span]
  out$span_frames <- length(span)
  out$index_missing <- sum(!span %in% clock$frame)
  out$ball_present <- sum(!is.na(seen$x)) / length(span)
  out$ball_keyframe <- sum(!is.na(seen$x) & !(seen$interp %in% TRUE)) / length(span)
  out$ball_det <- mean(seen$bdet > 0, na.rm = TRUE)
  out$ball_err_mean <- mean(seen$berr, na.rm = TRUE)
  pw <- raw$players[frame %in% span]
  out$player_rows <- nrow(pw)
  out$player_rows_expected <- 10L * length(span)
  out$player_det <- mean(pw$det == 1L)
  out$player_err_det <- mean(pw$err[pw$det == 1L])
  out$player_err_ext <- mean(pw$err[pw$det == 0L])
  out$frames_short <- sum(pw[, .N, by = frame]$N < 10L) + sum(!span %in% pw$frame)
  out$gc_increases <- sum(diff(clock[frame %in% span]$gc) > 1e-6, na.rm = TRUE)
  out$period_changes <- uniqueN(clock[frame %in% span]$period) - 1L
  # landmarks: release, late flight (2 frames before contact, else the shot's end), 0.2 s after an observed
  # contact, one frame before the first possible touch
  cf <- s$contact_frame
  lm <- c(release = s$f0, late_flight = max(s$f0, fcoalesce(cf, s$f1) - 2L),
          post_contact = if (is.na(cf)) NA_integer_ else cf + 5L,
          pre_touch = if (is.na(s$touch_frame)) NA_integer_ else max(s$f0, s$touch_frame - 1L))
  ids <- tracked_identity(raw, roster, lm[!is.na(lm)])
  home_off <- raw$home_team == s$off_team
  lms <- rbindlist(lapply(names(lm), function(k) {
    f <- lm[[k]]
    if (is.na(f)) return(data.table(landmark = k, frame = NA_integer_, ball_ok = NA, ball_lag = NA_integer_,
                                    tracked_complete = NA, tracked_matches_chance = NA, chance_complete = NA))
    id <- ids[frame == f]
    complete <- nrow(id) == 1L && id$n_home == 5L && id$n_away == 5L && id$n_unique == 10L && id$off_roster == 0L &&
      id$wrong_side == 0L
    off_set <- if (nrow(id)) (if (home_off) id$home_ids[[1]] else id$away_ids[[1]]) else integer()
    def_set <- if (nrow(id)) (if (home_off) id$away_ids[[1]] else id$home_ids[[1]]) else integer()
    data.table(landmark = k, frame = f, ball_ok = ball_usable(w, f), ball_lag = ball_lag(w, f), tracked_complete = complete,
               tracked_matches_chance = complete && setequal(off_set, cp_ids$off) && setequal(def_set, cp_ids$def),
               chance_complete = length(cp_ids$off) == 5L && length(cp_ids$def) == 5L)
  }))
  list(row = out, landmarks = lms)
}

#' The terminal-outcome taxonomy of the roadmap, one label per missed field goal, from event rows and the
#' ball track. Tipped-but-unsecured is not identifiable from Gate 0 evidence and is left to Gate 1.
terminal_outcome <- function(ep) {
  ep[, terminal := fcase(
    made %in% TRUE, "made (no rebound)",
    fouled %in% TRUE, "fouled miss (free throws, no live rebound)",
    is.na(reb_id) & period_end, "no rebound row: end of period",
    is.na(reb_id) & foul_after, "no rebound row: foul",
    is.na(reb_id) & turnover_after, "no rebound row: turnover or violation",
    is.na(reb_id), "no rebound row: unexplained",
    rf <= f0, "rebound row at or before the release (tip sequence linked to the tip)",
    grabbed %in% TRUE & foul_after, "player rebound, foul in the scramble",
    grabbed %in% TRUE, "secured individual rebound",
    grabbed %in% FALSE & period_end, "team rebound: end of period",
    grabbed %in% FALSE & held_ball, "team rebound: held ball",
    grabbed %in% FALSE & foul_after, "team rebound: foul",
    grabbed %in% FALSE & (ball_oob_window %in% TRUE), "team rebound: out of bounds (ball seen out)",
    grabbed %in% FALSE & (ball_tracked_reb %in% FALSE | dead_at_reb %in% TRUE), "team rebound: ball not tracked at the award",
    grabbed %in% FALSE, "team rebound: other / unclear",
    default = "unknown")]
  ep[]
}
