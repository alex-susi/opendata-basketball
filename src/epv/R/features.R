# Feature layer for the expected possession value (EPV) model.
#
# Everything here is computed from tracking positions at or before the frame being priced, in feet,
# rotated so the offense attacks the hoop at +x. The same functions build features for real events
# (shots, passes) and for hypothetical ones (any player shooting now, any pass the holder could throw),
# so the component models are trained and applied on identical definitions.
# Requires src/play_viewer/R/data.R (tracking cache, play index, record helpers).

FT_PER_M <- 3.28084
HALF_L <- 14 * FT_PER_M
HALF_W <- 7.5 * FT_PER_M
HOOP_X <- (14 - 1.575) * FT_PER_M
THREE_R <- 6.75 * FT_PER_M
THREE_Y <- 6.6 * FT_PER_M

GRID_STEP <- 3L          # price every third frame (about 8 Hz)
TRAIN_STEP <- 6L         # state models train on every sixth frame
VEL_LAG <- 6L            # backward difference over 0.24 s: no look-ahead
MAX_SPEED <- 30          # ft/s, clips tracking jumps
AIR_FRAMES <- 38L        # the last toucher stays "holder" for 1.5 s after the touch ends
HAZARD_FRAMES <- 50L     # turnover horizon: 2 seconds
RIM_RADIUS <- 10         # ft, rebounding area around the hoop
LANE_SPEED <- 12         # ft/s a defender is credited with when jumping a passing lane
LEAD_CAP <- 0.6          # seconds of constant-velocity projection allowed
LANE_MIN_S <- 0.1        # defenders this close to the passer count as ball pressure, not lane threats

CONTEXT_COLS <- c("dist", "angle", "three", "x", "ay", "def1", "def2", "n6", "between", "rim_def", "closing",
                  "speed", "bound", "off_rim", "def_rim", "ahead", "def_spread")

# ---- small matrix helpers ------------------------------------------------------------------------

row_min <- function(m) do.call(pmin, lapply(seq_len(ncol(m)), function(j) m[, j]))
row_max <- function(m) do.call(pmax, lapply(seq_len(ncol(m)), function(j) m[, j]))
pick <- function(m, col) m[cbind(seq_len(nrow(m)), col)]

#' Second smallest value in each row.
row_min2 <- function(m) {
  m[cbind(seq_len(nrow(m)), max.col(-m, ties.method = "first"))] <- Inf
  row_min(m)
}

# ---- state -----------------------------------------------------------------------------------------

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
  fr <- trk$frames[frame %% GRID_STEP == 0L | frame %in% extra_frames]
  fr[, play := findInterval(frame, plays$start_frame)]
  fr <- fr[play > 0L][frame <= plays$end_frame[play]]
  pl <- add_velocity(copy(trk$players))[frame %in% fr$frame]
  pl[, play := fr$play[match(frame, fr$frame)]]
  pl[, flip := fifelse(plays$left_hoop[play], -1, 1)]
  pl[, role := fifelse(home == (plays$off_team[play] == plays$home_team[play]), 1L, 2L)]
  for (col in c("x", "y", "vx", "vy")) set(pl, j = col, value = pl[[col]] * pl$flip)
  five <- pl[, .(n_off = sum(role == 1L), n_def = sum(role == 2L)), by = frame][n_off == 5L & n_def == 5L, frame]
  fr <- fr[frame %in% five]
  pl <- pl[frame %in% five]
  setorder(pl, frame, role, pid)
  team <- function(r) {
    rows <- which(pl$role == r)
    lapply(c(x = "x", y = "y", vx = "vx", vy = "vy", pid = "pid", det = "det"),
           function(col) matrix(pl[[col]][rows], ncol = 5L, byrow = TRUE))
  }
  fr[, flip := fifelse(plays$left_hoop[play], -1, 1)]
  fr[, c("bx", "by", "poss_id", "game_id") := .(bx * flip, by * flip, plays$id[play], g)]
  fr[, sc := fifelse(is.na(sc), pmin(gc, 24), sc)]
  list(fr = fr, off = team(1L), def = team(2L), plays = plays)
}

#' Who has the ball on each row: the offensive player of the current or just-ended touch.
#' Adds slot (column in the offense matrices), holder id, seconds held, dribbles so far and ball-in-air flag.
add_holder <- function(S, touches, dribble_frames) {
  tl <- touches[order(f0)]
  i <- pmax(findInterval(S$fr$frame, tl$f0), 1L)
  hit <- S$off$pid == tl$pid[i]
  valid <- S$fr$frame >= tl$f0[i] & rowSums(hit) == 1L & S$fr$frame - tl$f1[i] <= AIR_FRAMES
  S$fr[, slot := fifelse(valid, max.col(hit, ties.method = "first"), NA_integer_)]
  S$fr[, holder := fifelse(valid, tl$pid[i], NA_integer_)]
  S$fr[, held := fifelse(valid, (frame - tl$f0[i]) / 25, NA_real_)]
  S$fr[, in_air := valid & frame > tl$f1[i]]
  S$fr[, touch_start := fifelse(valid, tl$f0[i], NA_integer_)]
  S$fr[, drib := fifelse(valid, findInterval(frame, dribble_frames) - findInterval(tl$f0[i] - 1L, dribble_frames), NA_integer_)]
  S
}

# ---- features ------------------------------------------------------------------------------------

#' Court and defensive context of one offensive player per row.
#' @param px,py,pvx,pvy Position and velocity vectors (one element per row).
#' @param D Defender matrices (x, y, vx, vy), possibly projected forward.
#' @param off_x,off_y Offense position matrices, for counting bodies near the rim.
#' @return data.table with CONTEXT_COLS.
player_context <- function(px, py, pvx, pvy, D, off_x, off_y) {
  dx <- D$x - px
  dy <- D$y - py
  gap <- sqrt(dx^2 + dy^2)
  near <- max.col(-gap, ties.method = "first")
  hoop <- pmax(sqrt((HOOP_X - px)^2 + py^2), 0.1)
  ux <- (HOOP_X - px) / hoop
  uy <- -py / hoop
  along <- dx * ux + dy * uy
  beside <- abs(dx * uy - dy * ux)
  def_hoop <- sqrt((D$x - HOOP_X)^2 + D$y^2)
  off_hoop <- sqrt((off_x - HOOP_X)^2 + off_y^2)
  data.table(dist = hoop, angle = abs(atan2(py, HOOP_X - px)), three = as.integer(hoop > THREE_R | abs(py) > THREE_Y),
             x = px, ay = abs(py), def1 = row_min(gap), def2 = row_min2(gap), n6 = rowSums(gap < 6),
             between = rowSums(along > 0 & along < hoop & beside < 3), rim_def = row_min(def_hoop),
             closing = -pick((dx * (D$vx - pvx) + dy * (D$vy - pvy)) / pmax(gap, 0.1), near),
             speed = sqrt(pvx^2 + pvy^2), bound = pmin(HALF_W - abs(py), HALF_L - abs(px)),
             off_rim = rowSums(off_hoop < RIM_RADIUS) - (hoop < RIM_RADIUS), def_rim = rowSums(def_hoop < RIM_RADIUS),
             ahead = rowSums(def_hoop < hoop), def_spread = rowMeans(def_hoop))
}

#' Defenders moved along their current velocity for `lead` seconds (capped).
project_defense <- function(D, lead) {
  lead <- pmin(lead, LEAD_CAP)
  list(x = D$x + D$vx * lead, y = D$y + D$vy * lead, vx = D$vx, vy = D$vy)
}

#' Geometry of a pass from (px, py) to a receiver, priced where the receiver will be on arrival.
#' lane_margin is the tightest defender's distance from the ball's path when the ball passes, minus the
#' ground LANE_SPEED covers in the ball's travel time; negative means a defender can get there.
#' @param flight c(intercept, seconds per foot) of the pass-duration fit.
#' @return data.table of pass features plus the receiver's arrival point (ax, ay) and flight time tf.
pass_features <- function(px, py, rx, ry, rvx, rvy, D, flight) {
  tf <- flight[1] + flight[2] * sqrt((rx - px)^2 + (ry - py)^2)
  ax <- rx + rvx * pmin(tf, LEAD_CAP)
  ay <- ry + rvy * pmin(tf, LEAD_CAP)
  sx <- ax - px
  sy <- ay - py
  len <- pmax(sqrt(sx^2 + sy^2), 0.1)
  s <- pmin(pmax(((D$x - px) * sx + (D$y - py) * sy) / len^2, 0), 1)
  tb <- s * tf
  ex <- D$x + D$vx * pmin(tb, LEAD_CAP) - (px + s * sx)
  ey <- D$y + D$vy * pmin(tb, LEAD_CAP) - (py + s * sy)
  margin <- sqrt(ex^2 + ey^2) - LANE_SPEED * tb
  margin[s < LANE_MIN_S] <- 15
  margin <- pmin(pmax(margin, -10), 15)
  arrive <- project_defense(D, tf)
  data.table(len = len, tf = tf, ax = ax, ay = ay, lane_margin = row_min(margin), lane_margin2 = row_min2(margin),
             recv_def = row_min(sqrt((arrive$x - ax)^2 + (arrive$y - ay)^2)),
             pass_def = row_min(sqrt((D$x - px)^2 + (D$y - py)^2)),
             recv_hoop = sqrt((HOOP_X - ax)^2 + ay^2), backcourt = as.integer(px < 0))
}

# ---- per-game tables -----------------------------------------------------------------------------

#' The event tables the EPV model needs, straight from one game's dynamic events file.
game_events <- function(root, g) {
  ev <- read_json_file(match_file(root, g, "_dynamic_events.json"))
  shots <- data.table(shot_id = chr_field(ev$shots, "id"), poss_id = chr_field(ev$shots, "possessionId"),
                      frame = int_field(ev$shots, "startFrame"), pid = int_field(ev$shots, "shooterId"),
                      made = lgl_field(ev$shots, "outcome"), fouled = lgl_field(ev$shots, "fouled"),
                      three_ev = lgl_field(ev$shots, "three"), def_dist_ev = num_field(ev$shots, "closestDefDist"))
  reb <- data.table(shot_id = chr_field(ev$rebounds, "shotId"), fg = lgl_field(ev$rebounds, "fgReb"),
                    oreb = !lgl_field(ev$rebounds, "defensive"))[fg & !is.na(shot_id)]
  shots[, oreb := reb$oreb[match(shot_id, reb$shot_id)]]
  passes <- data.table(frame = int_field(ev$passes, "startFrame"), end_frame = int_field(ev$passes, "endFrame"),
                       passer = int_field(ev$passes, "passerId"), receiver = int_field(ev$passes, "receiverId"),
                       thief = int_field(ev$passes, "toReceiverId"), turnover = lgl_field(ev$passes, "turnover"),
                       inbounds = lgl_field(ev$passes, "inbounds"), len_ev = num_field(ev$passes, "distance"))
  ft <- data.table(poss_id = chr_field(ev$free_throws, "possessionId"), frame = int_field(ev$free_throws, "frame"),
                   made = lgl_field(ev$free_throws, "outcome"), shot_id = chr_field(ev$free_throws, "shotId"))
  points <- rbind(shots[made == TRUE, .(poss_id, frame, pts = fifelse(three_ev, 3, 2))],
                  ft[made == TRUE, .(poss_id, frame, pts = 1)])
  list(shots = shots, passes = passes, ft = ft, points = points,
       turnovers = data.table(poss_id = chr_field(ev$turnovers, "possessionId"), frame = int_field(ev$turnovers, "frame")),
       dribble_frames = sort(int_field(ev$dribbles, "frame")),
       orb_chances = data.table(poss_id = chr_field(ev$chances, "possessionId"), frame = int_field(ev$chances, "startFrame"),
                                start = chr_field(ev$chances, "startType"))[start == "FGORB"])
}

#' Points the offense scores in the same possession at or after each (possession, frame).
points_from <- function(poss_id, frame, points) {
  at <- data.table(poss_id = poss_id, frame = frame)
  fcoalesce(points[at, on = .(poss_id, frame >= frame), .(pts = sum(pts)), by = .EACHI]$pts, 0)
}

#' For an intercepted pass the intended receiver is not recorded. Take the teammate best aligned with
#' the line from the passer to where the interceptor took the ball, preferring teammates beyond that point.
infer_receiver <- function(S, row, passer_slot, thief_x, thief_y) {
  px <- pick(S$off$x[row, , drop = FALSE], passer_slot)
  py <- pick(S$off$y[row, , drop = FALSE], passer_slot)
  tx <- thief_x - px
  ty <- thief_y - py
  reach <- sqrt(tx^2 + ty^2)
  mx <- S$off$x[row, , drop = FALSE] - px
  my <- S$off$y[row, , drop = FALSE] - py
  mate <- sqrt(mx^2 + my^2)
  off_line <- acos(pmin(pmax((mx * tx + my * ty) / pmax(mate * reach, 0.1), -1), 1))
  off_line[mate < 0.6 * reach] <- off_line[mate < 0.6 * reach] + pi
  off_line[cbind(seq_along(row), passer_slot)] <- Inf
  max.col(-off_line, ties.method = "first")
}

#' All model tables for one game.
#' @param flight Pass-duration coefficients, see pass_features().
#' @return list(rows, slots, cands, shots, passes, counts): see build_epv.R for how each is used.
game_tables <- function(app, g, flight) {
  ev <- game_events(app$root, g)
  S <- game_state(app, g, extra_frames = c(ev$shots$frame, ev$passes$frame))
  S <- add_holder(S, app$touches[game_id == g], ev$dribble_frames)
  fr <- S$fr
  n <- nrow(fr)
  fr[, row := seq_len(n)]
  slot_of <- function(row, pid) {
    hit <- S$off$pid[row, , drop = FALSE] == pid
    fifelse(rowSums(hit) == 1L, max.col(hit, ties.method = "first"), NA_integer_)
  }
  context <- lapply(1:5, function(j) player_context(S$off$x[, j], S$off$y[, j], S$off$vx[, j], S$off$vy[, j], S$def,
                                                    S$off$x, S$off$y))

  # rows: one per priced frame, with the holder's own state and the outcome labels
  last_to <- ev$turnovers[, .(to_frame = max(frame)), by = poss_id]
  fr[, to_frame := last_to$to_frame[match(poss_id, last_to$poss_id)]]
  fr[, c("rop_y", "pts_y") := .(as.integer(!is.na(to_frame) & to_frame > frame), points_from(poss_id, frame, ev$points))]
  fr[, haz_y := as.integer(rop_y == 1L & to_frame - frame <= HAZARD_FRAMES)]
  # Once a shot has left the shooter's hands he has no decision left to price, and that shot's points are no
  # longer "points from here on". Stop pricing from the frame after release until the next touch starts.
  shot_frames <- sort(ev$shots$frame)
  last_shot <- c(NA_integer_, shot_frames)[findInterval(fr$frame - 1L, shot_frames) + 1L]
  fr[, shot_gone := !is.na(last_shot) & !is.na(touch_start) & last_shot >= touch_start]
  fr[, grid := frame %% GRID_STEP == 0L & !is.na(slot) & !stopped & !shot_gone]
  fr[, ball_dist := fifelse(is.na(slot), NA_real_, sqrt((bx - pick(S$off$x, fcoalesce(slot, 1L)))^2 +
                                                        (by - pick(S$off$y, fcoalesce(slot, 1L)))^2))]

  # slots: every offensive player on every row, as a potential shooter
  slots <- rbindlist(lapply(1:5, function(j) cbind(data.table(row = fr$row, slot = j, pid = S$off$pid[, j]), context[[j]])))
  slots[, is_holder := fr$slot[row] == slot & !is.na(fr$slot[row])]
  slots[, c("sc", "held", "drib") := .(fr$sc[row], fifelse(is_holder, fr$held[row], 0), fifelse(is_holder, fr$drib[row], 0L))]

  # cands: every pass the holder could throw on a grid row, priced at the receiver's arrival
  gr <- fr[grid == TRUE]
  cands <- rbindlist(lapply(1:5, function(j) {
    use <- gr[slot != j]
    pf <- pass_features(pick(S$off$x[use$row, , drop = FALSE], use$slot), pick(S$off$y[use$row, , drop = FALSE], use$slot),
                        S$off$x[use$row, j], S$off$y[use$row, j], S$off$vx[use$row, j], S$off$vy[use$row, j],
                        lapply(S$def, function(m) m[use$row, , drop = FALSE]), flight)
    arrive <- project_defense(lapply(S$def, function(m) m[use$row, , drop = FALSE]), pf$tf)
    ctx <- player_context(pf$ax, pf$ay, S$off$vx[use$row, j], S$off$vy[use$row, j], arrive,
                          S$off$x[use$row, , drop = FALSE], S$off$y[use$row, , drop = FALSE])
    cbind(data.table(row = use$row, slot = j, pid = S$off$pid[use$row, j], sc = pmax(use$sc - pf$tf, 0), held = 0, drib = 0L),
          pf[, .(len, tf, lane_margin, lane_margin2, recv_def, pass_def, recv_hoop, backcourt)], ctx)
  }))

  # shots: real attempts at the release frame, with the shooter's context
  sh <- merge(ev$shots, fr[, .(frame, row, holder, held_row = held, drib_row = drib, sc)], by = "frame")
  sh[, slot := slot_of(row, pid)]
  shot_counts <- c(shots = nrow(ev$shots), no_state = nrow(ev$shots) - nrow(sh), not_on_offense = sum(is.na(sh$slot)))
  sh <- sh[!is.na(slot)]
  sh <- cbind(sh, slots[.(sh$row, sh$slot), on = .(row, slot), ..CONTEXT_COLS])
  sh[, c("held", "drib") := .(fifelse(holder == pid, held_row, NA_real_), fifelse(holder == pid, drib_row, NA_integer_))]

  # passes: completed passes (receiver known) and intercepted ones (receiver inferred)
  pa <- merge(ev$passes[!inbounds & (turnover | (!is.na(receiver) & passer != receiver))],
              fr[, .(frame, row, flip)], by = "frame")
  pa[, passer_slot := slot_of(row, passer)]
  pa <- pa[!is.na(passer_slot)]
  trk <- readRDS(tracking_cache_path(app$root, g))$players
  taken <- trk[.(pa$end_frame, pa$thief), on = .(frame, pid), .(x, y)]
  pa[, recv_slot := slot_of(row, receiver)]
  steal <- which(pa$turnover & !is.na(taken$x))
  pa[steal, recv_slot := infer_receiver(S, row, passer_slot, taken$x[steal] * flip, taken$y[steal] * flip)]
  pa <- pa[!is.na(recv_slot) & recv_slot != passer_slot]
  pf <- pass_features(pick(S$off$x[pa$row, , drop = FALSE], pa$passer_slot), pick(S$off$y[pa$row, , drop = FALSE], pa$passer_slot),
                      pick(S$off$x[pa$row, , drop = FALSE], pa$recv_slot), pick(S$off$y[pa$row, , drop = FALSE], pa$recv_slot),
                      pick(S$off$vx[pa$row, , drop = FALSE], pa$recv_slot), pick(S$off$vy[pa$row, , drop = FALSE], pa$recv_slot),
                      lapply(S$def, function(m) m[pa$row, , drop = FALSE]), flight)
  pa <- cbind(pa[, .(frame, end_frame, turnover = as.integer(turnover), len_ev)], pf)

  orb <- ev$orb_chances[, .(pts = points_from(poss_id, frame, ev$points))]
  keep <- c("row", "frame", "poss_id", "period", "gc", "sc", "slot", "holder", "held", "drib", "in_air", "ball_dist",
            "grid", "haz_y", "rop_y", "pts_y")
  tag <- function(dt) dt[, game_id := g]
  list(rows = tag(fr[, ..keep]), slots = tag(slots[row %in% c(gr$row, sh$row)]), cands = tag(cands), shots = tag(sh), passes = tag(pa),
       orb = tag(orb), ft = tag(ev$ft), counts = c(shot_counts, passes = nrow(pa), steals = sum(pa$turnover)))
}
