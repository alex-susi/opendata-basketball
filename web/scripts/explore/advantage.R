# Topic: advantage creation. Who creates advantages, and with which actions?
#
# An action's creator: the ball handler of a pick, the receiver of a handoff, the ball handler of an isolation, a
# post-up or a drive, the cutter of an off-ball screen. His defender: the one SkillCorner names on the action, else his
# matchup at that frame. Over the 2 s from the action's frame (every 2nd frame, same possession, frontcourt), from
# the tracking:
#   beaten      the creator is more than BEAT ft closer to the hoop than his own defender (in HOLD sampled frames,
#               about 0.3 s)
#   help drawn  two or more defenders within TWO ft of the creator at once (in HOLD sampled frames)
#   switch      SkillCorner's coverage on a pick or handoff is a switch (a different defender now has him)
# An action "creates an advantage" when any of the three happens. This is a deliberately simple definition, chosen to
# be checkable in the play viewer; it is not SkillCorner's and is not validated against video.
# Season view: the aggregates (293 games) give the drive blow-by rate and the pick ball handler's points per direct
# pick for many more possessions than the ten tracked games.

# Thresholds: ft for beaten (beat) and help (two), the window and sampling step in frames, frames needed (hold).
ADV <- list(beat = 1, two = 6, window = 50L, step = 2L, hold = 4L)

topic_advantage <- function(BL) {
  AA <- list()
  # One game at a time: every action with its creator and his defender, then 2 s of tracking after it.
  for (B in BL) {
    acts <- rbind(B$picks[, .(kind = "pick", chance, f0, actor, adef, cov)], B$handoffs[, .(kind = "handoff", chance, f0, actor, adef, cov)],
                  B$isos[, .(kind = "isolation", chance, f0, actor, adef, cov = NA_character_)],
                  B$posts[, .(kind = "post-up", chance, f0, actor, adef, cov = NA_character_)],
                  B$drives[, .(kind = "drive", chance, f0, actor, adef, cov = NA_character_)],
                  B$obs[, .(kind = "off-ball screen", chance, f0, actor, adef, cov)], fill = TRUE)
    acts <- merge(acts, B$ch[in_pop == TRUE, .(chance, pts, xpts, tov, ftrip, fga, efg_pts, live, oreb, cut_f, transition, poss0 = poss)], by = "chance")
    acts <- acts[!is.na(actor) & !is.na(f0)]
    if (!nrow(acts)) next
    acts[is.na(adef), adef := marker_of(B, f0, actor)]
    acts[, i := .I]
    # Every 2nd frame for 2 s after the action, in the same possession.
    q <- acts[, .(frame = f0 + seq(0L, ADV$window, by = ADV$step)), by = .(i, actor, adef, poss0)]
    q[, possf := B$Fr$poss[match(frame, B$Fr$frame)]]
    q <- q[!is.na(possf) & possf == poss0]
    W <- B$P[.(unique(q$frame)), nomatch = 0L]
    a_ <- merge(q, W[, .(frame, actor = pid, ax = x, ay = y)], by = c("frame", "actor"))
    # Each sampled frame: defenders near the creator, and his margin on his own defender toward the hoop.
    D <- merge(a_[, .(i, frame, ax, ay, adef)], W[off == FALSE, .(frame, dpid = pid, dx = x, dy = y)], by = "frame", allow.cartesian = TRUE)
    D[, dd := sqrt((dx - ax)^2 + (dy - ay)^2)]
    per_f <- D[, .(near2 = sum(dd <= ADV$two), near = min(dd),
                   own_margin = if (any(dpid == adef, na.rm = TRUE)) hoop_dist(dx[which(dpid == adef)[1]], dy[which(dpid == adef)[1]]) - hoop_dist(ax[1], ay[1]) else NA_real_,
                   front = ax[1] > 0), by = .(i, frame)]
    # Beaten and help drawn need HOLD sampled frames in the frontcourt.
    st <- per_f[front == TRUE, .(beaten = sum(own_margin > ADV$beat, na.rm = TRUE) >= ADV$hold, help = sum(near2 >= 2) >= ADV$hold,
                                 sep0 = near[1], sep_max = max(near), n_fr = .N), by = i]
    acts <- merge(acts, st, by = "i", all.x = TRUE)
    acts[, switched := kind %in% c("pick", "handoff") & cov %in% "switch"]
    # Did a closeout follow within 4 s in the same chance (the advantage passed on)?
    acts[, co_after := vapply(seq_len(.N), function(k) any(B$co$chance == chance[k] & B$co$f0 > f0[k] & B$co$f0 <= f0[k] + 100L), NA)]
    acts[, `:=`(game = B$game, canon = B$roster$canon[match(actor, B$roster$pid)], name = B$roster$name[match(actor, B$roster$pid)],
                team = B$roster$team_name[match(actor, B$roster$pid)])]
    AA[[length(AA) + 1]] <- acts
  }
  # Actions with enough sampled frames; an advantage is beaten, help drawn or a switch.
  A <- rbindlist(AA, fill = TRUE)[!is.na(n_fr) & n_fr >= 5]
  A[, adv := beaten | help | switched]
  A[, how := fifelse(switched, "switch", fifelse(beaten & help, "beaten and help drawn", fifelse(beaten, "beaten", fifelse(help, "help drawn", "none"))))]
  kind_lv <- c("pick", "handoff", "drive", "isolation", "post-up", "off-ball screen")
  how_lv <- c("beaten", "help drawn", "beaten and help drawn", "switch", "none")
  base_adv <- mean(A$adv)
  hc <- A[transition == FALSE]

  # Per player in the half court (15+ actions), with his rate by action type.
  pl <- hc[, .(n = .N, name = name[1], team = team[1], adv = mean(adv), beaten = mean(beaten), help = mean(help), switched = sum(switched),
               picks = sum(kind == "pick"), drives = sum(kind == "drive"), isos = sum(kind == "isolation"), posts = sum(kind == "post-up"),
               obs = sum(kind == "off-ball screen"), ppc = mean(pts), co_after = mean(co_after)), by = canon][n >= 15][order(-adv)]
  pk <- dcast(hc[, .(adv = mean(adv), n = .N), by = .(canon, kind)][n >= 5], canon ~ kind, value.var = "adv")
  pl <- merge(pl, pk, by = "canon", all.x = TRUE)
  setorder(pl, -adv)

  # Season aggregates.
  al <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
  canon <- function(p) {
    m <- al$canonical_player_id[match(p, al$player_id)]
    fifelse(is.na(m), p, m)
  }
  # A traded player's total row when he has one, else his per-team rows.
  rows_of <- function(d) {
    d <- copy(d)
    d[, canon := canon(player_id)]
    tot <- d[is.na(team_id) | team_name == "total"]
    d[!(canon %in% tot$canon) | is.na(team_id) | team_name == "total"]
  }
  dr <- rows_of(fread(file.path(a$root, "data", "aggregates", "acb_drivesaggregates_20252026.csv")))
  pk_s <- rows_of(fread(file.path(a$root, "data", "aggregates", "acb_picksaggregates_20252026.csv")))
  sd <- dr[, .(drives = sum(total_drives), blowby = sum(blowby_count), dpts = sum(points), dfouls = sum(fouls), poss = sum(possessions_played),
               name = player_name[1]), by = canon]
  sp <- pk_s[, .(picks = sum(handler_total_picks), ppts = sum(handler_points), psucc = sum(handler_successful_pick), switch_picks = sum(handler_picks_vs_switch),
                 switch_pts = sum(handler_points_vs_switch)), by = canon]
  season <- merge(sd, sp, by = "canon", all = TRUE)
  season[is.na(drives), drives := 0L][is.na(picks), picks := 0L]
  season[, `:=`(blowby_rate = blowby / pmax(1, drives), pts_drive = dpts / pmax(1, drives), ppp = ppts / pmax(1, picks), succ = psucc / pmax(1, picks),
                drives100 = 100 * drives / pmax(1, poss))]
  lg_bb <- sum(season$blowby, na.rm = TRUE) / sum(season$drives, na.rm = TRUE)
  lg_ppp <- sum(season$ppts, na.rm = TRUE) / sum(season$picks, na.rm = TRUE)
  # Season rates shrunk toward the league with 40 drives (or picks) of prior weight.
  season[, bb_shrunk := (blowby + 40 * lg_bb) / (drives + 40)]
  season[, ppp_shrunk := (ppts + 40 * lg_ppp) / (picks + 40)]
  s_drv <- season[drives >= 100][order(-bb_shrunk)]
  s_pk <- season[picks >= 100][order(-ppp_shrunk)]
  # Tracked advantage vs season blow-by, per player.
  cmp <- merge(pl[, .(canon, name, n, adv)], season[, .(canon, bb_shrunk, drives)], by = "canon")[drives >= 50]
  rr <- if (nrow(cmp) > 4) cor(cmp$adv, cmp$bb_shrunk) else NA_real_

  # The tab's document.
  sections <- list(SECTION("ad-question", "The question and the definition",
                           P("An advantage is a moment when the defense is out of balance. This tab counts three kinds:"),
                           BUL(sprintf("**Beaten** = the man with the action got more than %g ft nearer the hoop than his own defender", ADV$beat),
                               sprintf("**Help drawn** = a second defender had to come, so two defenders were within %g ft of him at once", ADV$two),
                               "**Switch** = a pick or handoff forced a switch (SkillCorner's coverage)",
                               "Each of the first two must last about 0.3 s, within 2 s of a pick, handoff, drive, isolation, post-up or off-ball screen"),
                           KPIS(KPI("Actions", int(nrow(A)), sprintf("%s in the half court", int(nrow(hc)))),
                                KPI("Created an advantage", pct(base_adv), "beaten, help drawn or switch"),
                                KPI("Beaten", pct(mean(A$beaten)), sprintf("help drawn %s", pct(mean(A$help)))),
                                KPI("Switches", pct(mean(A[kind %in% c("pick", "handoff")]$switched)), "of picks and handoffs")),
                           CAVEAT("A post-up or a pick naturally has two defenders near the ball (the screener's man), so help drawn means different things for different actions",
                                  "Compare players within an action type")),
                   SECTION("ad-actions", "Which actions create advantages",
                           GRID(RATES("Advantage rate by action", lapply(kind_lv, function(k) rrow(k, sum(A[kind == k]$adv), nrow(A[kind == k]))), ref = base_adv, unit = "created an advantage"),
                                RATES("Beaten, by action", lapply(kind_lv, function(k) rrow(k, sum(A[kind == k]$beaten), nrow(A[kind == k]))), ref = mean(A$beaten), unit = "creator beat his defender"),
                                RATES("Help drawn, by action", lapply(kind_lv, function(k) rrow(k, sum(A[kind == k]$help), nrow(A[kind == k]))), ref = mean(A$help), unit = "two defenders on him"),
                                RATES("Closeout followed within 4 s", lapply(kind_lv, function(k) rrow(k, sum(A[kind == k]$co_after), nrow(A[kind == k]))), ref = mean(A$co_after), unit = "a closeout followed")),
                           COLS("How advantages were made, by action", kind_lv, lapply(how_lv[1:4], function(h) SERIES1(h, sapply(kind_lv, function(k) mean(A[kind == k]$how == h)), PAL[match(h, how_lv)])),
                                note = "Shares of each action type's events. The rest created none."),
                           outcome_table(copy(A)[, `:=`(g = paste(kind, "·", fifelse(adv, "advantage", "none")))], "g",
                                         label = "Action · advantage", title = "The chance's outcome after each action, with and without an advantage", min_n = 15, limit = 14)),
                   SECTION("ad-value", "What an advantage is worth",
                           outcome_panel(copy(hc)[, grp := how], order = how_lv, base = hc, title = "Half court, by advantage"),
                           CAVEAT("A chance can hold several actions, so a chance's points appear once per action in it.")),
                   SECTION("ad-players", "Who creates advantages (ten tracked games)",
                           TABLE("Players with 15+ half-court actions", limit = 40, rows = pl, cols = list(col("name", "Player"), col("team", "Team"), col("n", "Actions", "int"), col("adv", "Advantage", "pct", ref = mean(hc$adv), scale = 0.2),
                                                                                                           col("beaten", "Beaten", "pct"), col("help", "Help drawn", "pct"), col("switched", "Switches", "int"),
                                                                                                           col("pick", "Adv. on picks", "pct"), col("drive", "on drives", "pct"), col("isolation", "on isos", "pct"),
                                                                                                           col("post-up", "on posts", "pct"), col("off-ball screen", "off screens", "pct"),
                                                                                                           col("co_after", "Closeout followed", "pct"), col("ppc", "Pts/chance", "num2", ref = mean(hc$pts), scale = 0.4)),
                                 note = "Per-action rates need five or more actions of that type. Most players appear in one game.")),
                   SECTION("ad-season", "Season view (aggregates, 293 games)",
                           BUL("The aggregates have no advantage flag, but two columns describe beating a defender",
                               sprintf("SkillCorner's blow-by rate on drives (league %s)", pct(lg_bb)),
                               sprintf("The ball handler's points per direct pick (league %.2f)", lg_ppp),
                               "Rates are shrunk toward the league with 40 events of prior weight, so small samples do not top the list"),
                           GRID(TABLE("Drivers with 100+ season drives, by shrunk blow-by rate", limit = 25, rows = s_drv, cols = list(col("name", "Player"), col("drives", "Drives", "int"), col("drives100", "Drives/100 poss", "num1"),
                                                                                                                                       col("blowby_rate", "Blow-by", "pct", ref = lg_bb, scale = 0.1), col("bb_shrunk", "Blow-by (shrunk)", "pct"), col("pts_drive", "Pts/drive", "num2"))),
                                TABLE("Pick ball handlers with 100+ direct picks, by shrunk points per pick", limit = 25, rows = s_pk, cols = list(col("name", "Player"), col("picks", "Direct picks", "int"), col("ppp", "Pts/pick", "num2", ref = lg_ppp, scale = 0.25),
                                                                                                                                                   col("ppp_shrunk", "Pts/pick (shrunk)", "num2"), col("succ", "Successful picks", "pct"), col("switch_picks", "vs switch", "int")))),
                           P(if (is.na(rr)) "Too few players to compare the tracked advantage rate with the season blow-by rate." else
                             sprintf("For the %d players with 15+ tracked actions and 50+ season drives, the tracked advantage rate and the shrunk season blow-by rate correlate at %.2f.", nrow(cmp), rr)),
                           SCAT("Tracked advantage rate against season blow-by rate", points = cmp[, .(x = r2(bb_shrunk), y = r2(adv), g = 0L, tip = sprintf("%s\n%.0f%% advantage over %d actions\nseason blow-by %.0f%% over %d drives", name, 100 * adv, n, 100 * bb_shrunk, drives))],
                                xlabel = "season blow-by rate (shrunk)", ylabel = "tracked advantage rate", xfmt = "pct", yfmt = "pct", radius = 4)),
                   SECTION("ad-limits", "What this shows and does not",
                           BUL("It shows which actions and players knock the defense out of balance by a simple, checkable rule",
                               "It does not account for who is guarding the creator, the shot clock, or whether the advantage was used"),
                           H("If this becomes the topic"),
                           BUL("Define the advantage against the defense's expected position (where it usually stands given the ball and the attackers)",
                               "Credit the player whose action caused it",
                               "Follow the advantage through passes to the shot")))
  DOC("advantage", "Advantage creation", "Which actions and players knock the defense out of balance (defender beaten, help drawn, switch), and what that is worth.", sections)
}
