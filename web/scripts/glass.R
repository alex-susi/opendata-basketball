# Rebounding roles: what each attacker does while a shot is in the air (sourced by annotations.R and sample_stats.R;
# `a` is the loaded Shiny app). SkillCorner labels none of this, so it is read from the tracking.
#
# Window: from the shot's release (shots.startFrame) to the end of its flight (shots.endFrame, when the ball reaches
# the rim or is caught, capped at 3 s). Only this window is used, so a role is what a player chose to do before
# anyone knew where the ball would go, not who got it. Distances are to the hoop the offense attacks; "toward his own
# end" is along the court's length, in the viewer's frame (the offense attacks +x).
#
# Each attacker other than the shooter gets one role, judged from where he started as well as where he went:
#   crash   on the glass: within CRASH_NEAR ft of the hoop when the flight ends, or he gained CRASH_GAIN ft on it
#           and finished inside the three-point line (FIBA: 6.75 m arc, straight 6.6 m from the hoop's line in the
#           corners)
#   back    retreating (shown as "Retreat"): moved at least BACK_GAIN ft toward his own end, or finished in the
#           backcourt
#   safety  already back: started at least SAFETY_FAR ft from the hoop, the deepest attacker, and stayed there
#   hold    everyone else: kept his spot (a corner shooter staying to space, a big already in the paint who did not
#           move is a crash, by CRASH_NEAR)
# The shooter is labelled separately: "follow" if he crashed after his own shot, else "shooter".
#
# Box-outs: a crasher, or any attacker who was already within CRASH_NEAR ft of the hoop at release, is boxed out when
# a defender holds the spot between him and the hoop for at least BOX_FRAMES frames, checked from BOX_BEFORE frames
# before the ball reaches the rim until the rebound (at most BOX_AFTER frames after): closer to the hoop, within
# BOX_NEAR ft of him, and within BOX_LANE ft of the straight line from him to the hoop (contact usually comes as the
# ball comes off the rim, not at it). It must also hold: once in the spot, the defender is never beaten later in the
# window (the attacker more than BOX_BEAT ft closer to the hoop than him), so a crasher who gets round or through
# his man to the rim was not boxed out. And there must be contact: at least one frame in the spot within BOX_TOUCH ft
# of him (a defender standing 3-5 ft in front who never meets the crasher is not boxing out). For display, the box-out
# starts (bf) when the defender stopped him: the first
# frame in the spot within BOX_TOUCH ft of him where the attacker's speed toward the hoop (over SLOW_HALF frames
# either side) is under BOX_SLOW ft/s or under BOX_DROP of his fastest so far in the window; it lasts to the end of
# the window (b1). The timing does not decide whether there was a box-out. His assigned defender at release (matchups) is tried first, then the defender
# who held the spot longest; that defender is the "boxer". An earlier geometric box-out detector failed
# its stability checks (decision log, 2026-11-05: one-foot moves changed pairings), so this is a coarse flag about
# whether a crash was met, not a skill measure.
#
# Seen: the share of the window's frames in which the player was detected on camera (not extrapolated). The camera
# follows the ball, so players getting back are often off screen; every role carries it so it can be filtered.

# Thresholds in ft and frames (see the definitions above); court geometry in feet.
GLASS <- list(crash_near = 8, crash_gain = 4, back_gain = 3, safety_far = 28,
              box_near = 5, box_lane = 3, box_before = 12L, box_after = 25L, box_frames = 3L, box_beat = 1, box_slow = 3, box_drop = 0.7, box_touch = 3, slow_half = 3L,
              max_flight = 75L, reach = 2L)
GLASS_HOOP_X <- 14 * 3.28084 - 1.575 * 3.28084
GLASS_THREE_R <- 6.75 * 3.28084
GLASS_THREE_Y <- 6.6 * 3.28084

#' TRUE where (x, y), in the viewer's frame, is inside the three-point line of the hoop at +x.
inside_three <- function(x, y) {
  dx <- GLASS_HOOP_X - x
  corner <- dx <= sqrt(GLASS_THREE_R^2 - GLASS_THREE_Y^2)
  fifelse(corner, abs(y) < GLASS_THREE_Y, sqrt(dx^2 + y^2) < GLASS_THREE_R)
}

#' One row per attacker per shot: f, f1 (frames), shot id, pid, role, d0/d1 (ft from the hoop at release and at the
#' end of the flight), boxed and boxer (crashers and attackers who started near the hoop), seen (0-1), made (the
#' shot), plus the shot's possession. rd: ft from his spot when the flight ended to where the rebound was taken (the
#' rebounder's tracked spot at the rebound frame; NA for team rebounds or untracked rebounders), for asking whether
#' the ball came his way.
game_glass <- function(game_id, ev) {
  G <- GLASS
  gid <- game_id
  # The game's tracking, attack directions, shots (flight capped at max_flight frames), chance rosters, rebounds and
  # matchups.
  trk <- a$get_tracking(a$app_data, gid)$players[, .(frame, pid, x, y, det)]
  setkey(trk, frame, pid)
  left <- setNames(ann_lgl(ev$possessions, "leftHoop"), ann_chr(ev$possessions, "id"))
  sh <- data.table(id = ann_chr(ev$shots, "id"), f = ann_int(ev$shots, "startFrame"), f1 = ann_int(ev$shots, "endFrame"),
                   shooter = ann_int(ev$shots, "shooterId"), chance = ann_chr(ev$shots, "chanceId"),
                   poss = ann_chr(ev$shots, "possessionId"), made = ann_lgl(ev$shots, "outcome"))[!is.na(f) & !is.na(f1)]
  sh[, f1 := pmin(pmax(f1, f + 1L), f + G$max_flight)]
  cpa <- data.table(chance = ann_chr(ev$chance_players, "chanceId"), pid = ann_int(ev$chance_players, "playerId"),
                    off = ann_lgl(ev$chance_players, "offense"))
  cp <- cpa[off == TRUE]
  cpd <- cpa[off == FALSE]
  rb <- data.table(shot = ann_chr(ev$rebounds, "shotId"), f = ann_int(ev$rebounds, "frame"),
                   reb = ann_int(ev$rebounds, "rebounderId"), got = ann_lgl(ev$rebounds, "rebounded"))[!is.na(shot) & !is.na(f)]
  reb_f <- setNames(rb$f, rb$shot)
  mu <- data.table(f0 = ann_int(ev$matchups, "startFrame"), f1 = ann_int(ev$matchups, "endFrame"),
                   def = ann_int(ev$matchups, "defPlayerId"), off = ann_int(ev$matchups, "offPlayerId"))
  # A player's spot at a frame, from the nearest tracked frame within `reach`, in the viewer's frame.
  spot <- function(fr, ids, sgn) {
    out <- matrix(NA_real_, length(ids), 2)
    for (d in c(0L, -1L, 1L, -2L, 2L)) {
      miss <- is.na(out[, 1])
      if (!any(miss)) break
      hit <- trk[.(fr + d, ids[miss]), .(x, y)]
      out[miss, ] <- cbind(sgn * hit$x, -sgn * hit$y)
    }
    out
  }
  rows <- vector("list", nrow(sh))
  # One shot at a time: every attacker's spot at release and at the end of the flight.
  for (i in seq_len(nrow(sh))) {
    s <- sh[i]
    sgn <- if (isTRUE(left[s$poss])) -1 else 1
    ids <- unique(cp[chance == s$chance, pid])
    if (!length(ids)) next
    p0 <- spot(s$f, ids, sgn)
    p1 <- spot(s$f1, ids, sgn)
    ok <- !is.na(p0[, 1]) & !is.na(p1[, 1])
    if (!any(ok)) next
    ids <- ids[ok]
    p0 <- p0[ok, , drop = FALSE]
    p1 <- p1[ok, , drop = FALSE]
    d0 <- sqrt((GLASS_HOOP_X - p0[, 1])^2 + p0[, 2]^2)
    d1 <- sqrt((GLASS_HOOP_X - p1[, 1])^2 + p1[, 2]^2)
    # Distance from his end-of-flight spot to where the rebound was secured.
    rd <- rep(NA_real_, length(ids))
    rr <- rb[shot == s$id & got %in% TRUE & !is.na(reb)]
    if (nrow(rr)) {
      q <- spot(rr$f[1], rr$reb[1], sgn)
      if (!is.na(q[1, 1])) rd <- round(sqrt((p1[, 1] - q[1, 1])^2 + (p1[, 2] - q[1, 2])^2), 1)
    }
    # Role from where he started and where he went.
    crash <- d1 <= G$crash_near | (d0 - d1 >= G$crash_gain & inside_three(p1[, 1], p1[, 2]))
    back <- (p0[, 1] - p1[, 1] >= G$back_gain) | p1[, 1] < 0
    deepest <- d0 == max(d0[ids != s$shooter])
    role <- fifelse(crash, "crash", fifelse(back, "back", fifelse(d0 >= G$safety_far & deepest & d1 >= G$safety_far, "safety", "hold")))
    role[ids == s$shooter] <- ifelse(crash[ids == s$shooter] & d0[ids == s$shooter] - d1[ids == s$shooter] >= G$crash_gain, "follow", "shooter")
    # Box-outs, frame by frame from BOX_BEFORE frames before the ball reaches the rim until the rebound (at most
    # BOX_AFTER frames on): the attacker's matchup at release first, then the defender who held the spot longest.
    boxed <- rep(NA, length(ids))
    boxer <- rep(NA_integer_, length(ids))
    bf <- rep(NA_integer_, length(ids))
    b1 <- rep(NA_integer_, length(ids))
    defs <- unique(cpd[chance == s$chance, pid])
    cand <- ids[role %in% c("crash", "follow") | (role != "shooter" & d0 <= G$crash_near)]
    if (length(defs) && length(cand)) {
      w0 <- max(s$f, s$f1 - G$box_before)
      w1 <- max(s$f1, min(s$f1 + G$box_after, reb_f[s$id], na.rm = TRUE))
      W <- trk[.((w0 - G$slow_half):(w1 + G$slow_half)), nomatch = 0L][, .(frame, pid, x = sgn * x, y = -sgn * y)]
      # The attacker's speed toward the hoop (ft/s), over SLOW_HALF frames either side.
      A <- W[pid %in% cand, .(frame, apid = pid, ax = x, ay = y)]
      setorder(A, apid, frame)
      A[, alen := sqrt((GLASS_HOOP_X - ax)^2 + ay^2)]
      A[, closing := (shift(alen, G$slow_half) - shift(alen, G$slow_half, type = "lead")) /
                     ((shift(frame, G$slow_half, type = "lead") - shift(frame, G$slow_half)) / 25), by = apid]
      A <- A[frame >= w0 & frame <= w1]
      A[, peak := cummax(fifelse(is.na(closing), 0, pmax(closing, 0))), by = apid]
      # Every attacker-defender pair at every frame of the window: is the defender in the spot between him and the hoop?
      J <- merge(A,
                 W[pid %in% defs & frame >= w0 & frame <= w1, .(frame, dpid = pid, dx = x, dy = y)],
                 by = "frame", allow.cartesian = TRUE)
      if (nrow(J)) {
        J[, `:=`(hx = GLASS_HOOP_X - ax, hy = -ay, vx = dx - ax, vy = dy - ay)]
        J[, len := pmax(sqrt(hx^2 + hy^2), 1e-6)]
        J[, `:=`(gap = sqrt(vx^2 + vy^2), dd = sqrt((GLASS_HOOP_X - dx)^2 + dy^2))]
        J[, fits := dd < len & gap <= G$box_near & (vx * hx + vy * hy) / len > 0 & abs(vx * hy - vy * hx) / len <= G$box_lane]
        setorder(J, apid, dpid, frame)
        # Held: in the spot for BOX_FRAMES frames, in contact there at least once (within BOX_TOUCH ft), and never
        # beaten afterwards (the attacker more than BOX_BEAT ft closer to the hoop than the defender at any later
        # frame of the window). That decides a box-out. When it starts (display only): the first frame the attacker
        # stalled in contact (his speed toward the hoop under BOX_SLOW ft/s or under BOX_DROP of his peak: the
        # defender stopped him); failing that, the first frame in contact.
        K <- J[, {
          f_fit <- if (any(fits)) frame[which(fits)[1]] else NA_integer_
          touch <- fits & gap <= G$box_touch
          stall <- touch & !is.na(closing) & (closing < G$box_slow | closing < G$box_drop * peak)
          .(n = sum(fits), gap = mean(gap), contact = any(touch),
            start = if (any(stall)) frame[which(stall)[1]] else if (any(touch)) frame[which(touch)[1]] else NA_integer_,
            beaten = !is.na(f_fit) && any(frame > f_fit & len < dd - G$box_beat))
        }, by = .(apid, dpid)][beaten == FALSE & contact == TRUE]
        for (j in which(ids %in% J$apid)) {
          k <- K[apid == ids[j] & n >= G$box_frames][order(-n, gap)]
          m <- mu[off == ids[j] & f0 <= s$f & f1 >= s$f]$def
          pick <- if (length(m) && m[1] %in% k$dpid) m[1] else if (nrow(k)) k$dpid[1] else NA_integer_
          boxed[j] <- !is.na(pick)
          boxer[j] <- pick
          if (!is.na(pick)) {
            bf[j] <- k[dpid == pick, start]
            b1[j] <- w1
          }
        }
      }
    }
    # Share of the flight's frames in which each attacker was detected on camera.
    seen <- vapply(ids, function(p) {
      w <- trk[.(s$f:s$f1, p), det]
      if (all(is.na(w))) NA_real_ else round(mean(w == 1L, na.rm = TRUE), 2)
    }, 0)
    rows[[i]] <- data.table(f = s$f, f1 = s$f1, shot = s$id, poss = s$poss, made = s$made, pid = ids, role = role,
                            d0 = round(d0, 1), d1 = round(d1, 1), boxed = boxed, boxer = boxer, bf = bf, b1 = b1, rd = rd, seen = seen)
  }
  out <- rbindlist(rows)
  if (!nrow(out)) NULL else out
}
