# Step 01 of the rebounding manual: the rebound episode table and its join, identity, timing, orientation and
# coverage audits. Builds on the Gate 0 audit of the earlier roadmap (gate0.R, run_gate0.R), whose per-miss records
# (outcome taxonomy, exclusions, landmarks, identity at each landmark) it reads from gate0.rds.
# Requires geometry.R, extract.R, audit.R (ball_track, rot, window_players).

PERIOD_SECONDS <- function(period) ifelse(period <= 4L, 600, 300)   # FIBA: 10-minute quarters, 5-minute overtimes

#' The one transform from the camera frame to the attack frame of a shot (offence attacks +x): a 180-degree
#' rotation when the offence attacks the camera's left hoop. It is its own inverse, and it is applied with the same
#' `flip` to the ball and all ten players. Positions and displacements (velocities) transform alike.
attack_frame <- function(x, y, flip) {
  stopifnot(all(flip %in% c(-1, 1)))
  list(x = rot(x, flip), y = rot(y, flip))
}

#' Clock coverage of every period of a game, from the tracking lines' clock headers (tracking_clock()).
#' running_share: frames with the game clock running / (25 x period length); distinct_share: distinct running
#' game-clock values / (25 x period length); start_gap: period length minus the first (largest) clock value seen.
period_coverage <- function(clock) {
  clock[, .(lines = .N, running_frames = sum(!stopped), distinct_running = uniqueN(gc[!stopped]),
            first_clock = max(gc, na.rm = TRUE), dead_share = mean(no_players)), by = .(game_id, period)][
    , length_s := PERIOD_SECONDS(period)][
    , `:=`(running_share = running_frames / (25 * length_s), distinct_share = distinct_running / (25 * length_s),
           start_gap = length_s - first_clock)][]
}

#' The ten players tracked at a frame, by side, against the roster and the chance's players.
players_at <- function(raw, s, f, roster, cp_off, cp_def) {
  pl <- window_players(raw, s, f)
  pl <- merge(pl, roster[, .(pid, r_team = team)], by = "pid", all.x = TRUE)
  off_ids <- sort(pl[off == TRUE]$pid)
  def_ids <- sort(pl[off == FALSE]$pid)
  data.table(n_off = length(off_ids), n_def = length(def_ids), duplicated_ids = anyDuplicated(pl$pid) > 0,
             off_roster = sum(is.na(pl$r_team)),
             wrong_team = sum(!is.na(pl$r_team) & pl$r_team != fifelse(pl$off, s$off_team, s$def_team)),
             matches_chance = setequal(off_ids, cp_off) && setequal(def_ids, cp_def),
             off_ids = paste(off_ids, collapse = ";"), def_ids = paste(def_ids, collapse = ";"),
             detected_share = mean(pl$det == 1L))
}

#' Ball and player quality of one episode by stage: before release (1 s), flight (release to contact, or to
#' endFrame when no contact is found), contact to rebound, and the second after the rebound.
#' Ball keyframes are counted at the audit's tolerance (0.015 ft) and at the stricter 0.001 ft.
stage_quality <- function(raw, s) {
  contact <- fcoalesce(s$contact_frame, s$f1)
  bounds <- list(pre_release = c(s$f0 - 25L, s$f0 - 1L), flight = c(s$f0, contact - 1L),
                 contact_to_rebound = c(contact, s$rf), after_rebound = c(s$rf + 1L, s$rf + 25L))
  w <- ball_track(raw$frames, s, s$f0 - 26L, s$rf + 26L)
  w[, strict_mid := abs(x - (shift(x) + shift(x, -1L)) / 2) < 0.001 & abs(z - (shift(z) + shift(z, -1L)) / 2) < 0.001]
  rbindlist(lapply(names(bounds), function(k) {
    b <- bounds[[k]]
    if (is.na(b[1]) || is.na(b[2]) || b[2] < b[1]) return(NULL)
    fr <- b[1]:b[2]
    bw <- w[frame %in% fr]
    pw <- raw$players[frame %in% fr]
    data.table(stage = k, frames = length(fr), ball_present = sum(!is.na(bw$x)) / length(fr),
               ball_keyframe = sum(!is.na(bw$x) & !(bw$interp %in% TRUE)) / length(fr),
               ball_keyframe_strict = sum(!is.na(bw$x) & !(bw$strict_mid %in% TRUE)) / length(fr),
               ball_detected = if (nrow(bw)) mean(bw$bdet > 0, na.rm = TRUE) else NA_real_,
               ball_pred_error = if (nrow(bw)) mean(bw$berr, na.rm = TRUE) else NA_real_,
               player_rows = nrow(pw), player_rows_expected = 10L * length(fr),
               player_detected = if (nrow(pw)) mean(pw$det == 1L) else NA_real_,
               player_err_detected = if (any(pw$det == 1L)) mean(pw$err[pw$det == 1L]) else NA_real_,
               player_err_extrapolated = if (any(pw$det == 0L)) mean(pw$err[pw$det == 0L]) else NA_real_,
               player_err_p95 = if (nrow(pw)) unname(quantile(pw$err, 0.95)) else NA_real_)
  }))
}

#' Orientation evidence of one shot, independent of possessions.leftHoop: where the ball is at shots.endFrame after
#' the shot's rotation, how close the ball comes to the attacked hoop and to the opposite hoop between release and the
#' rebound (at most `window` frames), and how many of the ten players stand in the attacked half at release.
orientation_record <- function(raw, s, window = 75L) {
  w <- ball_track(raw$frames, s, s$f1, s$f1)
  to <- min(s$f0 + window, if (is.na(s$rf)) s$f0 + window else max(s$rf, s$f1))
  path <- ball_track(raw$frames, s, s$f0, to)[!is.na(x)]
  pl <- window_players(raw, s, s$f0)
  data.table(ball_x_end = if (nrow(w)) w$x[1] else NA_real_, ball_y_end = if (nrow(w)) w$y[1] else NA_real_,
             ball_z_end = if (nrow(w)) w$z[1] else NA_real_,
             closest_attacked_hoop = if (nrow(path)) min(sqrt((path$x - RIM_X)^2 + path$y^2)) else NA_real_,
             closest_other_hoop = if (nrow(path)) min(sqrt((path$x + RIM_X)^2 + path$y^2)) else NA_real_,
             players_attacked_half = if (nrow(pl)) sum(pl$px > 0) else NA_integer_,
             defenders_attacked_half = if (nrow(pl)) sum(pl$px > 0 & !pl$off) else NA_integer_)
}

#' Frame-by-entity tracking rows of one game's cached windows, in the manual's contract columns (camera frame).
tracking_rows <- function(raw, home_team, away_team) {
  b <- raw$frames[!is.na(bx), .(frame_idx = frame, entity_id = "ball", team_id = NA_integer_, x_ft = bx, y_ft = by,
                                z_ft = bz, is_detected = bdet > 0, pred_error = berr, speed_ft_s = bspeed)]
  p <- raw$players[, .(frame_idx = frame, entity_id = as.character(pid), team_id = fifelse(home, home_team, away_team),
                       x_ft = x, y_ft = y, z_ft = 0, is_detected = det == 1L, pred_error = err, speed_ft_s = speed)]
  out <- rbind(b, p)
  out[, game_id := raw$shots$game_id[1]]
  setcolorder(out, "game_id")
  setorder(out, frame_idx, entity_id)
  out[]
}

#' Two views of one episode for the orientation review: the camera frame with both hoops labelled and the attacked
#' one marked, and the attack frame after the shot's rotation. Ball path from release to rebound + 0.5 s, players
#' at release (filled) and at the rebound (open), red = offence.
draw_orientation <- function(raw, s, hoop, reason) {
  last <- if (!is.na(s$rf)) max(s$rf, s$f1) else s$f1
  w <- raw$frames[frame >= s$f0 & frame <= last + 12L & !is.na(bx)]
  home_off <- raw$home_team == s$off_team
  pl <- raw$players[frame %in% c(s$f0, s$rf)]
  pl[, off := home == home_off]
  attacked_cam <- if (isTRUE(s$left_hoop)) -RIM_X else RIM_X
  half_court <- function() {
    rect(-COURT_HALF_L, -COURT_HALF_W, COURT_HALF_L, COURT_HALF_W, border = "grey40")
    lines(c(0, 0), c(-COURT_HALF_W, COURT_HALF_W), col = "grey60")
  }
  for (view in c("camera", "attack")) {
    f <- if (view == "camera") 1 else s$flip
    par(mar = c(1.5, 1, 3, 1))
    plot(NA, xlim = c(-COURT_HALF_L - 2, COURT_HALF_L + 2), ylim = c(-COURT_HALF_W - 3, COURT_HALF_W + 3), asp = 1,
         axes = FALSE, xlab = "", ylab = "",
         main = if (view == "camera")
           sprintf("%s [%s]\ncamera frame; leftHoop = %s, P%d, gc at rebound %s", s$shot_id, reason, s$left_hoop,
                   s$period, if (is.na(s$rgc)) "-" else sprintf("%.1f", s$rgc))
         else sprintf("attack frame (flip %+d): %s\n%s", s$flip, fcoalesce(s$outcome12, "no rebound row"), s$exclusion_label),
         cex.main = 0.8)
    half_court()
    hx <- if (view == "camera") c(-RIM_X, RIM_X) else c(-RIM_X, RIM_X)
    symbols(hx, c(0, 0), circles = rep(RIM_R, 2), inches = FALSE, add = TRUE, fg = "grey50", lwd = 1.5)
    if (view == "camera") {
      text(-RIM_X, COURT_HALF_W + 2, "camera-left hoop", cex = 0.65)
      text(RIM_X, COURT_HALF_W + 2, "camera-right hoop", cex = 0.65)
      symbols(attacked_cam, 0, circles = 2.2, inches = FALSE, add = TRUE, fg = "orange", lwd = 2)
    } else {
      text(RIM_X, COURT_HALF_W + 2, "attacked hoop (+x)", cex = 0.65, col = "darkorange3")
      symbols(hoop$hx, hoop$hy, circles = RIM_R, inches = FALSE, add = TRUE, fg = "orange", lwd = 2)
    }
    points(f * w$bx, f * w$by, pch = 16, cex = 0.35, col = grey(seq(0.75, 0, length.out = max(1, nrow(w)))))
    at0 <- pl[frame == s$f0]
    at1 <- pl[frame == s$rf]
    if (nrow(at0)) points(f * at0$x, f * at0$y, pch = 21, cex = 1.6, bg = fifelse(at0$off, "tomato", "steelblue"))
    if (nrow(at1)) points(f * at1$x, f * at1$y, pch = 1, cex = 1.6, lwd = 1.5, col = fifelse(at1$off, "tomato", "steelblue"))
    sh <- at0[pid == s$pid]
    if (nrow(sh)) points(f * sh$x, f * sh$y, pch = 8, cex = 1.4, col = "black")
    if (view == "attack" && !is.na(s$ev_x)) points(-s$ev_x, -s$ev_y, pch = 3, cex = 1.8, lwd = 2, col = "darkgreen")
  }
}
