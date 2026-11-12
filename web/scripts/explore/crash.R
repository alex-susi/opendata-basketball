# Topic: crash rate and crash aggression. How many attackers go to the glass after a shot, what does it buy in
# offensive rebounds, and what does it cost in the opponent's next chance?
#
# Roles come from the site's rebounding roles (web/scripts/glass.R, decision log 2026-11-08), judged only from the
# shot's flight (release to the rim), before anyone knows where the ball goes: crash (on the glass), retreat, safety
# (already back), hold, and the shooter (follow = crashed his own shot). A crasher is "boxed out" when a defender
# held the spot between him and the hoop with contact (glass.R's rule; coarse, not validated against video).
#
# The opponent's next chance after a defensive rebound is rebounds.nextChanceId. "Numbers at the rim": attackers
# and defenders within 10 ft of the hoop when the ball reached the rim (the shot's endFrame). "Nearest to the ball":
# for a rebound a player secured, the player who was nearest the spot where it was secured (the rebounder's tracked
# position at the rebound frame) when the ball reached the rim.

topic_crash <- function(BL) {
  S <- list()
  R <- list()
  NR <- list()
  # One game at a time: each shot's crash counts, rebound and the opponent's next chance; player rows; nearest to the
  # ball.
  for (B in BL) {
    gl <- B$glass
    if (!nrow(gl)) next
    sh <- B$shots[, .(shot, poss, chance, f, f1, made, fouled, three, zone, team, pid_s = pid, xpts, dist)]
    per <- gl[, .(n_crash = sum(role %in% c("crash", "follow")), n_back = sum(role %in% c("back", "safety")),
                  n_hold = sum(role == "hold"), follow = any(role == "follow"),
                  n_boxed = sum(boxed %in% TRUE), gain = mean((d0 - d1)[role %in% c("crash", "follow")]),
                  seen_back = mean(seen[role %in% c("back", "safety")], na.rm = TRUE)), by = shot]
    s <- merge(sh, per, by = "shot")
    s[, live := !made & !fouled]
    rb <- B$rb[!is.na(shot)][!duplicated(shot)]
    s <- merge(s, rb[, .(shot, defensive, got, rpid = pid, rf = f, next_chance, rx = x, ry = y)], by = "shot", all.x = TRUE)
    s[, oreb := live & defensive %in% FALSE]
    nx <- B$ch[, .(next_chance = chance, n_pts = pts, n_trans = transition, n_tov = tov, n_ft = ftrip, n_xpts = xpts,
                   n_secs = (cut_f - c0) / FPS, n_off = off, n_fga = fga, n_live = live, n_oreb = oreb, n_efg = efg_pts)]
    s <- merge(s, nx, by = "next_chance", all.x = TRUE)
    # Numbers at the rim.
    W <- B$P[.(unique(s$f1)), nomatch = 0L][, d := hoop_dist(x, y)]
    nr <- W[, .(att10 = sum(off & d <= 10), def10 = sum(!off & d <= 10), att6 = sum(off & d <= 6), def6 = sum(!off & d <= 6)), by = .(f1 = frame)]
    s <- merge(s, nr, by = "f1", all.x = TRUE)
    s[, game := B$game]
    S[[length(S) + 1]] <- s

    # Player rows: every attacker role on every shot, with who rebounded.
    g2 <- merge(gl, s[, .(shot, live, oreb, rpid, defensive, zone)], by = "shot")
    g2[, got_it := live & oreb & !is.na(rpid) & rpid == pid]
    g2[, `:=`(canon = B$roster$canon[match(pid, B$roster$pid)], name = B$roster$name[match(pid, B$roster$pid)],
              team = B$roster$team_name[match(pid, B$roster$pid)], game = B$game)]
    R[[length(R) + 1]] <- g2

    # Nearest to the ball's eventual spot, when it reached the rim.
    q <- s[live == TRUE & got %in% TRUE & !is.na(rpid)]
    if (nrow(q)) {
      spot <- pos_at(B, q$rf, q$rpid)
      # The rebound frame can fall in the next possession, whose positions are stored attacking the other way.
      rposs <- B$P[.(q$rf, q$rpid), poss, mult = "first"]
      flip <- fifelse(!is.na(rposs) & rposs != q$poss, -1, 1)
      q[, `:=`(sx = flip * spot$x, sy = flip * spot$y)]
      q <- q[!is.na(sx)]
      Wq <- B$P[.(unique(q$f1)), nomatch = 0L]
      J <- merge(q[, .(shot, f1, sx, sy, rpid, defensive)], Wq[, .(f1 = frame, pid, x, y, off)], by = "f1", allow.cartesian = TRUE)
      J[, dd := sqrt((x - sx)^2 + (y - sy)^2)]
      J[, rank := frank(dd, ties.method = "first"), by = shot]
      J[, `:=`(canon = B$roster$canon[match(pid, B$roster$pid)], name = B$roster$name[match(pid, B$roster$pid)],
               team = B$roster$team_name[match(pid, B$roster$pid)])]
      NR[[length(NR) + 1]] <- J
    }
  }
  # Stack the games; live misses get crash-count and retreat bins.
  s <- rbindlist(S, fill = TRUE)
  g <- rbindlist(R, fill = TRUE)
  nr <- rbindlist(NR, fill = TRUE)
  m <- s[live == TRUE]
  m[, crb := factor(pmin(n_crash, 3), 0:3, c("0", "1", "2", "3+"))]
  m[, bkb := factor(pmin(n_back, 3), 0:3, c("0", "1", "2", "3+"))]
  m[, zone3 := fifelse(zone == "three", "three", fifelse(zone == "rim", "rim", "other two"))]
  cr_lv <- levels(m$crb)
  base_oreb <- mean(m$oreb)
  dreb <- m[defensive %in% TRUE & !is.na(n_pts)]
  dreb_base <- mean(dreb$n_pts)

  # Trade-off per crash level.
  tr <- m[, .(n = .N, p_oreb = mean(oreb),
              pts_after_oreb = mean(n_pts[oreb & !is.na(n_pts)]),
              opp_pts = mean(n_pts[defensive %in% TRUE & !is.na(n_pts)]),
              opp_trans = mean(n_trans[defensive %in% TRUE & !is.na(n_trans)]),
              opp_n = sum(defensive %in% TRUE & !is.na(n_pts))), by = crb][order(crb)]
  tr[, net := p_oreb * pts_after_oreb - (1 - p_oreb) * opp_pts]

  m[, diff10 := att10 - def10]
  m[, dfb := factor(pmin(pmax(diff10, -4), 1), -4:1, c("−4 or fewer", "−3", "−2", "−1", "0", "+1 or more"))]

  # Crashers: who gets the ball, by box-out and gain.
  cz <- g[role %in% c("crash", "follow") & live == TRUE]
  cz[, start := cut(d0, c(-Inf, 10, 18, 24, Inf), labels = c("under 10 ft", "10-18 ft", "18-24 ft", "24+ ft (from the arc)"))]
  cz[, gainb := cut(d0 - d1, c(-Inf, 2, 6, 12, Inf), labels = c("under 2 ft", "2-6 ft", "6-12 ft", "12+ ft"))]

  # Players.
  pl <- g[role != "shooter" & role != "follow" | role == "follow", .(shots = sum(role != "shooter"), crash = sum(role %in% c("crash", "follow")), back = sum(role %in% c("back", "safety")),
                                                                     misses_crashed = sum(role %in% c("crash", "follow") & live), oreb = sum(got_it), boxed = sum(boxed %in% TRUE & role %in% c("crash", "follow")),
                                                                     gain = mean((d0 - d1)[role %in% c("crash", "follow")]), name = name[1], team = team[1]), by = canon]
  pl[, `:=`(crash_rate = crash / pmax(1, shots), oreb_per_crash = oreb / pmax(1, misses_crashed), boxed_rate = boxed / pmax(1, crash))]
  pl <- pl[shots >= 40][order(-crash_rate)]
  # Nearest vs collected.
  pos <- nr[, .(nearest = sum(rank == 1), got = sum(pid == rpid), name = name[1], team = team[1]), by = canon]
  pos[, beyond := got - nearest]
  pos <- pos[nearest + got >= 6][order(-beyond)]
  near_share <- nr[rank == 1, mean(pid == rpid)]
  off_near <- nr[rank == 1, mean(off)]
  off_got <- nr[rank == 1, mean(!defensive)]

  # Teams.
  tm <- rbindlist(lapply(BL, function(B) unique(B$roster[, .(team = team, team_name)])))[!duplicated(team)]
  m[, team_name := tm$team_name[match(team, tm$team)]]
  tt <- m[, .(misses = .N, crashers = mean(n_crash), back = mean(n_back), oreb = mean(oreb),
              opp_trans = mean(n_trans[defensive %in% TRUE], na.rm = TRUE), opp_pts = mean(n_pts[defensive %in% TRUE], na.rm = TRUE)), by = team_name][misses >= 30][order(-crashers)]

  # The tab's document.
  sections <- list(SECTION("cr-question", "The question and the data",
                           P("After a shot goes up, each attacker chooses to go to the glass, hold his spot or get back."),
                           BUL("Crashing wins offensive rebounds. Getting back stops transition",
                               "This tab counts those choices on every shot in the ten games, using the site's rebounding roles",
                               "Roles are judged during the shot's flight, before the ball comes off the rim",
                               "Each live miss is followed to its rebound and to the next chance"),
                           KPIS(KPI("Live misses", int(nrow(m)), sprintf("of %s shots", int(nrow(s)))),
                                KPI("Crashers per miss", sprintf("%.2f", mean(m$n_crash)), sprintf("%.2f retreat or safety", mean(m$n_back))),
                                KPI("Offense keeps the ball", pct(base_oreb), "offensive or team rebound"),
                                KPI("Opponent after a defensive rebound", sprintf("%.2f pts", dreb_base), sprintf("transition %s", pct(mean(dreb$n_trans, na.rm = TRUE))))),
                           CAVEAT("Roles come from simple distance rules on the tracking (web/scripts/glass.R)",
                                  sprintf("Players getting back are often off camera (%s of their frames detected), so their positions are partly extrapolated", pct(mean(m$seen_back, na.rm = TRUE))))),
                   SECTION("cr-rate", "Crash rate and offensive rebounds",
                           GRID(RATES("Offense keeps the ball, by number of crashers", lapply(cr_lv, function(l) rrow(l, sum(m[crb == l]$oreb), nrow(m[crb == l]))), ref = base_oreb, unit = "of live misses kept", refLabel = "all"),
                                RATES("…by attackers getting back (retreat or safety)", lapply(cr_lv, function(l) rrow(l, sum(m[bkb == l]$oreb), nrow(m[bkb == l]))), ref = base_oreb, unit = "of live misses kept"),
                                RATES("…by attackers minus defenders within 10 ft at the rim", lapply(levels(m$dfb), function(l) rrow(l, sum(m[dfb == l]$oreb, na.rm = TRUE), sum(m$dfb == l, na.rm = TRUE))),
                                      ref = base_oreb, unit = "of live misses kept"),
                                RATES("…when the shooter followed his shot", list(rrow("followed", sum(m[follow == TRUE]$oreb), nrow(m[follow == TRUE])),
                                                                                  rrow("did not", sum(m[follow == FALSE]$oreb), nrow(m[follow == FALSE]))), ref = base_oreb, unit = "of live misses kept")),
                           TABLE("Crashers by shot range", limit = 12, rows = dcast(m[!is.na(zone3), .(r = mean(oreb), n = .N), by = .(zone3, crb)], zone3 ~ crb, value.var = c("r", "n")), cols = c(list(col("zone3", "Shot range", title = "Where the missed shot was taken from")), lapply(cr_lv, function(l) col(paste0("r_", l), paste(l, "crashing"), "pct", ref = base_oreb, scale = 0.15)),
                                                                                                                                                                                                     lapply(cr_lv, function(l) col(paste0("n_", l), paste("n", l), "int")))),
                           TAKE(sprintf("With no crasher the offense kept %s of live misses", pct(tr[crb == "0"]$p_oreb)),
                                sprintf("With one crasher %s, two %s, three or more %s", pct(tr[crb == "1"]$p_oreb), pct(tr[crb == "2"]$p_oreb), pct(tr[crb == "3+"]$p_oreb)))),
                   SECTION("cr-cost", "What crashing costs: the opponent's next chance",
                           BUL("When the defense gets the rebound, the attackers who crashed are behind the play",
                               "These charts follow the opponent's next chance (rebounds.nextChanceId), by how many attackers crashed and how many got back"),
                           GRID(RATES("Opponent's points in the next chance, by crashers", lapply(cr_lv, function(l) mrow(l, dreb[crb == l]$n_pts)), fmt = "num2", ref = dreb_base, unit = "points per chance"),
                                RATES("Opponent's next chance is transition, by crashers", lapply(cr_lv, function(l) {
                                  x <- dreb[crb == l & !is.na(n_trans)]
                                  rrow(l, sum(x$n_trans), nrow(x))
                                }),
                                      ref = mean(dreb$n_trans, na.rm = TRUE), unit = "transition"),
                                RATES("Opponent's points in the next chance, by attackers back", lapply(cr_lv, function(l) mrow(l, dreb[bkb == l]$n_pts)), fmt = "num2", ref = dreb_base, unit = "points per chance"),
                                RATES("Opponent's next chance is transition, by attackers back", lapply(cr_lv, function(l) {
                                  x <- dreb[bkb == l & !is.na(n_trans)]
                                  rrow(l, sum(x$n_trans), nrow(x))
                                }),
                                      ref = mean(dreb$n_trans, na.rm = TRUE), unit = "transition")),
                           outcome_table(copy(dreb)[, `:=`(pts = n_pts, xpts = n_xpts, tov = n_tov, ftrip = n_ft, live = n_live %in% TRUE, oreb = n_oreb %in% TRUE, fga = n_fga %in% TRUE,
                                                           efg_pts = n_efg, g = as.character(crb))], "g", label = "Attackers who crashed", title = "The opponent's next chance in full, by crashers", min_n = 10),
                           TABLE("The trade per live miss", limit = 6, rows = tr, cols = list(col("crb", "Crashers"), col("n", "Live misses", "int"), col("p_oreb", "P(keep)", "pct"), col("pts_after_oreb", "Pts after keeping", "num2"),
                                                                                              col("opp_pts", "Opp. pts after losing it", "num2"), col("opp_trans", "Opp. transition", "pct"),
                                                                                              col("net", "Net per miss", "num2", ref = 0, scale = 0.3)),
                                 note = "Net = P(keep) × points in the offense's next chance − (1 − P(keep)) × the opponent's points in theirs. A tally of these games, not a model. Each term has its own noise."),
                           COLS("Net points per live miss by crashers", cr_lv, list(SERIES1("Net", tr$net)), fmt = "num2", labels = TRUE)),
                   SECTION("cr-who", "Crashers: start, gain and box-outs",
                           GRID(RATES("Crasher got the rebound himself, by where he started", lapply(levels(cz$start), function(l) rrow(l, sum(cz[start == l]$got_it), nrow(cz[start == l]))),
                                      ref = mean(cz$got_it), unit = "of misses he crashed"),
                                RATES("…by ground gained during the flight", lapply(levels(cz$gainb), function(l) rrow(l, sum(cz[gainb == l]$got_it), nrow(cz[gainb == l]))),
                                      ref = mean(cz$got_it), unit = "of misses he crashed"),
                                RATES("…by whether he was boxed out", list(rrow("boxed out", sum(cz[boxed %in% TRUE]$got_it), nrow(cz[boxed %in% TRUE])),
                                                                           rrow("not boxed out", sum(cz[!(boxed %in% TRUE)]$got_it), nrow(cz[!(boxed %in% TRUE)]))),
                                      ref = mean(cz$got_it), unit = "of misses he crashed"),
                                RATES("…by the shot's range", lapply(c("rim", "other two", "three"), function(l) rrow(l, sum(cz[zone == l | (l == "other two" & zone %in% c("paint", "mid-range"))]$got_it),
                                                                                                                      nrow(cz[zone == l | (l == "other two" & zone %in% c("paint", "mid-range"))]))),
                                      ref = mean(cz$got_it), unit = "of misses he crashed"))),
                   SECTION("cr-position", "Who was nearest the ball, and who got it",
                           BUL(sprintf("For %s rebounds a player secured, the player nearest the spot where it was secured (measured when the ball reached the rim) got it %s of the time",
                                       int(uniqueN(nr$shot)), pct(near_share)),
                               sprintf("The offense had the nearest player on %s of these rebounds and secured %s of them", pct(off_near), pct(off_got)),
                               "A player who collects more than he was nearest for beats closer players to the ball (reach, timing, effort)",
                               "Fewer means others took balls that came his way",
                               "This is a simple stand-in for the archived court-control question"),
                           TABLE("Players: rebounds collected vs times nearest when the ball hit the rim", limit = 30, rows = pos, cols = list(col("name", "Player"), col("team", "Team"), col("nearest", "Nearest", "int"), col("got", "Collected", "int"),
                                                                                                                                               col("beyond", "Collected − nearest", "int", ref = 0, scale = 4)),
                                 note = "Rebounds both teams secured, six or more as nearest or collector. 'Nearest' uses the spot where the ball was secured, which already depends on who got it."),
                           TABLE("Attackers: crash rate and offensive rebounds (40+ shots on court, not shooting)", limit = 30, rows = pl, cols = list(col("name", "Player"), col("team", "Team"), col("shots", "Shots", "int"), col("crash_rate", "Crash rate", "pct", ref = mean(g[role != "shooter"]$role %in% c("crash", "follow")), scale = 0.2),
                                                                                                                                                       col("back", "Got back", "int"), col("misses_crashed", "Misses crashed", "int"), col("oreb", "OREB", "int"),
                                                                                                                                                       col("oreb_per_crash", "OREB per crash", "pct"), col("boxed_rate", "Boxed out", "pct"), col("gain", "Gain (ft)", "num1")))),
                   SECTION("cr-teams", "Teams",
                           TABLE("Teams: crashers per miss, rebounds kept, and what the opponent did after", limit = 20, rows = tt, cols = list(col("team_name", "Team"), col("misses", "Live misses", "int"), col("crashers", "Crashers", "num2", ref = mean(m$n_crash), scale = 0.5),
                                                                                                                                                col("back", "Back", "num2"), col("oreb", "Kept", "pct", ref = base_oreb, scale = 0.12),
                                                                                                                                                col("opp_trans", "Opp. transition after DREB", "pct", ref = mean(dreb$n_trans, na.rm = TRUE), scale = 0.15, low = TRUE),
                                                                                                                                                col("opp_pts", "Opp. pts after DREB", "num2", ref = dreb_base, scale = 0.3, low = TRUE)),
                                 note = "One or two games per team.")),
                   SECTION("cr-limits", "What this shows and does not",
                           BUL("It shows how crash numbers relate to offensive rebounds and to the opponent's next chance in these games",
                               "It does not show what would happen if a team crashed one more player",
                               "Teams crash more on certain shots (short misses, bigs on the floor) and against certain opponents"),
                           H("If this becomes the topic"),
                           BUL("The interactive version (move players after the release, see P(offensive rebound) and the transition risk) needs a rebound-location model and a who-gets-there-first model",
                               "Both were built and archived on 2026-11-06 (zz_Archive/src/rebounding, court control in web/src/lib/control.ts)",
                               "The descriptive tables here are the ground truth they would have to reproduce")))
  DOC("crash", "Crashing the glass", "How many attackers crash after a shot, what it buys in offensive rebounds, and what it costs in the opponent's next chance.", sections)
}
