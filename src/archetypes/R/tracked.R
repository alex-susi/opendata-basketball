# Event and tracking counts behind the playstyle archetype features (the ten tracked games).
#
# Everything here is a count or a sum per player, per game, per half of the game's chances (odd or even in
# order of start frame). Features are ratios of these counts (see spec.R), so they can be recomputed on
# either half to measure how repeatable they are. Nothing uses a result: no makes, points, turnovers,
# fouls, blocks or rebounds collected.
# Tracking positions are rotated so the offense attacks the hoop at +x (as in src/epv/R/features.R).
# Event coordinates put the offensive hoop at -x, so they are rotated by 180 degrees to match.
# Requires src/play_viewer/R/data.R and src/epv/R/features.R.

KEY_HALF_W <- 2.45 * FT_PER_M      # half the width of the key
KEY_LEN <- 5.8 * FT_PER_M          # baseline to free-throw line
CORNER_X <- HALF_L - 2.99 * FT_PER_M   # the three-point line runs straight from the baseline to here
TOP_HALF_W <- 10         # ft either side of the hoop line that counts as the top of the floor
DUNKER_W <- 14           # ft: outer edge of the dunker spot (baseline, just outside the key)
RIM_SHOT <- 6            # ft: a two from this close is a rim shot
STILL_SPEED <- 2         # ft/s: slower than this is standing still
FAR_DEF <- 18            # ft from the hoop: a defender beyond this is out on the perimeter
HELP_GAP <- 8            # ft from an off-ball assignment that counts as helping off him
MEET_GAP <- 8            # ft: the on-ball defender has picked the ball up once this close
ROLL_FRAMES <- 62L       # 2.5 s after an on-ball screen
CUT_AFTER_FRAMES <- 50L  # 2 s after an off-ball screen
MOVE_NEAR <- 10          # ft: ending this close to the hoop is a roll or a cut to the rim
MOVE_GAIN <- 6           # ft closer to the hoop that also counts as one
POP_FAR <- 20            # ft: a screener ending this far out has popped
CUT_FRAMES <- 51L        # 2 s (17 grid steps) window for a cut detected from tracking alone
CUT_FAR <- 18            # ft: a cut starts at least this far from the hoop
CUT_NEAR <- 8            # ft: and ends within this
CUT_CATCH <- 12          # ft: a cutter may have caught the ball, but only this close in (otherwise it is a drive)
CUT_GAP_FRAMES <- 50L    # cuts by one player closer together than this are one cut
SCREEN_SHOT_FRAMES <- 100L   # a shot within 4 s of using an off-ball screen or handoff came off that screen
CRASH_NEAR <- 8          # ft from the hoop when the ball reaches the rim: on the glass
CRASH_GAIN <- 4          # ft gained on the hoop between release and rim that also counts
RETREAT_GAIN <- 3        # ft lost: getting back (offense) or leaking out (defense)
DRIVE_HELP_NEAR <- 6     # ft from the driver at the end of a drive
DRIVE_HELP_GAIN <- 4     # ft closed on the driver during the drive

#' An [x, y] field of every record as an n x 2 matrix, NA where it is missing.
ev_xy <- function(recs, name) {
  t(vapply(recs, function(r) {
    v <- as.numeric(unlist(r[[name]]))
    if (length(v) == 2L) v else c(NA_real_, NA_real_)
  }, c(0, 0)))
}

has_outcome <- function(recs, value, name = "outcomes") vapply(recs, function(r) value %in% unlist(r[[name]]), NA)

hoop_dist <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)

#' Court zone of a point in attack-+x coordinates.
#' @return One of backcourt, paint, dunker, mid, corner, wing, top (the last three are beyond the arc).
court_zone <- function(x, y) {
  three <- hoop_dist(x, y) > THREE_R | abs(y) > THREE_Y
  paint <- x > HALF_L - KEY_LEN & abs(y) < KEY_HALF_W
  fifelse(x < 0, "backcourt",
          fifelse(paint, "paint",
                  fifelse(three, fifelse(x > CORNER_X, "corner", fifelse(abs(y) <= TOP_HALF_W, "top", "wing")),
                          fifelse(x > CORNER_X & abs(y) < DUNKER_W, "dunker", "mid"))))
}

#' Sum `value` by player, half and key, dropping rows with a missing player, half or value.
tally <- function(pid, half, key, value = 1) {
  n <- length(pid)
  dt <- data.table(pid = as.integer(pid), half = as.integer(half), stat = rep_len(key, n), value = as.numeric(rep_len(value, n)))
  dt[!is.na(pid) & !is.na(half) & !is.na(value), .(value = sum(value)), by = .(pid, half, stat)]
}

#' Tally several named columns of a table at once (each column becomes a key).
tally_cols <- function(dt, cols) rbindlist(lapply(cols, function(k) tally(dt$pid, dt$half, k, dt[[k]])))

#' Chances of one game in start order, with the half they fall in and the frame of their shot.
chance_table <- function(ev) {
  ch <- data.table(id = chr_field(ev$chances, "id"), f0 = int_field(ev$chances, "startFrame"),
                   f1 = int_field(ev$chances, "endFrame"), gc0 = num_field(ev$chances, "startGameClock"),
                   gc1 = num_field(ev$chances, "endGameClock"), start = chr_field(ev$chances, "startType"),
                   transition = lgl_field(ev$chances, "transition"), fc = int_field(ev$chances, "frontcourtFrame"))
  ch <- ch[!is.na(f0) & !is.na(f1) & f1 >= f0][order(f0)]
  ch[, half := seq_len(.N) %% 2L]
  ch[, secs := pmax(fcoalesce(gc0 - gc1, 0), 0)]
  shot <- data.table(id = chr_field(ev$shots, "chanceId"), frame = int_field(ev$shots, "startFrame"))[, .(frame = min(frame)), by = id]
  ch[, shot_frame := shot$frame[match(id, shot$id)]]
  ch
}

# ---- events --------------------------------------------------------------------------------------

#' Counts that need only the event file.
#' @return list(counts, touches, picks, shots, off_screens): the tables the tracking step reuses.
event_counts <- function(ev, ch) {
  half_of <- function(recs) ch$half[match(chr_field(recs, "chanceId"), ch$id)]
  per <- function(recs, field, key, value = 1, keep = TRUE) {
    tally(fifelse(rep_len(keep, length(recs)), int_field(recs, field), NA_integer_), half_of(recs), key, value)
  }
  out <- list()

  # exposure: chances and clock seconds on court
  cp <- data.table(pid = int_field(ev$chance_players, "playerId"), chance = chr_field(ev$chance_players, "chanceId"),
                   off = lgl_field(ev$chance_players, "offense"))
  cp[, c("half", "secs") := .(ch$half[match(chance, ch$id)], ch$secs[match(chance, ch$id)])]
  out$exposure <- rbind(tally(cp$pid, cp$half, fifelse(cp$off, "off_ch", "def_ch")),
                        tally(cp$pid, cp$half, fifelse(cp$off, "off_secs", "def_secs"), cp$secs))

  # touches
  loc <- -ev_xy(ev$touches, "location")
  tu <- data.table(id = chr_field(ev$touches, "id"), pid = int_field(ev$touches, "playerId"),
                   chance = chr_field(ev$touches, "chanceId"), half = half_of(ev$touches),
                   f0 = int_field(ev$touches, "startFrame"), f1 = int_field(ev$touches, "endFrame"),
                   touch_drib = fcoalesce(int_field(ev$touches, "numDribbles"), 0L), touch_secs = num_field(ev$touches, "touchTime"),
                   x = loc[, 1], y = loc[, 2], touch_shot = as.integer(lgl_field(ev$touches, "ledToShot")),
                   touch_pass = as.integer(has_outcome(ev$touches, "PASS")))
  tu <- tu[!is.na(pid) & !is.na(f0) & !is.na(f1) & f1 >= f0]
  tu[, touch_secs := fcoalesce(touch_secs, (f1 - f0) / 25)]
  tu[, c("touches", "touch_zero", "dist", "zone") := .(1L, as.integer(touch_drib == 0L), hoop_dist(x, y), court_zone(x, y))]
  front <- tu[!is.na(zone) & zone != "backcourt"]
  out$touches <- rbind(tally_cols(tu, c("touches", "touch_drib", "touch_secs", "touch_zero", "touch_shot", "touch_pass")),
                       tally(front$pid, front$half, "touch_fc"), tally(front$pid, front$half, "touch_fc_dist", front$dist),
                       tally(front$pid, front$half, paste0("touch_z_", front$zone)))

  # who has the ball when it first reaches the frontcourt (second chances excluded)
  first <- merge(tu[, .(chance, pid, f0, f1)], ch[!start %in% c("FGORB", "FTORB") & !is.na(fc), .(chance = id, fc)], by = "chance")
  first[, wait := fifelse(f0 <= fc & f1 >= fc, 0L, fifelse(f0 > fc, f0 - fc, NA_integer_))]
  first <- first[!is.na(wait)][order(chance, wait)][, .SD[1], by = chance]
  out$initiate <- rbind(tally(first$pid, ch$half[match(first$chance, ch$id)], "init"),
                        cp[off == TRUE & chance %in% first$chance, tally(pid, half, "off_ch_bc")])

  # passes that reached a teammate
  pa <- data.table(pid = int_field(ev$passes, "passerId"), half = half_of(ev$passes), to = int_field(ev$passes, "receiverId"),
                   pass_len = num_field(ev$passes, "distance"), from_region = chr_field(ev$passes, "passerRegion"),
                   to_region = chr_field(ev$passes, "receiverRegion"), pass_to_shot = as.integer(lgl_field(ev$passes, "ledToShot")),
                   drop = lgl_field(ev$passes, "inbounds") | lgl_field(ev$passes, "turnover"))
  pa <- pa[!drop & !is.na(to) & pid != to & !is.na(pass_len)]
  pa[, c("passes", "pass_inside", "pass_kickout") := .(1L, as.integer(to_region %in% c("key", "ra")),
                                                         as.integer(from_region %in% c("key", "ra") & grepl("three", to_region)))]
  out$passes <- tally_cols(pa, c("passes", "pass_len", "pass_inside", "pass_kickout", "pass_to_shot"))

  # on-ball screens, with the coverage each defender played
  bh_type <- chr_field(ev$picks, "bhrDefType")
  scr_type <- chr_field(ev$picks, "scrDefType")
  called <- function(type) !is.na(type) & type != "none"
  out$picks <- rbind(per(ev$picks, "ballhandlerId", "pick_bh"), per(ev$picks, "screenerId", "pick_scr"),
                     per(ev$picks, "ballhandlerDefId", "d_pick_bh"), per(ev$picks, "screenerDefId", "d_pick_scr"),
                     per(ev$picks, "ballhandlerDefId", "d_bh_cov", keep = called(bh_type)),
                     per(ev$picks, "ballhandlerDefId", paste0("d_bh_", bh_type), keep = called(bh_type)),
                     per(ev$picks, "screenerDefId", "d_scr_cov", keep = called(scr_type)),
                     per(ev$picks, "screenerDefId", paste0("d_scr_", scr_type), keep = called(scr_type)))

  # handoffs, off-ball screens, drives, isolations, post-ups
  ob <- ev$off_ball_screens
  out$actions <- rbind(per(ev$handoffs, "setterId", "ho_set"), per(ev$handoffs, "receiverId", "ho_recv"),
                       per(ev$handoffs, "receiverDefId", "d_ho_recv"), per(ev$handoffs, "setterDefId", "d_ho_set"),
                       per(ob, "screenerId", "obs_scr"), per(ob, "cutterId", "obs_cut"),
                       per(ob, "cutterId", "obs_cut_touch", lgl_field(ob, "ledToTouch")),
                       per(ob, "cutterId", "obs_cut_shot", lgl_field(ob, "ledToShot")),
                       per(ob, "cutterDefId", "d_obs_cut"), per(ob, "screenerDefId", "d_obs_scr"),
                       per(ev$drives, "ballhandlerId", "drives"), per(ev$drives, "ballhandlerDefId", "d_drive"),
                       per(ev$isolations, "ballhandlerId", "iso"), per(ev$isolations, "ballhandlerDefId", "d_iso"),
                       per(ev$posts, "ballhandlerId", "post"), per(ev$posts, "ballhandlerDefId", "d_post"))

  # closeouts: what the man with the ball did, and how far the defender came from
  co <- ev$closeouts
  action <- chr_field(co, "bhrAction")
  out$closeouts <- rbind(per(co, "ballhandlerId", "co_faced"), per(co, "ballhandlerId", "co_shot", action == "shot"),
                         per(co, "ballhandlerId", "co_drive", action == "drive"), per(co, "ballhandlerDefId", "d_co"),
                         per(co, "ballhandlerDefId", "d_co_dist", num_field(co, "touchDistance")),
                         per(co, "ballhandlerDefId", "d_co_dist_n", !is.na(num_field(co, "touchDistance"))))

  # shots: where they were taken, whether they came off a screen, and who was nearest
  sh <- data.table(chance = chr_field(ev$shots, "chanceId"), half = half_of(ev$shots), frame = int_field(ev$shots, "startFrame"),
                   pid = int_field(ev$shots, "shooterId"), three = lgl_field(ev$shots, "three"), dist = num_field(ev$shots, "distance"),
                   cns = lgl_field(ev$shots, "catchAndShoot"), touch = chr_field(ev$shots, "touchId"),
                   nearest = int_field(ev$shots, "closestDefId"))
  sh[, zone := fifelse(three, "three", fifelse(is.na(dist), NA_character_, fifelse(dist <= RIM_SHOT, "rim", "mid")))]
  used <- rbind(data.table(pid = int_field(ob, "cutterId"), frame = int_field(ob, "frame")),
                data.table(pid = int_field(ev$handoffs, "receiverId"), frame = int_field(ev$handoffs, "frame")))
  sh[, off_screen := vapply(seq_len(.N), function(i) any(used$pid == pid[i] & frame[i] - used$frame >= 0L &
                                                           frame[i] - used$frame <= SCREEN_SHOT_FRAMES, na.rm = TRUE), NA)]
  out$shots <- rbind(tally(sh$pid, sh$half, "shots"), tally(sh$pid, sh$half, paste0("shot_", sh$zone)),
                     tally(sh$pid, sh$half, "shot_off_screen", sh$off_screen), tally(sh$nearest, sh$half, "d_shot"),
                     tally(sh$nearest, sh$half, paste0("d_shot_", sh$zone)))

  # the glass: where everyone else is when the ball is released and when it reaches the rim
  at_shot <- ev_xy(ev$chance_players, "shotLoc")
  at_rim <- ev_xy(ev$chance_players, "rimLoc")
  gl <- cbind(cp, d0 = hoop_dist(-at_shot[, 1], -at_shot[, 2]), d1 = hoop_dist(-at_rim[, 1], -at_rim[, 2]))
  gl <- gl[!is.na(d0) & !is.na(d1) & pid != sh$pid[match(chance, sh$chance)]]
  gl[, c("crash", "retreat") := .(as.integer(d1 <= CRASH_NEAR | d0 - d1 >= CRASH_GAIN), as.integer(d1 - d0 >= RETREAT_GAIN))]
  out$glass <- rbind(tally(gl$pid, gl$half, fifelse(gl$off, "glass_n", "d_glass_n")),
                     tally(gl$pid, gl$half, fifelse(gl$off, "glass_crash", "d_glass_crash"), gl$crash),
                     tally(gl$pid, gl$half, fifelse(gl$off, "glass_back", "d_glass_leak"), gl$retreat))

  # switching: how many different men a defender is assigned within one chance
  mu <- data.table(def = int_field(ev$matchups, "defPlayerId"), off = int_field(ev$matchups, "offPlayerId"),
                   chance = chr_field(ev$matchups, "chanceId"), f0 = int_field(ev$matchups, "startFrame"),
                   f1 = int_field(ev$matchups, "endFrame"))
  mu <- mu[!is.na(def) & !is.na(off) & !is.na(f0) & !is.na(f1) & f1 >= f0]
  sw <- mu[, .(men = uniqueN(off)), by = .(pid = def, chance)]
  sw[, half := ch$half[match(chance, ch$id)]]
  out$switching <- rbind(tally(sw$pid, sw$half, "d_mu_ch"), tally(sw$pid, sw$half, "d_mu_switch", sw$men - 1L))

  picks <- data.table(frame = int_field(ev$picks, "frame"), half = half_of(ev$picks), scr = int_field(ev$picks, "screenerId"),
                      scr_def = int_field(ev$picks, "screenerDefId"))
  off_screens <- data.table(frame = int_field(ob, "frame"), half = half_of(ob), cutter = int_field(ob, "cutterId"))
  drives <- data.table(half = half_of(ev$drives), f0 = int_field(ev$drives, "startFrame"), f1 = int_field(ev$drives, "endFrame"),
                       bh = int_field(ev$drives, "ballhandlerId"), bh_def = int_field(ev$drives, "ballhandlerDefId"))
  list(counts = rbindlist(out), touches = tu, picks = picks, shots = sh, off_screens = off_screens, drives = drives,
       matchups = mu, on_court = cp)
}

# ---- tracking at event frames -------------------------------------------------------------------

#' Counts that need a player's position at a particular frame: roll or pop after a screen, the cutter's
#' path after an off-ball screen, the screener defender's depth, shooter speed, help on drives.
frame_counts <- function(trk, plays, E) {
  P <- trk$players
  setkey(P, pid, frame)
  flip_at <- function(frame) fifelse(plays$left_hoop[pmax(findInterval(frame, plays$start_frame), 1L)], -1, 1)
  dist_at <- function(who, when, flip) {
    hit <- P[.(who, when), on = .(pid, frame), .(x, y)]
    hoop_dist(hit$x * flip, hit$y * flip)
  }
  step <- function(who, f_from, f_to) {
    a <- P[.(who, f_from), on = .(pid, frame), .(x, y)]
    b <- P[.(who, f_to), on = .(pid, frame), .(x, y)]
    sqrt((a$x - b$x)^2 + (a$y - b$y)^2)
  }
  out <- list()

  # screener: toward the hoop (roll), out to the perimeter (pop), or neither; and how deep his defender sat
  pk <- E$picks[!is.na(frame)]
  flip <- flip_at(pk$frame)
  d0 <- dist_at(pk$scr, pk$frame, flip)
  d1 <- dist_at(pk$scr, pk$frame + ROLL_FRAMES, flip)
  roll <- d1 <= MOVE_NEAR | d0 - d1 >= MOVE_GAIN
  depth <- d0 - dist_at(pk$scr_def, pk$frame, flip)
  out$picks <- rbind(tally(pk$scr, pk$half, "pick_scr_trk", !is.na(d0) & !is.na(d1)), tally(pk$scr, pk$half, "pick_roll", roll),
                     tally(pk$scr, pk$half, "pick_pop", !roll & d1 >= POP_FAR),
                     tally(pk$scr_def, pk$half, "d_scr_depth", depth), tally(pk$scr_def, pk$half, "d_scr_depth_n", !is.na(depth)))

  # cutter off an off-ball screen: to the rim or not
  ob <- E$off_screens[!is.na(frame)]
  flip <- flip_at(ob$frame)
  d0 <- dist_at(ob$cutter, ob$frame, flip)
  d1 <- dist_at(ob$cutter, ob$frame + CUT_AFTER_FRAMES, flip)
  out$off_screens <- rbind(tally(ob$cutter, ob$half, "obs_cut_trk", !is.na(d0) & !is.na(d1)),
                           tally(ob$cutter, ob$half, "obs_cut_rim", d1 <= MOVE_NEAR | d0 - d1 >= MOVE_GAIN))

  # shooter speed at release (0.24 s backward difference) and over the second before a catch-and-shoot three
  sh <- E$shots[!is.na(zone)]
  speed <- pmin(step(sh$pid, sh$frame - VEL_LAG, sh$frame) * 25 / VEL_LAG, MAX_SPEED)
  cs <- E$shots[three & cns]
  cs[, f0 := E$touches$f0[match(touch, E$touches$id)]]
  cs <- cs[!is.na(f0)]
  path <- Reduce(`+`, lapply(0:3, function(k) step(cs$pid, cs$f0 - VEL_LAG * (k + 1L), cs$f0 - VEL_LAG * k)))
  out$shots <- rbind(tally(sh$pid, sh$half, paste0("shot_", sh$zone, "_speed"), speed),
                     tally(sh$pid, sh$half, paste0("shot_", sh$zone, "_trk"), !is.na(speed)),
                     tally(cs$pid, cs$half, "cns3_pre_speed", pmin(path * 25 / (4 * VEL_LAG), MAX_SPEED)),
                     tally(cs$pid, cs$half, "cns3_trk", !is.na(path)))

  # help on drives: defenders other than the driver's own who close on him by the end of the drive
  dv <- E$drives[!is.na(f0) & !is.na(f1) & f1 > f0]
  setkey(P, frame)
  help <- rbindlist(lapply(seq_len(nrow(dv)), function(i) {
    end <- P[.(dv$f1[i]), nomatch = NULL]
    start <- P[.(dv$f0[i]), nomatch = NULL]
    me <- end[pid == dv$bh[i]]
    me0 <- start[pid == dv$bh[i]]
    if (nrow(me) != 1L || nrow(me0) != 1L) return(NULL)
    others <- end[home != me$home & !pid %in% dv$bh_def[i]]
    before <- start[match(others$pid, pid)]
    data.table(pid = others$pid, half = dv$half[i], gap1 = sqrt((others$x - me$x)^2 + (others$y - me$y)^2),
               gap0 = sqrt((before$x - me0$x)^2 + (before$y - me0$y)^2))
  }))
  setkey(P, pid, frame)
  help <- help[!is.na(gap0)]
  out$drives <- rbind(tally(help$pid, help$half, "d_drive_other"),
                      tally(help$pid, help$half, "d_drive_help", help$gap1 <= DRIVE_HELP_NEAR & help$gap0 - help$gap1 >= DRIVE_HELP_GAIN))
  rbindlist(out)
}

# ---- tracking on the grid ------------------------------------------------------------------------

#' One side of a game state as a long table: one row per player per grid frame.
side_long <- function(side, fr) {
  rbindlist(lapply(1:5, function(j) {
    data.table(row = seq_len(nrow(fr)), frame = fr$frame, pid = side$pid[, j], x = side$x[, j], y = side$y[, j],
               speed = sqrt(side$vx[, j]^2 + side$vy[, j]^2), det = side$det[, j], chance = fr$chance, half = fr$half,
               set = fr$set, live = fr$live, holder = fr$holder, catch_dist = fr$catch_dist)
  }))
}

#' Counts from every third frame: where players stand, how they move and whom they guard.
#' "Set" frames are half-court offense: clock running, not a transition chance, the ball in the
#' frontcourt, at or after the chance's first frontcourt frame and no later than its shot's release.
#' @return list(counts, pairs): pairs is set frames per (defender, assigned man, half).
grid_counts <- function(app, g, ch, E) {
  S <- game_state(app, g)
  fr <- S$fr
  ci <- findInterval(fr$frame, ch$f0)
  cj <- pmax(ci, 1L)
  inside <- ci > 0L & fr$frame <= ch$f1[cj]
  fr[, chance := fifelse(inside, ch$id[cj], NA_character_)]
  fr[, half := fifelse(inside, ch$half[cj], NA_integer_)]
  fr[, live := inside & !stopped]
  fr[, set := (live & !ch$transition[cj] & frame >= ch$fc[cj] & bx > 0 &
                 (is.na(ch$shot_frame[cj]) | frame <= ch$shot_frame[cj])) %in% TRUE]
  tl <- E$touches[order(f0)]
  ti <- pmax(findInterval(fr$frame, tl$f0), 1L)
  in_touch <- fr$frame >= tl$f0[ti] & fr$frame <= tl$f1[ti]
  fr[, holder := fifelse(in_touch, tl$pid[ti], NA_integer_)]
  fr[, catch_dist := fifelse(in_touch, tl$dist[ti], NA_real_)]
  out <- list()

  # offense away from the ball
  O <- side_long(S$off, fr)
  O[, c("d", "zone", "on_ball") := .(hoop_dist(x, y), court_zone(x, y), !is.na(holder) & holder == pid)]
  ob <- O[set & !on_ball & x > 0]
  out$off_ball <- rbind(tally(ob$pid, ob$half, "offb_n"), tally(ob$pid, ob$half, paste0("offb_", ob$zone)),
                        tally(ob$pid, ob$half, "offb_still", ob$speed < STILL_SPEED), tally(ob$pid, ob$half, "offb_speed", ob$speed),
                        tally(ob$pid, ob$half, "offb_dist", ob$d), tally(ob$pid, ob$half, "offb_det", ob$det))

  # cuts: off the ball and far out 2 s ago, at the rim now, in the same chance
  before <- O[.(O$pid, O$frame - CUT_FRAMES), on = .(pid, frame), .(d, on_ball, chance)]
  O[, cut := (set & d <= CUT_NEAR & before$d >= CUT_FAR & before$chance == chance & !before$on_ball &
                (!on_ball | catch_dist <= CUT_CATCH)) %in% TRUE]
  cuts <- O[cut == TRUE][order(pid, frame)]
  cuts[, fresh := is.na(shift(frame)) | frame - shift(frame) > CUT_GAP_FRAMES, by = pid]
  cuts <- cuts[fresh == TRUE]
  screened <- vapply(seq_len(nrow(cuts)), function(i) any(E$picks$scr == cuts$pid[i] & cuts$frame[i] - E$picks$frame >= 0L &
                                                            cuts$frame[i] - E$picks$frame <= SCREEN_SHOT_FRAMES, na.rm = TRUE), NA)
  out$cuts <- tally(cuts$pid[!screened], cuts$half[!screened], "cuts")

  # order of arrival in the frontcourt after a defensive rebound or a live turnover
  runs <- ch[start %in% c("FGDRB", "FTDRB", "TO"), id]
  crossed <- O[chance %in% runs & x > 0, .(frame = min(frame), half = half[1]), by = .(chance, pid)]
  crossed <- crossed[E$on_court[off == TRUE], on = .(chance, pid), nomatch = NULL]
  crossed[, c("rank", "n") := .(frank(frame, ties.method = "min"), .N), by = chance]
  crossed <- crossed[n >= 4L]
  out$transition <- rbind(tally(crossed$pid, crossed$half, "trans_n"), tally(crossed$pid, crossed$half, "trans_rank", crossed$rank))

  # defense: location, and position relative to the assigned man
  D <- side_long(S$def, fr)
  mu <- E$matchups[order(def, f0)]
  D[, man := {
    m <- mu[def == .BY$pid]
    i <- findInterval(frame, m$f0)
    i1 <- pmax(i, 1L)
    if (nrow(m)) fifelse(i > 0L & frame <= m$f1[i1], m$off[i1], NA_integer_) else rep(NA_integer_, .N)
  }, by = pid]
  him <- O[.(D$row, D$man), on = .(row, pid), .(x, y, d)]
  D[, c("d", "zone", "gap", "man_d") := .(hoop_dist(x, y), court_zone(x, y), sqrt((x - him$x)^2 + (y - him$y)^2), him$d)]
  D[, last := d == min(d), by = row]
  D[, state := fifelse(is.na(gap) | is.na(holder), NA_character_, fifelse(man == holder, "on", "off"))]
  ds <- D[set == TRUE]
  on <- ds[state == "on"]
  off <- ds[state == "off"]
  out$defense <- rbind(tally(ds$pid, ds$half, "dfr_n"), tally(ds$pid, ds$half, "dfr_paint", ds$zone == "paint"),
                       tally(ds$pid, ds$half, "dfr_far", ds$d > FAR_DEF), tally(ds$pid, ds$half, "dfr_dist", ds$d),
                       tally(ds$pid, ds$half, "dfr_speed", ds$speed), tally(ds$pid, ds$half, "dfr_det", ds$det),
                       tally(ds$pid, ds$half, "dfr_last", ds$last), tally(ds$pid, ds$half, "dfr_man_n", !is.na(ds$man_d)),
                       tally(ds$pid, ds$half, "dfr_man_dist", ds$man_d), tally(on$pid, on$half, "dfr_on"),
                       tally(on$pid, on$half, "dfr_on_gap", on$gap), tally(off$pid, off$half, "dfr_offb"),
                       tally(off$pid, off$half, "dfr_offb_gap", off$gap), tally(off$pid, off$half, "dfr_help", off$gap >= HELP_GAP))

  # where the on-ball defender first gets within reach of the ball in each chance
  meet <- D[live & state == "on" & gap <= MEET_GAP][order(frame), .SD[1], by = .(pid, chance)]
  out$meet <- rbind(tally(meet$pid, meet$half, "d_meet_n"), tally(meet$pid, meet$half, "d_meet_dist", meet$d))
  list(counts = rbindlist(out), pairs = ds[!is.na(man), .(frames = .N), by = .(def = pid, off = man, half)])
}

#' Every count for one game.
#' @return list(counts = (pid, half, stat, value) with raw player ids, pairs = defender-assignment frames).
game_counts <- function(app, g) {
  ev <- read_json_file(match_file(app$root, g, "_dynamic_events.json"))
  ch <- chance_table(ev)
  E <- event_counts(ev, ch)
  frames <- frame_counts(readRDS(tracking_cache_path(app$root, g)), app$plays[game_id == g][order(start_frame)], E)
  grid <- grid_counts(app, g, ch, E)
  counts <- rbind(E$counts, frames, grid$counts)[, .(value = sum(value)), by = .(pid, half, stat)]
  list(counts = counts[, game_id := g], pairs = grid$pairs[, game_id := g])
}
