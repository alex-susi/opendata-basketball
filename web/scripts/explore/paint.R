# Topic: paint touches. How does getting the ball into the key change what a chance produces?
#
# Paint touch: a touch (one player's continuous control of the ball) whose SkillCorner regionsIn includes the key
# or the restricted area, starting before the chance's last shot was released (or before the chance ended). This
# counts catches in the paint, drives and dribbles into it, post-ups and offensive rebounds taken there. The entry
# frame is the first frame the ball holder is tracked inside the key during that touch (the touch's start if he is
# never tracked there). How the paint was reached is read off the touch: an offensive rebound's touch, a post-up's
# touch, a drive's touch, a touch that starts in the key (a catch: cut, roll or dump-off), else another dribble in.

topic_paint <- function(BL) {
  rows <- list()
  kick <- list()
  geo <- list()
  pts_poss <- list()
  spots <- list()
  agree <- list()
  # One game at a time: paint touches and how each was reached, shots after them, team shape at the entry, possessions.
  for (B in BL) {
    ch <- B$ch[in_pop == TRUE]
    tc <- merge(B$touches, ch[, .(chance, cut_f, off)], by = "chance")[f0 <= cut_f & team == off]
    # Tracking check of the vendor flag: holder in the key at some frame of the touch.
    Hd <- B$Fr[!is.na(holder), .(frame, holder)]
    Hd <- merge(Hd, B$P[, .(frame, pid, x, y)], by.x = c("frame", "holder"), by.y = c("frame", "pid"))
    Hd[, inp := in_paint(x, y)]
    tc[, key := .I]
    hit <- Hd[inp == TRUE][tc[, .(key, holder = pid, f0, f1)], on = .(holder, frame >= f0, frame <= f1),
                            .(key, frame = x.frame), nomatch = 0L][, .(entry = min(frame)), by = key]
    tc[hit, on = "key", entry := i.entry]
    tc[, trk_paint := !is.na(entry)]
    agree[[length(agree) + 1]] <- tc[, .(vendor = vendor_paint, tracked = trk_paint)]
    # The vendor-flagged paint touches: entry frame, how the paint was reached, and what the toucher did.
    pt <- tc[vendor_paint == TRUE]
    pt[, entry := fifelse(is.na(entry), f0, entry)]
    oreb_t <- B$rb[defensive == FALSE & !is.na(touch)]$touch
    pt[, source := fifelse(touch %in% oreb_t, "offensive rebound",
                           fifelse(touch %in% B$posts$touch, "post-up",
                                   fifelse(touch %in% B$drives$touch, "drive",
                                           fifelse(in_paint(x0, y0), "catch in the key", "other dribble in"))))]
    pt[, did := fifelse(grepl("FG[MX]", outs), "shot", fifelse(grepl("TO", outs), "turnover",
                                                               fifelse(grepl("FOU_S|FOU_B", outs), "fouled", fifelse(grepl("PASS", outs), "pass out", "other"))))]
    # Each chance's first paint touch and its count.
    first <- pt[order(entry)][, .SD[1], by = chance]
    ch[, n_pt := pt[, .N, by = chance][ch, on = "chance", fifelse(is.na(N), 0L, N)]]
    ch[first, on = "chance", `:=`(src = i.source, entry = i.entry, did = i.did)]
    ch[, sc_entry := B$Fr$sc[match(entry, B$Fr$frame)]]
    ch[, secs := (cut_f - c0) / FPS]
    ch[, entry_to_end := (cut_f - entry) / FPS]
    rows[[length(rows) + 1]] <- ch
    spots[[length(spots) + 1]] <- cbind(first[, .(source)], first[, {
      p <- pos_at(B, entry, pid)
      .(x = p$x, y = p$y)
    }])

    # Shots taken on a later touch than a paint touch (kick-outs and swings) versus shots in chances with none.
    s <- merge(B$shots[fga == TRUE], ch[, .(chance, transition, start)], by = "chance")
    s <- merge(s, B$touches[, .(touch, pid_t = pid)], by = "touch", all.x = TRUE)
    s[, paint_before := FALSE]
    s[, after_secs := NA_real_]
    for (i in seq_len(nrow(s))) {
      p <- pt[chance == s$chance[i] & touch != s$touch[i] & entry < s$f[i]]
      if (nrow(p)) {
        s$paint_before[i] <- TRUE
        s$after_secs[i] <- (s$f[i] - max(p$entry)) / FPS
      }
    }
    s[, own_paint := touch %in% pt$touch]
    s[, game := B$game]
    kick[[length(kick) + 1]] <- s

    # Team shape around the paint entry, and in matched moments with no paint touch: frames 2-4 s into
    # half-court chances that never reach the key.
    g1 <- aligned_geom(B, first$entry, first$source, offsets = seq(-2, 2, by = 0.2))
    if (nrow(g1)) geo[[length(geo) + 1]] <- g1

    # Points per possession by whether any of its chances had a paint touch.
    pp <- ch[, .(pts = sum(pts), any_pt = any(n_pt > 0), trans = any(transition)), by = poss]
    pts_poss[[length(pts_poss) + 1]] <- pp
  }
  # Stack the games, then label chances by paint touch and context.
  ch <- rbindlist(rows, fill = TRUE)
  K <- rbindlist(kick, fill = TRUE)
  G <- rbindlist(geo, fill = TRUE)
  PP <- rbindlist(pts_poss)
  SP_ <- rbindlist(spots, fill = TRUE)
  AG <- rbindlist(agree)

  ch[, pt := fifelse(n_pt > 0, "paint touch", "no paint touch")]
  ch[, ctx := fifelse(start == "FGORB", "after offensive rebound", fifelse(transition, "transition", "half court"))]
  ch[, npt := fifelse(n_pt >= 3, "3+", as.character(n_pt))]
  base <- ch
  share_pt <- mean(ch$n_pt > 0)
  hc <- ch[ctx == "half court"]
  w <- ch[pt == "paint touch"]
  wo <- ch[pt == "no paint touch"]
  agree_v <- AG[vendor == TRUE, mean(tracked)]
  agree_t <- AG[tracked == TRUE, mean(vendor)]

  # Duration strata: chances that last longer have more time to reach the paint.
  ch[, dur := cut(secs, c(-Inf, 6, 10, 14, Inf), labels = c("under 6 s", "6-10 s", "10-14 s", "14 s or more"))]
  dur_tab <- ch[ctx == "half court", .(n = .N, ppc = mean(pts)), by = .(dur, pt)]
  dur_lines <- dcast(dur_tab, dur ~ pt, value.var = "ppc")
  durcats <- levels(ch$dur)

  # Kick-out shots.
  K[, kind := fifelse(own_paint, "shot on the paint touch itself", fifelse(paint_before, "shot after a paint touch (kick-out or swing)", "no paint touch before the shot"))]
  K3 <- K[three == TRUE & !own_paint]
  K3[, grp := fifelse(paint_before, "after a paint touch", "no paint touch before")]
  K3[, abin := cut(after_secs, c(-Inf, 1.5, 3, 5, Inf), labels = c("under 1.5 s", "1.5-3 s", "3-5 s", "5 s or more"))]

  # Team shape timeline.
  Gm <- G[, .(def_paint = mean(def_paint), def_hull = mean(def_hull), open_mean = mean(open_mean, na.rm = TRUE),
              holder_open = mean(holder_open, na.rm = TRUE), n = .N), by = .(grp, t)]
  src_lv <- c("drive", "catch in the key", "post-up", "offensive rebound", "other dribble in")
  Gm <- Gm[n >= 15]

  # Teams.
  teams <- rbindlist(lapply(BL, function(B) unique(B$roster[, .(team = team, team_name)])))
  teams <- unique(teams, by = "team")
  ch[, team_name := teams$team_name[match(off, teams$team)]]
  tt <- ch[, .(n = .N, pt_rate = mean(n_pt > 0), ppc_pt = mean(pts[n_pt > 0]), ppc_no = mean(pts[n_pt == 0]),
               tov_pt = mean(tov[n_pt > 0]), tov_no = mean(tov[n_pt == 0]),
               ft_pt = mean(ftrip[n_pt > 0]), ft_no = mean(ftrip[n_pt == 0])), by = team_name][order(-pt_rate)]
  tt[, gap := ppc_pt - ppc_no]

  # Players: who gets the ball into the paint, and what happens.
  pl_pt <- rbindlist(lapply(BL, function(B) {
    ch <- B$ch[in_pop == TRUE]
    tc <- merge(B$touches, ch[, .(chance, cut_f, off)], by = "chance")[f0 <= cut_f & team == off]
    tc[, canon := B$roster$canon[match(pid, B$roster$pid)]]
    tc[, name := B$roster$name[match(pid, B$roster$pid)]]
    tc[, team_name := B$roster$team_name[match(pid, B$roster$pid)]]
    tc
  }))
  pl <- pl_pt[, .(touches = .N, paint = sum(vendor_paint), drives_in = sum(vendor_paint & !in_paint(x0, y0)),
                  shot = sum(vendor_paint & grepl("FG[MX]", outs)), pass = sum(vendor_paint & grepl("PASS", outs) & !grepl("FG[MX]", outs)),
                  ast = sum(vendor_paint & grepl("AST", outs)), fouled = sum(vendor_paint & grepl("FOU_S|FOU_B", outs)),
                  tov = sum(vendor_paint & grepl("TO", outs)), name = name[1], team = team_name[1]), by = canon]
  pl[, `:=`(paint_rate = paint / touches, shot_share = shot / pmax(1, paint), pass_share = pass / pmax(1, paint),
            ast_share = ast / pmax(1, paint), tov_share = tov / pmax(1, paint))]
  pl <- pl[paint >= 10][order(-paint)]

  # Shot-clock timing of the first paint touch.
  scb <- ch[!is.na(sc_entry) & ctx == "half court"]
  scb[, scbin := cut(sc_entry, c(-Inf, 6, 12, 18, Inf), labels = c("0-6 s left", "6-12 s left", "12-18 s left", "18-24 s left"))]

  # The tab's document.
  sections <- list(SECTION("pt-question", "The Question",
                           P("When the offense gets the ball into the paint, what happens to the rest of the chance?"),
                           BUL("**Paint touch** = any touch whose SkillCorner regions include the paint (`key`) or the restricted area, before the chance's shot. That covers catches on a cut or roll, drives, post-ups and offensive rebounds",
                               "**Chance** = one scoring opportunity. An offensive rebound keeps the possession alive and starts a new chance, so I score points, shot quality, turnovers, free throws and offensive rebounds per chance",
                               sprintf("I checked SkillCorner's flag against the tracking. On %s of flagged touches the ball handler is tracked inside the paint at some frame, so I kept the flag as delivered", pct(agree_v)),
                               sprintf("Going the other way, SkillCorner flags %s of the touches where the tracking puts the ball handler in the paint", pct(agree_t))),
                           KPIS(KPI("Chances", int(nrow(ch)), "ten tracked games"),
                                KPI("With a paint touch", pct(share_pt), sprintf("%s chances", int(sum(ch$n_pt > 0)))),
                                KPI("Points per chance", sprintf("%.2f vs %.2f", mean(w$pts), mean(wo$pts)), "with vs without"),
                                KPI("Paint touches", int(sum(ch$n_pt)), sprintf("%.2f per chance", mean(ch$n_pt)))),
                           CAVEAT("Chances that reach the paint also run longer, face different defenses and feature different shooters",
                                  "Every gap on this tab is an association across ten games. Forcing more paint touches would likely close only part of it")),
                   SECTION("pt-overall", "With and Without a Paint Touch",
                           BUL("Each dot is the group's rate with a 90% interval (Wilson for shares, ±1.645 standard errors for means)",
                               "The dashed line is the average over all chances",
                               "The intervals treat chances as independent. Chances in one game share players and opponents, so the true intervals are wider"),
                           outcome_panel(copy(ch)[, grp := pt], order = c("paint touch", "no paint touch"), base = base),
                           TAKE(sprintf("**Chances with a paint touch score more.** %.2f points per chance with one and %.2f without, about %.0f more points per 100 chances", mean(w$pts), mean(wo$pts), 100 * (mean(w$pts) - mean(wo$pts))),
                                sprintf("**Fewer turnovers, more trips to the line.** Turnovers %s vs %s, free-throw trips %s vs %s", pct(mean(w$tov)), pct(mean(wo$tov)), pct(mean(w$ftrip)), pct(mean(wo$ftrip))),
                                sprintf("**Better shots.** %.2f vs %.2f xPts per attempt", mean(w$xpts, na.rm = TRUE), mean(wo$xpts, na.rm = TRUE)),
                                sprintf("**About the same on the glass.** Offensive rebounds on live misses %s vs %s", pct(sum(w$oreb & w$live) / max(1, sum(w$live))), pct(sum(wo$oreb & wo$live) / max(1, sum(wo$live)))))),
                   SECTION("pt-context", "By Context and Count",
                           BUL("Transition chances and putbacks reach the paint far more often than half-court sets, so the overall split mixes contexts",
                               "The tables repeat the outcomes inside each context, then by how many paint touches the chance had"),
                           outcome_table(copy(ch)[, g2 := paste(ctx, "·", pt)], "g2", base = base, label = "Context · paint touch", limit = 6,
                                         title = "Outcomes by context"),
                           outcome_table(copy(ch), "npt", base = base, label = "Paint touches in the chance", limit = 6,
                                         title = "Outcomes by number of paint touches"),
                           GRID(COLS("Half-court points per chance by chance length", durcats,
                                     list(SERIES1("No paint touch", dur_lines[match(durcats, dur)][["no paint touch"]], PAL[2]),
                                          SERIES1("Paint touch", dur_lines[match(durcats, dur)][["paint touch"]], PAL[1])), fmt = "num2", labels = TRUE,
                                     note = "Longer chances have more time to reach the paint. The gap inside each length band is what remains of the association."),
                                RATES("Half-court points per chance by shot clock at the first paint touch",
                                      lapply(levels(scb$scbin), function(l) mrow(l, scb[scbin == l]$pts)), fmt = "num2", unit = "points per chance",
                                      ref = mean(hc$pts), refLabel = "half court"))),
                   SECTION("pt-source", "How the Ball Got In",
                           P("The first paint touch of each chance, by how it happened, and what that touch did next."),
                           outcome_panel(copy(ch[!is.na(src)])[, grp := src], order = src_lv, base = base),
                           COLS("What the first paint touch did", src_lv,
                                lapply(c("shot", "pass out", "fouled", "turnover"), function(d) SERIES1(d, sapply(src_lv, function(s) {
                                  x <- ch[src == s]
                                  if (!nrow(x)) NA else mean(x$did == d)
                                }), PAL[match(d, c("shot", "pass out", "fouled", "turnover"))])),
                                fmt = "pct", note = "Shares of each source's first paint touches. I left out 'other' (held, timeout, period end)."),
                           GRID(COURT("Where first paint touches were made (ball handler at the entry frame)", SP_$x, SP_$y, bw = 1.2),
                                COURT("Where drives reached the paint", SP_[source == "drive"]$x, SP_[source == "drive"]$y, bw = 1.2))),
                   SECTION("pt-kick", "Kickouts",
                           BUL("A paint touch often ends in a pass out of the paint",
                               "These charts take three-point attempts from a later touch than the paint touch in the same chance (the kickout, or a swing after it)",
                               "I compare them with threes from chances where the ball never reached the paint before the shot"),
                           GRID(RATES("Three-point attempts: shot quality (xPts)", list(mrow("after a paint touch", K3[paint_before == TRUE]$xpts),
                                                                                        mrow("no paint touch before", K3[paint_before == FALSE]$xpts)),
                                      fmt = "num2", unit = "xPts per attempt", ref = mean(K3$xpts, na.rm = TRUE)),
                                RATES("Three-point attempts: closest defender at release (ft)", list(mrow("after a paint touch", K3[paint_before == TRUE]$defDist),
                                                                                                     mrow("no paint touch before", K3[paint_before == FALSE]$defDist)),
                                      fmt = "num1", unit = "ft to the closest defender", ref = mean(K3$defDist, na.rm = TRUE)),
                                RATES("Three-point attempts: made", list(rrow("after a paint touch", sum(K3[paint_before == TRUE]$made), nrow(K3[paint_before == TRUE])),
                                                                         rrow("no paint touch before", sum(K3[paint_before == FALSE]$made), nrow(K3[paint_before == FALSE]))),
                                      unit = "made", ref = mean(K3$made)),
                                RATES("Threes after a paint touch, by time since it", lapply(levels(K3$abin), function(l) mrow(l, K3[abin == l]$defDist)),
                                      fmt = "num1", unit = "ft to the closest defender", ref = mean(K3[paint_before == FALSE]$defDist, na.rm = TRUE),
                                      refLabel = "no paint touch")),
                           TABLE("All FGA by where the shot came from relative to the paint touch",
                                 cols = list(col("kind", "Where the shot came from"), col("n", "FGA", "int"), col("xpts", "xPts", "num2"), col("efg", "eFG%", "pct"),
                                             col("def", "Closest def. (ft)", "num1"), col("cns", "Catch & shoot", "pct"), col("three", "Threes", "pct")),
                                 rows = K[, .(n = .N, xpts = mean(xpts, na.rm = TRUE), efg = sum(made * fifelse(three, 1.5, 1)) / .N,
                                              def = mean(defDist, na.rm = TRUE), cns = mean(cns, na.rm = TRUE), three = mean(three)), by = kind][order(-n)]),
                           TAKE(sprintf("**Kickouts find more room.** On threes after a paint touch the closest defender was %.1f ft away, against %.1f ft on threes without one",
                                        mean(K3[paint_before == TRUE]$defDist, na.rm = TRUE), mean(K3[paint_before == FALSE]$defDist, na.rm = TRUE)),
                                sprintf("**And better looks.** %.2f vs %.2f xPts per attempt", mean(K3[paint_before == TRUE]$xpts, na.rm = TRUE), mean(K3[paint_before == FALSE]$xpts, na.rm = TRUE)))),
                   SECTION("pt-shape", "How the Defense Collapses",
                           BUL("Team shape from the tracking, averaged over the first paint touch of each chance",
                               "From 2 s before the entry frame to 2 s after. 0 is the first frame the ball handler is tracked in the paint",
                               "Only frames with all ten players tracked count, and each point needs at least 15 entries",
                               "**Hull** = the area inside the five defenders (their convex hull). A smaller hull means the defense has shrunk the floor"),
                           GRID(SCAT("Defenders inside the paint", lines = LINES_BY(Gm, "t", "def_paint", "grp", src_lv), xlabel = "seconds from the paint entry", ylabel = "defenders in the paint"),
                                SCAT("Defense's hull (sq ft)", lines = LINES_BY(Gm, "t", "def_hull", "grp", src_lv), xlabel = "seconds from the paint entry", ylabel = "sq ft", yfmt = "int"),
                                SCAT("Off-ball attackers: distance to the nearest defender (ft)", lines = LINES_BY(Gm, "t", "open_mean", "grp", src_lv), xlabel = "seconds from the paint entry", ylabel = "ft"),
                                SCAT("Ball handler: distance to the nearest defender (ft)", lines = LINES_BY(Gm, "t", "holder_open", "grp", src_lv), xlabel = "seconds from the paint entry", ylabel = "ft")),
                           {
                             at <- function(m, tt) Gm[grp == "drive" & abs(t - tt) < 0.01][[m]][1]
                             TAKE(sprintf("**The help comes.** On drives, defenders in the paint go from %.1f two seconds before the entry to %.1f one second after", at("def_paint", -2), at("def_paint", 1)),
                                  sprintf("The defense's hull shrinks from %.0f to %.0f sq ft as the help sinks", at("def_hull", -2), at("def_hull", 1)),
                                  sprintf("Attackers away from the ball gain room, from %.1f ft to %.1f ft at the entry. That room feeds the kickout threes above", at("open_mean", -2), at("open_mean", 0)))
                           }),
                   SECTION("pt-teams", "Teams and Players",
                           TABLE("Teams: paint touch rate and what it is worth", limit = 20, rows = tt[n >= 50], cols = list(col("team_name", "Team"), col("n", "Chances", "int"), col("pt_rate", "Paint touch %", "pct", ref = share_pt, scale = 0.12),
                                                                                                                             col("ppc_pt", "Pts/ch with", "num2"), col("ppc_no", "Pts/ch without", "num2"), col("gap", "Pts/ch gap", "num2", ref = 0, scale = 0.4),
                                                                                                                             col("tov_pt", "TOV% with", "pct"), col("tov_no", "TOV% without", "pct"), col("ft_pt", "FT trip% with", "pct"), col("ft_no", "FT trip% without", "pct")),
                                 note = "Most teams appear in one or two of the ten games, so each row is a small sample of that team."),
                           TABLE("Players with 10+ paint touches: what they do with them", limit = 25, rows = pl, cols = list(col("name", "Player"), col("team", "Team"), col("touches", "Touches", "int"), col("paint", "Paint touches", "int"),
                                                                                                                              col("paint_rate", "Paint %", "pct", ref = mean(pl_pt$vendor_paint), scale = 0.15),
                                                                                                                              col("shot_share", "Shot share", "pct", title = "Share of his paint touches that ended in his own shot"),
                                                                                                                              col("pass_share", "Pass out", "pct"), col("ast_share", "Assist", "pct"),
                                                                                                                              col("fouled", "Fouled", "int"), col("tov_share", "TOV", "pct", ref = sum(pl$tov) / sum(pl$paint), scale = 0.08, low = TRUE)),
                                 note = "Shares of each player's paint touches. A touch that passes and assists counts in both."),
                           BUL(sprintf("Per possession, the offense scored %.2f points when any of its chances reached the paint and %.2f when none did", mean(PP[any_pt == TRUE]$pts), mean(PP[any_pt == FALSE]$pts)),
                               sprintf("That covers %s possessions, counting every chance in each", int(nrow(PP))))),
                   SECTION("pt-limits", "What to Keep in Mind",
                           BUL("This tab shows how often the ball gets into the paint, how it gets there, how the defense collapses in the next two seconds and how the chance ends",
                               "Good offenses, bad defenses and long chances all produce more paint touches. The gaps above mix those in with any effect of the touch itself"),
                           H("Next Steps"),
                           BUL("Compare paint touches within the same team and lineup",
                               "Split touches that end the chance (layup, foul) from touches that move the defense (kickout). The first group is mostly shot location",
                               "Test whether a bigger collapse predicts a more open next shot beyond where that shot is taken")))
  DOC("paint", "Paint Touches", "How getting the ball into the paint relates to shot quality, turnovers, free throws and offensive rebounds in the ten tracked games.", sections)
}
