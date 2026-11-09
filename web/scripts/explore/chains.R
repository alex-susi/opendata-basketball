# Topic: pre-shot actions and chains of actions, and team spacing.
#
# Actions of a chance, in frame order, up to its last shot's release (or its end): SkillCorner's picks, handoffs,
# off-ball screens, drives, isolations, post-ups and closeouts, the site's basket cuts (web/scripts/cuts.R; cuts
# through an off-ball screen are already that screen) and paint touches (the Paint touches tab's definition).
# A chain is that sequence with immediate repeats collapsed ("Pick ×2"). Screens are picks, handoffs and off-ball
# screens; "consecutive" screens follow each other within 3 s.
#
# Spacing (tracking, frames with all ten players): the area of each team's convex hull, attackers beyond the arc,
# defenders in the key, and the mean distance from each attacker without the ball to his nearest defender, averaged
# over a chance's half-court frames (every 5th frame from the frontcourt frame to the shot).

ACT_LV <- c("Pick", "Handoff", "Off-ball screen", "Drive", "Iso", "Post-up", "Closeout", "Cut", "Paint touch")

chance_actions <- function(B) {
  ch <- B$ch[in_pop == TRUE]
  ev <- rbind(
    B$picks[, .(chance, f = f0, act = "Pick", actor)], B$handoffs[, .(chance, f = f0, act = "Handoff", actor)],
    B$obs[, .(chance, f = f0, act = "Off-ball screen", actor)], B$drives[, .(chance, f = f0, act = "Drive", actor)],
    B$isos[, .(chance, f = f0, act = "Iso", actor)], B$posts[, .(chance, f = f0, act = "Post-up", actor)],
    B$co[, .(chance, f = f0, act = "Closeout", actor)], fill = TRUE)
  if (nrow(B$cuts)) {
    cu <- B$cuts[kind == "basket"]
    cho <- ch[order(c0)]
    k <- findInterval(cu$f, cho$c0)
    cu[, chance := fifelse(k > 0 & f <= cho$c1[pmax(k, 1)], cho$chance[pmax(k, 1)], NA_character_)]
    ev <- rbind(ev, cu[!is.na(chance), .(chance, f, act = "Cut", actor = pid)], fill = TRUE)
  }
  tc <- merge(B$touches[vendor_paint == TRUE], ch[, .(chance, cut_f, off)], by = "chance")[f0 <= cut_f & team == off]
  ev <- rbind(ev, tc[, .(chance, f = f0, act = "Paint touch", actor = pid)], fill = TRUE)
  ev <- merge(ev, ch[, .(chance, c0, cut_f)], by = "chance")[f <= cut_f & f >= c0 - 25]
  ev[order(chance, f)]
}

topic_chains <- function(BL) {
  CH <- list(); EV <- list(); SPC <- list(); AL <- list(); REL <- list()
  for (B in BL) {
    ch <- B$ch[in_pop == TRUE]
    ev <- chance_actions(B)
    EV[[length(EV) + 1]] <- ev[, game := B$game]
    # Half-court spacing over the chance.
    hc <- ch[transition == FALSE & !is.na(front) & cut_f > pmax(c0, front)]
    fr <- hc[, .(frame = seq(pmax(c0, front), cut_f, by = 5L)), by = chance]
    G <- frame_geom(B, fr$frame)
    if (nrow(G)) {
      S <- merge(fr, G, by = "frame")[, .(off_hull = mean(off_hull), def_hull = mean(def_hull), off_arc = mean(off_arc),
                                           def_paint = mean(def_paint), open_mean = mean(open_mean, na.rm = TRUE),
                                           holder_open = mean(holder_open, na.rm = TRUE), nfr = .N, det = mean(det)), by = chance]
      SPC[[length(SPC) + 1]] <- S
    }
    # At release (FGA chances): spacing of the floor when the shot went up.
    R <- frame_geom(B, ch[fga == TRUE & !is.na(shot_f)]$shot_f)
    if (nrow(R)) REL[[length(REL) + 1]] <- merge(ch[fga == TRUE, .(chance, frame = shot_f)], R, by = "frame")
    # Team shape around each action.
    al <- ev[act != "Paint touch" | TRUE]
    g <- aligned_geom(B, al$f, al$act, offsets = seq(-2, 2, by = 0.2))
    if (nrow(g)) AL[[length(AL) + 1]] <- g
    CH[[length(CH) + 1]] <- ch
  }
  ch <- rbindlist(CH, fill = TRUE); ev <- rbindlist(EV, fill = TRUE)
  S <- rbindlist(SPC); A <- rbindlist(AL); R <- rbindlist(REL)
  ch[, ctx := fifelse(start == "FGORB", "after offensive rebound", fifelse(transition, "transition", "half court"))]
  base <- ch
  hc <- ch[ctx == "half court"]

  # Chain strings.
  coll <- function(a) {
    r <- rle(a)
    paste(ifelse(r$lengths > 1, paste0(r$values, " ×", r$lengths), r$values), collapse = " → ")
  }
  chains <- ev[, .(chain = coll(act), n_act = .N, last = act[.N],
                   tail2 = coll(tail(act, 2)), tail3 = coll(tail(act, 3)),
                   n_scr = sum(act %in% c("Pick", "Handoff", "Off-ball screen")),
                   run_scr = { s <- f[act %in% c("Pick", "Handoff", "Off-ball screen")]
                               if (length(s) < 2) as.numeric(length(s)) else { r <- rle(diff(s) <= 75); as.numeric(max(1, r$lengths[r$values] + 1)) } },
                   last_gap = (cut_f[1] - f[.N]) / FPS), by = chance]
  ch <- merge(ch, chains, by = "chance", all.x = TRUE)
  ch[is.na(n_act), `:=`(chain = "(no tracked action)", n_act = 0L, last = "(none)", tail2 = "(no tracked action)",
                        tail3 = "(no tracked action)", n_scr = 0L, run_scr = 0L)]
  for (a_ in ACT_LV) ch[, (paste0("has_", a_)) := chance %in% ev[act == a_]$chance]
  hc <- ch[ctx == "half court"]

  # Presence of each action (half court).
  pres <- rbindlist(lapply(ACT_LV, function(a_) {
    w <- hc[get(paste0("has_", a_)) == TRUE]; wo <- hc[get(paste0("has_", a_)) == FALSE]
    data.table(grp = a_, n = nrow(w), share = nrow(w) / nrow(hc), ppc = mean(w$pts), ppc_wo = mean(wo$pts),
               xpts = mean(w$xpts, na.rm = TRUE), xpts_wo = mean(wo$xpts, na.rm = TRUE),
               tov = mean(w$tov), tov_wo = mean(wo$tov), ftrip = mean(w$ftrip), ftrip_wo = mean(wo$ftrip),
               oreb = sum(w$oreb & w$live) / max(1, sum(w$live)), oreb_wo = sum(wo$oreb & wo$live) / max(1, sum(wo$live)))
  }))
  pres[, gap := ppc - ppc_wo]

  ch[, nact_bin := fifelse(n_act >= 6, "6+", as.character(n_act))]
  ch[, nscr_bin := fifelse(n_scr >= 4, "4+", as.character(n_scr))]
  ch[, run_bin := fifelse(run_scr >= 3, "3+ in a row", fifelse(run_scr == 2, "2 in a row", fifelse(run_scr == 1, "1 (no follow-up)", "no screen")))]
  hc <- ch[ctx == "half court"]

  # Spacing bins.
  hs <- merge(hc, S[nfr >= 5], by = "chance")
  hs[, ohb := qbins(off_hull, 5)]; hs[, dhb := qbins(def_hull, 5)]
  hs[, arcb := cut(off_arc, c(-Inf, 1.5, 2.5, 3.5, Inf), labels = c("under 1.5", "1.5-2.5", "2.5-3.5", "3.5 or more"))]
  hs[, dpb := cut(def_paint, c(-Inf, 1, 1.5, 2, Inf), labels = c("under 1", "1-1.5", "1.5-2", "2 or more"))]
  hs[, ratio := off_hull / def_hull]
  hs[, rb := qbins(ratio, 5, 2)]
  R <- merge(R, ch[, .(chance, xpts, efg_pts, shot_zone, pts)], by = "chance")
  R[, arcb := factor(pmin(off_arc, 4), levels = 0:4, labels = c("0", "1", "2", "3", "4+"))]
  R[, dpb := factor(pmin(def_paint, 3), levels = 0:3, labels = c("0", "1", "2", "3+"))]

  # Actions' effect on team shape.
  Am <- A[, .(def_hull = mean(def_hull), def_paint = mean(def_paint), open_mean = mean(open_mean, na.rm = TRUE),
              holder_open = mean(holder_open, na.rm = TRUE), off_hull = mean(off_hull), n = .N), by = .(grp, t)][n >= 20]
  delta <- A[, .(pre = mean(def_hull[t == -1]), post = mean(def_hull[t == 1]), pp0 = mean(def_paint[t == -1]), pp1 = mean(def_paint[t == 1]),
                 o0 = mean(open_mean[t == -1], na.rm = TRUE), o1 = mean(open_mean[t == 1], na.rm = TRUE), n = sum(t == 0)), by = grp]
  setorder(delta, -n)

  top_chain <- function(key, min_n, lim, title) {
    t <- outcomes_by(hc, key)[n >= min_n]
    setnames(t, key, "grp"); setorder(t, -n)
    ref <- outcomes_by(copy(hc)[, all := 1L], "all")
    TABLE(title, limit = lim, rows = t, cols = list(
      col("grp", "Actions (in order)"), col("n", "Chances", "int"),
      col("ppc", "Pts/chance", "num2", ref = ref$ppc, scale = 0.3), col("xpts", "xPts/FGA", "num2", ref = ref$xpts, scale = 0.15),
      col("tov", "TOV%", "pct", ref = ref$tov, scale = 0.08, low = TRUE), col("ftrip", "FT trip%", "pct", ref = ref$ftrip, scale = 0.08),
      col("oreb", "OREB%", "pct", ref = ref$oreb, scale = 0.12), col("live", "Live misses", "int")),
      note = "Half-court chances; tints compare with all half-court chances (blue above, red below). Small groups swing widely.")
  }

  pair <- ev[, .(a1 = act[-.N], a2 = act[-1]), by = chance][, pairs := paste(a1, "→", a2)]
  pair <- merge(unique(pair[, .(chance, pairs)]), hc[, .(chance, pts, tov, ftrip, xpts)], by = "chance")
  pt <- pair[, .(n = .N, ppc = mean(pts), tov = mean(tov), ftrip = mean(ftrip), xpts = mean(xpts, na.rm = TRUE)), by = pairs][n >= 25][order(-n)]

  sections <- list(
    SECTION("ch-question", "The question and the data",
      P("Which actions, and which orders of actions, come before the best chances? Each half-court chance is reduced to the list of actions SkillCorner marked in it (picks, handoffs, off-ball screens, drives, isolations, post-ups, closeouts), ",
        "plus the site's basket cuts and paint touches, in the order they happened, up to the shot. Outcomes are the chance's points, shot quality (xPts per FGA), turnovers, free-throw trips and offensive rebounds on live misses."),
      KPIS(KPI("Half-court chances", int(nrow(hc)), sprintf("of %s chances", int(nrow(ch)))),
           KPI("Actions per chance", sprintf("%.1f", mean(hc$n_act)), "median " %+% median(hc$n_act)),
           KPI("With a screen", pct(mean(hc$n_scr > 0)), sprintf("%.1f screens per chance", mean(hc$n_scr))),
           KPI("Distinct chains", int(uniqueN(hc$chain)), "after collapsing repeats")),
      CAVEAT("Actions are SkillCorner's detections plus the site's cuts; both miss some actions and mislabel others. A long chain is also a long chance, and the shot clock forces shots late in long chains, so counts and orders are confounded with time.")),
    SECTION("ch-presence", "Chances with and without each action",
      TABLE("Half-court chances: with each action vs without it", limit = 12, rows = pres, cols = list(
        col("grp", "Action"), col("n", "Chances with it", "int"), col("share", "Share", "pct"),
        col("ppc", "Pts/ch with", "num2", ref = mean(hc$pts), scale = 0.25), col("ppc_wo", "without", "num2"),
        col("gap", "Gap", "num2", ref = 0, scale = 0.3),
        col("xpts", "xPts with", "num2", ref = mean(hc$xpts, na.rm = TRUE), scale = 0.15), col("xpts_wo", "without", "num2"),
        col("tov", "TOV% with", "pct", ref = mean(hc$tov), scale = 0.08, low = TRUE), col("tov_wo", "without", "pct"),
        col("ftrip", "FT% with", "pct", ref = mean(hc$ftrip), scale = 0.08), col("ftrip_wo", "without", "pct"),
        col("oreb", "OREB% with", "pct"), col("oreb_wo", "without", "pct")),
        note = "A chance with two kinds of action counts in both rows."),
      outcome_panel(rbindlist(lapply(ACT_LV, function(a_) hc[get(paste0("has_", a_)) == TRUE][, grp := a_])), order = ACT_LV, base = hc, total = nrow(hc),
                    title = "Half court, with the action")),
    SECTION("ch-count", "How many actions, and screens in a row",
      outcome_panel(copy(hc)[, grp := nact_bin], order = c(as.character(0:5), "6+"), base = hc, title = "Actions in the chance"),
      GRID(outcome_table(copy(hc), "nscr_bin", base = hc, label = "Screens in the chance", title = "By number of screens"),
           outcome_table(copy(hc), "run_bin", base = hc, label = "Longest run of screens", title = "Consecutive screens (each within 3 s of the last)"))),
    SECTION("ch-chains", "Chains: the order of actions",
      P("Full chains are too varied to compare (", int(uniqueN(hc$chain)), " distinct ones), so the tables use the last action, the last two and the last three before the shot."),
      outcome_table(copy(hc), "last", base = hc, label = "Last action before the shot", title = "By the last action", min_n = 15),
      top_chain("tail2", 20, 25, "The last two actions (20+ chances)"),
      top_chain("tail3", 15, 25, "The last three actions (15+ chances)"),
      TABLE("Pairs anywhere in the chain (one action straight after another, 25+ chances)", limit = 25, rows = pt, cols = list(
        col("pairs", "Pair"), col("n", "Chances", "int"), col("ppc", "Pts/chance", "num2", ref = mean(hc$pts), scale = 0.3),
        col("xpts", "xPts/FGA", "num2", ref = mean(hc$xpts, na.rm = TRUE), scale = 0.15),
        col("tov", "TOV%", "pct", ref = mean(hc$tov), scale = 0.08, low = TRUE), col("ftrip", "FT trip%", "pct", ref = mean(hc$ftrip), scale = 0.08)))),
    SECTION("ch-shape", "What each action does to the defense's shape",
      P("Team shape averaged over every action of each kind, from 2 s before it to 2 s after (0 = SkillCorner's frame for the action: the screen, the start of a drive, isolation or post-up, the start of a closeout, the start of a cut or paint touch)."),
      GRID(
        SCAT("Area of the defense's convex hull (sq ft)", lines = LINES_BY(Am, "t", "def_hull", "grp", ACT_LV), xlabel = "seconds from the action", ylabel = "sq ft", yfmt = "int"),
        SCAT("Defenders inside the key", lines = LINES_BY(Am, "t", "def_paint", "grp", ACT_LV), xlabel = "seconds from the action", ylabel = "defenders"),
        SCAT("Off-ball attackers: nearest defender (ft)", lines = LINES_BY(Am, "t", "open_mean", "grp", ACT_LV), xlabel = "seconds from the action", ylabel = "ft"),
        SCAT("Ball holder: nearest defender (ft)", lines = LINES_BY(Am, "t", "holder_open", "grp", ACT_LV), xlabel = "seconds from the action", ylabel = "ft")),
      TABLE("One second before vs one second after", limit = 12, rows = delta[, .(grp, n, pre, post, dh = post - pre, pp0, pp1, o0, o1, do = o1 - o0)], cols = list(
        col("grp", "Action"), col("n", "Actions", "int"), col("pre", "Def. hull −1 s", "int"), col("post", "+1 s", "int"),
        col("dh", "Change", "int", ref = 0, scale = 60), col("pp0", "Def. in key −1 s", "num1"), col("pp1", "+1 s", "num1"),
        col("o0", "Off-ball room −1 s (ft)", "num1"), col("o1", "+1 s", "num1"), col("do", "Change", "num2", ref = 0, scale = 0.8)))),
    SECTION("ch-spacing", "Spacing and outcomes",
      P("Each half-court chance's spacing averaged over its frames from the frontcourt to the shot (every 5th frame, all ten players tracked, at least five frames). Bins are quintiles of the chances."),
      outcome_panel(copy(hs)[, grp := as.character(ohb)], order = levels(hs$ohb), base = hc, title = "Offense hull (sq ft)"),
      outcome_panel(copy(hs)[, grp := as.character(dhb)], order = levels(hs$dhb), base = hc, title = "Defense hull (sq ft)"),
      GRID(outcome_table(copy(hs)[, g := as.character(arcb)], "g", base = hc, label = "Attackers beyond the arc (mean)", title = "Shooters spotted up"),
           outcome_table(copy(hs)[, g := as.character(dpb)], "g", base = hc, label = "Defenders in the key (mean)", title = "Defenders packing the key")),
      SCAT("Offense hull against defense hull (one point per chance, coloured by whether it scored)",
           points = hs[, .(x = r2(off_hull, 0), y = r2(def_hull, 0), g = as.integer(pts == 0), tip = sprintf("%s\n%d points\noffense hull %.0f sq ft\ndefense hull %.0f sq ft", chance, pts, off_hull, def_hull))],
           groups = c("scored", "did not score"), xlabel = "offense hull (sq ft)", ylabel = "defense hull (sq ft)", xfmt = "int", yfmt = "int", radius = 2.5, opacity = 0.4),
      P("At the release of the shot (FGA chances): how many attackers were beyond the arc and how many defenders were in the key, against the shot's quality."),
      GRID(RATES("xPts per FGA by attackers beyond the arc at release", lapply(levels(R$arcb), function(l) mrow(l, R[arcb == l]$xpts)), fmt = "num2",
                 unit = "xPts", ref = mean(R$xpts, na.rm = TRUE)),
           RATES("xPts per FGA by defenders in the key at release", lapply(levels(R$dpb), function(l) mrow(l, R[dpb == l]$xpts)), fmt = "num2",
                 unit = "xPts", ref = mean(R$xpts, na.rm = TRUE))),
      CAVEAT("Spacing at release is tied to where the shot is: a layup puts the shooter (and his defender) in the key. The chance-average view is less tied to the shot spot but still reflects the opponent and the lineup.")),
    SECTION("ch-limits", "What this shows and does not",
      P("It shows which actions and short sequences come before better and worse chances, and how each action moves the defense in the next two seconds. ",
        "It does not separate the action from who runs it, against whom, or how much time was left."),
      P("If this becomes the topic: model the chance outcome on the last action with team and opponent terms; use the shape changes (hull, key, room off the ball) as the mechanism, ",
        "and test whether an action that shrinks the defense more leads to a better next shot."))
  )
  DOC("chains", "Pre-shot actions", "Which actions and chains of actions precede better chances, how they change the defense's shape, and how spacing relates to outcomes.", sections)
}
`%+%` <- function(a, b) paste0(a, b)
