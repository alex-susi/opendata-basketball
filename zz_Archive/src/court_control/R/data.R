# Tables for the court control model: missed shots with the rebound that followed, and live frames for
# the relevance (where the ball goes next) model.
#
# Everything is rotated so the offense attacks the hoop at +x, as in src/epv/ and the play viewer.
# Requires src/play_viewer/R/data.R and src/epv/R/features.R (game_state(), HOOP_X, HALF_L, HALF_W).

FLIGHT_STEP <- 5L        # frames between in-flight samples of a missed shot (0.2 s)
RELEVANCE_STEP <- 12L    # frames between relevance samples (about 2 Hz)
RELEVANCE_AHEAD <- 36L   # frames ahead at which the ball's position is the relevance target (1.44 s; game_state() keeps every third frame)

#' Missed field goals of one game with the rebound that followed. Fouled misses are left out: they are
#' free-throw trips with no live rebound.
#' @return data.table(shot_id, pid, f0, f1, three, blocked, rf, grabbed, oreb, rpid).
missed_shots <- function(root, g) {
  ev <- read_json_file(match_file(root, g, "_dynamic_events.json"))
  sh <- data.table(shot_id = chr_field(ev$shots, "id"), pid = int_field(ev$shots, "shooterId"),
                   f0 = int_field(ev$shots, "startFrame"), f1 = int_field(ev$shots, "endFrame"),
                   made = lgl_field(ev$shots, "outcome"), fouled = lgl_field(ev$shots, "fouled"),
                   three = lgl_field(ev$shots, "three"), blocked = lgl_field(ev$shots, "blocked"))
  rb <- data.table(shot_id = chr_field(ev$rebounds, "shotId"), rf = int_field(ev$rebounds, "frame"),
                   fg = lgl_field(ev$rebounds, "fgReb"), grabbed = lgl_field(ev$rebounds, "rebounded"),
                   oreb = !lgl_field(ev$rebounds, "defensive"), rpid = int_field(ev$rebounds, "rebounderId"))
  rb <- unique(rb[fg == TRUE & !is.na(shot_id)], by = "shot_id")
  merge(sh[made == FALSE & fouled == FALSE, !c("made", "fouled")], rb[, !"fg"], by = "shot_id")
}

#' Offense and defense on given rows of a game state as n x 10 matrices (offense in columns 1 to 5).
ten <- function(S, rows) {
  both <- function(col) cbind(S$off[[col]][rows, , drop = FALSE], S$def[[col]][rows, , drop = FALSE])
  list(x = both("x"), y = both("y"), vx = both("vx"), vy = both("vy"), pid = both("pid"))
}

#' Missed shots of one game, sampled at release and every FLIGHT_STEP frames until the ball reaches the
#' rim, with all ten players' positions and velocities on each sample and where the rebound was taken.
#' @return list(shots = one row per shot, samples = one row per sample, P = player matrices of the samples).
rebound_table <- function(app, g) {
  sh <- missed_shots(app$root, g)
  sh <- sh[!is.na(f0) & !is.na(f1) & f1 > f0 & f1 - f0 <= 50L]
  wanted <- sh[, .(frame = seq(f0, f1, by = FLIGHT_STEP)), by = shot_id]
  S <- game_state(app, g, extra_frames = unique(c(wanted$frame, sh$f0)))
  fr <- S$fr[, .(frame, row = .I, flip, poss_id)]
  rel <- fr[.(sh$f0), on = "frame"]
  sh[, c("row0", "flip") := .(rel$row, rel$flip)]
  sh <- sh[!is.na(row0)]
  # where the shot was taken from: the shooter's position at release
  hit <- S$off$pid[sh$row0, , drop = FALSE] == sh$pid
  sh <- sh[rowSums(hit) == 1L]
  hit <- S$off$pid[sh$row0, , drop = FALSE] == sh$pid
  slot <- max.col(hit, ties.method = "first")
  sh[, c("sx", "sy") := .(pick(S$off$x[row0, , drop = FALSE], slot), pick(S$off$y[row0, , drop = FALSE], slot))]
  sh[, dist := sqrt((HOOP_X - sx)^2 + sy^2)]
  # where the rebound was taken: the rebounder's tracked position at the rebound frame
  trk <- readRDS(tracking_cache_path(app$root, g))$players
  at <- trk[.(sh$rf, sh$rpid), on = .(frame, pid), .(x, y)]
  sh[, c("rx", "ry") := .(at$x * flip, at$y * flip)]
  sh[grabbed == FALSE | is.na(rx), c("rx", "ry") := NA_real_]

  smp <- merge(wanted, sh[, .(shot_id, f0)], by = "shot_id")
  smp <- smp[frame %in% fr$frame & frame %in% S$fr$frame]
  smp[, row := fr$row[match(frame, fr$frame)]]
  smp <- smp[S$fr$poss_id[row] == S$fr$poss_id[sh$row0[match(shot_id, sh$shot_id)]]]
  smp[, elapsed := (frame - f0) / 25]
  setorder(smp, shot_id, frame)
  P <- ten(S, smp$row)
  tag <- function(dt) dt[, game_id := g]
  list(shots = tag(sh[, .(shot_id, pid, f0, f1, rf, three, blocked, grabbed, oreb, rpid, sx, sy, dist, rx, ry)]),
       samples = tag(smp[, .(shot_id, frame, elapsed)]), P = P)
}

#' Live half-court and transition frames with a ball holder, every RELEVANCE_STEP frames, with where the
#' ball is RELEVANCE_AHEAD frames later. Frames whose target falls outside the possession or on a dead
#' ball are dropped.
#' @return list(rows = data.table(game_id, poss_id, frame, bx, by, tx, ty), P = player matrices).
relevance_table <- function(app, g) {
  S <- game_state(app, g)
  touches <- app$touches[game_id == g]
  ev <- read_json_file(match_file(app$root, g, "_dynamic_events.json"))
  S <- add_holder(S, touches, sort(int_field(ev$dribbles, "frame")))
  fr <- S$fr[, .(frame, row = .I, poss_id, bx, by, stopped, slot, in_air)]
  ahead <- fr[, .(frame = frame - RELEVANCE_AHEAD, tx = bx, ty = by, tposs = poss_id, tstop = stopped)]
  fr <- merge(fr, ahead, by = "frame")
  fr <- fr[frame %% RELEVANCE_STEP == 0L & !stopped & !tstop & tposs == poss_id & !is.na(slot) & !in_air &
             !is.na(bx) & !is.na(tx)]
  setorder(fr, frame)
  list(rows = fr[, .(game_id = g, poss_id, frame, bx, by, tx, ty)], P = ten(S, fr$row))
}

#' Live passes of one game at their release: all ten players, the ball, and where and by which team the
#' ball was next controlled (the receiver's spot when he caught it, or the interceptor's when he took it).
#' Inbounds passes, passes to oneself and passes longer than two seconds in the air are left out.
#' @return list(rows = data.table(game_id, frame, bx, by, tx, ty, len, intercepted), P = player matrices).
pass_table <- function(app, g) {
  ev <- read_json_file(match_file(app$root, g, "_dynamic_events.json"))
  pa <- data.table(frame = int_field(ev$passes, "startFrame"), end_frame = int_field(ev$passes, "endFrame"),
                   passer = int_field(ev$passes, "passerId"), receiver = int_field(ev$passes, "receiverId"),
                   thief = int_field(ev$passes, "toReceiverId"), turnover = lgl_field(ev$passes, "turnover"),
                   inbounds = lgl_field(ev$passes, "inbounds"))
  pa <- pa[!inbounds & end_frame > frame & end_frame - frame <= 50L &
             ((turnover & !is.na(thief)) | (!turnover & !is.na(receiver) & receiver != passer))]
  pa[, taker := fifelse(turnover, thief, receiver)]
  S <- game_state(app, g, extra_frames = pa$frame)
  fr <- S$fr[, .(frame, row = .I, flip, bx, by)]
  pa <- merge(pa, fr, by = "frame")
  pa <- pa[!is.na(bx)]
  trk <- readRDS(tracking_cache_path(app$root, g))$players
  at <- trk[.(pa$end_frame, pa$taker), on = .(frame, pid), .(x, y)]
  pa[, c("tx", "ty") := .(at$x * flip, at$y * flip)]
  pa <- pa[!is.na(tx)]
  setorder(pa, frame)
  list(rows = pa[, .(game_id = g, frame, bx, by, tx, ty, len = sqrt((tx - bx)^2 + (ty - by)^2), intercepted = turnover)],
       P = ten(S, pa$row))
}
