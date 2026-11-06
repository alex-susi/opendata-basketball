# Step 02 of the rebounding manual: an automated labeler for the contact states of a missed shot, from release to
# the credited rebound: rim or board contact, player touches (blocks, tips, catches), floor bounces, control and the
# ball going out. It reads only the tracking; the rubric it follows is docs/project/ANNOTATION_RUBRIC.md and its
# thresholds are config/experiment.yaml (step02$detector).
#
# A contact is a departure of the measured ball track from a short ballistic arc fitted to the measured frames just
# before it (x and y linear in time, z with the track's own fixed curvature). Each departure is then named by where it
# happens: in the rim or board zone, low and falling (floor), or within reach of a player. Interpolated ball frames
# (exact midpoints of their neighbours) are never fitted. Ball positions are in the ball frame of audit.R (offence
# attacking +x, calibrated hoop); they are shifted to the player frame (bundle.R, to_player_frame()) before any
# distance to a player is taken.
# Requires geometry.R, audit.R (ball_track, window_players), bundle.R (to_player_frame).

CONTACT_KINDS <- c("rim", "board", "rim_or_board")

#' The ball track of an episode with time, measured-frame flag at the given midpoint tolerance, and the ball
#' shifted to the player frame.
contact_track <- function(raw, s, from, to, hoop, tol) {
  w <- ball_track(raw$frames, s, from, to)[!is.na(x)]
  mid <- abs(w$x - (shift(w$x) + shift(w$x, -1L)) / 2) < tol & abs(w$z - (shift(w$z) + shift(w$z, -1L)) / 2) < tol &
    shift(w$frame) == w$frame - 1L & shift(w$frame, -1L) == w$frame + 1L
  w[, key := !(mid %in% TRUE)]
  w[, t := (frame - s$f0) / FPS]
  pf <- to_player_frame(w$x - hoop$hx, w$y - hoop$hy, w$z, hoop)
  w[, c("xp", "yp") := .(pf$x, pf$y)]
  w[]
}

#' Ballistic arc through measured positions (x, y linear in t; z with fixed downward acceleration g), evaluated at
#' times `tn`. Needs at least two points; returns a matrix with columns x, y, z.
arc_predict <- function(t, x, y, z, tn, g) {
  X <- cbind(1, t)
  bx <- qr.solve(X, x); by <- qr.solve(X, y); bz <- qr.solve(X, z + 0.5 * g * t^2)
  cbind(x = bx[1] + bx[2] * tn, y = by[1] + by[2] * tn, z = bz[1] + bz[2] * tn - 0.5 * g * tn^2)
}

#' One-step prediction residuals of measured frames from the previous `fit_keys` measured frames, with no resets:
#' used only on free flight to calibrate the break threshold.
one_step_residuals <- function(track, g, fit_keys) {
  k <- track[key == TRUE]
  if (nrow(k) < 4L) return(numeric())
  vapply(4:nrow(k), function(i) {
    idx <- max(1L, i - fit_keys):(i - 1L)
    p <- arc_predict(k$t[idx], k$x[idx], k$y[idx], k$z[idx], k$t[i], g)
    sqrt((p[1] - k$x[i])^2 + (p[2] - k$y[i])^2 + (p[3] - k$z[i])^2)
  }, 0)
}

#' Departures from free flight, greedily: an arc is extended one measured frame at a time while each new frame lies
#' within `break_ft` of its prediction; a frame that does not starts a new arc. The departure frame is the last frame
#' (measured or filled) still within half the threshold of the old arc. A new arc needs three measured frames before
#' it can break again, so a held or rattling ball gives a run of closely spaced breaks.
segment_breaks <- function(track, th, break_ft, start) {
  k <- track[key == TRUE & frame >= start]
  n <- nrow(k)
  out <- list()
  seg <- 1L
  i <- 4L
  while (i <= n) {
    idx <- max(seg, i - th$fit_keys):(i - 1L)
    if (length(idx) < 3L) { i <- i + 1L; next }
    p <- arc_predict(k$t[idx], k$x[idx], k$y[idx], k$z[idx], k$t[i], th$g_track_ft_s2)
    r <- sqrt((p[1] - k$x[i])^2 + (p[2] - k$y[i])^2 + (p[3] - k$z[i])^2)
    if (r > break_ft) {
      between <- track[frame > k$frame[i - 1L] & frame <= k$frame[i]]
      pb <- arc_predict(k$t[idx], k$x[idx], k$y[idx], k$z[idx], between$t, th$g_track_ft_s2)
      rb <- sqrt((pb[, 1] - between$x)^2 + (pb[, 2] - between$y)^2 + (pb[, 3] - between$z)^2)
      first_off <- which(rb > break_ft / 2)[1]
      cf <- if (is.na(first_off) || first_off == 1L) k$frame[i - 1L] else between$frame[first_off - 1L]
      vz_in <- (k$z[i - 1L] - k$z[idx[1]]) / max(1e-9, k$t[i - 1L] - k$t[idx[1]])
      out[[length(out) + 1L]] <- data.table(frame = cf, resid = r, key_before = k$frame[i - 1L],
                                            key_after = k$frame[i], vz_in = vz_in)
      seg <- i
      i <- i + 3L
    } else i <- i + 1L
  }
  rbindlist(out)
}

#' Ball-to-player horizontal distances (player frame) at chosen frames, nearest first, with detection flags.
nearest_players <- function(track, pl, frames) {
  b <- track[frame %in% frames, .(frame, xp, yp, z)]
  j <- merge(pl[frame %in% frames, .(frame, pid, off, px, py, det, err)], b, by = "frame")
  j[, d := sqrt((px - xp)^2 + (py - yp)^2)]
  setorder(j, frame, d)
  j[]
}

#' Name one departure: rim, board, rim_or_board, floor, player (with actor or unknown actor) or unknown.
classify_break <- function(br, track, near, hoop, th) {
  at <- track[frame %in% c(br$frame, br$frame + 1L)]
  dx <- at$x - hoop$hx; dy <- at$y - hoop$hy; dh <- sqrt(dx^2 + dy^2)
  in_rim <- any(dh <= RIM_R + BALL_R + th$rim_pad_ft & at$z >= RIM_Z - th$rim_z_below_ft & at$z <= RIM_Z + th$rim_z_above_ft)
  in_board <- any(dx >= (BOARD_X - RIM_X) - BALL_R - th$board_pad_ft & abs(dy) <= BOARD_HALF_W + th$board_pad_ft &
                    at$z >= BOARD_Z0 - th$board_pad_ft & at$z <= BOARD_Z1 + th$board_pad_ft)
  z <- at$z[1]
  nb <- near[frame == br$frame]
  reach <- nrow(nb) && nb$d[1] <= th$touch_ft && z <= th$reach_max_z_ft
  ambiguous <- reach && nrow(nb) > 1L && nb$d[2] - nb$d[1] < th$actor_margin_ft
  zone <- if (in_rim && in_board) "rim_or_board" else if (in_rim) "rim" else if (in_board) "board" else NA_character_
  kind <- if (!is.na(zone)) {
    # after the first contact, a player standing under the ring within reach and below it makes the cause unclear;
    # episode_contact_states() names the first break in the zone by its zone whoever stands below
    if (reach && nb$d[1] <= 2 && z <= RIM_Z + 1) "unknown" else zone
  } else if (z <= th$floor_z_ft && br$vz_in < 0) "floor"
  else if (reach) "player" else "unknown"
  data.table(frame = br$frame, kind = kind, zone = zone, resid = br$resid, ball_z = z, hoop_dist = dh[1],
             actor_id = if (kind == "player" && !ambiguous) nb$pid[1] else NA_integer_,
             actor_off = if (kind == "player" && !ambiguous) nb$off[1] else NA,
             actor_det = if (kind == "player" && !ambiguous) nb$det[1] else NA_integer_,
             nearest_id = if (nrow(nb)) nb$pid[1] else NA_integer_, nearest_d = if (nrow(nb)) nb$d[1] else NA_real_,
             second_d = if (nrow(nb) > 1L) nb$d[2] else NA_real_,
             key_gap = br$key_after - br$key_before)
}

#' The first run in which one player has the ball: within control_ft (player frame), below control_z, moving with
#' the player (horizontal relative speed and vertical ball speed small) for control_frames frames, one miss allowed.
control_run <- function(track, pl, th, start) {
  b <- track[frame >= start, .(frame, xp, yp, z)]
  if (nrow(b) < th$control_frames) return(NULL)
  b[, c("bvx", "bvy", "bvz") := .((shift(xp, -1L) - shift(xp)) * FPS / 2, (shift(yp, -1L) - shift(yp)) * FPS / 2,
                                  (shift(z, -1L) - shift(z)) * FPS / 2)]
  p <- pl[frame >= start - 1L]
  setorder(p, pid, frame)
  p[, c("pvx", "pvy") := .((shift(px, -1L) - shift(px)) * FPS / 2, (shift(py, -1L) - shift(py)) * FPS / 2), by = pid]
  j <- merge(p[, .(frame, pid, off, px, py, pvx, pvy, det)], b, by = "frame")
  # the ball must not be falling or rising fast where control starts; after that a dribble keeps control
  j[, ok := sqrt((px - xp)^2 + (py - yp)^2) <= th$control_ft & z <= th$control_z_ft &
          sqrt((bvx - pvx)^2 + (bvy - pvy)^2) <= th$control_rel_speed_ft_s]
  j[, calm := abs(bvz) <= th$control_vz_ft_s]
  j[is.na(ok), ok := FALSE]
  j[is.na(calm), calm := FALSE]
  frames <- b$frame
  best <- NULL
  for (id in unique(j[ok == TRUE]$pid)) {
    okf <- frames %in% j[pid == id & ok == TRUE]$frame
    startf <- frames %in% j[pid == id & ok == TRUE & calm == TRUE]$frame
    run <- frollsum(as.integer(okf), th$control_frames, align = "left")
    hit <- which(startf & run >= th$control_frames - 1L)
    if (length(hit) && (is.null(best) || frames[hit[1]] < best$frame))
      best <- list(frame = frames[hit[1]], pid = id, off = j[pid == id]$off[1],
                   det = j[pid == id & frame == frames[hit[1]]]$det[1])
  }
  if (is.null(best)) return(NULL)
  # a second player as close as the controller through the run: a shared ball (tie-up), controller unknown
  run_frames <- frames[frames >= best$frame & frames < best$frame + th$control_frames]
  d <- j[frame %in% run_frames][order(frame, sqrt((px - xp)^2 + (py - yp)^2))]
  d[, dist := sqrt((px - xp)^2 + (py - yp)^2)]
  shared <- d[, .(gap = if (.N > 1L) dist[2] - dist[1] else Inf, second = pid[2]), by = frame]
  best$shared <- mean(shared$gap < th$shared_margin_ft) >= th$shared_share
  best
}

#' Confidence of one labelled moment: measured ball frames close on both sides, a clear departure, and (for a
#' player) a detected, unambiguous actor.
event_confidence <- function(key_gap, resid, break_ft, actor_ok) {
  sharp <- !is.na(resid) && resid >= 2 * break_ft
  tight <- !is.na(key_gap) && key_gap <= 2L
  if (sharp && tight && actor_ok) "high" else if ((sharp || tight) && actor_ok) "medium" else "low"
}

#' All contact states of one missed shot. Returns list(events = one row per labelled moment, summary = one row with
#' the rubric's fields).
episode_contact_states <- function(raw, s, hoop, th, break_ft) {
  last <- s$rf + th$window_after_rebound
  tr <- contact_track(raw, s, s$f0, last, hoop, th$keyframe_tol_ft)
  pl <- window_players(raw, s, unique(c(tr$frame, tr$frame - 1L, tr$frame + 1L)))
  start <- s$f0 + th$skip_after_release
  brs <- segment_breaks(tr, th, break_ft, start)
  near <- nearest_players(tr, pl, if (nrow(brs)) brs$frame else integer())
  cls <- if (nrow(brs)) rbindlist(lapply(seq_len(nrow(brs)), function(i) classify_break(brs[i], tr, near, hoop, th))) else
    data.table(frame = integer(), kind = character(), zone = character(), resid = numeric(), ball_z = numeric(),
               hoop_dist = numeric(), actor_id = integer(), actor_off = logical(), actor_det = integer(),
               nearest_id = integer(), nearest_d = numeric(), second_d = numeric(), key_gap = integer())
  # the first break in the rim or board zone is the first rim or board contact, whoever stands below it
  zi <- which(!is.na(cls$zone))[1]
  if (!is.na(zi)) cls[zi, kind := zone]
  rim_frame <- if (!is.na(zi)) cls$frame[zi] else NA_integer_
  first_rim <- if (!is.na(zi)) cls[zi] else cls[0]
  # blocks: a defender's departure before both the rim contact and the shot's end; other early departures near a
  # player (the shooter's hand, a teammate) are left unexplained
  early <- cls$kind == "player" & cls$frame < min(rim_frame, s$f1, na.rm = TRUE)
  cls[early & !(actor_off %in% FALSE), kind := "unknown"]
  blocks <- cls[kind == "player" & frame < min(rim_frame, s$f1, na.rm = TRUE)]
  # touches, control and out of bounds are looked for after the rim contact, else the block, else endFrame
  after <- fcoalesce(rim_frame, if (nrow(blocks)) blocks$frame[1] else NA_integer_, s$f1)
  oob <- tr[frame > after & (abs(xp) > COURT_HALF_L + BALL_R | abs(yp) > COURT_HALF_W + BALL_R) & z < 3]$frame[1]
  ctl <- control_run(tr, pl, th, after)
  if (!is.null(ctl) && !is.na(oob) && oob < ctl$frame) ctl <- NULL
  end <- min(c(if (!is.null(ctl)) ctl$frame, oob, last), na.rm = TRUE)
  touches <- cls[kind == "player" & frame > after & frame <= end]
  ctl_pid <- if (is.null(ctl) || ctl$shared) NA_integer_ else ctl$pid
  ctl_frame <- if (is.null(ctl)) NA_integer_ else ctl$frame
  touches[, type := fifelse(is.na(actor_id), "UNKNOWN",
                            fifelse(actor_id %in% ctl_pid & ctl_frame - frame <= th$catch_window_frames, "catch", "tip"))]
  inferred <- FALSE
  if (!is.null(ctl) && !nrow(touches[type == "catch"]) &&
      !nrow(touches[frame >= ctl$frame - th$catch_window_frames])) {
    # the ball came to a player without a measurable departure: the catch is placed at the start of control
    z_at <- tr[frame == ctl$frame]$z
    touches <- rbind(touches, data.table(frame = ctl$frame, kind = "player", resid = NA_real_, ball_z = z_at,
                                         actor_id = if (ctl$shared) NA_integer_ else ctl$pid, actor_off = ctl$off,
                                         actor_det = ctl$det, type = "catch", key_gap = NA_integer_), fill = TRUE)
    inferred <- TRUE
  }
  setorder(touches, frame)
  first_touch <- if (nrow(blocks)) blocks[1][, type := "block"] else touches[seq_len(min(1L, .N))]
  tips <- touches[type != "catch"]
  terminal <- if (!is.null(ctl)) (if (ctl$shared) "held_ball" else "control") else if (!is.na(oob)) "out_of_bounds" else "unresolved"
  conf <- function(r) if (is.null(r) || !nrow(r) || is.na(r$frame)) NA_character_ else
    event_confidence(r$key_gap, r$resid, break_ft, if (identical(r$kind, "player")) !is.na(r$actor_id) && r$actor_det %in% 1L else TRUE)
  c_rim <- conf(first_rim); c_touch <- conf(first_touch)
  c_ctl <- if (is.null(ctl)) NA_character_ else if (ctl$shared) "low" else if (ctl$det %in% 1L) "high" else "medium"
  levels <- c("low", "medium", "high")
  label_conf <- if (terminal == "unresolved") "low" else
    levels[min(match(na.omit(c(c_rim, c_touch, c_ctl)), levels), 3L)]
  zat <- function(f) if (is.na(f)) NA_real_ else tr[frame == f]$z[1]
  summary <- data.table(
    episode_id = s$shot_id, game_id = s$game_id, break_ft = break_ft, n_breaks = nrow(cls),
    first_rim_or_board_frame = rim_frame,
    contact_kind = if (is.na(rim_frame)) (if (nrow(cls[kind == "unknown" & frame < s$f1 + 10L])) "UNKNOWN" else "none") else first_rim$kind,
    first_player_contact_frame = if (nrow(first_touch)) first_touch$frame else NA_integer_,
    first_contact_player_id = if (nrow(first_touch)) first_touch$actor_id else NA_integer_,
    first_contact_type = if (nrow(first_touch)) first_touch$type else "none",
    first_touch_inferred = inferred && nrow(first_touch) && first_touch$frame == ctl$frame,
    tip_frames_and_players = paste(sprintf("%d:%s", tips$frame, fifelse(is.na(tips$actor_id), "?", as.character(tips$actor_id))),
                                   collapse = ";"),
    n_tips = nrow(tips),
    first_control_frame = if (!is.null(ctl)) ctl$frame else NA_integer_,
    controller_id = if (!is.null(ctl) && !ctl$shared) ctl$pid else NA_integer_,
    controller_off = if (!is.null(ctl)) ctl$off else NA,
    out_of_bounds_frame = oob, terminal = terminal,
    ball_center_z_at_first_touch = zat(if (nrow(first_touch)) first_touch$frame else NA_integer_),
    ball_center_z_at_control = zat(if (!is.null(ctl)) ctl$frame else NA_integer_),
    first_touch_actor_detected = if (nrow(first_touch)) first_touch$actor_det else NA_integer_,
    controller_detected = if (!is.null(ctl)) ctl$det else NA_integer_,
    rim_confidence = c_rim, touch_confidence = c_touch, control_confidence = c_ctl, label_confidence = label_conf,
    n_unknown_breaks = nrow(cls[kind == "unknown" & frame <= end]))
  ev <- rbind(
    data.table(frame = s$f0, kind = "released", actor_id = s$pid, confidence = "high"),
    if (nrow(cls)) cls[frame <= end, .(frame, kind = fifelse(kind == "player", "player_touch", kind), actor_id,
                                       confidence = vapply(seq_len(.N), function(i) conf(.SD[i]), ""))],
    if (nrow(blocks)) blocks[1, .(frame, kind = "block", actor_id, confidence = c_touch)],
    if (nrow(tips)) tips[, .(frame, kind = "tip", actor_id, confidence = vapply(seq_len(.N), function(i) conf(.SD[i]), ""))],
    if (!is.null(ctl)) data.table(frame = ctl$frame, kind = "controlled", actor_id = if (ctl$shared) NA_integer_ else ctl$pid,
                                  confidence = c_ctl),
    if (!is.na(oob)) data.table(frame = oob, kind = "out_of_bounds", actor_id = NA_integer_, confidence = "medium"),
    data.table(frame = s$rf, kind = "credited_rebound", actor_id = s$rpid, confidence = "official"),
    fill = TRUE)
  ev[, ball_z_ft := tr$z[match(frame, tr$frame)]]
  ev[, c("episode_id", "game_id") := .(s$shot_id, s$game_id)]
  setorder(ev, frame)
  list(events = ev, summary = summary)
}

#' Problems with the time order of one episode's labels (empty when the order is right): rim/board contact after
#' release, touches after the rim, control after the first touch, nothing labelled after the terminal state.
sequence_problems <- function(sm, f0) {
  p <- character()
  if (!is.na(sm$first_rim_or_board_frame) && sm$first_rim_or_board_frame <= f0) p <- c(p, "rim_not_after_release")
  if (!is.na(sm$first_player_contact_frame) && sm$first_player_contact_frame <= f0) p <- c(p, "touch_not_after_release")
  if (!is.na(sm$first_player_contact_frame) && !is.na(sm$first_rim_or_board_frame) &&
      sm$first_contact_type != "block" && sm$first_player_contact_frame < sm$first_rim_or_board_frame)
    p <- c(p, "touch_before_rim_not_block")
  if (!is.na(sm$first_control_frame) && !is.na(sm$first_player_contact_frame) &&
      sm$first_control_frame < sm$first_player_contact_frame) p <- c(p, "control_before_first_touch")
  if (!is.na(sm$first_control_frame) && !is.na(sm$out_of_bounds_frame) && sm$out_of_bounds_frame < sm$first_control_frame)
    p <- c(p, "control_after_out_of_bounds")
  p
}
