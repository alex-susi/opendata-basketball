# Per-player figures from the ten tracked games (sourced by export_data.R, which defines `a`): the box score,
# on-court ratings, SkillCorner shot quality by zone, tracking summaries and points per action. The season
# aggregates (annotations.R, season_figures) cover only offense and only shots, drives and picks, so everything
# else in the site's player card comes from here, labelled as the tracked games.
#
# Definitions (all over the ten games, per person and team, canonical ids):
#   Minutes        game clock elapsed over the chances he was on court for (chance_players).
#   Points         made field goals (2 or 3) plus made free throws.
#   FGA            shot events less fouled misses (FIBA box-score convention); and-one makes count.
#   Ratings        points his team scored (allowed) per 100 possessions he was on court for, from the shots and
#                  free throws of those possessions (possessions.offPlayerIds/defPlayerIds: anyone on court at any
#                  point of the possession).
#   Usage          his FGA + 0.44 FTA + turnovers over his team's, in the possessions he was on offense for.
#   OREB%, DREB%   his rebounds over every rebound (team rebounds too) after shots and free throws of chances he
#                  was on court for, on that end.
#   Shot quality   mean SkillCorner shotQuality of his FGA (null scores left out), overall and by zone: Rim = the
#                  restricted area, Mid-Range = every other two, Three. guardZone: the same for the opponents' FGA
#                  on which he was the closest defender at release (shots.closestDefId).
#   Points per action  the points from the action's own outcomes: his made field goal (2 or 3) plus the shot he
#                  assisted (AST3 = 3, AST2 or a bare AST = 2); free throws are left out, as in the season
#                  aggregates. Picks count direct picks only (as the season aggregates do); every other action
#                  counts all its events (as the season drives do).
#   Tracking       live play only (game clock running). Positions smoothed over 5 frames (as the site's motion.ts),
#                  steps faster than 35 ft/s left out. Top speed is the fastest 0.5 s average. Paint time is time
#                  on offense inside the key he attacks. Nearest opponent sampled every 5th frame (0.2 s).

sample_figures <- function() {
  M <- 3.28084
  HALF_L <- 14 * M
  KEY_X <- HALF_L - 5.8 * M
  KEY_HW <- 2.45 * M
  lst <- function(recs, f) lapply(recs, function(r) as.character(unlist(r[[f]])))
  ids <- function(recs, f) lapply(recs, function(r) as.integer(unlist(r[[f]])))
  own_pts <- function(o) if ("FGM3" %in% o) 3L else if ("FGM" %in% o) 2L else 0L
  ast_pts <- function(o) if ("AST3" %in% o) 3L else if (any(c("AST2", "AST") %in% o)) 2L else 0L
  act_pts <- function(outs) vapply(outs, function(o) own_pts(o) + ast_pts(o), 0L)
  games <- as.integer(fromJSON(file.path(a$root, "data", "matches.json"))$id)

  box <- list(); trk_rows <- list(); acts <- list(); zones <- list(); guards <- list(); ball <- list()
  for (g in games) {
    ev <- a$read_json_file(a$match_file(a$root, g, "_dynamic_events.json"))
    roster <- a$app_data$roster[game_id == g, .(pid, team = team_id, canon)]
    team_of <- function(pid) roster$team[match(pid, roster$pid)]

    # ---- events ----
    sh <- ev$shots
    shots <- data.table(poss = a$chr_field(sh, "possessionId"), pid = a$int_field(sh, "shooterId"), f = a$int_field(sh, "startFrame"),
                        team = a$int_field(sh, "offTeamId"), made = a$lgl_field(sh, "outcome"),
                        three = a$lgl_field(sh, "three"), fouled = a$lgl_field(sh, "fouled"), blocked = a$lgl_field(sh, "blocked"),
                        assisted = a$lgl_field(sh, "assisted"), passer = suppressWarnings(as.integer(a$chr_field(sh, "passerId"))),
                        blocker = a$int_field(sh, "blockerId"), region = a$chr_field(sh, "region"),
                        sq = a$num_field(sh, "shotQuality"), def = suppressWarnings(as.integer(a$chr_field(sh, "closestDefId"))),
                        defDist = a$num_field(sh, "closestDefDist"), contested = a$lgl_field(sh, "contested"))
    shots[, fga := !(fouled & !made)]
    shots[, pts := fifelse(made, fifelse(three, 3L, 2L), 0L)]
    ft <- data.table(poss = a$chr_field(ev$free_throws, "possessionId"), pid = a$int_field(ev$free_throws, "shooterId"),
                     team = a$int_field(ev$free_throws, "offTeamId"), made = a$lgl_field(ev$free_throws, "outcome"))
    rb <- data.table(chance = a$chr_field(ev$rebounds, "chanceId"), pid = a$int_field(ev$rebounds, "rebounderId"),
                     got = a$lgl_field(ev$rebounds, "rebounded"), defensive = a$lgl_field(ev$rebounds, "defensive"))
    to <- data.table(poss = a$chr_field(ev$turnovers, "possessionId"), pid = a$int_field(ev$turnovers, "turnedOverId"),
                     team = a$int_field(ev$turnovers, "offTeamId"),
                     stealer = suppressWarnings(as.integer(a$chr_field(ev$turnovers, "stealerId"))))
    fo <- data.table(pid = a$int_field(ev$fouls, "foulerId"), tech = a$lgl_field(ev$fouls, "isTechnical"))
    # The ten games' scores must close from shots and free throws (they do in this release).
    scored <- rbind(shots[made == TRUE, .(team, pts)], ft[made == TRUE, .(team, pts = 1L)])[, .(pts = sum(pts)), by = team]
    m <- fromJSON(file.path(a$root, "data", "matches.json"))
    mr <- m[m$id == g, ]
    stopifnot(scored[team == mr$home_team$id]$pts == mr$home_score, scored[team == mr$away_team$id]$pts == mr$away_score)

    # ---- minutes ----
    ch <- ev$chances
    chances <- data.table(chance = a$chr_field(ch, "id"), secs = pmax(0, a$num_field(ch, "startGameClock") - a$num_field(ch, "endGameClock")))
    cp <- data.table(chance = a$chr_field(ev$chance_players, "chanceId"), pid = a$int_field(ev$chance_players, "playerId"),
                     offense = a$lgl_field(ev$chance_players, "offense"))
    cp <- merge(unique(cp), chances, by = "chance")
    mins <- cp[, .(min = sum(secs) / 60), by = pid]

    # ---- possessions: who was on court, points and plays ----
    ps <- ev$possessions
    poss <- data.table(poss = a$chr_field(ps, "id"), off = a$int_field(ps, "offTeamId"), f0 = a$int_field(ps, "startFrame"),
                       f1 = a$int_field(ps, "endFrame"), left = a$lgl_field(ps, "leftHoop"))
    on_off <- data.table(poss = rep(poss$poss, lengths(ids(ps, "offPlayerIds"))), pid = unlist(ids(ps, "offPlayerIds")))
    on_def <- data.table(poss = rep(poss$poss, lengths(ids(ps, "defPlayerIds"))), pid = unlist(ids(ps, "defPlayerIds")))
    pp <- merge(poss[, .(poss, off)],
                rbind(shots[, .(poss, team, pts, plays = as.numeric(fga))], ft[, .(poss, team, pts = as.integer(made), plays = 0.44)],
                      to[, .(poss, team, pts = 0L, plays = 1)])[, .(pts = sum(pts), plays = sum(plays)), by = .(poss, team)],
                by.x = c("poss", "off"), by.y = c("poss", "team"), all.x = TRUE)
    pp[is.na(pts), `:=`(pts = 0L, plays = 0)]
    rate_off <- merge(unique(on_off), pp, by = "poss")[, .(offPoss = .N, offPts = sum(pts), teamPlays = sum(plays)), by = pid]
    rate_def <- merge(unique(on_def), pp, by = "poss")[, .(defPoss = .N, defPts = sum(pts)), by = pid]

    # ---- rebounding chances on court ----
    ch_off <- data.table(chance = rep(chances$chance, lengths(ids(ch, "offPlayerIds"))), pid = unlist(ids(ch, "offPlayerIds")))
    ch_def <- data.table(chance = rep(chances$chance, lengths(ids(ch, "defPlayerIds"))), pid = unlist(ids(ch, "defPlayerIds")))
    rb[, row := .I]
    reb_opp <- rbind(merge(unique(ch_off), rb[, .(chance, row, defensive)], by = "chance")[defensive == FALSE, .(pid, side = "o")],
                     merge(unique(ch_def), rb[, .(chance, row, defensive)], by = "chance")[defensive == TRUE, .(pid, side = "d")])
    reb_opp <- dcast(reb_opp[, .N, by = .(pid, side)], pid ~ side, value.var = "N", fill = 0L)
    for (col in c("o", "d")) if (!col %in% names(reb_opp)) reb_opp[, (col) := 0L]

    # ---- the box score per player ----
    b <- Reduce(function(x, y) merge(x, y, by = "pid", all = TRUE), list(
      roster[, .(pid)], mins,
      shots[, .(pts_fg = sum(pts), fga = sum(fga), fgm = sum(made), fg3a = sum(fga & three), fg3m = sum(made & three),
                fouledShots = sum(fouled), blockedOn = sum(blocked & fga)), by = pid],
      ft[, .(fta = .N, ftm = sum(made)), by = pid],
      rb[got == TRUE, .(oreb = sum(!defensive), dreb = sum(defensive)), by = pid],
      shots[made == TRUE & assisted == TRUE & !is.na(passer), .(ast = .N), by = .(pid = passer)],
      shots[made == TRUE & assisted == TRUE, .(astd = .N), by = pid],
      to[!is.na(stealer), .(stl = .N), by = .(pid = stealer)],
      shots[!is.na(blocker), .(blk = .N), by = .(pid = blocker)],
      to[!is.na(pid), .(tov = .N), by = pid],
      fo[tech == FALSE, .(pf = .N), by = pid],
      rate_off, rate_def,
      reb_opp[, .(pid, orebOpp = o, drebOpp = d)]))
    num <- setdiff(names(b), "pid")
    for (col in num) set(b, which(is.na(b[[col]])), col, 0)
    b <- b[min > 0 | fga > 0 | fta > 0]
    b[, `:=`(pts = pts_fg + ftm, plays = fga + 0.44 * fta + tov, g = 1L)][, pts_fg := NULL]
    b[, `:=`(team = team_of(pid), canon = roster$canon[match(pid, roster$pid)])]
    box[[length(box) + 1L]] <- b


    # ---- touches ----
    tc <- ev$touches
    ball[[length(ball) + 1L]] <- data.table(pid = a$int_field(tc, "playerId"), secs = a$num_field(tc, "touchTime"),
                                            drb = a$int_field(tc, "numDribbles"))[, .(touches = .N, ballSecs = sum(secs, na.rm = TRUE),
                                                                                       dribbles = sum(drb, na.rm = TRUE)), by = pid][, team := team_of(pid)]

    # ---- actions ----
    act <- function(key, recs, actor, outs, cov, direct_only = FALSE) {
      if (!length(recs)) return(NULL)
      dt <- data.table(kind = key, pid = a$int_field(recs, actor), pts = act_pts(lst(recs, outs)),
                       cov = if (is.null(cov)) "all" else fcoalesce(a$chr_field(recs, cov), "none"),
                       direct = a$lgl_field(recs, "direct"))
      if (direct_only) dt <- dt[direct == TRUE]
      dt[, team := team_of(pid)][, direct := NULL]
    }
    acts[[length(acts) + 1L]] <- rbind(
      act("pickH", ev$picks, "ballhandlerId", "bhrOutcomes", "bhrDefType", TRUE),
      act("pickS", ev$picks, "screenerId", "scrOutcomes", "scrDefType", TRUE),
      act("drive", ev$drives, "ballhandlerId", "bhrOutcomes", "category"),
      act("handoff", ev$handoffs, "receiverId", "bhrOutcomes", "receiverDefType"),
      act("obs", ev$off_ball_screens, "cutterId", "outcomes", "cutterDefType"),
      act("obsS", ev$off_ball_screens, "screenerId", "scrOutcomes", "screenerDefType"),
      act("post", ev$posts, "ballhandlerId", "bhrOutcomes", "section"),
      act("iso", ev$isolations, "ballhandlerId", "bhrOutcomes", NULL),
      act("closeout", ev$closeouts, "ballhandlerId", "bhrOutcomes", "bhrAction"))

    # ---- tracking ----
    trk <- a$get_tracking(a$app_data, g)
    pl <- merge(trk$players[, .(frame, pid, x, y)], trk$frames[, .(frame, stopped)], by = "frame")
    setorder(pl, pid, frame)
    pl[, run := cumsum(c(TRUE, diff(frame) != 1L)), by = pid]
    pl[, `:=`(sx = frollmean(x, 5L, align = "center"), sy = frollmean(y, 5L, align = "center")), by = .(pid, run)]
    pl[is.na(sx), `:=`(sx = x, sy = y)]
    pl[, step := c(NA_real_, sqrt(diff(sx)^2 + diff(sy)^2)), by = .(pid, run)]
    pl[step * 25 > 35, step := NA_real_]
    pl[, top := frollmean(step * 25, 13L, align = "center"), by = .(pid, run)]
    setorder(poss, f0)
    k <- findInterval(pl$frame, poss$f0)
    inside <- k > 0L & pl$frame <= poss$f1[pmax(k, 1L)]
    pl[, `:=`(off_team = fifelse(inside, poss$off[pmax(k, 1L)], NA_integer_),
              sgn = fifelse(inside, fifelse(poss$left[pmax(k, 1L)], -1, 1), NA_real_), team = team_of(pid))]
    pl[, on_o := team == off_team]
    lv <- pl[stopped == FALSE]
    t1 <- lv[, .(secs = .N / 25, dist = sum(step, na.rm = TRUE),
                 offSecs = sum(on_o %in% TRUE) / 25, offDist = sum(step[on_o %in% TRUE], na.rm = TRUE),
                 defSecs = sum(on_o %in% FALSE) / 25, defDist = sum(step[on_o %in% FALSE], na.rm = TRUE),
                 paint = sum(on_o %in% TRUE & sgn * x >= KEY_X & abs(y) <= KEY_HW) / 25,
                 top = suppressWarnings(max(top, na.rm = TRUE))), by = .(pid, team)]
    t1[!is.finite(top), top := NA_real_]
    sub <- lv[frame %% 5L == 0L & !is.na(on_o), .(frame, pid, team, on_o, x, y)]
    near <- sub[sub, on = "frame", allow.cartesian = TRUE, nomatch = NULL][team != i.team,
             .(d = min(sqrt((x - i.x)^2 + (y - i.y)^2))), by = .(frame, pid = i.pid, on_o = i.on_o)]
    t2 <- near[, .(openN = sum(on_o), openSum = sum(d[on_o]), nearN = sum(!on_o), nearSum = sum(d[!on_o])), by = pid]
    trk_rows[[length(trk_rows) + 1L]] <- merge(t1, t2, by = "pid", all.x = TRUE)

    # ---- shot quality by zone, shots on his defence ----
    # SkillCorner left the context of a few shots blank (no region or closest defender; see web/src/lib/shotfill.ts).
    # Their zone comes from the shooter's tracked distance to the hoop he attacks at release (rim within the 4.1 ft
    # restricted area), and their closest defender is the nearest tracked opponent then.
    fs <- shots[fga == TRUE]
    fs[, zone := fifelse(three, "three", fifelse(region == "ra", "rim", "mid"))]
    blank <- fs[is.na(region) | is.na(def), which = TRUE]
    for (r in blank) {
      at <- pl[frame >= fs$f[r] - 3L & frame <= fs$f[r] + 3L][order(abs(frame - fs$f[r]))]
      me <- at[pid == fs$pid[r]][1]
      if (is.na(me$x)) next
      at <- at[frame == me$frame]
      if (is.na(fs$region[r]) && !fs$three[r]) {
        hoop <- me$sgn * (HALF_L - 1.575 * M)
        set(fs, r, "zone", if (!is.na(hoop) && sqrt((me$x - hoop)^2 + me$y^2) <= 1.25 * M) "rim" else "mid")
      }
      if (is.na(fs$def[r])) {
        opp <- at[!is.na(team) & team != me$team]
        if (nrow(opp)) set(fs, r, "def", opp$pid[which.min(sqrt((opp$x - me$x)^2 + (opp$y - me$y)^2))])
      }
    }
    zones[[length(zones) + 1L]] <- fs[, .(pid, team, zone, made, three, sq, defDist, contested)]
    guards[[length(guards) + 1L]] <- fs[!is.na(def), .(pid = def, team = team_of(def), zone, made, three, sq)]
    message("  sample figures: game ", g)
  }

  key_of <- function(pid, team) {
    canon <- a$app_data$roster$canon[match(pid, a$app_data$roster$pid)]
    paste0(fcoalesce(canon, pid), ":", team)
  }
  sum_key <- function(dt) {
    dt <- copy(dt)[!is.na(team)]
    dt[, key := key_of(pid, team)]
    cols <- setdiff(names(dt), c("pid", "team", "key", "canon"))
    dt[, lapply(.SD, function(v) sum(v, na.rm = TRUE)), by = key, .SDcols = cols]
  }
  B <- sum_key(rbindlist(box, fill = TRUE))
  Tk <- rbindlist(trk_rows, fill = TRUE)[!is.na(team)]
  Tk[, key := key_of(pid, team)]
  Tk <- Tk[, c(lapply(.SD, function(v) sum(v, na.rm = TRUE)), list(top = suppressWarnings(max(top, na.rm = TRUE)))), by = key,
           .SDcols = c("secs", "dist", "offSecs", "offDist", "defSecs", "defDist", "paint", "openN", "openSum", "nearN", "nearSum")]
  Z <- rbindlist(zones)
  Z[, key := key_of(pid, team)]
  G <- rbindlist(guards)[!is.na(team)]
  G[, key := key_of(pid, team)]
  BL <- sum_key(rbindlist(ball))
  A <- rbindlist(acts)
  Ak <- A[!is.na(team)][, key := key_of(pid, team)][, .(n = .N, pts = sum(pts)), by = .(key, kind)]

  r1 <- function(v) round(v, 1)
  zone_vec <- function(z) c(nrow(z), sum(z$made), sum(z$made & z$three), sum(!is.na(z$sq)), r1(sum(z$sq, na.rm = TRUE)))
  players <- list()
  for (i in seq_len(nrow(B))) {
    r <- B[i]
    k <- r$key
    t <- Tk[key == k]
    z <- Z[key == k]
    gd <- G[key == k]
    bl <- BL[key == k]
    ak <- Ak[key == k]
    rec <- list(
      g = r$g, min = r1(r$min), pts = r$pts, fga = r$fga, fgm = r$fgm, fg3a = r$fg3a, fg3m = r$fg3m, fta = r$fta, ftm = r$ftm,
      oreb = r$oreb, dreb = r$dreb, ast = r$ast, astd = r$astd, stl = r$stl, blk = r$blk, tov = r$tov, pf = r$pf,
      offPoss = r$offPoss, offPts = r$offPts, defPoss = r$defPoss, defPts = r$defPts, plays = r1(r$plays), teamPlays = r1(r$teamPlays),
      orebOpp = r$orebOpp, drebOpp = r$drebOpp,
      zone = list(rim = I(zone_vec(z[zone == "rim"])), mid = I(zone_vec(z[zone == "mid"])), three = I(zone_vec(z[zone == "three"]))),
      shotDef = I(c(nrow(z), r1(sum(z$defDist, na.rm = TRUE)), sum(z$contested))),
      guard = I(c(nrow(gd), sum(gd$made), sum(gd$made & gd$three))),
      guardZone = list(rim = I(zone_vec(gd[zone == "rim"])), mid = I(zone_vec(gd[zone == "mid"])), three = I(zone_vec(gd[zone == "three"]))),
      fouledShots = r$fouledShots, blockedOn = r$blockedOn,
      ball = if (nrow(bl)) I(c(bl$touches, r1(bl$ballSecs), bl$dribbles)) else NULL,
      trk = if (nrow(t)) list(secs = r1(t$secs), dist = round(t$dist), offSecs = r1(t$offSecs), offDist = round(t$offDist),
                              defSecs = r1(t$defSecs), defDist = round(t$defDist), paint = r1(t$paint),
                              top = if (is.finite(t$top)) r1(t$top) else NULL,
                              open = I(c(t$openN, r1(t$openSum))), near = I(c(t$nearN, r1(t$nearSum)))) else NULL,
      acts = if (nrow(ak)) setNames(lapply(seq_len(nrow(ak)), function(j) I(c(ak$n[j], ak$pts[j]))), ak$kind) else NULL)
    players[[k]] <- rec[!vapply(rec, is.null, NA)]
  }

  league_acts <- lapply(split(A, A$kind), function(d) {
    by <- d[, .(n = .N, pts = sum(pts)), by = cov]
    list(all = I(c(nrow(d), sum(d$pts))), by = setNames(lapply(seq_len(nrow(by)), function(j) I(c(by$n[j], by$pts[j]))), by$cov))
  })
  list(games = length(games),
       players = players,
       league = list(zone = list(rim = I(zone_vec(Z[zone == "rim"])), mid = I(zone_vec(Z[zone == "mid"])),
                                 three = I(zone_vec(Z[zone == "three"]))),
                     acts = league_acts))
}
