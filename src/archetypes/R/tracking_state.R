# Tracking state helpers used by the archetype features (src/archetypes/R/tracked.R).
# Copied on 2026-11-06 from the EPV feature layer (now zz_Archive/src/epv/R/features.R) when the EPV model was
# archived, so the archetypes no longer depend on it. Only what tracked.R uses is kept; the definitions are unchanged.
# Requires src/play_viewer/R/data.R (tracking cache, play index).

# Court geometry in feet (FIBA metres converted).
FT_PER_M <- 3.28084
HALF_L <- 14 * FT_PER_M
HALF_W <- 7.5 * FT_PER_M
HOOP_X <- (14 - 1.575) * FT_PER_M
THREE_R <- 6.75 * FT_PER_M
THREE_Y <- 6.6 * FT_PER_M

GRID_STEP <- 3L          # sample every third frame (about 8 Hz)
VEL_LAG <- 6L            # backward difference over 0.24 s: no look-ahead
MAX_SPEED <- 30          # ft/s, clips tracking jumps

pick <- function(m, col) m[cbind(seq_len(nrow(m)), col)]

#' Backward-difference velocities for every tracked player, clipped to MAX_SPEED.
add_velocity <- function(players) {
  setkey(players, pid, frame)
  players[, c("vx", "vy") := {
    ok <- !is.na(shift(frame, VEL_LAG)) & frame - shift(frame, VEL_LAG) == VEL_LAG
    .(fifelse(ok, (x - shift(x, VEL_LAG)) * 25 / VEL_LAG, 0), fifelse(ok, (y - shift(y, VEL_LAG)) * 25 / VEL_LAG, 0))
  }, by = pid]
  players[, slow := pmin(1, MAX_SPEED / pmax(sqrt(vx^2 + vy^2), 1e-6))]
  players[, c("vx", "vy", "slow") := .(vx * slow, vy * slow, NULL)]
}

#' Both teams' positions and velocities on a set of frames of one game, as row-per-frame matrices.
#' @param g Game id.
#' @param extra_frames Frames to include besides the pricing grid (shot and pass releases).
#' @return list(fr = frame table, off = list of n x 5 matrices, def = same, plays = that game's possessions).
game_state <- function(app, g, extra_frames = integer(0)) {
  trk <- readRDS(tracking_cache_path(app$root, g))
  plays <- app$plays[game_id == g][order(start_frame)]
  # Grid frames inside a possession, with velocities, flipped so that the offense attacks toward +x.
  fr <- trk$frames[frame %% GRID_STEP == 0L | frame %in% extra_frames]
  fr[, play := findInterval(frame, plays$start_frame)]
  fr <- fr[play > 0L][frame <= plays$end_frame[play]]
  pl <- add_velocity(copy(trk$players))[frame %in% fr$frame]
  pl[, play := fr$play[match(frame, fr$frame)]]
  pl[, flip := fifelse(plays$left_hoop[play], -1, 1)]
  pl[, role := fifelse(home == (plays$off_team[play] == plays$home_team[play]), 1L, 2L)]
  for (col in c("x", "y", "vx", "vy")) set(pl, j = col, value = pl[[col]] * pl$flip)
  # Keep frames with exactly five players per side, then split them into per-team matrices.
  five <- pl[, .(n_off = sum(role == 1L), n_def = sum(role == 2L)), by = frame][n_off == 5L & n_def == 5L, frame]
  fr <- fr[frame %in% five]
  pl <- pl[frame %in% five]
  setorder(pl, frame, role, pid)
  team <- function(r) {
    rows <- which(pl$role == r)
    lapply(c(x = "x", y = "y", vx = "vx", vy = "vy", pid = "pid", det = "det"),
           function(col) matrix(pl[[col]][rows], ncol = 5L, byrow = TRUE))
  }
  # Ball position in the same frame; a missing shot clock falls back to the game clock (at most 24 s).
  fr[, flip := fifelse(plays$left_hoop[play], -1, 1)]
  fr[, c("bx", "by", "poss_id", "game_id") := .(bx * flip, by * flip, plays$id[play], g)]
  fr[, sc := fifelse(is.na(sc), pmin(gc, 24), sc)]
  list(fr = fr, off = team(1L), def = team(2L), plays = plays)
}

