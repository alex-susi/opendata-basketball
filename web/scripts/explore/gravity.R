# Topic: off-ball gravity of shooters, rollers and cutters.
#
# Gravity here is how much defensive attention a player draws when he does not have the ball. Two views:
#
# 1. Spot-up gravity (shooters). Frames: every 5th frame of half-court play (frontcourt frame to the shot, game clock
#    running, a ball holder on offense, all ten players tracked). For each attacker without the ball: the distance to
#    his nearest defender, his floor zone and his distance from the ball. "Expected" room is the mean over all
#    attackers in the same zone and ball-distance band; a player's gravity is expected minus actual (positive = the
#    defense stays closer to him than to a typical player in the same spot). Ball-distance bands: under 15, 15-22,
#    22-30, 30+ ft. Spot-up frames: on the perimeter, 15+ ft from the ball, and not within 1 s before to 2 s after
#    his own screen or off-ball-screen cut.
# 2. Run gravity (rollers and cutters). Rolls: the screener of a pick who, within 2.5 s, ends within 10 ft of the hoop
#    or 6 ft closer to it (the archetype rule). Cuts: the site's basket cuts and cuts through off-ball screens toward
#    the hoop (web/scripts/cuts.R). At the moment the runner is nearest the hoop: defenders within PULL ft of him
#    other than his own matchup ("help pulled"), and how much room the ball holder and the other attackers had.

GRAV <- list(step = 5L, pull = 8, roll_win = 62L, roll_near = 10, roll_gain = 6)

topic_gravity <- function(BL) {
  FR <- list(); RUN <- list(); TEAMF <- list(); ON <- list()
  for (B in BL) {
    ch <- B$ch[in_pop == TRUE & transition == FALSE & !is.na(front) & cut_f > pmax(c0, front)]
    fr <- ch[, .(frame = seq(pmax(c0, front), cut_f, by = GRAV$step)), by = .(chance, pts)]
    fr <- merge(fr, B$Fr[stopped == FALSE & !is.na(holder), .(frame, holder)], by = "frame")
    W <- B$P[.(unique(fr$frame)), nomatch = 0L]
    W <- W[, if (.N == 10L && sum(off) == 5L) .SD, by = frame]
    W <- merge(W, fr[, .(frame, holder, chance)], by = "frame")
    W <- W[, if (any(off & pid == holder)) .SD, by = frame]
    H <- W[pid == holder, .(frame, hpid = pid, hx = x, hy = y)]
    A <- merge(W[off == TRUE & pid != holder, .(frame, chance, pid, ax = x, ay = y, det)], H, by = "frame")
    D <- W[off == FALSE, .(frame, dpid = pid, dx = x, dy = y)]
    J <- merge(A[, .(frame, pid, ax, ay)], D, by = "frame", allow.cartesian = TRUE)[, .(near = min(sqrt((ax - dx)^2 + (ay - dy)^2))), by = .(frame, pid)]
    A <- merge(A, J, by = c("frame", "pid"))
    A[, `:=`(zone = floor_zone(ax, ay), bdist = sqrt((ax - hx)^2 + (ay - hy)^2))]
    A[, mark := marker_of(B, frame, pid)]
    A[D, on = .(frame, mark = dpid), `:=`(mx = i.dx, my = i.dy)]
    A[, mark_gap := sqrt((mx - ax)^2 + (my - ay)^2)]
    # Help position: how far the marker sits from his man toward the ball (0 = on him, 1 = at the ball).
    A[, toward := { vx <- hx - ax; vy <- hy - ay; ((mx - ax) * vx + (my - ay) * vy) / pmax(vx^2 + vy^2, 1e-6) }]
    A[, `:=`(game = B$game, canon = B$roster$canon[match(pid, B$roster$pid)], name = B$roster$name[match(pid, B$roster$pid)],
             team = B$roster$team_name[match(pid, B$roster$pid)])]
    # Busy: within 1 s before to 2 s after setting a screen (pick, handoff, off-ball screen) or using an off-ball
    # screen, when a defender is near him because of the action rather than his threat.
    busy <- rbind(B$picks[, .(pid = screener, f0)], B$handoffs[, .(pid = screener, f0)], B$obs[, .(pid = screener, f0)],
                  B$obs[, .(pid = actor, f0)])[!is.na(pid) & !is.na(f0)][, `:=`(a0 = f0 - 25L, a1 = f0 + 50L)]
    A[, busy := FALSE]
    if (nrow(busy)) A[busy, on = .(pid, frame >= a0, frame <= a1), busy := TRUE]
    FR[[length(FR) + 1]] <- A
    # Frame-level: the holder's room and defenders in the key, for "shooters spaced" counts.
    hf <- merge(H, D, by = "frame", allow.cartesian = TRUE)[, .(holder_open = min(sqrt((hx - dx)^2 + (hy - dy)^2)), def_paint = sum(in_paint(dx, dy))), by = frame]
    # On-ball frames for the four-situation table: the holder, his spot and his room.
    ob <- merge(H, hf[, .(frame, near = holder_open)], by = "frame")
    ON[[length(ON) + 1]] <- ob[, .(frame, canon = B$roster$canon[match(hpid, B$roster$pid)], name = B$roster$name[match(hpid, B$roster$pid)],
                                   team = B$roster$team_name[match(hpid, B$roster$pid)], x = hx, y = hy, near, game = B$game)]
    TEAMF[[length(TEAMF) + 1]] <- merge(hf, A[, .(spaced = list(canon[zone %in% c("corner three", "above-break three", "deep")])), by = frame], by = "frame")[, game := B$game]

    # Runs: rolls and cuts.
    pk <- B$picks[!is.na(screener)]
    rolls <- rbindlist(lapply(seq_len(nrow(pk)), function(k) {
      p <- pk[k]
      fr_ <- p$f0 + 0:GRAV$roll_win
      pp <- pos_at(B, fr_, rep(p$screener, length(fr_)))
      if (all(is.na(pp$x))) return(NULL)
      d <- hoop_dist(pp$x, pp$y)
      j <- which.min(d)
      if (!(d[j] <= GRAV$roll_near || d[1] - d[j] >= GRAV$roll_gain) || is.na(d[1])) return(NULL)
      data.table(kind = "roll", pid = p$screener, f = fr_[j], f0 = p$f0, chance = p$chance, d0 = d[1], d1 = d[j])
    }))
    cuts <- if (nrow(B$cuts)) B$cuts[kind %in% c("basket", "in")] else data.table()
    if (nrow(cuts)) {
      cho <- B$ch[order(c0)]
      k <- findInterval(cuts$f, cho$c0)
      cuts[, chance := fifelse(k > 0 & f <= cho$c1[pmax(k, 1)], cho$chance[pmax(k, 1)], NA_character_)]
      cuts <- cuts[!is.na(chance)]
      cuts <- cuts[, .(kind = fifelse(kind == "basket", "basket cut", "screen cut"), pid, f = f1, f0 = f, chance)]
    }
    # Pick-and-pops (cuts.R): the screener moving out after the screen, measured where his pop ends.
    pops <- if (nrow(B$cuts)) B$cuts[kind == "pop"] else data.table()
    if (nrow(pops)) {
      pops <- merge(pops[, .(pid, f0 = f, f = f1, cov)], B$picks[, .(f0, pid = screener, chance)], by = c("f0", "pid"))
      pops[, kind := "pop"]
      cuts <- rbind(cuts, pops, fill = TRUE)
    }
    runs <- rbind(rolls, cuts, fill = TRUE)
    if (nrow(runs)) {
      runs[, poss0 := B$Fr$poss[match(f0, B$Fr$frame)]]
      Wr <- B$P[.(unique(runs$f)), nomatch = 0L]
      rp <- merge(runs, Wr[, .(f = frame, pid, rx = x, ry = y, rposs = poss)], by = c("f", "pid"))
      rp <- rp[rposs == poss0]
      rp[, mark := marker_of(B, f, pid)]
      Jr <- merge(rp[, .(f, pid, rx, ry, mark)], Wr[off == FALSE, .(f = frame, dpid = pid, dx = x, dy = y)], by = "f", allow.cartesian = TRUE)
      Jr[, dd := sqrt((dx - rx)^2 + (dy - ry)^2)]
      pulled <- Jr[, .(help_pulled = sum(dd <= GRAV$pull & (is.na(mark) | dpid != mark)), att = sum(dd <= GRAV$pull), near = min(dd),
                       own_gap = if (any(dpid == mark, na.rm = TRUE)) dd[which(dpid == mark)[1]] else NA_real_), by = .(f, pid)]
      rp <- merge(rp, pulled, by = c("f", "pid"))
      # Did the runner shoot within 2 s of the end of his run?
      sh <- B$shots[fga == TRUE, .(pid, sf = f, s_xpts = xpts, s_made = made, s_three = three)]
      rp[, `:=`(f50 = f + 50L, shot = FALSE, s_xpts = NA_real_, s_made = NA, s_three = NA)]
      rp[sh, on = .(pid, f <= sf, f50 >= sf), `:=`(shot = TRUE, s_xpts = i.s_xpts, s_made = i.s_made, s_three = i.s_three)]
      rp[, f50 := NULL]
      # Room for everyone else at that moment.
      G <- frame_geom(B, unique(rp$f))
      rp <- merge(rp, G[, .(f = frame, holder_open, open_mean, def_paint)], by = "f", all.x = TRUE)
      rp <- merge(rp, B$ch[, .(chance, pts, xpts, transition)], by = "chance")
      rp[, `:=`(game = B$game, canon = B$roster$canon[match(pid, B$roster$pid)], name = B$roster$name[match(pid, B$roster$pid)],
                team = B$roster$team_name[match(pid, B$roster$pid)])]
      RUN[[length(RUN) + 1]] <- rp
    }
  }
  A <- rbindlist(FR, fill = TRUE); R <- rbindlist(RUN, fill = TRUE); TF <- rbindlist(TEAMF, fill = TRUE)
  A[, zone4 := fifelse(zone %in% c("rim", "paint"), "paint", fifelse(zone == "deep", "above-break three", zone))]
  A <- A[zone4 != "backcourt"]
  A[, bband := cut(bdist, c(-Inf, 15, 20, 25, 30, Inf), labels = c("under 15 ft", "15-20 ft", "20-25 ft", "25-30 ft", "30+ ft"))]
  exp_tab <- A[, .(exp_near = mean(near), n = .N), by = .(zone4, bband)]
  A <- merge(A, exp_tab[, .(zone4, bband, exp_near)], by = c("zone4", "bband"))
  A[, grav := exp_near - near]
  # Spot-up frames: on the perimeter and at least 15 ft from the ball, so screeners and handoff partners next to the
  # ball (whose defenders are near them because of the action) are left out.
  A[, spot := zone4 %in% c("corner three", "above-break three") & bdist >= 15 & !busy]
  zone_lv <- c("corner three", "above-break three", "mid-range", "paint")
  band_lv <- levels(A$bband)

  prof <- SP[, .(canon, three_per100, three_shrunk, drives_per100, three_att, archetype)]
  A <- merge(A, prof, by = "canon", all.x = TRUE)
  lg3 <- attr(SP, "league_three")
  per <- A[spot == TRUE, .(frames = .N, grav = mean(grav), near = mean(near), mark_gap = mean(mark_gap, na.rm = TRUE),
                                                             toward = mean(toward, na.rm = TRUE), name = name[1], team = team[1],
                                                             v3 = three_per100[1], p3 = three_shrunk[1], arch = archetype[1]), by = canon][frames >= 100]
  per <- per[order(-grav)]
  per[, shooter := fifelse(is.na(v3), "no season profile", fifelse(v3 >= 10 & p3 >= lg3, "high-volume shooter",
                   fifelse(v3 >= 5, "some volume", "rarely shoots threes")))]
  sh_lv <- c("high-volume shooter", "some volume", "rarely shoots threes")
  A[, shooter := per$shooter[match(canon, per$canon)]]
  A[is.na(shooter), shooter := fifelse(is.na(three_per100), "no season profile", fifelse(three_per100 >= 10 & three_shrunk >= lg3, sh_lv[1], fifelse(three_per100 >= 5, sh_lv[2], sh_lv[3])))]
  rr_v <- per[!is.na(v3), cor(grav, v3)]
  rr_p <- per[!is.na(p3), cor(grav, p3)]

  arch <- A[spot == TRUE & !is.na(archetype), .(grav = mean(grav), frames = .N, players = uniqueN(canon)), by = archetype][players >= 3][order(-grav)]
  arch_in <- A[zone4 == "paint" & !is.na(archetype), .(grav = mean(grav), frames = .N, players = uniqueN(canon)), by = archetype][players >= 3][order(-grav)]

  # Shooters spaced on the floor and the holder's room.
  shooters <- per[shooter == sh_lv[1]]$canon
  TF[, n_shooters := vapply(spaced, function(s) sum(s %in% shooters), 0L)]
  TF[, n_spaced := lengths(spaced)]
  TF[, nsb := factor(pmin(n_shooters, 3), 0:3, c("0", "1", "2", "3+"))]
  TF[, nspb := factor(pmin(n_spaced, 4), 0:4, c("0", "1", "2", "3", "4"))]

  R[, kind := factor(kind, c("roll", "pop", "basket cut", "screen cut"))]
  R[, hpb := factor(pmin(help_pulled, 2), 0:2, c("0", "1", "2+"))]
  rp_pl <- R[transition == FALSE, .(runs = .N, rolls = sum(kind == "roll"), pops = sum(kind == "pop"), cuts = sum(kind %in% c("basket cut", "screen cut")),
                                    pulled = mean(help_pulled >= 1), help = mean(help_pulled), name = name[1], team = team[1], ppc = mean(pts)),
             by = canon][runs >= 10][order(-pulled)]
  P_ <- R[kind == "pop"]
  RL <- R[kind == "roll"]
  P_[, covl := fifelse(is.na(cov) | cov == "none", "none called", cov)]
  cov_lv <- P_[, .N, by = covl][N >= 8][order(-N)]$covl

  # ---- four situations, after the NBA's split: on or off the ball, perimeter (over 20 ft from the hoop) or interior.
  # Expected room is the mean over every attacker in the same situation, hoop-distance band and (off the ball)
  # ball-distance band; gravity is expected minus actual. Minutes count the sampled half-court frames (0.2 s each).
  ONB <- rbindlist(ON)
  SIT <- rbind(A[, .(canon, name, team, role = "off", x = ax, y = ay, bdist, near)],
               ONB[, .(canon, name, team, role = "on", x, y, bdist = NA_real_, near)])[x > 0]
  SIT[, hd := hoop_dist(x, y)]
  SIT[, loc := fifelse(hd > 20, "perimeter", "interior")]
  SIT[, hb := cut(hd, c(-Inf, 4, 8, 12, 16, 20, 24, 28, Inf))]
  SIT[, bb := fifelse(role == "on", "on", as.character(cut(bdist, c(-Inf, 10, 15, 20, 25, 30, Inf))))]
  SIT[, gv := mean(near) - near, by = .(role, hb, bb)]
  MIN_PER_FRAME <- GRAV$step / FPS / 60
  sit <- SIT[, .(min = .N * MIN_PER_FRAME, gv = mean(gv)), by = .(canon, role, loc)]
  sit[, key := paste(role, loc, sep = "_")]
  wide <- dcast(sit, canon ~ key, value.var = c("min", "gv"))
  for (k in c("on_perimeter", "on_interior", "off_perimeter", "off_interior")) {
    for (v in c("min_", "gv_")) if (!paste0(v, k) %in% names(wide)) wide[, (paste0(v, k)) := NA_real_]
    wide[is.na(get(paste0("min_", k))), (paste0("min_", k)) := 0]
    wide[get(paste0("min_", k)) < 0.5, (paste0("gv_", k)) := NA_real_]
  }
  tot <- SIT[, .(min_all = .N * MIN_PER_FRAME, gv_all = mean(gv), name = name[1], team = team[1]), by = canon]
  wide <- merge(tot, wide, by = "canon")
  wide <- merge(wide, SP[, .(canon, arch = archetype)], by = "canon", all.x = TRUE)[min_all >= 3][order(-gv_all)]
  sit_sum <- SIT[, .(min = .N * MIN_PER_FRAME, room = mean(near), players = uniqueN(canon)), by = .(role, loc)]
  g_col <- function(key, label, grp, what) {
    if (what == "min") col(paste0("min_", key), label, "num1", group = grp, title = sprintf("Minutes %s (half-court frames, all ten players tracked)", tolower(grp)))
    else col(paste0("gv_", key), label, "num2", ref = 0, scale = 1.2, group = grp,
             title = sprintf("Gravity %s. Expected room minus actual room in ft, positive means tighter than typical. Blank under half a minute", tolower(grp)))
  }

  # ---- data for the room explorer (GravityRoom.svelte): one row per sampled off-ball frame, every 3rd.
  al <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
  canon_of <- function(p) { m <- al$canonical_player_id[match(p, al$player_id)]; fifelse(is.na(m), p, m) }
  sa <- fread(file.path(a$root, "data", "aggregates", "acb_shotsaggregates_20252026.csv"))
  sa[, canon := canon_of(player_id)]
  tots <- sa[is.na(team_id) | team_name == "total"]
  sa <- sa[!(canon %in% tots$canon) | is.na(team_id) | team_name == "total"]
  zs <- sa[, .(poss = sum(possessions_played), corner = sum(zone_corner_3_attempts), abv = sum(zone_above_break_3_attempts),
               mid = sum(zone_mid_range_attempts), paint = sum(zone_paint_non_ra_attempts), rim = sum(zone_restricted_area_attempts)), by = canon][poss >= 100]
  zone_col <- c("corner three" = "corner", "above-break three" = "abv", "deep" = "abv", "mid-range" = "mid", "paint" = "paint", "rim" = "rim")
  zlong <- melt(zs, id.vars = c("canon", "poss"), variable.name = "zc", value.name = "att")[, per100 := 100 * att / poss]
  cuts3 <- zlong[poss >= 300, .(q1 = quantile(per100, 1 / 3), q2 = quantile(per100, 2 / 3)), by = zc]
  zlong <- merge(zlong, cuts3, by = "zc")
  zlong[, tend := fifelse(per100 < q1, 0L, fifelse(per100 < q2, 1L, 2L))]
  W8 <- A[seq(1L, .N, by = 3L), .(canon, zc = unname(zone_col[zone]), px = ax, py = ay, bx = hx, by = hy, room = near)][!is.na(zc)]
  W8 <- merge(W8, zlong[, .(canon, zc = as.character(zc), tend)], by = c("canon", "zc"))
  zone_names <- c(corner = "corner three", abv = "above-break three", mid = "mid-range", paint = "paint (outside the restricted area)", rim = "restricted area")
  room_doc <- list(built = format(Sys.time(), "%Y-%m-%d %H:%M"), n = nrow(W8), scale = list(pos = 2, room = 10), hoop = HOOP_X,
                   px = as.integer(round(2 * W8$px)), py = as.integer(round(2 * W8$py)), bx = as.integer(round(2 * W8$bx)),
                   by = as.integer(round(2 * W8$by)), room = as.integer(round(10 * W8$room)), t = W8$tend,
                   cuts = lapply(names(zone_names), function(z) list(zone = zone_names[[z]], q1 = round(cuts3[zc == z]$q1, 1), q2 = round(cuts3[zc == z]$q2, 1))))
  write_json(room_doc, file.path(EX_OUT, "explore_gravity_room.json"), auto_unbox = TRUE, digits = NA)
  message("Wrote explore_gravity_room.json (", nrow(W8), " frames)")

  gs <- function(l) A[spot == TRUE & shooter == l, mean(grav)]
  sections <- list(
    SECTION("gv-question", "The question and the definitions",
      P("Gravity is the defensive attention a player draws. Following the NBA's Gravity stat, this tab splits it four ways, on or off the ball and on the perimeter or in the interior, and adds two closer looks."),
      BUL("**Gravity** = expected room minus actual room, in feet. Room is the distance to the nearest defender. Expected is the average for any attacker in the same situation and spot. Positive means defenders stayed closer than usual",
          "**Perimeter** = more than 20 ft from the hoop, **interior** = 20 ft or less (the NBA's split)",
          "**Spot-up gravity** looks only at shooters standing on the perimeter, away from the ball",
          "**Run gravity** counts the extra defenders a roll, cut or pick-and-pop pulls toward the runner"),
      KPIS(KPI("Half-court minutes", sprintf("%.0f", nrow(ONB) * MIN_PER_FRAME), "all ten players tracked"),
           KPI("Players with 3+ minutes", int(nrow(wide)), "in the four-situation table"),
           KPI("Rolls, pops and cuts", int(nrow(R)), sprintf("%s rolls, %s pops, %s cuts", int(nrow(RL)), int(nrow(P_)), int(sum(R$kind %in% c("basket cut", "screen cut"))))),
           KPI("Help pulled", pct(mean(R$help_pulled >= 1)), sprintf("of runs drew a second defender within %g ft", GRAV$pull))),
      CAVEAT("Room depends on the defense's scheme, the score and the other nine players as much as on the player",
             "Frames within a possession are not independent, so frame counts overstate the sample",
             "The NBA measures defensive pressure from its own model. This tab uses the simpler distance to the nearest defender")),
    SECTION("gv-situations", "Gravity in four situations",
      BUL(sprintf("On the ball, perimeter: %s minutes, average room %.1f ft", int(sit_sum[role == "on" & loc == "perimeter"]$min), sit_sum[role == "on" & loc == "perimeter"]$room),
          sprintf("On the ball, interior: %s minutes, average room %.1f ft", int(sit_sum[role == "on" & loc == "interior"]$min), sit_sum[role == "on" & loc == "interior"]$room),
          sprintf("Off the ball, perimeter: %s player-minutes, average room %.1f ft", int(sit_sum[role == "off" & loc == "perimeter"]$min), sit_sum[role == "off" & loc == "perimeter"]$room),
          sprintf("Off the ball, interior: %s player-minutes, average room %.1f ft", int(sit_sum[role == "off" & loc == "interior"]$min), sit_sum[role == "off" & loc == "interior"]$room)),
      TABLE("Players with 3+ tracked half-court minutes, by overall gravity", limit = 40, rows = wide, cols = list(
        col("name", "Player"), col("team", "Team"), col("arch", "Archetype"),
        g_col("all", "Min", "Overall", "min"), g_col("all", "Grav", "Overall", "gv"),
        g_col("on_perimeter", "Perim min", "On-ball", "min"), g_col("on_perimeter", "Perim grav", "On-ball", "gv"),
        g_col("on_interior", "Int min", "On-ball", "min"), g_col("on_interior", "Int grav", "On-ball", "gv"),
        g_col("off_perimeter", "Perim min", "Off-ball", "min"), g_col("off_perimeter", "Perim grav", "Off-ball", "gv"),
        g_col("off_interior", "Int min", "Off-ball", "min"), g_col("off_interior", "Int grav", "Off-ball", "gv")),
        note = "Minutes are half-court offense with all ten players on camera, about 10 per team per game, so samples are small. Hover a header for its definition."),
      TAKE(sprintf("%s minutes on the ball and %s off it per player on average in this table", num(mean(wide$min_on_perimeter + wide$min_on_interior), 1),
                   num(mean(wide$min_off_perimeter + wide$min_off_interior), 1)),
           sprintf("Overall gravity spans %.2f to %.2f ft across these players", min(wide$gv_all), max(wide$gv_all)),
           "On-ball interior gravity is the noisiest column, because few players hold the ball near the rim for long")),
    SECTION("gv-room", "How much room off-ball players get",
      P("Average distance from an attacker without the ball to his nearest defender, by where he stands and how far the ball is. This is the expected room spot-up players are compared with."),
      TABLE("Expected room (ft) by zone and distance from the ball", limit = 10, rows = dcast(exp_tab[zone4 != "backcourt"], zone4 ~ bband, value.var = "exp_near")[match(zone_lv, zone4)],
            cols = c(list(col("zone4", "Zone")), lapply(band_lv, function(b) col(b, paste("ball", b), "num1")))),
      GRID(
        RATES("Room in the corner, by shooter type", lapply(sh_lv, function(l) mrow(l, A[spot == TRUE & zone4 == "corner three" & shooter == l]$near)), fmt = "num1",
              ref = mean(A[spot == TRUE & zone4 == "corner three"]$near), unit = "ft to the nearest defender", label_width = 190),
        RATES("Room above the break, by shooter type", lapply(sh_lv, function(l) mrow(l, A[spot == TRUE & zone4 == "above-break three" & shooter == l]$near)), fmt = "num1",
              ref = mean(A[spot == TRUE & zone4 == "above-break three"]$near), unit = "ft to the nearest defender", label_width = 190),
        RATES("Spot-up gravity (expected − actual room), by shooter type", lapply(sh_lv, function(l) mrow(l, A[spot == TRUE & shooter == l]$grav)),
              fmt = "num2", ref = 0, refLabel = "typical", unit = "ft tighter than typical", label_width = 190),
        RATES("Marker's position toward the ball (0 = on his man, 1 = at the ball)", lapply(sh_lv, function(l) mrow(l, A[spot == TRUE & shooter == l]$toward)),
              fmt = "num2", ref = mean(A[spot == TRUE]$toward, na.rm = TRUE), unit = "of the way to the ball", label_width = 190)),
      H("Shooter types"),
      BUL("**High-volume shooter** = 10+ season three-point attempts per 100 possessions, at or above the league percentage",
          "**Some volume** = 5+ attempts per 100 possessions, or 10+ below the league percentage",
          "**Rarely shoots threes** = under 5 attempts per 100 possessions",
          sprintf("League three-point percentage is %s. Each player's percentage is shrunk toward it with 100 attempts of prior weight", pct(lg3, 1)),
          sprintf("Spot-up frames are on the perimeter, 15+ ft from the ball and not just after his own screen. %d players have 100 or more", nrow(per))),
      TAKE(sprintf("High-volume shooters were guarded %.2f ft tighter than a typical player in the same spot", gs(sh_lv[1])),
           sprintf("Players with some volume were %.2f ft and players who rarely shoot threes %.2f ft (negative means looser)", gs(sh_lv[2]), gs(sh_lv[3])),
           sprintf("Player by player, spot-up gravity barely tracks season shooting (correlation %.2f with volume, %.2f with percentage)", rr_v, rr_p),
           "Several bigs who rarely shoot top the player list on 100-200 frames, probably because they stand on the perimeter just before screening or when trailing the play"),
      H("Try it: expected room for any spot"),
      list(type = "widget", name = "gravity-room", data = "explore_gravity_room.json")),
    SECTION("gv-players", "Players: spot-up gravity",
      GRID(
        SCAT("Spot-up gravity against season three-point volume", points = per[!is.na(v3), .(x = r2(v3, 1), y = r2(grav, 2), g = as.integer(p3 < lg3),
                                                                                              tip = sprintf("%s\n%.2f ft tighter than typical\n%d frames\n%.1f 3PA per 100 possessions\n%.1f%% from three (shrunk)", name, grav, frames, v3, 100 * p3))],
             groups = c("3P% at or above league", "below league"), xlabel = "season 3PA per 100 possessions", ylabel = "gravity (ft)", radius = 4,
             lines = list(LINE(c(0, max(per$v3, na.rm = TRUE)), c(0, 0), color = "var(--muted)", dashed = TRUE))),
        SCAT("Spot-up gravity against shrunk three-point percentage", points = per[!is.na(p3), .(x = r2(p3, 3), y = r2(grav, 2), g = as.integer(v3 < 5),
                                                                                                  tip = sprintf("%s\n%.2f ft tighter than typical\n%.1f%% from three (shrunk)", name, grav, 100 * p3))],
             groups = c("5+ 3PA/100", "under 5"), xlabel = "season 3P% (shrunk)", ylabel = "gravity (ft)", xfmt = "pct1", radius = 4)),
      TABLE("Players with 100+ spot-up frames, by spot-up gravity", limit = 40, rows = per, cols = list(
        col("name", "Player"), col("team", "Team"), col("arch", "Archetype"), col("frames", "Frames", "int"),
        col("grav", "Gravity (ft)", "num2", ref = 0, scale = 1.5), col("near", "Room (ft)", "num1"), col("mark_gap", "Marker gap (ft)", "num1"),
        col("toward", "Marker toward ball", "num2"), col("v3", "3PA/100", "num1"), col("p3", "3P% (shrunk)", "pct1"))),
      GRID(
        TABLE("By offensive archetype, on the perimeter", limit = 12, rows = arch, cols = list(col("archetype", "Archetype"), col("players", "Players", "int"),
              col("frames", "Frames", "int"), col("grav", "Gravity (ft)", "num2", ref = 0, scale = 1))),
        TABLE("By offensive archetype, in the paint", limit = 12, rows = arch_in, cols = list(col("archetype", "Archetype"), col("players", "Players", "int"),
              col("frames", "Frames", "int"), col("grav", "Gravity (ft)", "num2", ref = 0, scale = 1))))),
    SECTION("gv-spacing", "Shooters on the floor and the ball handler's room",
      P("For every sampled frame, how many high-volume shooters were spotted beyond the arc, against the ball holder's room and the defenders in the key."),
      GRID(
        RATES("Ball holder's room by high-volume shooters spaced", lapply(levels(TF$nsb), function(l) mrow(l, TF[nsb == l]$holder_open)), fmt = "num2",
              ref = mean(TF$holder_open), unit = "ft to the nearest defender"),
        RATES("Defenders in the key by high-volume shooters spaced", lapply(levels(TF$nsb), function(l) mrow(l, TF[nsb == l]$def_paint)), fmt = "num2",
              ref = mean(TF$def_paint), unit = "defenders in the key"),
        RATES("Defenders in the key by any attackers spaced beyond the arc", lapply(levels(TF$nspb), function(l) mrow(l, TF[nspb == l]$def_paint)), fmt = "num2",
              ref = mean(TF$def_paint), unit = "defenders in the key"),
        RATES("Ball holder's room by any attackers spaced", lapply(levels(TF$nspb), function(l) mrow(l, TF[nspb == l]$holder_open)), fmt = "num2",
              ref = mean(TF$holder_open), unit = "ft to the nearest defender")),
      CAVEAT("These intervals treat frames as independent and are far too narrow. Read the direction, not the precision")),
    SECTION("gv-runs", "Rollers, poppers and cutters",
      BUL("**Roll** = the screener of a pick reaches 10 ft of the hoop, or gets 6 ft closer, within 2.5 s",
          "**Pop** = the screener moves out instead, ending 16+ ft from the hoop (web/scripts/cuts.R). Pops are also drawn in the play viewer and listed in its Action filter",
          "**Cut** = a basket cut, or a cut through an off-ball screen toward the hoop",
          sprintf("**Help pulled** = a defender other than his own within %g ft when the run ends", GRAV$pull)),
      GRID(
        RATES("Help pulled, by kind of run", lapply(levels(R$kind), function(l) rrow(l, sum(R[kind == l]$help_pulled >= 1), nrow(R[kind == l]))),
              ref = mean(R$help_pulled >= 1), unit = "pulled a defender other than his own"),
        RATES("Ball holder's room when the run ends", lapply(levels(R$kind), function(l) mrow(l, R[kind == l]$holder_open)), fmt = "num2",
              ref = mean(R$holder_open, na.rm = TRUE), unit = "ft to the nearest defender"),
        RATES("Other attackers' room when the run ends", lapply(levels(R$kind), function(l) mrow(l, R[kind == l]$open_mean)), fmt = "num2",
              ref = mean(R$open_mean, na.rm = TRUE), unit = "ft to the nearest defender"),
        RATES("Runner shot within 2 s", lapply(levels(R$kind), function(l) rrow(l, sum(R[kind == l]$shot), nrow(R[kind == l]))),
              ref = mean(R$shot), unit = "runner took a shot within 2 s"),
        RATES("Points in the chance, by help pulled", lapply(levels(R$hpb), function(l) mrow(l, R[hpb == l]$pts)), fmt = "num2",
              ref = mean(R$pts), unit = "points per chance"),
        RATES("Points in the chance, by kind of run", lapply(levels(R$kind), function(l) mrow(l, R[kind == l]$pts)), fmt = "num2",
              ref = mean(R$pts), unit = "points per chance")),
      H("Pick-and-pops"),
      GRID(
        RATES("Popper's own defender gap when the pop ends, by coverage on the screener", lapply(cov_lv, function(l) mrow(l, P_[covl == l]$own_gap)), fmt = "num1",
              ref = mean(P_$own_gap, na.rm = TRUE), unit = "ft from his own defender"),
        RATES("Popper shot within 2 s, by coverage on the screener", lapply(cov_lv, function(l) rrow(l, sum(P_[covl == l]$shot), nrow(P_[covl == l]))),
              ref = mean(P_$shot), unit = "popper shot within 2 s"),
        COURT("Where pops ended", P_$rx, P_$ry, bw = 1.5),
        COURT("Where rolls ended", RL$rx, RL$ry, bw = 1.2)),
      TAKE(sprintf("%s of %s picks were pops and %s were rolls in these games", int(nrow(P_)), int(sum(vapply(BL, function(B) nrow(B$picks), 0L))), int(nrow(RL))),
           sprintf("Poppers ended %.1f ft from their own defender on average and shot within 2 s %s of the time", mean(P_$own_gap, na.rm = TRUE), pct(mean(P_$shot))),
           sprintf("When a popper shot, the attempt averaged %.2f xPts", mean(P_[shot == TRUE]$s_xpts, na.rm = TRUE))),
      TABLE("Players with 10+ half-court rolls, pops and cuts", limit = 30, rows = rp_pl, cols = list(
        col("name", "Player"), col("team", "Team"), col("runs", "Runs", "int"), col("rolls", "Rolls", "int"), col("pops", "Pops", "int"), col("cuts", "Cuts", "int"),
        col("pulled", "Pulled help", "pct", ref = mean(R$help_pulled >= 1), scale = 0.2), col("help", "Help defenders", "num2"),
        col("ppc", "Pts/chance (runs)", "num2", ref = mean(R$pts), scale = 0.4)))),
    SECTION("gv-limits", "What this shows and does not",
      BUL("It shows how much room players get by situation, spot and player, and how often rolls, pops and cuts pull help",
          sprintf("Spot-up gravity lines up only weakly with season shooting (correlation %.2f with volume, %.2f with percentage), so it is not yet a clean shooting-threat measure", rr_v, rr_p),
          "It does not separate the player from the defense's plan, and expected room ignores the defender's own role and the shot clock"),
      H("If this becomes the topic"),
      BUL("Model room on spot, distance to the ball and the ball holder's threat, with a player effect shrunk toward his archetype",
          "Replace nearest-defender distance with a pressure measure closer to the NBA's (how many defenders lean toward him, and how far)",
          "Test whether higher-gravity lineups get better shots for the others"))
  )
  DOC("gravity", "Gravity", "How much defensive attention players draw on and off the ball, on the perimeter and inside, and how rolls, pops and cuts pull help.", sections)
}
