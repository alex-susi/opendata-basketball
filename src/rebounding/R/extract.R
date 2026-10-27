# Rebound episodes and the raw tracking around them.
#
# One episode per shot record (made, missed, fouled or not) with its rebound rows, so the audit can count
# every class. Tracking is read straight from the delivered JSON Lines, each line matched on its frameIdx
# (every file skips some indices), so that isDetected, predError and speed survive for the ball and every
# player; the play viewer's cache drops them.
# Coordinates stay in the camera frame here; rotate with `flip` (possessions.leftHoop) when used.
# Requires src/play_viewer/R/data.R (match_file, record helpers, canon_id).

WINDOW_BEFORE <- 25L     # frames kept before a release (1 s)
WINDOW_AFTER <- 50L      # frames kept after the later of the shot's end and its rebound (2 s)
WINDOW_MAX <- 300L       # never more than 12 s after a release
MADE_AFTER <- 15L        # frames kept after a made shot's end frame

#' Every shot of one game with its context and the field-goal rebound rows that point to it.
#' @return list(shots, rebounds, players = canonical on-court participants of the game).
game_episodes <- function(root, g, aliases) {
  ev <- read_json_file(match_file(root, g, "_dynamic_events.json"))
  poss <- data.table(poss_id = chr_field(ev$possessions, "id"), left_hoop = lgl_field(ev$possessions, "leftHoop"))
  sh <- data.table(game_id = g, shot_id = chr_field(ev$shots, "id"), chance_id = chr_field(ev$shots, "chanceId"),
                   poss_id = chr_field(ev$shots, "possessionId"), touch_id = chr_field(ev$shots, "touchId"),
                   period = int_field(ev$shots, "period"),
                   f0 = int_field(ev$shots, "startFrame"), f1 = int_field(ev$shots, "endFrame"),
                   pid = int_field(ev$shots, "shooterId"), off_team = int_field(ev$shots, "offTeamId"),
                   def_team = int_field(ev$shots, "defTeamId"),
                   made = lgl_field(ev$shots, "outcome"), fouled = lgl_field(ev$shots, "fouled"),
                   three = lgl_field(ev$shots, "three"), blocked = lgl_field(ev$shots, "blocked"),
                   blocker = int_field(ev$shots, "blockerId"), dist_ev = num_field(ev$shots, "distance"),
                   shot_type = chr_field(ev$shots, "shotType"), cst = chr_field(ev$shots, "complexShotType"),
                   sx_cam = vapply(ev$shots, function(r) as.numeric(r$location[[1]] %||% NA), 0),
                   sy_cam = vapply(ev$shots, function(r) as.numeric(r$location[[2]] %||% NA), 0))
  sh <- merge(sh, poss, by = "poss_id", all.x = TRUE, sort = FALSE)
  sh[, flip := fifelse(left_hoop %in% TRUE, -1, 1)]
  rb <- data.table(game_id = g, reb_id = chr_field(ev$rebounds, "id"), shot_id = chr_field(ev$rebounds, "shotId"),
                   rf = int_field(ev$rebounds, "frame"), fg = lgl_field(ev$rebounds, "fgReb"),
                   grabbed = lgl_field(ev$rebounds, "rebounded"), defensive = lgl_field(ev$rebounds, "defensive"),
                   rpid = int_field(ev$rebounds, "rebounderId"), rteam = int_field(ev$rebounds, "teamId"),
                   next_chance = chr_field(ev$rebounds, "nextChanceId"),
                   rx_cam = vapply(ev$rebounds, function(r) as.numeric(r$location[[1]] %||% NA), 0),
                   ry_cam = vapply(ev$rebounds, function(r) as.numeric(r$location[[2]] %||% NA), 0))
  cp <- data.table(chance_id = chr_field(ev$chance_players, "chanceId"), pid = int_field(ev$chance_players, "playerId"),
                   offense = lgl_field(ev$chance_players, "offense"))
  ch <- data.table(chance_id = chr_field(ev$chances, "id"), usable = lgl_field(ev$chances, "usable"),
                   quality = int_field(ev$chances, "qualityIndex"), transition = lgl_field(ev$chances, "transition"))
  sh <- merge(sh, ch, by = "chance_id", all.x = TRUE, sort = FALSE)
  sh[, canon := canon_id(pid, aliases)]
  rb[, rcanon := canon_id(rpid, aliases)]
  list(shots = sh, rebounds = rb, chance_players = cp[, game_id := g][, canon := canon_id(pid, aliases)])
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' The frames each shot needs: from a second before release until two seconds after the later of the shot's
#' end and its rebound (capped), or a little past the end of a made shot.
window_frames <- function(shots, rebounds) {
  last_rb <- rebounds[fg == TRUE & !is.na(shot_id), .(rf = max(rf, na.rm = TRUE)), by = shot_id]
  w <- merge(shots[, .(shot_id, f0, f1, made)], last_rb, by = "shot_id", all.x = TRUE)
  w <- w[!is.na(f0) & !is.na(f1)]
  w[, to := fifelse(made, f1 + MADE_AFTER, pmin(f0 + WINDOW_MAX, pmax(f1, rf, na.rm = TRUE) + WINDOW_AFTER))]
  sort(unique(unlist(Map(function(a, b) seq(a - WINDOW_BEFORE, b), w$f0, w$to))))
}

#' Ball and player rows of chosen frames, read from the raw tracking file with every quality field.
#' @return list(frames = data.table(frame, period, gc, sc, stopped, bx, by, bz, bdet, berr, bspeed),
#'              players = data.table(frame, pid, home, x, y, det, err, speed)).
read_frames <- function(root, g, frames, chunk = 5000L) {
  lines <- readLines(tracking_source(root, g), warn = FALSE)
  # Files skip some frame indices, so a line is found by the frameIdx it starts with, not by its position.
  idx <- as.integer(sub('^\\{"frameIdx": ([0-9]+),.*$', "\\1", substr(lines, 1L, 32L)))
  if (anyNA(idx) || is.unsorted(idx, strictly = TRUE)) stop("Unreadable or unordered frameIdx in game ", g)
  attr(frames, "missing") <- sum(!frames %in% idx)
  lines <- lines[match(frames[frames %in% idx], idx)]
  index_gaps <- data.table(game_id = g, lines = length(idx), last_frame = max(idx),
                           missing_indices = max(idx) + 1L - length(idx), longest_gap = max(diff(idx)) - 1L)
  out <- lapply(split(seq_along(lines), ceiling(seq_along(lines) / chunk)), function(idx) {
    fr <- jsonlite::fromJSON(paste0("[", paste(lines[idx], collapse = ","), "]"), simplifyVector = FALSE)
    ball <- lapply(fr, `[[`, "ball")
    has <- lengths(lapply(ball, `[[`, "xyz")) == 3L
    bxyz <- function(k) vapply(seq_along(ball), function(i) if (has[i]) as.numeric(ball[[i]]$xyz[[k]]) else NA_real_, 0)
    bnum <- function(f) vapply(seq_along(ball), function(i) if (has[i]) as.numeric(ball[[i]][[f]] %||% NA) else NA_real_, 0)
    frames <- data.table(frame = int_field(fr, "frameIdx"), period = int_field(fr, "period"),
                         gc = num_field(fr, "gameClock"), sc = num_field(fr, "shotClock"),
                         stopped = lgl_field(fr, "gameClockStopped"),
                         bx = bxyz(1L), by = bxyz(2L), bz = bxyz(3L),
                         bdet = bnum("isDetected"), berr = bnum("predError"), bspeed = bnum("speed"))
    side <- function(key, home) {
      per <- lapply(fr, `[[`, key)
      pl <- unlist(per, recursive = FALSE)
      if (!length(pl)) return(NULL)
      xyz <- lapply(pl, `[[`, "xyz")
      data.table(frame = rep(int_field(fr, "frameIdx"), lengths(per)), pid = int_field(pl, "playerId"), home = home,
                 x = vapply(xyz, function(v) as.numeric(v[[1]]), 0), y = vapply(xyz, function(v) as.numeric(v[[2]]), 0),
                 det = int_field(pl, "isDetected"), err = num_field(pl, "predError"), speed = num_field(pl, "speed"))
    }
    list(frames = frames, players = rbind(side("homePlayers", TRUE), side("awayPlayers", FALSE)))
  })
  frames <- rbindlist(lapply(out, `[[`, "frames"))
  if (is.unsorted(frames$frame, strictly = TRUE)) stop("Frames out of order in game ", g)
  list(frames = frames, players = rbindlist(lapply(out, `[[`, "players")), index_gaps = index_gaps)
}

#' Episodes and tracking windows for one game, cached in outputs/cache/rebounding/raw_{g}.rds.
game_raw <- function(root, g, aliases, cache, force = FALSE) {
  path <- file.path(cache, sprintf("raw_%s.rds", g))
  if (file.exists(path) && !force) return(readRDS(path))
  ep <- game_episodes(root, g, aliases)
  need <- window_frames(ep$shots, ep$rebounds)
  trk <- read_frames(root, g, need)
  out <- c(ep, trk)
  saveRDS(out, path)
  out
}
