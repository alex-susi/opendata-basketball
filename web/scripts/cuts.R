# Off-ball cuts, found from the tracking (sourced by annotations.R; `a` is the loaded Shiny app). SkillCorner marks
# only the cuts that use an off-ball screen (off_ball_screens: the cutter and the screen's frame); the rest are found
# here. The site draws them (ann.cuts) and the play list filters on them (plays.json types).
#
# Positions are turned into the viewer's frame (the offense attacking the hoop at +x) and smoothed over 5 frames
# within unbroken runs, and velocity is the centred difference of the smoothed positions (steps over 35 ft/s left
# out), as the site's motion.ts does.
#   basket  an attacker without the ball, in the frontcourt, in live play, running at least MIN_SPEED ft/s with at
#           least MIN_TOWARD ft/s of it toward the hoop, for at least MIN_FRAMES (gaps of up to GAP frames bridged),
#           gaining at least MIN_GAIN ft on the basket, starting within MAX_START ft of it (not a transition sprint
#           from deep) and ending within MAX_END ft (in or near the paint)
#   in/out  every off-ball screen's cutter: his run through the screen, from LEAD frames before it until he slows
#           below SETTLE ft/s or AFTER frames pass (or gets the ball); "in" if it ends closer to the basket than it
#           started, "out" if further. A basket cut it overlaps becomes that screen cut ("in").
#   pop     a pick-and-pop: the screener of a SkillCorner pick, followed from the screen for up to POP_WIN frames (or
#           until he gets the ball), set at least POP_SET ft from the hoop, who does not roll (never within ROLL_NEAR
#           ft of the hoop and never ROLL_GAIN ft closer than at the screen) and ends at least POP_END ft out, either
#           having moved POP_AWAY ft further from the hoop or finishing beyond the arc after running at least
#           POP_RUN ft. The run is drawn like a cut; the coverage is the one on the screener (scrDefType).

CUT_RULES <- list(min_speed = 9, min_toward = 7, min_frames = 12L, gap = 3L, min_gain = 8, max_start = 32, max_end = 14,
                  lead = 12L, after = 50L, settle = 6, max_speed = 35,
                  pop_win = 62L, pop_set = 12, roll_near = 10, roll_gain = 6, pop_end = 16, pop_away = 3, pop_run = 4)
CUT_THREE_R <- 6.75 * 3.28084
CUT_THREE_Y <- 6.6 * 3.28084
CUT_M <- 3.28084
CUT_HOOP_X <- 14 * CUT_M - 1.575 * CUT_M

#' The cuts of one game: f, f1 (tracking frames), pid, kind (basket, in, out, pop) and the coverage on the cutter (on
#' the screener for a pop).
game_cuts <- function(game_id, ev, screens) {
  R <- CUT_RULES
  trk <- a$get_tracking(a$app_data, game_id)
  gid <- game_id
  roster <- a$app_data$roster[game_id == gid]
  ps <- data.table(f0 = ann_int(ev$possessions, "startFrame"), f1 = ann_int(ev$possessions, "endFrame"),
                   off = ann_int(ev$possessions, "offTeamId"), left = ann_lgl(ev$possessions, "leftHoop"))[order(f0)]
  tc <- data.table(pid = ann_int(ev$touches, "playerId"), f0 = ann_int(ev$touches, "startFrame"),
                   f1 = ann_int(ev$touches, "endFrame"))[!is.na(f0) & !is.na(f1)]

  d <- merge(trk$players[, .(frame, pid, x, y)], trk$frames[, .(frame, stopped)], by = "frame")
  k <- findInterval(d$frame, ps$f0)
  inside <- k > 0L & d$frame <= ps$f1[pmax(k, 1L)]
  d[, `:=`(off_team = fifelse(inside, ps$off[pmax(k, 1L)], NA_integer_),
           sgn = fifelse(inside, fifelse(ps$left[pmax(k, 1L)], -1, 1), NA_real_),
           team = roster$team_id[match(pid, roster$pid)])]
  d <- d[!is.na(sgn) & team == off_team]
  # The viewer's frame: the offense attacks +x (y's sign does not matter here).
  d[, `:=`(x = sgn * x, y = -sgn * y)]
  setorder(d, pid, frame)
  d[, run := cumsum(c(TRUE, diff(frame) != 1L)), by = pid]
  # Smoothed positions: the mean of the frames within 2 either side, in the same run.
  sm <- function(v) {
    s <- v; n <- rep(1, length(v))
    for (h in c(-2L, -1L, 1L, 2L)) {
      w <- shift(v, h)
      ok <- !is.na(w)
      s[ok] <- s[ok] + w[ok]; n[ok] <- n[ok] + 1
    }
    s / n
  }
  d[, `:=`(sx = sm(x), sy = sm(y)), by = .(pid, run)]
  d[, `:=`(pa = shift(sx), pb = shift(sx, -1L), qa = shift(sy), qb = shift(sy, -1L)), by = .(pid, run)]
  d[, steps := (!is.na(pa)) + (!is.na(pb))]
  d[, `:=`(vx = (fcoalesce(pb, sx) - fcoalesce(pa, sx)) * 25 / pmax(steps, 1),
           vy = (fcoalesce(qb, sy) - fcoalesce(qa, sy)) * 25 / pmax(steps, 1))]
  d[steps == 0L, c("vx", "vy") := NA_real_]
  d[, speed := sqrt(vx^2 + vy^2)]
  d[speed > R$max_speed, c("vx", "vy", "speed") := NA_real_]
  # On the ball: inside one of his touches.
  d[, hold := FALSE]
  d[tc, on = .(pid, frame >= f0, frame <= f1), hold := TRUE]
  d[, hoop := sqrt((CUT_HOOP_X - x)^2 + y^2)]
  d[, toward := fifelse(hoop > 1e-6, (vx * (CUT_HOOP_X - x) - vy * y) / hoop, 0)]
  d[, ok := !stopped & !is.na(speed) & x > 0 & !hold & speed >= R$min_speed & toward >= R$min_toward]

  # Basket cuts: runs of qualifying frames, bridging up to GAP missed frames.
  o <- d[ok == TRUE, .(pid, frame, hoop)]
  o[, seg := cumsum(c(TRUE, pid[-1] != pid[-.N] | (frame[-1] - frame[-.N] - 1L) > R$gap))]
  basket <- o[, .(f = frame[1], f1 = frame[.N], d0 = hoop[1], d1 = hoop[.N]), by = .(pid, seg)][
    f1 - f >= R$min_frames & d0 - d1 >= R$min_gain & d0 <= R$max_start & d1 <= R$max_end,
    .(f, f1, pid, kind = "basket", cov = NA_character_)]

  # Cuts through off-ball screens.
  obs <- if (is.null(screens)) NULL else screens[kind == "off_ball_screen" & !is.na(use)]
  out <- copy(basket)
  for (i in seq_len(if (is.null(obs)) 0L else nrow(obs))) {
    s <- obs[i]
    p <- d[pid == s$use & frame >= s$f - R$lead & frame <= s$f + R$after]
    if (!nrow(p) || !any(p$frame >= s$f)) next
    at <- which(p$frame >= s$f)[1]
    a0 <- 1L
    b <- at
    if (at < nrow(p)) for (t in (at + 1L):nrow(p)) {
      if (p$frame[t] - p$frame[t - 1L] != 1L || p$hold[t]) break
      b <- t
      if (p$frame[t] - s$f > 6 && !is.na(p$speed[t]) && p$speed[t] < R$settle) break
    }
    # The run starts at the first frame of the unbroken stretch leading into the screen.
    if (at > 1L) for (t in (at - 1L):1L) { if (p$frame[t + 1L] - p$frame[t] != 1L) { a0 <- t + 1L; break } }
    if (b <= a0) next
    g0 <- p$frame[a0]; g1 <- p$frame[b]
    hit <- which(out$pid == s$use & out$f <= g1 + 6 & out$f1 >= g0 - 6)
    if (length(hit)) {
      j <- hit[1]
      out[j, `:=`(f = min(f, g0), f1 = max(f1, g1), kind = "in", cov = s$covUse)]
      next
    }
    out <- rbind(out, data.table(f = g0, f1 = g1, pid = s$use, kind = if (p$hoop[b] < p$hoop[a0]) "in" else "out",
                                 cov = s$covUse))
  }

  # Pick-and-pops: the screener's run after his screen, if he moves out instead of rolling.
  pk <- if (is.null(screens)) NULL else screens[kind == "pick" & !is.na(scr)]
  for (i in seq_len(if (is.null(pk)) 0L else nrow(pk))) {
    s <- pk[i]
    p <- d[pid == s$scr & frame >= s$f & frame <= s$f + R$pop_win]
    if (nrow(p) < 10 || p$frame[1] - s$f > 3) next
    # Unbroken from the screen, up to and including the frame he gets the ball.
    brk <- which(diff(p$frame) != 1L)
    if (length(brk)) p <- p[seq_len(brk[1])]
    got <- which(p$hold)
    if (length(got)) p <- p[seq_len(got[1])]
    if (nrow(p) < 10) next
    h0 <- p$hoop[1]; h1 <- p$hoop[nrow(p)]
    if (h0 < R$pop_set || min(p$hoop) <= R$roll_near || h0 - min(p$hoop) >= R$roll_gain || h1 < R$pop_end) next
    dx <- CUT_HOOP_X - p$x[nrow(p)]
    arc <- if (dx <= sqrt(CUT_THREE_R^2 - CUT_THREE_Y^2)) abs(p$y[nrow(p)]) >= CUT_THREE_Y else h1 >= CUT_THREE_R
    run <- sum(sqrt(diff(p$sx)^2 + diff(p$sy)^2), na.rm = TRUE)
    if (!(h1 - h0 >= R$pop_away || (arc && run >= R$pop_run))) next
    out <- rbind(out, data.table(f = s$f, f1 = p$frame[nrow(p)], pid = s$scr, kind = "pop", cov = s$covScr))
  }
  if (!nrow(out)) return(NULL)
  out[order(f)]
}
