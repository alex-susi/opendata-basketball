# Topic: how driving lanes open up.
#
# For every SkillCorner drive, the floor at the drive's start frame and in the three seconds before it (tracking):
#   lane         the straight line from the ball handler to the hoop; a defender is "in the lane" when he is within
#                LANE_W ft of it and between the two (not behind the ball handler, not behind the hoop)
#   help in lane defenders in the lane other than the ball handler's own defender (drives.ballhandlerDefId)
#   help gap     the nearest of those other defenders' distance to the lane (ft)
#   on-ball gap  the ball handler's distance to his own defender; "in the way" when the defender's angle from the
#                lane at the ball handler is under 30°
#   spacers      attackers other than the ball handler beyond the arc; "bigs in the key" attackers in the key
# Outcomes: blowby (SkillCorner), how the drive ended (endType), whether the drive's touch drew a foul or lost the
# ball, and the chance's points.

# ft from the handler's line to the hoop within which a defender is in the lane.
LANE_W <- 6

# Lane measures for drives at given frames: help in the lane, gaps, the own defender's angle, spacers and bigs.
lane_frames <- function(B, q) {
  # q: i (drive), t (s), frame, bh, adef, poss0
  q <- copy(q)
  q[, possf := B$Fr$poss[match(frame, B$Fr$frame)]]
  q <- q[!is.na(possf) & possf == poss0]
  W <- B$P[.(unique(q$frame)), nomatch = 0L]
  b <- merge(q, W[, .(frame, bh = pid, bx = x, by = y)], by = c("frame", "bh"))
  if (!nrow(b)) return(data.table())
  # Every defender's distance to the lane segment and position along it (st: 0 at the handler, 1 at the hoop).
  D <- merge(b[, .(i, t, frame, bx, by, adef)], W[off == FALSE, .(frame, dpid = pid, dx = x, dy = y)], by = "frame", allow.cartesian = TRUE)
  sd <- seg_dist(D$dx, D$dy, D$bx, D$by, HOOP_X, 0)
  D[, `:=`(sdist = sd$d, st = sd$t)]
  D[, inlane := sdist <= LANE_W & st > 0 & st < 1]
  D[, own := !is.na(adef) & dpid == adef]
  # Per frame: defenders in the lane, the nearest helper's gap, and the own defender's gap and angle from the lane.
  out <- D[, {
    o <- which(own)
    ang <- if (length(o)) {
      ux <- dx[o] - bx[o]
      uy <- dy[o] - by[o]
      hx <- HOOP_X - bx[o]
      hy <- -by[o]
      acos(pmin(1, pmax(-1, (ux * hx + uy * hy) / sqrt((ux^2 + uy^2) * (hx^2 + hy^2))))) * 180 / pi
    } else NA_real_
    .(lane_n = sum(inlane), help_lane = sum(inlane & !own), help_gap = suppressWarnings(min(sdist[!own & st > 0 & st < 1.05])),
      gap = if (length(o)) sqrt((dx[o] - bx[o])^2 + (dy[o] - by[o])^2) else NA_real_, angle = ang,
      def_paint = sum(in_paint(dx, dy)), bh_hoop = hoop_dist(bx[1], by[1]))
  }, by = .(i, t, frame)]
  # Attackers beyond the arc and in the key, the ball handler excluded.
  O <- merge(b[, .(i, t, frame, bh)], W[off == TRUE, .(frame, opid = pid, ox = x, oy = y)], by = "frame", allow.cartesian = TRUE)[opid != bh]
  O <- O[, .(spacers = sum(beyond_arc(ox, oy)), bigs_key = sum(in_paint(ox, oy))), by = .(i, t)]
  out <- merge(out, O, by = c("i", "t"), all.x = TRUE)
  out[is.infinite(help_gap), help_gap := NA_real_]
  out
}

topic_lanes <- function(BL) {
  D0 <- list()
  TL <- list()
  # One game at a time: each drive's lane at its start, and every 0.2 s from 3 s before to 1 s after.
  for (B in BL) {
    dr <- merge(B$drives, B$ch[, .(chance, pts, transition, xpts, tov, ftrip, poss0 = poss)], by = "chance")
    if (!nrow(dr)) next
    dr[, i := .I]
    q <- dr[, .(i, frame = f0, t = 0, bh = actor, adef, poss0)]
    m <- lane_frames(B, q)
    dr <- merge(dr, m[, -c("t", "frame")], by = "i", all.x = TRUE)
    tq <- CJ(i = dr$i, t = seq(-3, 1, by = 0.2))
    tq <- merge(tq, dr[, .(i, f0, bh = actor, adef, poss0, category)], by = "i")
    tq[, frame := f0 + as.integer(round(t * FPS))]
    tl <- lane_frames(B, tq[, .(i, t, frame, bh, adef, poss0)])
    tl <- merge(tl, dr[, .(i, category, blowby)], by = "i")
    tl[, game := B$game]
    TL[[length(TL) + 1]] <- tl
    # The shot on the drive's touch, and names.
    sh <- B$shots[, .(touch, s_made = made, s_xpts = xpts, s_zone = zone)][!duplicated(touch)]
    dr <- merge(dr, sh, by = "touch", all.x = TRUE)
    dr[, `:=`(game = B$game, canon = B$roster$canon[match(actor, B$roster$pid)], name = B$roster$name[match(actor, B$roster$pid)],
              team = B$roster$team_name[match(actor, B$roster$pid)], def_name = B$roster$name[match(adef, B$roster$pid)])]
    D0[[length(D0) + 1]] <- dr
  }
  d <- rbindlist(D0, fill = TRUE)
  tl <- rbindlist(TL, fill = TRUE)
  # Outcomes and labels, then bins for the panels.
  d[, fouled := grepl("FOU_S|FOU_B", outs)]
  d[, lost := grepl("TO", outs)]
  d[, rim_shot := end == "shotNearBasket"]
  d[, cat := c(pick = "pick", handoff = "handoff", offBallScreen = "off-ball screen", iso = "isolation", closeout = "closeout", miscellaneous = "other")[category]]
  cat_lv <- c("pick", "handoff", "off-ball screen", "isolation", "closeout", "other")
  tl[, cat := c(pick = "pick", handoff = "handoff", offBallScreen = "off-ball screen", iso = "isolation", closeout = "closeout", miscellaneous = "other")[category]]
  d[, end2 := c(kickout = "kick-out", turnover = "turnover", pullout = "pull-out", pullup = "pull-up", interiorPass = "interior pass",
                shotNearBasket = "shot near the basket")[end]]
  d[is.na(end2), end2 := "other"]
  end_lv <- c("shot near the basket", "pull-up", "kick-out", "interior pass", "pull-out", "turnover")
  bb <- mean(d$blowby, na.rm = TRUE)
  ok <- d[!is.na(lane_n)]
  ok[, laneb := factor(pmin(help_lane, 2), 0:2, c("0 help defenders", "1", "2+"))]
  ok[, hgb := cut(help_gap, c(-Inf, 2, 4, 6, 9, Inf), labels = c("under 2 ft", "2-4 ft", "4-6 ft", "6-9 ft", "9+ ft"))]
  ok[, gapb := cut(gap, c(-Inf, 3, 4.5, 6, Inf), labels = c("under 3 ft", "3-4.5 ft", "4.5-6 ft", "6+ ft"))]
  ok[, angb := cut(angle, c(-Inf, 30, 60, 90, Inf), labels = c("in the way (<30°)", "30-60°", "60-90°", "beaten (>90°)"))]
  ok[, spb := factor(pmin(spacers, 4), 0:4, c("0", "1", "2", "3", "4"))]
  ok[, bkb := factor(pmin(bigs_key, 2), 0:2, c("0", "1", "2+"))]

  # Six panels for one grouping: blow-by, rim shot, foul, turnover, points and share of drives.
  drive_panel <- function(g, lv, title) {
    x <- ok[!is.na(get(g))]
    GRID(RATES(paste(title, "· blow-by"), lapply(lv, function(l) {
      y <- x[get(g) == l & !is.na(blowby)]
      rrow(l, sum(y$blowby), nrow(y))
    }), ref = bb, unit = "blow-by"),
         RATES(paste(title, "· shot near the basket"), lapply(lv, function(l) rrow(l, sum(x[get(g) == l]$rim_shot), nrow(x[get(g) == l]))), ref = mean(d$rim_shot), unit = "ended in a shot near the basket"),
         RATES(paste(title, "· fouled"), lapply(lv, function(l) rrow(l, sum(x[get(g) == l]$fouled), nrow(x[get(g) == l]))), ref = mean(d$fouled), unit = "drew a foul"),
         RATES(paste(title, "· lost the ball"), lapply(lv, function(l) rrow(l, sum(x[get(g) == l]$lost), nrow(x[get(g) == l]))), ref = mean(d$lost), unit = "turnover on the drive"),
         RATES(paste(title, "· points in the chance"), lapply(lv, function(l) mrow(l, x[get(g) == l]$pts)), fmt = "num2", ref = mean(d$pts), unit = "points per chance"),
         RATES(paste(title, "· share of drives"), lapply(lv, function(l) rrow(l, nrow(x[get(g) == l]), nrow(x))), unit = "of drives"))
  }

  # Average lane measures over time, by drive category and by blow-by.
  tlm <- tl[, .(help_lane = mean(help_lane), help_gap = mean(help_gap, na.rm = TRUE), gap = mean(gap, na.rm = TRUE),
                def_paint = mean(def_paint), angle = mean(angle, na.rm = TRUE), n = .N), by = .(cat, t)][n >= 15]
  tlb <- tl[!is.na(blowby), .(help_lane = mean(help_lane), gap = mean(gap, na.rm = TRUE), angle = mean(angle, na.rm = TRUE), n = .N),
            by = .(grp = fifelse(blowby, "blow-by", "no blow-by"), t)][n >= 15]
  # Change from 2 s before to the start.
  chg <- dcast(tl[abs(t + 2) < 0.01 | abs(t) < 0.01, .(i, game, cat, when = fifelse(t < -1, "before", "start"), help_lane, gap, angle, def_paint)],
               i + game + cat ~ when, value.var = c("help_lane", "gap", "angle", "def_paint"))
  chg <- chg[, .(n = .N, hl0 = mean(help_lane_before, na.rm = TRUE), hl1 = mean(help_lane_start, na.rm = TRUE),
                 g0 = mean(gap_before, na.rm = TRUE), g1 = mean(gap_start, na.rm = TRUE),
                 a0 = mean(angle_before, na.rm = TRUE), a1 = mean(angle_start, na.rm = TRUE)), by = cat][order(-n)]

  # Per player with 8+ drives.
  pl <- ok[, .(n = .N, name = name[1], team = team[1], blowby = mean(blowby, na.rm = TRUE), help_lane = mean(help_lane), gap = mean(gap, na.rm = TRUE),
               spacers = mean(spacers, na.rm = TRUE), rim = mean(rim_shot), ppc = mean(pts)), by = canon][n >= 8][order(-n)]

  # The tab's document.
  sections <- list(SECTION("ln-question", "The question and the data",
                           P("A driving lane is the path from the ball handler to the rim."),
                           BUL("It opens when his own defender is beaten or out of position, and the help is far from that path",
                               sprintf("**Lane** = the straight line from the ball handler to the hoop. A defender is in it when he is within %d ft of it and between the two", LANE_W),
                               "For each of SkillCorner's drives, this tab measures the lane at the start of the drive and in the three seconds before, and relates it to what the drive produced"),
                           KPIS(KPI("Drives", int(nrow(d)), sprintf("%s with full tracking at the start", int(nrow(ok)))),
                                KPI("Blow-by", pct(bb), "SkillCorner's flag"),
                                KPI("Help in the lane at the start", sprintf("%.2f", mean(ok$help_lane)), sprintf("defenders within %d ft of the path, besides his own", LANE_W)),
                                KPI("On-ball gap", sprintf("%.1f ft", median(ok$gap, na.rm = TRUE)), "median at the start")),
                           GRID(COURT("Where drives started", d$x, d$y, bw = 1.5), COURT("Where blow-by drives started", d[blowby %in% TRUE]$x, d[blowby %in% TRUE]$y, bw = 1.5)),
                           GRID(COLS("How drives ended", end_lv, list(SERIES1("Share of drives", sapply(end_lv, function(e) mean(d$end2 == e)))), labels = TRUE),
                                COLS("How drives were created", cat_lv, list(SERIES1("Share of drives", sapply(cat_lv, function(e) mean(d$cat == e)))), labels = TRUE))),
                   SECTION("ln-open", "The lane at the start of the drive",
                           drive_panel("laneb", levels(ok$laneb), "Help defenders in the lane"),
                           drive_panel("hgb", levels(ok$hgb), "Nearest help to the lane"),
                           drive_panel("angb", levels(ok$angb), "Own defender's angle"),
                           drive_panel("gapb", levels(ok$gapb), "On-ball gap")),
                   SECTION("ln-spacing", "Spacing around the drive",
                           BUL("**Spacers** = the four other attackers beyond the arc",
                               "**Attackers in the key** = attackers other than the driver standing in the key",
                               "Both are measured at the drive's start"),
                           drive_panel("spb", levels(ok$spb), "Spacers beyond the arc"),
                           drive_panel("bkb", levels(ok$bkb), "Attackers in the key"),
                           GRID(RATES("Help defenders in the lane by spacers", lapply(levels(ok$spb), function(l) mrow(l, ok[spb == l]$help_lane)), fmt = "num2",
                                      ref = mean(ok$help_lane), unit = "help defenders in the lane", refLabel = "all"),
                                RATES("Help defenders in the lane by attackers in the key", lapply(levels(ok$bkb), function(l) mrow(l, ok[bkb == l]$help_lane)), fmt = "num2",
                                      ref = mean(ok$help_lane), unit = "help defenders in the lane", refLabel = "all"))),
                   SECTION("ln-how", "How lanes open: the three seconds before",
                           BUL("The same measures every 0.2 s, from 3 s before the drive's start to 1 s after",
                               "Averaged by how SkillCorner says the drive was created, with at least 15 drives per point"),
                           GRID(SCAT("Help defenders in the lane", lines = LINES_BY(tlm, "t", "help_lane", "cat", cat_lv), xlabel = "seconds from the drive's start", ylabel = "defenders"),
                                SCAT("On-ball gap (ft)", lines = LINES_BY(tlm, "t", "gap", "cat", cat_lv), xlabel = "seconds from the drive's start", ylabel = "ft"),
                                SCAT("Own defender's angle from the lane (°)", lines = LINES_BY(tlm, "t", "angle", "cat", cat_lv), xlabel = "seconds from the drive's start", ylabel = "degrees", yfmt = "int"),
                                SCAT("Blow-by vs not: own defender's angle (°)", lines = LINES_BY(tlb, "t", "angle", "grp", c("blow-by", "no blow-by")), xlabel = "seconds from the drive's start", ylabel = "degrees", yfmt = "int")),
                           TABLE("Two seconds before vs the start, by how the drive was created", limit = 8, rows = chg, cols = list(col("cat", "Created by"), col("n", "Drives", "int"), col("hl0", "Help in lane −2 s", "num2"), col("hl1", "Help in lane at start", "num2"),
                                                                                                                                     col("g0", "On-ball gap −2 s", "num1"), col("g1", "On-ball gap at start", "num1"), col("a0", "Angle −2 s (°)", "num1"), col("a1", "Angle at start (°)", "num1"))),
                           TAKE(sprintf("Blow-by drives start with the ball handler's defender %.0f° off the lane on average, against %.0f° for the rest",
                                        mean(ok[blowby %in% TRUE]$angle, na.rm = TRUE), mean(ok[blowby %in% FALSE]$angle, na.rm = TRUE)),
                                sprintf("With no help defender in the lane, %s of drives end in a shot near the basket. With two or more, %s",
                                        pct(mean(ok[help_lane == 0]$rim_shot)), pct(mean(ok[help_lane >= 2]$rim_shot))))),
                   SECTION("ln-players", "Drivers",
                           TABLE("Players with 8+ drives: the lanes they attacked", limit = 30, rows = pl, cols = list(col("name", "Player"), col("team", "Team"), col("n", "Drives", "int"), col("blowby", "Blow-by", "pct", ref = bb, scale = 0.2),
                                                                                                                       col("help_lane", "Help in lane", "num2", ref = mean(ok$help_lane), scale = 0.5, low = TRUE), col("gap", "On-ball gap (ft)", "num1"),
                                                                                                                       col("spacers", "Spacers", "num1"), col("rim", "Shot near basket", "pct"), col("ppc", "Pts/chance", "num2", ref = mean(d$pts), scale = 0.4)))),
                   SECTION("ln-limits", "What this shows and does not",
                           BUL("It shows the state of the floor when drives start and how it changes in the seconds before, by how the drive was set up",
                               "The lane is a straight line to the rim, which simplifies real drives. They curve, and finish off either side"),
                           H("If this becomes the topic"),
                           BUL("The shape of the lane over time is the natural feature for a drive-outcome model",
                               "Compare it with the same shape on possessions where no drive happened, to see whether drivers pick open lanes or open lanes create drives")))
  DOC("lanes", "Driving lanes", "How the path to the rim looks when drives start, how it opens in the seconds before, and what open and crowded lanes produce.", sections)
}
