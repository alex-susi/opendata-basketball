# Topic: closeouts. Which defenders close out well, and what does a closeout lead to?
#
# SkillCorner marks a closeout when a defender runs at a player who has just caught the ball: the touch's frame,
# the closeout's start and end frames, the ball handler-to-defender distance at the touch, the start and the end,
# and what the ball handler did after the catch (bhrAction: shot, drive, pass, other).
#
# From the tracking, for the defender (positions smoothed over 5 frames, speed from the centred difference):
#   run          distance he covered from the closeout's start to its end (ft)
#   peak         his fastest speed during it (ft/s)
#   arrival      his speed over the last 3 frames before the end (ft/s): "under control" is low
#   reaction     closeout start minus the catch (s). SkillCorner starts every closeout before the catch (median
#                0.4 s, while the pass is in the air), so this measures how early he left, not a reaction time
#   goal side    at the end he is nearer the hoop than the ball handler
#   offset       the angle at the ball handler between the defender and the hoop (0° = squarely in the way)
# Shooter profile (season aggregates, 293 games): three-point attempts per 100 possessions, three-point percentage
# shrunk toward the league with 100 attempts of prior weight, and drives per 100 possessions. "Shooter" = above the
# median volume of the closed-out players and at or above the league percentage; "driver" = above their median drives.

topic_closeouts <- function(BL) {
  rows <- list()
  # One game at a time: each closeout with its chance outcome, the defender's run, and what the catch led to.
  for (B in BL) {
    co <- merge(B$co, B$ch[, .(chance, pts, xpts_ch = xpts, tov, ftrip, fga, efg_pts, live, oreb, transition, off)], by = "chance")
    if (!nrow(co)) next
    # The defender's track from 3 frames before to 3 after the closeout, smoothed, with speeds over 35 ft/s dropped.
    stat <- rbindlist(lapply(seq_len(nrow(co)), function(i) {
      c <- co[i]
      fr <- (c$f0 - 3L):(c$f1 + 3L)
      p <- pos_at(B, fr, rep(c$adef, length(fr)))
      ok <- !is.na(p$x)
      if (sum(ok) < 6) return(data.table(i = i))
      sx <- frollmean(p$x, 5, align = "center")
      sy <- frollmean(p$y, 5, align = "center")
      vx <- c(NA, diff(sx)) * FPS
      vy <- c(NA, diff(sy)) * FPS
      sp <- sqrt(vx^2 + vy^2)
      sp[sp > 35] <- NA
      inwin <- fr >= c$f0 & fr <= c$f1
      run <- sum(sqrt(diff(sx[inwin])^2 + diff(sy[inwin])^2), na.rm = TRUE)
      arr <- mean(sp[fr >= c$f1 - 3 & fr <= c$f1], na.rm = TRUE)
      # At the end: goal side, and the angle at the ball handler between the defender and the hoop.
      bh <- pos_at(B, c$f1, c$actor)
      dd <- pos_at(B, c$f1, c$adef)
      gs <- hoop_dist(dd$x, dd$y) < hoop_dist(bh$x, bh$y)
      ang <- {
        ux <- dd$x - bh$x
        uy <- dd$y - bh$y
        hx <- HOOP_X - bh$x
        hy <- -bh$y
        acos(pmin(1, pmax(-1, (ux * hx + uy * hy) / sqrt((ux^2 + uy^2) * (hx^2 + hy^2))))) * 180 / pi
      }
      data.table(i = i, run = run, peak = suppressWarnings(max(sp[inwin], na.rm = TRUE)), arrival = arr,
                 goal_side = gs, offset = ang, end_gap = sqrt((dd$x - bh$x)^2 + (dd$y - bh$y)^2), seen = mean(p$det[inwin] == 1L, na.rm = TRUE))
    }), fill = TRUE)
    co <- cbind(co, stat[, -"i"][match(seq_len(nrow(co)), stat$i)])
    # The shot or drive on the closed-out touch, and names.
    sh <- B$shots[, .(touch, s_made = made, s_three = three, s_xpts = xpts, s_fga = fga, s_cl = cl, s_dd = defDist)]
    co <- merge(co, sh[!duplicated(touch)], by = "touch", all.x = TRUE)
    dr <- B$drives[, .(touch, blowby, d_end = end)]
    co <- merge(co, dr[!duplicated(touch)], by = "touch", all.x = TRUE)
    co[, `:=`(game = B$game,
              def_canon = B$roster$canon[match(adef, B$roster$pid)], def_name = B$roster$name[match(adef, B$roster$pid)],
              def_team = B$roster$team_name[match(adef, B$roster$pid)],
              bh_canon = B$roster$canon[match(actor, B$roster$pid)], bh_name = B$roster$name[match(actor, B$roster$pid)])]
    rows[[length(rows) + 1]] <- co
  }
  co <- rbindlist(rows, fill = TRUE)
  # Timing, outcomes and the catch spot.
  co[is.infinite(peak), peak := NA_real_]
  co[, reaction := (f0 - ft) / FPS]
  co[, dur := (f1 - f0) / FPS]
  co[, fouled := grepl("FOU_S|FOU_B", outs)]
  co[, turnover := grepl("TO", outs)]
  co[, spot := floor_zone(x, y)]
  co[, spot := fifelse(spot %in% c("corner three", "above-break three"), spot, fifelse(spot == "deep", "above-break three", "inside the arc"))]
  co[, act := fifelse(is.na(bhr_action), "other", bhr_action)]

  # Shooter and driver profile of the man closed out, from the season aggregates.
  prof <- SP[, .(bh_canon = canon, three_per100, three_shrunk, drives_per100, three_att, archetype)]
  co <- merge(co, prof, by = "bh_canon", all.x = TRUE)
  lg3 <- attr(SP, "league_three")
  bh_players <- unique(co[!is.na(three_per100), .(bh_canon, three_per100, drives_per100)])
  med_v <- median(bh_players$three_per100)
  med_d <- median(bh_players$drives_per100)
  co[, shooter := !is.na(three_per100) & three_per100 >= med_v & three_shrunk >= lg3]
  co[, driver := !is.na(drives_per100) & drives_per100 >= med_d]
  co[, profile := fifelse(is.na(three_per100), "no season profile",
                          fifelse(shooter & !driver, "shooter, not a driver", fifelse(shooter & driver, "shooter and driver",
                                                                                      fifelse(!shooter & driver, "driver, not a shooter", "neither"))))]
  prof_lv <- c("shooter, not a driver", "shooter and driver", "driver, not a shooter", "neither")
  # Bins for the panels.
  co[, tight := cut(d1, c(-Inf, 4, 6, Inf), labels = c("tight (≤4 ft)", "medium (4-6 ft)", "loose (>6 ft)"))]
  tight_lv <- levels(co$tight)
  co[, arrb := cut(arrival, c(-Inf, 6, 10, 14, Inf), labels = c("under 6 ft/s", "6-10 ft/s", "10-14 ft/s", "14+ ft/s"))]
  co[, reb := cut(reaction, c(-Inf, -0.8, -0.5, -0.3, Inf), labels = c("0.8+ s before the catch", "0.5-0.8 s before", "0.3-0.5 s before", "under 0.3 s before"))]
  co[, runb := cut(run, c(-Inf, 6, 10, 15, Inf), labels = c("under 6 ft", "6-10 ft", "10-15 ft", "15+ ft"))]
  co[, offb := cut(offset, c(-Inf, 20, 45, 90, Inf), labels = c("in the way (<20°)", "20-45°", "45-90°", "beaten (>90°)"))]
  base_rates <- function(d) list(shot = mean(d$act == "shot"), drive = mean(d$act == "drive"), pass = mean(d$act == "pass"))
  br <- base_rates(co)

  # What followed, as five rates per group.
  act_panel <- function(g, lv, title) {
    d <- co[!is.na(get(g))]
    GRID(RATES(paste(title, "· shot"), lapply(lv, function(l) rrow(l, sum(d[get(g) == l]$act == "shot"), nrow(d[get(g) == l]))), ref = br$shot, unit = "shot after the catch"),
         RATES(paste(title, "· drive"), lapply(lv, function(l) rrow(l, sum(d[get(g) == l]$act == "drive"), nrow(d[get(g) == l]))), ref = br$drive, unit = "drove"),
         RATES(paste(title, "· blow-by on the drive"), lapply(lv, function(l) {
           x <- d[get(g) == l & act == "drive" & !is.na(blowby)]
           rrow(l, sum(x$blowby), nrow(x))
         }),
               ref = mean(co[act == "drive" & !is.na(blowby)]$blowby), unit = "blow-bys per drive"),
         RATES(paste(title, "· points in the chance"), lapply(lv, function(l) mrow(l, d[get(g) == l]$pts)), fmt = "num2", ref = mean(co$pts), unit = "points per chance"),
         RATES(paste(title, "· xPts of the catch-and-shoot"), lapply(lv, function(l) mrow(l, d[get(g) == l & act == "shot"]$s_xpts)), fmt = "num2",
               ref = mean(co[act == "shot"]$s_xpts, na.rm = TRUE), unit = "xPts of the shot after the closeout"),
         RATES(paste(title, "· fouled or turnover"), lapply(lv, function(l) rrow(l, sum(d[get(g) == l]$fouled | d[get(g) == l]$turnover), nrow(d[get(g) == l]))),
               ref = mean(co$fouled | co$turnover), unit = "foul drawn or turnover on the touch"))
  }

  # Decision matrix: profile x tightness.
  dm <- co[profile %in% prof_lv & !is.na(tight), .(n = .N, shot = mean(act == "shot"), drive = mean(act == "drive"),
                                                   blowby = sum(blowby & act == "drive", na.rm = TRUE) / max(1, sum(act == "drive" & !is.na(blowby))),
                                                   ppc = mean(pts), sxp = mean(s_xpts[act == "shot"], na.rm = TRUE)), by = .(profile, tight)]
  dm[, profile := factor(profile, prof_lv)][, tight := factor(tight, tight_lv)]
  setorder(dm, profile, tight)
  dm[, cell := paste(profile, "·", tight)]

  # Defenders.
  dfd <- co[!is.na(def_canon), .(n = .N, team = def_team[1], name = def_name[1], d1 = mean(d1, na.rm = TRUE), run = mean(run, na.rm = TRUE),
                                 peak = mean(peak, na.rm = TRUE), arrival = mean(arrival, na.rm = TRUE), reaction = mean(reaction, na.rm = TRUE),
                                 shot = mean(act == "shot"), drive = mean(act == "drive"),
                                 blowby = sum(blowby & act == "drive", na.rm = TRUE) / max(1, sum(act == "drive" & !is.na(blowby))),
                                 ppc = mean(pts), faced3 = mean(three_shrunk, na.rm = TRUE), shooters = mean(shooter)), by = def_canon][n >= 6][order(-n)]
  offn <- co[!is.na(bh_canon), .(n = .N, name = bh_name[1], profile = profile[1], three = three_shrunk[1], v3 = three_per100[1], dr = drives_per100[1],
                                 d1 = mean(d1, na.rm = TRUE), shot = mean(act == "shot"), drive = mean(act == "drive"), ppc = mean(pts)), by = bh_canon][n >= 5][order(-n)]

  # The tab's document.
  sections <- list(SECTION("co-question", "The question and the data",
                           P("A closeout is a defender running at a player who has just caught the ball. It is a trade."),
                           BUL("Close tight and fast, and he may drive past you",
                               "Stay back, and he may shoot",
                               "This tab describes SkillCorner's closeouts in the ten games, the defender's run from the tracking, what the ball handler did next, and how that depends on what kind of player he is"),
                           KPIS(KPI("Closeouts", int(nrow(co)), sprintf("%.0f per game", nrow(co) / length(BL))),
                                KPI("Shot after the catch", pct(br$shot), sprintf("drove %s, passed %s", pct(br$drive), pct(br$pass))),
                                KPI("Defender's run", sprintf("%.1f ft", median(co$run, na.rm = TRUE)), sprintf("median; peak speed %.1f ft/s", median(co$peak, na.rm = TRUE))),
                                KPI("End distance", sprintf("%.1f ft", median(co$d1, na.rm = TRUE)), "median, SkillCorner")),
                           COURT("Where the closed-out player caught the ball", co$x, co$y, bw = 1.5),
                           CAVEAT("About 60 closeouts per game means most defenders have a handful",
                                  "Rates per defender are shown with their counts. Read them as descriptions of these games, not ratings")),
                   SECTION("co-what", "What happens after a closeout",
                           GRID(COLS("What the ball handler did", c("shot", "drive", "pass", "other"),
                                     list(SERIES1("Share of closeouts", sapply(c("shot", "drive", "pass", "other"), function(a_) mean(co$act == a_)))), labels = TRUE),
                                COLS("By where he caught it", c("corner three", "above-break three", "inside the arc"),
                                     lapply(c("shot", "drive", "pass"), function(a_) SERIES1(a_, sapply(c("corner three", "above-break three", "inside the arc"),
                                                                                                        function(s) mean(co[spot == s]$act == a_)), PAL[match(a_, c("shot", "drive", "pass"))])), labels = FALSE)),
                           outcome_table(copy(co)[, xpts := xpts_ch],
                                         "act", label = "Ball handler's action", title = "The chance's outcome by the ball handler's action", min_n = 5)),
                   SECTION("co-run", "The defender's run",
                           BUL("How tight, how fast and how early the defender arrived, from SkillCorner's end distance and the tracking",
                               "Each panel shows what the ball handler did next and the chance's points"),
                           act_panel("tight", tight_lv, "End distance"),
                           act_panel("arrb", levels(co$arrb), "Arrival speed"),
                           act_panel("reb", levels(co$reb), "Start of the closeout"),
                           act_panel("offb", levels(co$offb), "Angle at the end"),
                           GRID(SCAT("Run length against end distance", points = co[!is.na(run) & !is.na(d1), .(x = r2(run, 1), y = r2(d1, 1), g = as.integer(act != "shot") + as.integer(act == "pass"),
                                                                                                                tip = sprintf("%s closing out %s\nran %.1f ft\nended %.1f ft away\nthen %s", def_name, bh_name, run, d1, act))],
                                     groups = c("shot", "drive / other", "pass"), xlabel = "defender's run (ft)", ylabel = "end distance (ft)", radius = 3),
                                SCAT("Peak speed against arrival speed", points = co[!is.na(peak) & !is.na(arrival), .(x = r2(peak, 1), y = r2(arrival, 1), g = as.integer(act == "drive" & blowby %in% TRUE),
                                                                                                                       tip = sprintf("%s closing out %s\npeak %.1f ft/s\narrival %.1f ft/s\nthen %s", def_name, bh_name, peak, arrival, act))],
                                     groups = c("no blow-by", "blow-by"), xlabel = "peak speed (ft/s)", ylabel = "arrival speed (ft/s)", radius = 3))),
                   SECTION("co-decision", "Closeouts by who was closed out on",
                           BUL("Season profiles split the ball handlers four ways",
                               sprintf("**Shooter** = above the median of the closed-out players in three-point attempts (%.1f per 100 possessions) and at or above the league percentage (%s)", med_v, pct(lg3, 1)),
                               sprintf("**Driver** = above their median in drives (%.1f per 100 possessions)", med_d),
                               "A tight closeout on a shooter who does not drive should take the shot away at little cost",
                               "On a driver who does not shoot, it gives up the drive for nothing"),
                           act_panel("profile", prof_lv, "Profile"),
                           TABLE("Profile × end distance", limit = 15, rows = dm, cols = list(col("profile", "Ball handler"), col("tight", "Closeout"), col("n", "Closeouts", "int"),
                                                                                              col("shot", "Shot", "pct", ref = br$shot, scale = 0.15), col("drive", "Drive", "pct", ref = br$drive, scale = 0.15),
                                                                                              col("blowby", "Blow-by per drive", "pct"), col("ppc", "Pts/chance", "num2", ref = mean(co$pts), scale = 0.35),
                                                                                              col("sxp", "xPts of the shot", "num2")),
                                 note = "Cells hold 10-60 closeouts. Differences of 10 points in a share are within noise."),
                           TAKE(sprintf("Shooters who do not drive shot after %s of closeouts and drove after %s",
                                        pct(mean(co[profile == prof_lv[1]]$act == "shot")), pct(mean(co[profile == prof_lv[1]]$act == "drive"))),
                                sprintf("Drivers who do not shoot shot after %s and drove after %s",
                                        pct(mean(co[profile == prof_lv[3]]$act == "shot")), pct(mean(co[profile == prof_lv[3]]$act == "drive"))))),
                   SECTION("co-players", "Defenders and the players they closed out on",
                           TABLE("Defenders with 6+ closeouts", limit = 30, rows = dfd, cols = list(col("name", "Defender"), col("team", "Team"), col("n", "Closeouts", "int"),
                                                                                                    col("d1", "End dist. (ft)", "num1", ref = mean(co$d1, na.rm = TRUE), scale = 1.5, low = TRUE),
                                                                                                    col("run", "Run (ft)", "num1"), col("peak", "Peak (ft/s)", "num1"), col("arrival", "Arrival (ft/s)", "num1"),
                                                                                                    col("reaction", "Reaction (s)", "num2"), col("shot", "Shot allowed", "pct", ref = br$shot, scale = 0.2, low = TRUE),
                                                                                                    col("drive", "Drive allowed", "pct"), col("blowby", "Blow-by/drive", "pct", ref = mean(co[act == "drive"]$blowby, na.rm = TRUE), scale = 0.3, low = TRUE),
                                                                                                    col("ppc", "Pts/ch after", "num2", ref = mean(co$pts), scale = 0.4, low = TRUE),
                                                                                                    col("faced3", "Opp. 3P%", "pct1"), col("shooters", "Shooters faced", "pct")),
                                 note = "Tints compare with all closeouts. For end distance, blow-bys and points, lower is the defense's better side. Counts are small."),
                           TABLE("Players closed out on 5+ times", limit = 30, rows = offn, cols = list(col("name", "Player"), col("profile", "Profile"), col("n", "Closeouts", "int"), col("v3", "3PA/100", "num1"),
                                                                                                        col("three", "3P% (shrunk)", "pct1"), col("dr", "Drives/100", "num1"), col("d1", "End dist. (ft)", "num1"),
                                                                                                        col("shot", "Shot", "pct", ref = br$shot, scale = 0.2), col("drive", "Drive", "pct", ref = br$drive, scale = 0.2), col("ppc", "Pts/chance", "num2")))),
                   SECTION("co-limits", "What this shows and does not",
                           BUL("It shows how closeouts are run in these games and what follows them, split by the defender's run and by the kind of player closed out on",
                               "It does not grade defenders. Most have under ten closeouts, and the player they close out on drives the outcome",
                               "SkillCorner's closeout detection itself is not validated here"),
                           H("If this becomes the topic"),
                           BUL("Closeout value = the outcome after the closeout minus what that ball handler usually produces from the same spot (season and tracked priors)",
                               "Pool it per defender with shrinkage",
                               "Then separate the run (speed, angle, timing) from the result")))
  DOC("closeouts", "Closeouts", "Who closes out, how (run, speed, timing, angle), what the ball handler does next, and how that depends on his shooting and driving.", sections)
}
