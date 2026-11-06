# One bundle per eligible missed shot: the ball track in the hoop-relative ball frame, the ten players in
# the player frame, and the episode's labels. Every later stage reads these bundles.
#
# Two frames are used because the reconstructed ball and the players do not share a ground plane at height:
# made shots cross rim height about 1.1 to 1.6 ft short of the nominal hoop at the camera's right end and
# 0.6 to 1.1 ft past it at the left end (audit/hoop_calibration.csv), while a held ball sits within about a
# foot of its holder. Ball physics therefore runs relative to each game end's calibrated hoop; positions are
# mapped to the player frame with a shift that grows from nothing at chest height to the full hoop offset at
# rim height (to_player_frame()).
# Requires geometry.R, audit.R (ball_track, rot), extract.R.

VEL_FRAMES <- 6L          # causal backward difference for player velocity (0.24 s), as in src/epv
PLAYER_SPEED_CAP <- 30    # ft/s
SHIFT_Z0 <- 4             # ft: below this height the ball needs no shift to the player frame
SHIFT_Z1 <- 10            # ft: at and above this height it gets the full hoop offset

#' Map hoop-relative ball positions to the player frame (offense attacking +x, nominal hoop at RIM_X).
#' @param hoop list(hx, hy): the calibrated ball-frame hoop centre of this game end.
to_player_frame <- function(x, y, z, hoop) {
  w <- pmin(1, pmax(0, (z - SHIFT_Z0) / (SHIFT_Z1 - SHIFT_Z0)))
  list(x = x + hoop$hx + w * (RIM_X - hoop$hx), y = y + hoop$hy + w * (0 - hoop$hy))
}

#' Players of a window with causal velocities (backward difference over VEL_FRAMES, capped).
player_tracks <- function(raw, s, from, to) {
  pl <- raw$players[frame >= from - VEL_FRAMES & frame <= to]
  home_off <- raw$home_team == s$off_team
  pl[, c("px", "py", "off") := .(rot(x, s$flip), rot(y, s$flip), home == home_off)]
  setorder(pl, pid, frame)
  pl[, c("vx", "vy") := {
    ok <- shift(frame, VEL_FRAMES) == frame - VEL_FRAMES
    .(fifelse(ok %in% TRUE, (px - shift(px, VEL_FRAMES)) * FPS / VEL_FRAMES, 0),
      fifelse(ok %in% TRUE, (py - shift(py, VEL_FRAMES)) * FPS / VEL_FRAMES, 0))
  }, by = pid]
  pl[, sp := sqrt(vx^2 + vy^2)]
  pl[sp > PLAYER_SPEED_CAP, c("vx", "vy") := .(vx * PLAYER_SPEED_CAP / sp, vy * PLAYER_SPEED_CAP / sp)]
  pl[frame >= from, .(frame, pid, off, x = px, y = py, vx, vy, det, err)]
}

#' Bundles for every eligible episode of one game.
game_bundles <- function(raw, ep, hoops, aliases) {
  el <- ep[game_id == raw$shots$game_id[1] & status == "eligible"]
  lapply(seq_len(nrow(el)), function(k) {
    s <- el[k]
    h <- hoops[game_id == s$game_id & left_hoop == s$left_hoop]
    hoop <- list(hx = h$hx, hy = h$hy)
    to <- min(s$f0 + WINDOW_MAX, max(s$rf, s$f1) + WINDOW_AFTER)
    b <- ball_track(raw$frames, s, s$f0 - 5L, to)[!is.na(x)]
    ball <- b[, .(frame, t = (frame - s$f0) / FPS, x = x - hoop$hx, y = y - hoop$hy, z, key = !(interp %in% TRUE),
                  err = berr)]
    pl <- player_tracks(raw, s, s$f0 - 25L, to)
    pl[, canon := canon_id(pid, aliases)]
    list(id = s$shot_id, game_id = s$game_id, shot = s, hoop = hoop, ball = ball, players = pl)
  })
}
