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
#           and finished within CRASH_REACH ft
#   back    getting back: moved at least BACK_GAIN ft toward his own end, or finished in the backcourt
#   safety  already back: started at least SAFETY_FAR ft from the hoop, the deepest attacker, and stayed there
#   hold    everyone else: kept his spot (a corner shooter staying to space, a big already in the paint who did not
#           move is a crash, by CRASH_NEAR)
# The shooter is labelled separately: "follow" if he crashed after his own shot, else "shooter".
#
# Box-outs: a crasher is "met" when his assigned defender at release (matchups) ends the flight between him and the
# hoop: closer to the hoop, within BOX_NEAR ft of him, and within BOX_LANE ft of the straight line from him to the
# hoop. An earlier geometric box-out detector failed its stability checks (decision log, 2026-11-05: one-foot moves
# changed pairings), so this is a coarse flag about whether a crash was contested, not a skill measure.
#
# Seen: the share of the window's frames in which the player was detected on camera (not extrapolated). The camera
# follows the ball, so players getting back are often off screen; every role carries it so it can be filtered.

GLASS <- list(crash_near = 8, crash_gain = 4, crash_reach = 15, back_gain = 3, safety_far = 28,
              box_near = 5, box_lane = 3, max_flight = 75L, reach = 2L)
GLASS_HOOP_X <- 14 * 3.28084 - 1.575 * 3.28084

#' One row per attacker per shot: f, f1 (frames), shot id, pid, role, d0/d1 (ft from the hoop at release and at the
#' end of the flight), boxed (crashers only), seen (0-1), made (the shot), plus the shot's possession.
game_glass <- function(game_id, ev) {
  G <- GLASS
  gid <- game_id
  trk <- a$get_tracking(a$app_data, gid)$players[, .(frame, pid, x, y, det)]
  setkey(trk, frame, pid)
  left <- setNames(ann_lgl(ev$possessions, "leftHoop"), ann_chr(ev$possessions, "id"))
  sh <- data.table(id = ann_chr(ev$shots, "id"), f = ann_int(ev$shots, "startFrame"), f1 = ann_int(ev$shots, "endFrame"),
                   shooter = ann_int(ev$shots, "shooterId"), chance = ann_chr(ev$shots, "chanceId"),
                   poss = ann_chr(ev$shots, "possessionId"), made = ann_lgl(ev$shots, "outcome"))[!is.na(f) & !is.na(f1)]
  sh[, f1 := pmin(pmax(f1, f + 1L), f + G$max_flight)]
  cp <- data.table(chance = ann_chr(ev$chance_players, "chanceId"), pid = ann_int(ev$chance_players, "playerId"),
                   off = ann_lgl(ev$chance_players, "offense"))[off == TRUE]
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
  for (i in seq_len(nrow(sh))) {
    s <- sh[i]
    sgn <- if (isTRUE(left[s$poss])) -1 else 1
    ids <- unique(cp[chance == s$chance, pid])
    if (!length(ids)) next
    p0 <- spot(s$f, ids, sgn); p1 <- spot(s$f1, ids, sgn)
    ok <- !is.na(p0[, 1]) & !is.na(p1[, 1])
    if (!any(ok)) next
    ids <- ids[ok]; p0 <- p0[ok, , drop = FALSE]; p1 <- p1[ok, , drop = FALSE]
    d0 <- sqrt((GLASS_HOOP_X - p0[, 1])^2 + p0[, 2]^2); d1 <- sqrt((GLASS_HOOP_X - p1[, 1])^2 + p1[, 2]^2)
    crash <- d1 <= G$crash_near | (d0 - d1 >= G$crash_gain & d1 <= G$crash_reach)
    back <- (p0[, 1] - p1[, 1] >= G$back_gain) | p1[, 1] < 0
    deepest <- d0 == max(d0[ids != s$shooter])
    role <- fifelse(crash, "crash", fifelse(back, "back", fifelse(d0 >= G$safety_far & deepest & d1 >= G$safety_far, "safety", "hold")))
    role[ids == s$shooter] <- ifelse(crash[ids == s$shooter] & d0[ids == s$shooter] - d1[ids == s$shooter] >= G$crash_gain, "follow", "shooter")
    # Box-outs: the crasher's matchup at release, at the end of the flight.
    boxed <- rep(NA, length(ids))
    for (j in which(role == "crash")) {
      m <- mu[off == ids[j] & f0 <= s$f & f1 >= s$f]
      if (!nrow(m)) next
      dp <- spot(s$f1, m$def[1], sgn)
      if (is.na(dp[1, 1])) next
      hx <- GLASS_HOOP_X - p1[j, 1]; hy <- -p1[j, 2]; len <- sqrt(hx^2 + hy^2)
      vx <- dp[1, 1] - p1[j, 1]; vy <- dp[1, 2] - p1[j, 2]
      along <- if (len > 1e-6) (vx * hx + vy * hy) / len else 0
      lane <- if (len > 1e-6) abs(vx * hy - vy * hx) / len else sqrt(vx^2 + vy^2)
      d_def <- sqrt((GLASS_HOOP_X - dp[1, 1])^2 + dp[1, 2]^2)
      boxed[j] <- d_def < d1[j] & sqrt(vx^2 + vy^2) <= G$box_near & along > 0 & lane <= G$box_lane
    }
    seen <- vapply(ids, function(p) {
      w <- trk[.(s$f:s$f1, p), det]
      if (all(is.na(w))) NA_real_ else round(mean(w == 1L, na.rm = TRUE), 2)
    }, 0)
    rows[[i]] <- data.table(f = s$f, f1 = s$f1, shot = s$id, poss = s$poss, made = s$made, pid = ids, role = role,
                            d0 = round(d0, 1), d1 = round(d1, 1), boxed = boxed, seen = seen)
  }
  out <- rbindlist(rows)
  if (!nrow(out)) NULL else out
}
