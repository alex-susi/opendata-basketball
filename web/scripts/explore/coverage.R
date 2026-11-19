## ═════════════════════════════════════════════════════════════════════════════
# Topic: pick-and-roll coverage, the EDA behind the screen coverage model (the site's Pick Coverage EDA tab).
#
# The label. SkillCorner labels two coverages on every on-ball screen (picks.bhrDefType on the ball handler's
# defender, picks.scrDefType on the screener's defender). Together they form one joint coverage: "over · drop",
# "over · show", "under · drop", "under · show", or a coverage both defenders share (switch, ice, blitz). In the ten
# games the shared coverages never mix with anything else, so the joint coverage is the label a model predicts.
#
# The frame. Every position is in the viewer's frame (offense attacks the hoop at +HOOP_X). The pick's own location
# comes from the site's corrected screen table (annotations.R fixes the y sign). Time 0 is picks.frame.
#
# Tracking windows. For each pick, the four players of the action (ball handler H, screener S, the handler's
# defender BD = ballhandlerDefId, the screener's defender SD = screenerDefId; both ids are the defenders BEFORE any
# switch) are looked up every 0.2 s from -3 s to +2 s, staying inside the pick's possession. Measures:
#   d_bd     H to BD (ft)                     d_sd     H to SD (ft)
#   d_hs     H to S (ft): the screen itself   d_def    BD to SD (ft): both defenders together = trap
#   bd_lvl   BD's hoop distance minus the screen spot's (ft): + above the screen (over), - below it (under)
#   sd_lvl   SD's hoop distance minus the screen spot's (ft): + up at the ball (show), - sitting back (drop)
# The screen spot is S's tracked position at time 0 (the event location when he is not tracked).
#
# Positions. Each player's archetype (archetypes/03_outputs, not refitted here) is grouped into guard, wing or big:
# the offensive archetype when he has one, else the defensive one. See POS_OFF and POS_DEF.
#
# Before the screen. Events of the same possession before the pick frame (off-ball screens, handoffs, earlier picks,
# drives, passes, the site's cuts) and the matchups table read up to 1 s before the pick frame, so the pick's own
# switch is never counted.
#
# The live model. The switch section reads the live screen coverage model's held-out predictions
# (screen_coverage/02_cache, through screen_coverage/01_scripts/R/predictions.R) and averages each screen's switch
# probability over the main time-weight curve. The section is left out when the caches are missing.
#
# Separation over time is shown with a rank statistic (AUC): pick one pick of each of two coverages at random; the
# AUC is how often the measure ranks them the right way round. 0.5 = no information, 1 = perfect. It is computed
# separately at each time step, so it says WHEN the coverages start to look different, not how well a model would do.
#
# Baselines are frequency look-ups: predict each pick's coverage from the shares in some reference group (with one
# pick of each coverage added, so none gets probability 0), scored by accuracy and log loss.
## ═════════════════════════════════════════════════════════════════════════════





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Window offsets (s from the pick) and the smallest defense sample shown.
COV <- list(t = round(seq(-3, 2, by = 0.2), 1), min_team = 25L)
JOINT_LV <- c("over · drop", "over · show", "under · drop", "under · show", "switch", "ice", "blitz")
FIVE_LV <- JOINT_LV[1:5]
# Line colours: each defender's coverage keeps one colour in every chart (switch is the same for both).
LINE_COL <- c(over = PAL[1], under = PAL[3], drop = PAL[2], show = PAL[4], switch = PAL[5],
              "over · drop" = PAL[1], "over · show" = PAL[2], "under · drop" = PAL[3], "under · show" = PAL[4])
# Archetypes grouped into positions.
POS_OFF <- c("Primary Ball Handler" = "guard", "Secondary Ball Handler" = "guard", "Slasher" = "guard",
             "Off Screen Shooter" = "wing", "Movement Shooter" = "wing", "Stationary Shooter" = "wing",
             "Athletic Finisher" = "wing", "Post Scorer" = "big", "Roll & Cut Big" = "big", "Versatile Big" = "big")
POS_DEF <- c("Point of Attack" = "guard", "Chaser" = "guard", "Helper" = "wing", "Anchor Big" = "big")
POS_LV <- c("guard", "wing", "big")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PICKS AND TRACKING WINDOWS ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' What happened earlier in each pick's possession, before the pick frame (one row per pick of `p`). Matchups are read
#' only up to 1 s before the pick frame. Also when the handler is first handed to the screener's defender in the
#' matchups table, from 1 s before to 3 s after the pick frame (t_hand, s; NA when he never is).
before_actions <- function(B, p) {
  # Every event table with its possession and frame (ff), empty tables kept usable.
  cp <- B$ch[, .(chance, poss)]
  ev <- function(dt) {
    if (!nrow(dt)) return(data.table(poss = character(), ff = integer(), cov = character()))
    x <- merge(dt, cp, by = "chance", all.x = TRUE)
    x[, ff := f0]
    x
  }
  ob <- ev(B$obs)
  ho <- ev(B$handoffs)
  pk <- ev(B$picks)
  dr <- ev(B$drives)
  pa <- ev(B$passes)
  cu <- if (nrow(B$cuts)) copy(B$cuts) else data.table(f = integer(), pid = integer())
  cu[, poss := B$Fr$poss[match(f, B$Fr$frame)]]
  mu <- merge(B$mu, cp, by = "chance")

  # One pick at a time: counts of earlier actions, earlier switches, and assignment changes for H and S.
  rbindlist(lapply(seq_len(nrow(p)), function(i) {
    r <- p[i]
    F0 <- r$f0
    PO <- r$poss
    w <- function(dt, sec = Inf) dt[poss %in% PO & ff < F0 & ff >= F0 - sec * FPS]
    o <- w(ob)
    h <- w(ho)
    k <- w(pk)
    m <- mu[poss %in% PO & f0 < F0 - FPS][order(f0)]
    s_first <- m[off == r$S]$def[1]
    h_first <- m[off == r$H]$def[1]
    m5 <- m[f1 >= F0 - 5 * FPS & off %in% c(r$H, r$S)]
    nchg <- if (nrow(m5)) m5[, uniqueN(def) - 1L, by = off][, sum(V1)] else 0L
    mh <- mu[poss %in% PO & off == r$H & def == r$SD & f1 >= F0 - FPS & f0 <= F0 + 3 * FPS][order(f0)]
    data.table(id = r$id, n_obs = nrow(o), obs_sw = any(o$cov == "switch"), n_ho = nrow(h), ho_sw = any(h$cov == "switch"),
               n_pk = nrow(k), pk_sw = any(k$cov == "switch"), n_dr = nrow(w(dr)), n_pass = nrow(w(pa)),
               cut3 = nrow(cu[poss %in% PO & f < F0 & f >= F0 - 3 * FPS]) > 0,
               s_cross = !is.na(s_first) && s_first != r$SD, h_cross = !is.na(h_first) && h_first != r$BD, nchg = nchg,
               t_hand = if (nrow(mh)) (max(mh$f0[1], F0 - FPS) - F0) / FPS else NA_real_)
  }))
}

#' Every pick of the ten games with its label, context, earlier actions and tracking window.
cov_data <- function(BL) {
  PK <- list()
  WIN <- list()
  for (B in BL) {
    # One game at a time: picks with their event fields, chance context and names, then the tracking window.
    g <- B$game
    if (!nrow(B$picks)) next
    ev <- a$read_json_file(a$match_file(a$root, g, "_dynamic_events.json"))$picks
    raw <- data.table(id = xc(ev, "id"), sc = xf(ev, "shotClock"), gc = xf(ev, "gameClock"), period = xi(ev, "period"),
                      off_team = xi(ev, "offTeamId"), def_team = xi(ev, "defTeamId"), hop = xl(ev, "handoffPick"),
                      bout = vapply(xlist(ev, "bhrOutcomes"), paste, "", collapse = "|"),
                      sout = vapply(xlist(ev, "scrOutcomes"), paste, "", collapse = "|"))
    p <- merge(B$picks[, .(id, chance, f0, H = actor, BD = adef, S = screener, SD = sdef, cov, scov, spot, x, y, direct, touch)],
               raw, by = "id")
    p[, game := g]
    p <- merge(p, B$ch[, .(chance, poss, transition, q, front, c0, pts, xpts, tov, ftrip, in_pop, start)], by = "chance", all.x = TRUE)
    tm <- unique(B$roster[, .(team, team_name)])
    p[, `:=`(def_name = tm$team_name[match(def_team, tm$team)], off_name = tm$team_name[match(off_team, tm$team)])]
    nm <- function(id) B$roster$name[match(id, B$roster$pid)]
    cn <- function(id) B$roster$canon[match(id, B$roster$pid)]
    p[, `:=`(h_name = nm(H), s_name = nm(S), bd_name = nm(BD), sd_name = nm(SD), h_canon = cn(H), s_canon = cn(S),
             bd_canon = cn(BD), sd_canon = cn(SD))]
    # Picks earlier in the same chance (re-screens) and seconds since the possession started.
    setorder(p, f0)
    p[, k_in_chance := seq_len(.N), by = chance]
    p[, poss_f0 := B$poss$f0[match(poss, B$poss$poss)]]
    p[, since_poss := (f0 - poss_f0) / FPS]
    # Matchups: the handler's assigned defender just before and 1.5 s after the pick.
    p[, `:=`(mk_pre = marker_of(B, f0 - 5L, H), mk_post = marker_of(B, f0 + 38L, H))]
    # Earlier actions in the possession and the switch hand-over time.
    p <- merge(p, before_actions(B, p), by = "id")

    # Tracking window.
    q <- CJ(i = seq_len(nrow(p)), t = COV$t)
    q[, frame := p$f0[i] + as.integer(round(t * FPS))]
    q[, poss0 := p$poss[i]]
    q[, possf := B$Fr$poss[match(frame, B$Fr$frame)]]
    # The four players at every offset; positions outside the pick's possession are dropped.
    look <- function(role) {
      pp <- pos_at(B, q$frame, p[[role]][q$i])
      list(x = pp$x, y = pp$y, det = pp$det)
    }
    h <- look("H")
    s <- look("S")
    bd <- look("BD")
    sd <- look("SD")
    q[, `:=`(hx = h$x, hy = h$y, sx = s$x, sy = s$y, bx = bd$x, by = bd$y, dx = sd$x, dy = sd$y,
             det4 = (h$det %in% 1L) + (s$det %in% 1L) + (bd$det %in% 1L) + (sd$det %in% 1L))]
    q[is.na(possf) | possf != poss0, c("hx", "hy", "sx", "sy", "bx", "by", "dx", "dy") := NA_real_]
    # Ten players tracked at the frame?
    n10 <- B$P[.(unique(q$frame)), .(n = .N), by = frame, nomatch = 0L]
    q[, all10 := frame %in% n10[n == 10L]$frame & !is.na(possf) & possf == poss0]
    # The screen spot: S at time 0, else the event location.
    s0 <- q[t == 0, .(i, s0x = fifelse(is.na(sx), p$x[i], sx), s0y = fifelse(is.na(sx), p$y[i], sy))]
    q <- merge(q, s0, by = "i")
    sdist <- hoop_dist(q$s0x, q$s0y)
    # Distances, and levels against the screen spot.
    q[, `:=`(d_bd = sqrt((hx - bx)^2 + (hy - by)^2), d_sd = sqrt((hx - dx)^2 + (hy - dy)^2),
             d_hs = sqrt((hx - sx)^2 + (hy - sy)^2), d_def = sqrt((bx - dx)^2 + (by - dy)^2),
             bd_lvl = hoop_dist(bx, by) - sdist, sd_lvl = hoop_dist(dx, dy) - sdist,
             h_lvl = hoop_dist(hx, hy) - sdist)]
    q[, id := p$id[i]]
    WIN[[length(WIN) + 1]] <- q[, .(id, t, d_bd, d_sd, d_hs, d_def, bd_lvl, sd_lvl, h_lvl, det4, all10,
                                    have4 = !is.na(hx) & !is.na(sx) & !is.na(bx) & !is.na(dx))]
    PK[[length(PK) + 1]] <- p
  }
  P <- rbindlist(PK, fill = TRUE)
  W <- rbindlist(WIN)
  # Joint coverage, the seven-coverage label, scheme, and context bands.
  P[, joint := fifelse(cov %in% c("switch", "ice", "blitz"), cov, paste(cov, scov, sep = " · "))]
  P[, joint7 := fifelse(joint %in% JOINT_LV, joint, NA_character_)]
  P[, scheme := fifelse(cov %in% c("switch", "ice", "blitz"), cov, "over/under")]
  P[, sc_band := cut(sc, c(-Inf, 6, 10, 14, 18, Inf), labels = c("0-6 s", "6-10 s", "10-14 s", "14-18 s", "18-24 s"))]
  P[, clutch := period >= 4 & gc <= 120]
  P[, side := fifelse(abs(y) <= 6, "middle of the floor", "side of the floor")]
  P[, spot_lab := c(middle = "middle", stepUp = "step-up", wing = "wing")[spot]]
  # Earlier actions as flags.
  P[, `:=`(sw_before = obs_sw | ho_sw | pk_sw, cross = s_cross | h_cross, re_pick = n_pk > 0, obs_before = n_obs > 0,
           ho_before = n_ho > 0, drive_before = n_dr > 0)]
  P[, pass_band := fifelse(n_pass >= 4, "4 or more", as.character(n_pass))]
  P[, chg_band := fifelse(nchg >= 2, "2 or more", as.character(nchg))]
  list(P = P, W = W)
}

#' Each player's archetypes (archetypes/03_outputs) and position group. Membership files key on the player id, with
#' the alias map as a fallback.
cov_positions <- function() {
  o <- fread(file.path(a$root, "archetypes", "03_outputs", "offense_membership.csv"))
  d <- fread(file.path(a$root, "archetypes", "03_outputs", "defense_membership.csv"))
  pos <- merge(o[, .(pid, oa = archetype)], d[, .(pid, da = archetype)], by = "pid", all = TRUE)
  pos[, pos := fifelse(!is.na(oa), unname(POS_OFF[oa]), unname(POS_DEF[da]))]
  al <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
  look <- function(ids, f) {
    v <- pos[[f]][match(ids, pos$pid)]
    c2 <- al$canonical_player_id[match(ids, al$player_id)]
    fifelse(is.na(v), pos[[f]][match(c2, pos$pid)], v)
  }
  list(pos = pos, look = look)
}

#' The live screen coverage model's held-out switch read per screen, averaged over the main time-weight curve (and
#' over its part before the pick frame). NULL when the model's caches cannot be read.
cov_model_reads <- function() {
  e <- new.env()
  tryCatch({
    sys.source(file.path(a$root, "screen_coverage", "01_scripts", "R", "predictions.R"), envir = e)
    sys.source(file.path(a$root, "screen_coverage", "01_scripts", "R", "window_weights.R"), envir = e)
    LG <- e$load_logistic(a$root)
    SQ <- e$load_seqheads(a$root)
    k <- match("switch", LG$calls)
    X <- LG$X[, .(id, off)]
    X[, `:=`(p = SQ$prob[, k], top = max.col(SQ$prob, ties.method = "first") == k, w = e$window_weight(off, "main"))]
    X[w > 0, .(p_sw = sum(w * p) / sum(w), read_sw = sum(w * top) / sum(w),
               p_sw_pre = sum((off < 0) * w * p) / sum((off < 0) * w)), by = id]
  }, error = function(err) {
    message("  live model predictions not read: ", conditionMessage(err))
    NULL
  })
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - HELPERS ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Shares of each joint coverage by a grouping (wide: one column per coverage, plus n), and each defender's part
#' among the five main coverages (h_over, h_under, h_switch; s_drop, s_show, s_switch; n5 picks).
mix_by <- function(P, by, lv = JOINT_LV, min_n = 1) {
  d <- P[!is.na(joint7) & joint7 %in% lv]
  t <- d[, .(n = .N), by = c(by, "joint7")]
  w <- dcast(t, as.formula(paste(paste(by, collapse = "+"), "~ joint7")), value.var = "n", fill = 0)
  for (l in JOINT_LV) if (!l %in% names(w)) w[, (l) := 0]
  w[, n := rowSums(.SD), .SDcols = lv]
  # Each defender's part, among the five main coverages.
  w[, n5 := `over · drop` + `over · show` + `under · drop` + `under · show` + switch]
  w[, `:=`(h_over = (`over · drop` + `over · show`) / n5, h_under = (`under · drop` + `under · show`) / n5, h_switch = switch / n5,
           s_drop = (`over · drop` + `under · drop`) / n5, s_show = (`over · show` + `under · show`) / n5, s_switch = switch / n5)]
  for (l in lv) w[, (l) := get(l) / n]
  w[n >= min_n]
}
#' Mann-Whitney AUC of x for group a (TRUE) vs b (FALSE).
auc <- function(x, g) {
  ok <- !is.na(x) & !is.na(g)
  x <- x[ok]
  g <- g[ok]
  n1 <- sum(g)
  n0 <- sum(!g)
  if (n1 < 5 || n0 < 5) return(NA_real_)
  r <- rank(x)
  (sum(r[g]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
#' Score probability rows (matrix, columns in JOINT_LV order) against labels: accuracy and mean log loss.
score <- function(prob, y) {
  j <- match(y, JOINT_LV)
  p <- prob[cbind(seq_along(j), j)]
  list(acc = mean(max.col(prob, ties.method = "first") == j), ll = -mean(log(p)), n = length(y))
}
#' Probabilities from counts with one of each coverage added.
smooth_counts <- function(cnt) (cnt + 1) / sum(cnt + 1)

KEYS <- setNames(c("o_drop", "o_show", "u_drop", "u_show", "switch", "ice", "blitz"), JOINT_LV)
#' Table columns for the seven coverage shares (tinted against the overall share).
mix_cols <- function(base) {
  lapply(JOINT_LV, function(l) col(KEYS[[l]], l, "pct", ref = base[[l]], scale = 0.25, group = "Share of the defense's coverages",
                                   title = sprintf("Share of the group's picks defended with %s", l)))
}
#' Table columns for each defender's part (over, under, switch / drop, show, switch), tinted against `b5`.
view_cols <- function(b5) {
  hc <- function(k, l, what) col(k, l, "pct", ref = b5[[k]], scale = 0.25, group = "Handler's defender",
                                 title = sprintf("Share of the group's picks (five main coverages) where the handler's defender %s", what))
  sc <- function(k, l, what) col(k, l, "pct", ref = b5[[k]], scale = 0.25, group = "Screener's defender",
                                 title = sprintf("Share of the group's picks (five main coverages) where the screener's defender %s", what))
  list(hc("h_over", "Over", "went over the screen"), hc("h_under", "Under", "went under the screen"), hc("h_switch", "Switch", "switched"),
       sc("s_drop", "Drop", "dropped"), sc("s_show", "Show", "showed"), sc("s_switch", "Switch", "switched"))
}
mix_rows <- function(w) {
  setnames(w, JOINT_LV, unname(KEYS[JOINT_LV]), skip_absent = TRUE)
  w
}
#' A coverage-mix table with a three-way switch: the full joint coverage, the handler's defender only, the screener's
#' defender only. `lead` columns show in every view; `extra` columns show in the views `extra_in` names
#' (list(full = keys, h = keys, s = keys)).
MIXTABLE <- function(title, w, lead, base, b5, joint = JOINT_LV, limit = 20, extra = list(), extra_in = list(),
                     n_title = "Picks in the group") {
  key <- function(l) vapply(l, `[[`, "", "key")
  cols <- c(lead, list(col("n", "Picks", "int", title = n_title),
                       col("n5", "Picks", "int", title = paste(n_title, "with one of the five main coverages (ice and blitz left out)"))),
            extra, mix_cols(base)[match(joint, JOINT_LV)], view_cols(b5))
  views <- list(list(label = "Full coverage", keys = c(key(lead), "n", extra_in$full, unname(KEYS[joint]))),
                list(label = "Handler's defender", keys = c(key(lead), "n5", extra_in$h, "h_over", "h_under", "h_switch")),
                list(label = "Screener's defender", keys = c(key(lead), "n5", extra_in$s, "s_drop", "s_show", "s_switch")))
  TABLE(title, cols = cols, rows = mix_rows(copy(w)), limit = limit, views = views)
}





## ═════════════════════════════════════════════════════════════════════════════
## 04 - SEASON AGGREGATES AND BASELINES ----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Season aggregates (offense-only): what each attacker faced as a handler and as a screener, and how he shoots.
cov_season <- function() {
  al <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
  canon <- function(p) {
    m <- al$canonical_player_id[match(p, al$player_id)]
    fifelse(is.na(m), p, m)
  }
  # A traded player's total row when he has one, else his per-team rows.
  rows <- function(d) {
    d <- copy(d)
    d[, canon := canon(player_id)]
    tot <- d[is.na(team_id) | team_name == "total"]
    d[!(canon %in% tot$canon) | is.na(team_id) | team_name == "total"]
  }
  pk <- rows(fread(file.path(a$root, "data", "aggregates", "acb_picksaggregates_20252026.csv")))
  sh <- rows(fread(file.path(a$root, "data", "aggregates", "acb_shotsaggregates_20252026.csv")))
  hv <- c("blitz", "ice", "over", "switch", "under")
  # Screener's defender buckets: "drop" here, "_vs_soft" in the aggregate CSV as SkillCorner delivers it.
  sv <- c(blitz = "blitz", ice = "ice", show = "show", drop = "soft", switch = "switch")
  # Coverage faced per player as handler and as screener, and his shooting.
  p <- pk[, c(list(name = player_name[1], h_tot = sum(handler_total_picks), s_tot = sum(screener_total_picks),
                   s_three = sum(screener_score_3pt + screener_miss_3pt), s_two = sum(screener_score_2pt + screener_miss_2pt)),
              setNames(lapply(hv, function(v) sum(get(paste0("handler_picks_vs_", v)))), paste0("h_", hv)),
              setNames(lapply(sv, function(v) sum(get(paste0("screener_picks_vs_", v)))), paste0("s_", names(sv)))), by = canon]
  s <- sh[, .(poss = sum(possessions_played), od3 = sum(od_three_attempts), od3m = sum(od_three_mades),
              three_att = sum(three_attempts), three_made = sum(three_mades)), by = canon]
  out <- merge(p, s, by = "canon", all.x = TRUE)
  out[, `:=`(h_called = h_blitz + h_ice + h_over + h_switch + h_under, s_called = s_blitz + s_ice + s_show + s_drop + s_switch)]
  out[, `:=`(od3_100 = 100 * od3 / pmax(1, poss), pop = s_three / pmax(1, s_tot))]
  attr(out, "hv") <- hv
  attr(out, "sv") <- sv
  out
}

#' Frequency baselines on the joint coverage (see the header). Returns one row per baseline.
cov_baselines <- function(L, S) {
  lv <- JOINT_LV
  cnt_of <- function(v) as.numeric(table(factor(v, lv)))
  setorder(L, game, def_team, f0)
  y <- L$joint7
  # Leave one game out: shares within a group of the other nine games, with the league mix worth 5 picks.
  logo <- function(grp) {
    grp[is.na(grp)] <- "unknown"
    pr <- matrix(NA_real_, nrow(L), length(lv))
    for (g in unique(L$game)) {
      tr <- L$game != g
      lg <- cnt_of(L$joint7[tr])
      for (k in unique(grp[!tr])) {
        rows <- which(!tr & grp == k)
        pr[rows, ] <- matrix(smooth_counts(cnt_of(L$joint7[tr & grp %in% k]) + 5 * lg / sum(lg)), length(rows), length(lv), byrow = TRUE)
      }
    }
    pr
  }
  # Online, within the game: the defense's own earlier coverages (league mix of the other games worth 5 picks).
  pr_game <- matrix(NA_real_, nrow(L), length(lv))
  pr_last <- pr_game
  for (g in unique(L$game)) {
    lg <- cnt_of(L$joint7[L$game != g])
    lgp <- 5 * lg / sum(lg)
    for (dt in unique(L[game == g]$def_team)) {
      rows <- which(L$game == g & L$def_team == dt)
      for (j in seq_along(rows)) {
        before <- if (j > 1) cnt_of(L$joint7[rows[seq_len(j - 1)]]) else rep(0, length(lv))
        last <- if (j > 1) cnt_of(L$joint7[rows[j - 1]]) else rep(0, length(lv))
        pr_game[rows[j], ] <- smooth_counts(before + lgp)
        pr_last[rows[j], ] <- smooth_counts(3 * last + lgp)
      }
    }
  }
  # Season files: the handler's faced over/under/switch/ice/blitz mix times the screener's show/drop split, each
  # pulled toward the league mix with 20 picks of weight. These include the ten games (10 of 293).
  W0 <- 20
  z <- function(v) {
    v[is.na(v)] <- 0
    v
  }
  hs <- S[match(L$h_canon, S$canon)]
  ss <- S[match(L$s_canon, S$canon)]
  hk <- c("h_over", "h_under", "h_switch", "h_ice", "h_blitz")
  lgh <- colSums(S[, ..hk])
  lgh <- lgh / sum(lgh)
  lgs <- sum(S$s_show) / (sum(S$s_show) + sum(S$s_drop))
  h_n <- z(hs$h_called)
  ph <- sapply(hk, function(k) (z(hs[[k]]) + W0 * lgh[[k]]) / (h_n + W0))
  pshow <- (z(ss$s_show) + W0 * lgs) / (z(ss$s_show) + z(ss$s_drop) + W0)
  pr_season <- cbind(ph[, "h_over"] * (1 - pshow), ph[, "h_over"] * pshow, ph[, "h_under"] * (1 - pshow), ph[, "h_under"] * pshow,
                     ph[, "h_switch"], ph[, "h_ice"], ph[, "h_blitz"])
  pr_season <- pr_season / rowSums(pr_season)
  # Not a usable baseline: the defense's shares over its whole game, the pick itself included. It shows how much a
  # perfect knowledge of a team's game plan (and nothing else) would be worth.
  pr_full <- matrix(NA_real_, nrow(L), length(lv))
  for (g in unique(L$game)) {
    lg <- cnt_of(L$joint7[L$game != g])
    for (dt in unique(L[game == g]$def_team)) {
      rows <- which(L$game == g & L$def_team == dt)
      pr_full[rows, ] <- matrix(smooth_counts(cnt_of(L$joint7[rows]) + 5 * lg / sum(lg)), length(rows), length(lv), byrow = TRUE)
    }
  }
  # Score every baseline.
  rbindlist(list(c(list(base = "League shares (other nine games)"), score(logo(rep("all", nrow(L))), y)),
                 c(list(base = "By pick location type"), score(logo(L$spot_lab), y)),
                 c(list(base = "By shot-clock band"), score(logo(as.character(L$sc_band)), y)),
                 c(list(base = "This defense's earlier coverages in the game"), score(pr_game, y)),
                 c(list(base = "This defense's previous coverage"), score(pr_last, y)),
                 c(list(base = "Handler's and screener's season (aggregates)"), score(pr_season, y)),
                 c(list(base = "Ceiling: the defense's mix over its whole game (uses the answers)"), score(pr_full, y))))
}

#' A quick held-out check: does a small logistic on the live model's switch read plus pre-screen signals (position
#' of the screener's defender, the two defenders' size gap, cross-match, earlier switch, earlier pick) read switches
#' better than the model's read alone? Leave one game out. Returns the scores and the stacked probabilities.
switch_check <- function(M) {
  M <- copy(M)
  M[, `:=`(y = joint7 == "switch", lp = qlogis(pmin(pmax(p_sw, 1e-4), 1 - 1e-4)), lpp = qlogis(pmin(pmax(p_sw_pre, 1e-4), 1 - 1e-4)),
           sd_small = sd_pos != "big", like = size_gap == 0L)]
  logo <- function(f) {
    p <- numeric(nrow(M))
    for (g in unique(M$game)) {
      fit <- glm(f, binomial, data = M[game != g])
      p[M$game == g] <- predict(fit, M[game == g], type = "response")
    }
    p
  }
  sig <- "sd_small + like + cross + sw_before + re_pick"
  fs <- list(c("The model's read (main curve)", "y ~ lp", "m"), c("Signals alone", paste("y ~", sig), "m"),
             c("The model's read + signals", paste("y ~ lp +", sig), "m"),
             c("The model's read before the pick frame", "y ~ lpp", "b"), c("Before the pick frame + signals", paste("y ~ lpp +", sig), "b"))
  P <- lapply(fs, function(f) logo(as.formula(f[2])))
  ll_g <- function(p) M[, .(ll = -mean(y * log(p[.I]) + (1 - y) * log(1 - p[.I]))), by = game]$ll
  ref <- list(m = ll_g(P[[1]]), b = ll_g(P[[4]]))
  tab <- rbindlist(lapply(seq_along(fs), function(i) {
    p <- P[[i]]
    data.table(check = fs[[i]][1], ll = -mean(M$y * log(p) + (1 - M$y) * log(1 - p)), auc = auc(p, M$y),
               better = if (i %in% c(1, 4)) NA_integer_ else sum(ll_g(p) < ref[[fs[[i]][3]]]))
  }))
  fit <- glm(as.formula(paste("y ~ lp +", sig)), binomial, data = M)
  list(tab = tab, p_plus = P[[3]], y = M$y, odds = exp(coef(fit)), base_ll = -mean(M$y * log(mean(M$y)) + (1 - M$y) * log(1 - mean(M$y))))
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - THE TAB: DATA ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Everything the sections quote, computed once. Returns an environment the section builders read from.
cov_prepare <- function(BL) {
  E <- new.env()
  with(E, {
    D <- cov_data(BL)
    P <- D$P
    S <- cov_season()
    # Positions of the four players, and the two defenders' size gap.
    PO <- cov_positions()
    P[, `:=`(h_pos = PO$look(H, "pos"), s_pos = PO$look(S, "pos"), bd_pos = PO$look(BD, "pos"), sd_pos = PO$look(SD, "pos"),
             sd_def_arch = PO$look(SD, "da"), sd_off_arch = PO$look(SD, "oa"))]
    rank3 <- c(guard = 1L, wing = 2L, big = 3L)
    P[, size_gap := abs(rank3[bd_pos] - rank3[sd_pos])]
    P[, `:=`(gap_lab = c("same size", "one step apart", "guard and big")[size_gap + 1L],
             pair_lab = paste(bd_pos, sd_pos, sep = " · "), hs_lab = paste(h_pos, s_pos, sep = " · "))]
    # The labelled picks (seven coverages) and the five main coverages.
    L <- copy(P[!is.na(joint7)])
    L5 <- L[joint7 %in% FIVE_LV]
    n_all <- nrow(P)
    n7 <- nrow(L)
    n5 <- nrow(L5)
    cnt <- vapply(JOINT_LV, function(l) sum(L$joint7 == l), 0L)
    base <- as.list(cnt / n7)
    b5 <- as.list(mix_by(copy(L)[, all := 1L], "all")[, .(h_over, h_under, h_switch, s_drop, s_show, s_switch)])
    sw_all <- mean(L5$joint7 == "switch")
    W <- merge(D$W, P[, .(id, joint7, cov, scov, scheme)], by = "id")
    MR <- cov_model_reads()
  })
  E
}

#' Rate rows of a flag `f` (a function of the rows) by the levels of column `by`.
rate_by <- function(d, by, lev, f) {
  lapply(lev, function(l) {
    x <- d[as.character(get(by)) %in% l]
    rrow(l, sum(f(x)), nrow(x))
  })
}
yn <- function(v) fifelse(v %in% TRUE, "yes", "no")
is_sw <- function(x) x$joint7 == "switch"
#' Evaluate a section's code with the prepared data in reach (its own variables stay local).
in_E <- function(E, expr) eval(substitute(expr), new.env(parent = E))
#' A coverage-mix table of the seven-coverage picks by one column (`lev` orders the rows, `min_n` hides small groups).
mix_tab <- function(E, by, label, title, lev = NULL, key_title = label, min_n = 1, d = E$L, limit = 20) {
  w <- mix_by(d, by, min_n = min_n)
  setnames(w, by, "grp")
  w <- w[!is.na(grp)]
  w <- if (!is.null(lev)) w[order(match(as.character(grp), lev))] else w[order(-n)]
  MIXTABLE(title, w, list(col("grp", label, title = key_title)), base = E$base, b5 = E$b5, limit = limit)
}





## ═════════════════════════════════════════════════════════════════════════════
## 06 - SECTIONS: LABEL, MOTION, TIMING, CONTEXT -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

sec_label <- function(E) in_E(E, {
  # The two labels against each other, the seven coverages, and the ten games against the season.
  cross <- dcast(P[, .N, by = .(cov, scov)], cov ~ scov, value.var = "N", fill = 0)
  cross <- cross[match(c("over", "under", "switch", "ice", "blitz"), cov)]
  scov_lv <- intersect(c("drop", "show", "switch", "ice", "blitz", "none"), names(cross))
  cross[, n := rowSums(.SD), .SDcols = scov_lv]
  cnt_tab <- data.table(coverage = JOINT_LV, n = as.integer(cnt), share = as.numeric(cnt) / n7,
                        bhr = c("over", "over", "under", "under", "switch", "ice", "blitz"),
                        scr = c("drop", "show", "drop", "show", "switch", "ice", "blitz"),
                        games = vapply(JOINT_LV, function(l) uniqueN(L[joint7 == l]$game), 0L))
  hv <- attr(S, "hv")
  sv <- attr(S, "sv")
  sea_h <- colSums(S[, paste0("h_", hv), with = FALSE])
  names(sea_h) <- hv
  sea_s <- colSums(S[, paste0("s_", names(sv)), with = FALSE])
  names(sea_s) <- names(sv)
  h_share_sea <- sea_h / sum(S$h_tot)
  s_share_sea <- sea_s / sum(S$s_tot)
  dir10 <- P[direct == TRUE]
  h_cmp_lv <- c("over", "under", "switch", "ice", "blitz")
  s_cmp_lv <- c("drop", "show", "switch", "ice", "blitz")
  maj <- JOINT_LV[which.max(cnt)]
  SECTION("cv-question", "The coverages",
          P("How SkillCorner labels each pick, how often each coverage happens, and whether the ten games look like the season."),
          KPIS(KPI("Picks", int(n_all), "on-ball screens in the ten games"),
               KPI("Labelled picks", int(n7), sprintf("%d with no coverage on the screener's defender left out", n_all - n7)),
               KPI("Most common coverage", maj, sprintf("%s of picks", pct(max(cnt) / n7))),
               KPI("Rarest coverages", sprintf("%d ice · %d blitz", cnt[["ice"]], cnt[["blitz"]]), "too few to learn from")),
          BUL("**Two labels per pick.** bhrDefType is the ball handler's defender (over, under, switch, ice or blitz). scrDefType is the screener's defender (drop, show, switch, ice, blitz or none). SkillCorner's raw label for drop is soft",
              "**One coverage per pick.** Switch, ice and blitz always come as a pair. Over or under always pairs with drop, show or none. So the two labels make one coverage with seven values",
              "**Five main coverages.** Over · drop, over · show (hedge), under · drop, under · show and switch. The model leaves out ice and blitz"),
          TABLE("Handler's defender (rows) against screener's defender (columns)", limit = 6, rows = cross,
                cols = c(list(col("cov", "Handler's defender", title = "bhrDefType, the coverage of the ball handler's defender")),
                         lapply(scov_lv, function(s) col(s, s, "int", group = "Screener's defender", title = sprintf("Picks where the screener's defender played %s", s))),
                         list(col("n", "Picks", "int", title = "All picks with this coverage on the handler's defender")))),
          TABLE("The seven coverages", limit = 8, rows = cnt_tab, cols = list(col("coverage", "Coverage", title = "The handler's defender's and the screener's defender's coverage together"),
                                                                             col("bhr", "Handler's defender", title = "bhrDefType"), col("scr", "Screener's defender", title = "scrDefType"),
                                                                             col("n", "Picks", "int", title = "Picks with this coverage in the ten games"),
                                                                             col("share", "Share", "pct1", title = "Share of the labelled picks"),
                                                                             col("games", "Games", "int", title = "Games (of ten) with at least one"))),
          H("Are the ten games typical?"),
          P("The season files count direct picks only (the handler or screener shot, passed for an assist or drew a foul right after the pick). They give each defender's coverage across the league, never the pair together."),
          GRID(COLS("Handler's defender: ten games vs season", h_cmp_lv, labels = TRUE,
                    list(SERIES1("ten games (direct picks)", sapply(h_cmp_lv, function(l) mean(dir10$cov == l)), PAL[1]),
                         SERIES1("season, 293 games (direct picks)", h_share_sea[h_cmp_lv], PAL[2]))),
               COLS("Screener's defender: ten games vs season", s_cmp_lv, labels = TRUE,
                    list(SERIES1("ten games (direct picks)", sapply(s_cmp_lv, function(l) mean(dir10$scov == l)), PAL[1]),
                         SERIES1("season, 293 games (direct picks)", s_share_sea[s_cmp_lv], PAL[2])))),
          TAKE(sprintf("**Over is the default.** Over · drop and over · show make up %s of picks. Guessing the more common one is right %s of the time", pct((cnt[["over · drop"]] + cnt[["over · show"]]) / n7), pct(max(cnt) / n7)),
               sprintf("**The sample matches the season.** Season direct picks are %s over, %s under and %s switch. Only %s of %s have no coverage on the handler's defender, and %s none on the screener's",
                       pct(h_share_sea[["over"]]), pct(h_share_sea[["under"]]), pct(h_share_sea[["switch"]]),
                       int(sum(S$h_tot) - sum(sea_h)), int(sum(S$h_tot)), int(sum(S$s_tot) - sum(sea_s))),
               sprintf("**Ice and blitz are rare everywhere.** Ice is %s of season direct picks and blitz %s", pct(h_share_sea[["ice"]], 1), pct(h_share_sea[["blitz"]], 1))))
})

sec_motion <- function(E) in_E(E, {
  # Average traces of the five main coverages, by joint coverage or by one defender's part of it.
  W5 <- W[joint7 %in% FIVE_LV]
  mcols <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl")
  AG <- list(j = W5[, lapply(.SD, mean, na.rm = TRUE), by = .(grp = joint7, t), .SDcols = mcols],
             h = W5[, lapply(.SD, mean, na.rm = TRUE), by = .(grp = cov, t), .SDcols = mcols],
             s = W5[, lapply(.SD, mean, na.rm = TRUE), by = .(grp = scov, t), .SDcols = mcols])
  LV <- list(j = FIVE_LV, h = c("over", "under", "switch"), s = c("drop", "show", "switch"))
  ag <- function(k, g, tt, m) AG[[k]][grp == g & t == tt][[m]]
  zero_line <- function(lo, hi) LINE(c(0, 0), c(lo, hi), color = "var(--muted)", dashed = TRUE)
  trace_chart <- function(m, k, title, ylab) {
    v <- AG[[k]][[m]]
    lo <- floor(min(v, na.rm = TRUE))
    hi <- ceiling(max(v, na.rm = TRUE))
    SCAT(title, lines = c(LINES_BY(AG[[k]], "t", m, "grp", LV[[k]], colors = LINE_COL), list(zero_line(lo, hi))),
         xlabel = "seconds from the pick (0 = picks.frame)", ylabel = ylab, xdomain = c(-3, 2), ydomain = c(lo, hi))
  }
  closest <- W[!is.na(d_hs), .SD[which.min(d_hs)], by = id]
  mk <- P[!is.na(mk_post), .(n = .N, sd = mean(mk_post == SD), bd = mean(mk_post == BD)), by = scheme][order(-n)]
  mk_pre <- P[, mean(mk_pre == BD, na.rm = TRUE)]
  SECTION("cv-motion", "What each coverage looks like",
          P("The four players of the screen from 3 s before to 2 s after the pick frame. Lines are averages. A chart about one defender splits by his own coverage, so the handler's defender shows over, under and switch and the screener's defender shows drop, show and switch. Ice and blitz are left out. The dashed line is the pick frame."),
          BUL(sprintf("**Time 0 is the pick frame** (picks.frame). The handler comes off the screener's shoulder a median %.1f s later (middle half %.1f to %.1f s)", median(closest$t), quantile(closest$t, .25), quantile(closest$t, .75)),
              "**Level vs the screen** is a player's distance from the hoop minus the screen spot's, in feet. Above the screen is positive and below is negative. Over keeps the handler's defender above the screen and under takes him below it. Show brings the screener's defender up to the ball and drop keeps him back",
              sprintf("**Who is who.** ballhandlerDefId and screenerDefId name the defenders before any switch. The matchups table agrees on %s of picks just before the screen", pct(mk_pre))),
          GRID(trace_chart("bd_lvl", "h", "Handler's defender: level vs the screen", "ft above (+) or below (−)"),
               trace_chart("sd_lvl", "s", "Screener's defender: level vs the screen", "ft above (+) or below (−)"),
               trace_chart("d_bd", "h", "Handler to his own defender", "ft"),
               trace_chart("d_sd", "s", "Handler to the screener's defender", "ft"),
               trace_chart("d_def", "j", "The two defenders' distance from each other", "ft"),
               trace_chart("h_lvl", "h", "Handler: level vs the screen, by his defender's coverage", "ft above (+) or below (−)")),
          TABLE("Who guards the handler 1.5 s after the pick (matchups table)", limit = 5, rows = mk, cols = list(col("scheme", "Coverage", title = "Over/under groups the four over and under coverages"),
                                                                                                                  col("n", "Picks", "int", title = "Picks with a matchup row for the handler 1.5 s after the pick"),
                                                                                                                  col("sd", "Screener's defender", "pct", title = "Share where the handler's assigned defender is now the screener's defender"),
                                                                                                                  col("bd", "Own defender", "pct", title = "Share where the handler's assigned defender is still his original defender"))),
          TAKE(sprintf("**Under drops below the screen.** The handler's defender is %.1f ft below the screen level 0.4 s after the pick frame. Going over he is %.1f ft above it", -ag("h", "under", 0.4, "bd_lvl"), ag("h", "over", 0.4, "bd_lvl")),
               sprintf("**Show meets the ball.** The screener's defender is %.1f ft from the handler 0.4 s after the pick frame. Drop keeps him %.1f ft away", ag("s", "show", 0.4, "d_sd"), ag("s", "drop", 0.4, "d_sd")),
               sprintf("**Switch trades men late.** By +2 s the handler's own defender is %.1f ft away and the screener's defender %.1f ft", ag("h", "switch", 2, "d_bd"), ag("s", "switch", 2, "d_sd")),
               sprintf("**Under starts with a high handler.** 1 s before the pick frame the handler is %.1f ft above the screen when his defender goes under and %.1f ft when he goes over", ag("h", "under", -1, "h_lvl"), ag("h", "over", -1, "h_lvl")),
               sprintf("**The matchups table agrees on switches.** %s of switches hand the handler to the screener's defender 1.5 s after the pick, against %s of over and under picks", pct(mk[scheme == "switch"]$sd), pct(mk[scheme == "over/under"]$sd))),
          CAVEAT("Averages hide spread. Single picks overlap a lot, which the next section measures"))
})

sec_timing <- function(E) in_E(E, {
  # Separation (AUC) of each measure at each moment, for three questions.
  meas <- c(bd_lvl = "handler's defender: level vs screen", sd_lvl = "screener's defender: level vs screen",
            d_bd = "handler to his own defender", d_sd = "handler to screener's defender", d_def = "defender to defender",
            h_lvl = "handler: level vs screen")
  contrasts <- list(list(name = "Under or over (the handler's defender)", ids = P[cov %in% c("over", "under"), .(id, g = cov == "under")]),
                    list(name = "Show or drop (the screener's defender, over and under picks)", ids = P[cov %in% c("over", "under") & scov %in% c("show", "drop"), .(id, g = scov == "show")]),
                    list(name = "Switch or not (switch against over and under picks)", ids = P[scheme %in% c("switch", "over/under"), .(id, g = scheme == "switch")]))
  CN <- vapply(contrasts, `[[`, "", "name")
  SEP <- rbindlist(lapply(contrasts, function(cc) {
    d <- merge(W[, c("id", "t", names(meas)), with = FALSE], cc$ids, by = "id")
    rbindlist(lapply(names(meas), function(m) d[, .(contrast = cc$name, m = m, auc = auc(get(m), g)), by = t]))
  }))
  SEP[, `:=`(sep = pmax(auc, 1 - auc), lab = meas[m])]
  sep_at <- function(k, mm, tt) SEP[contrast == CN[k] & m == mm & t == tt]$sep
  best_at <- function(k, tt) SEP[contrast == CN[k] & t == tt][which.max(sep)]
  zero_line <- function(lo, hi) LINE(c(0, 0), c(lo, hi), color = "var(--muted)", dashed = TRUE)
  sep_chart <- function(k) {
    SCAT(CN[k], lines = c(LINES_BY(SEP[contrast == CN[k]], "t", "sep", "lab", unname(meas)), list(zero_line(0.5, 1))),
         xlabel = "seconds from the pick", ylabel = "separation (AUC, 0.5 = none, 1 = perfect)", xdomain = c(-3, 2),
         ydomain = c(0.5, 1), yfmt = "num2")
  }
  best_tab <- rbindlist(lapply(c(-2, -1, -0.4, 0, 0.4, 1, 2), function(tt) {
    b <- lapply(1:3, function(k) best_at(k, tt))
    data.table(t = tt, uo = b[[1]]$sep, uo_m = b[[1]]$lab, ss = b[[2]]$sep, ss_m = b[[2]]$lab, sw = b[[3]]$sep, sw_m = b[[3]]$lab)
  }))
  SECTION("cv-timing", "When it shows",
          P("If two coverages only look different after the screen, a model that sees those frames is recognising the coverage. Before the screen it has to predict it."),
          BUL("**Separation (AUC).** Take one pick of each kind at random. The AUC is how often a measure puts them the right way round. 0.5 is a coin flip and 1 is always right. Each point is one measure at one moment",
              "The charts follow each measure from −3 s to +2 s for the three questions a model faces"),
          GRID(sep_chart(1), sep_chart(2), sep_chart(3), cols = 1),
          TABLE("Best single measure at each moment", limit = 10, rows = best_tab, cols = list(col("t", "Seconds", "num1", title = "Seconds from the pick frame"),
                                                                                               col("uo", "AUC", "num2", group = "Under or over", title = "Best separation of any single measure at that moment"),
                                                                                               col("uo_m", "Best measure", group = "Under or over", title = "The measure that separates best at that moment"),
                                                                                               col("ss", "AUC", "num2", group = "Show or drop", title = "Best separation of any single measure at that moment"),
                                                                                               col("ss_m", "Best measure", group = "Show or drop", title = "The measure that separates best at that moment"),
                                                                                               col("sw", "AUC", "num2", group = "Switch or not", title = "Best separation of any single measure at that moment"),
                                                                                               col("sw_m", "Best measure", group = "Switch or not", title = "The measure that separates best at that moment"))),
          TAKE(sprintf("**Under or over shows late.** Best AUC %.2f 1 s before the pick frame and %.2f 0.4 s after it", best_at(1, -1)$sep, best_at(1, 0.4)$sep),
               sprintf("**Show or drop shows first.** The screener's defender's level separates %.2f at −0.4 s and %.2f at the pick frame", sep_at(2, "sd_lvl", -0.4), sep_at(2, "sd_lvl", 0)),
               sprintf("**Switch shows last.** Best %.2f at the pick frame, %.2f at +1 s and %.2f at +2 s", best_at(3, 0)$sep, best_at(3, 1)$sep, best_at(3, 2)$sep),
               "**So a read before the screen leans on set-up and context.** A model allowed to look 0.5 to 1 s past the screen is mostly reading a coverage already visible in the tracking"),
          CAVEAT("One measure at one moment is a floor. Combining measures and frames separates better, most of all before the screen",
                 "SkillCorner's labels come from its own tracking model, so part of the after-screen separation is the labelling rule itself"))
})

sec_context <- function(E) in_E(E, {
  # The mix by situation, the switch and under rates that move most, and where each coverage happens.
  L[, `:=`(k_lab = fifelse(k_in_chance == 1L, "first pick of the chance", "re-screen (2nd+ pick)"),
           hop_lab = fifelse(hop, "handoff-pick", "plain pick"),
           clutch_lab = fifelse(clutch, "last 2 min of Q4 / OT", "rest of the game"))]
  sw_sc <- L[!is.na(sc_band), .(k = sum(joint7 == "switch"), n = .N), by = sc_band][order(sc_band)]
  OU <- L[cov %in% c("over", "under")]
  un_spot <- OU[, .(k = sum(cov == "under"), n = .N), by = spot_lab][order(match(spot_lab, c("middle", "step-up", "wing")))]
  hl <- merge(W[t == -1 & cov %in% c("over", "under") & !is.na(h_lvl), .(id, h_lvl)], P[, .(id, cov)], by = "id")
  hl[, band := cut(h_lvl, c(-Inf, 3, 8, 13, Inf), labels = c("under 3 ft", "3-8 ft", "8-13 ft", "13+ ft"))]
  sw_rate <- function(b) {
    r <- sw_sc[sc_band == b]
    r$k / r$n
  }
  un_band <- function(b) mean(hl[band == b]$cov == "under")
  SECTION("cv-context", "Where and when",
          P("The coverage mix by situation. Each share is of that row's picks. Blue cells are above the overall share and red cells below. The switch above each table shows the full coverage or one defender at a time."),
          mix_tab(E, "spot_lab", "Location type", "By pick location type (picks.locationType)", c("middle", "step-up", "wing"), "SkillCorner's locationType: middle, step-up or wing"),
          mix_tab(E, "sc_band", "Shot clock", "By shot clock left at the pick", levels(P$sc_band), "Seconds left on the shot clock at the pick"),
          mix_tab(E, "k_lab", "Pick in chance", "First pick or re-screen", NULL, "Whether an earlier pick happened in the same chance"),
          mix_tab(E, "hop_lab", "Kind", "Plain pick or handoff-pick", NULL, "picks.handoffPick, a handoff combined with a pick"),
          mix_tab(E, "clutch_lab", "Game time", "Late-game picks", NULL, "Last two minutes of the fourth quarter or overtime"),
          GRID(RATES("Switch rate by shot clock left", lapply(seq_len(nrow(sw_sc)), function(i) rrow(as.character(sw_sc$sc_band[i]), sw_sc$k[i], sw_sc$n[i])),
                     ref = base[["switch"]], unit = "of picks switched", label_width = 90),
               RATES("Under rate by location type (over and under picks)", lapply(seq_len(nrow(un_spot)), function(i) rrow(un_spot$spot_lab[i], un_spot$k[i], un_spot$n[i])),
                     ref = mean(OU$cov == "under"), unit = "went under", label_width = 90),
               RATES("Under rate by how far above the screen the handler is 1 s before", lapply(levels(hl$band), function(b) rrow(b, sum(hl[band == b]$cov == "under"), nrow(hl[band == b]))),
                     ref = mean(hl$cov == "under"), unit = "went under", label_width = 110)),
          GRID(COURT("Where over picks were set", L[cov == "over"]$x, L[cov == "over"]$y),
               COURT("Where under picks were set", L[cov == "under"]$x, L[cov == "under"]$y),
               COURT("Where switches happened", L[joint7 == "switch"]$x, L[joint7 == "switch"]$y),
               COURT("Where the screener's defender showed", L[scov == "show"]$x, L[scov == "show"]$y)),
          TAKE(sprintf("**Switches grow as the shot clock runs down.** %s of picks with 18+ s left, %s with 6 s or less", pct(sw_rate("18-24 s")), pct(sw_rate("0-6 s"))),
               sprintf("**Under follows how high the handler starts.** %s go under when he is 13+ ft above the screen 1 s before, %s when he is within 3 ft", pct(un_band("13+ ft")), pct(un_band("under 3 ft"))),
               sprintf("**Location type barely matters.** The under rate only moves from %s to %s", pct(min(un_spot$k / un_spot$n)), pct(max(un_spot$k / un_spot$n)))))
})





## ═════════════════════════════════════════════════════════════════════════════
## 07 - SECTIONS: PEOPLE, BEFORE THE SCREEN, SWITCHES --------------------------
## ═════════════════════════════════════════════════════════════════════════════

sec_people <- function(E) in_E(E, {
  # How the archetypes map to positions, the mix by the four players' positions, and what the archetypes contain.
  pos <- PO$pos
  arch_tab <- rbind(pos[!is.na(oa), .(side = "offense", players = .N), by = .(archetype = oa)],
                    pos[!is.na(da), .(side = "defense", players = .N), by = .(archetype = da)])
  arch_tab[, group := fifelse(side == "offense", unname(POS_OFF[archetype]), unname(POS_DEF[archetype]))]
  arch_tab <- arch_tab[order(side != "offense", match(group, POS_LV), -players)]
  xt <- dcast(pos[!is.na(oa) & !is.na(da), .N, by = .(grp = unname(POS_OFF[oa]), da)], grp ~ da, value.var = "N", fill = 0)
  for (k in names(POS_DEF)) if (!k %in% names(xt)) xt[, (k) := 0L]
  xt <- xt[order(match(grp, POS_LV))]
  n_big_anchor <- pos[da %in% "Anchor Big" & !is.na(oa), .(k = sum(POS_OFF[oa] == "big"), n = .N)]
  n_chaser <- pos[da %in% "Chaser" & !is.na(oa), .(k = sum(POS_OFF[oa] == "guard"), n = .N)]
  n_players <- uniqueN(c(P$H, P$S, P$BD, P$SD))
  n_off <- sum(!is.na(PO$look(unique(c(P$H, P$S, P$BD, P$SD)), "oa")))
  # Rates of the five main coverages by position.
  sw_pos <- function(col_) L5[, .(k = sum(joint7 == "switch"), n = .N, show = mean(scov == "show"), under = mean(cov == "under")), by = c(col_)]
  s_sd <- sw_pos("sd_pos")
  s_gap <- sw_pos("gap_lab")
  gb <- L5[pair_lab == "guard · big"]
  OU5 <- L5[cov %in% c("over", "under")]
  # What the archetype clusters contain (feature dictionary).
  dict <- fread(file.path(a$root, "archetypes", "03_outputs", "feature_dictionary.csv"))
  scr_feats <- c("d_pick_bh_per100", "d_pick_scr_per100", "d_meet_dist", "d_guard_handler", "d_guard_screener", "d_onball_share",
                 "d_switch_per100", "d_scr_drop_share", "d_scr_show_share", "d_scr_switch_share", "d_scr_depth", "d_bh_under_share",
                 "d_bh_switch_share", "s_ctx_bh_under_share", "s_ctx_bh_switch_share", "s_ctx_scr_drop_share", "s_ctx_scr_switch_share")
  ft <- dict[feature %in% scr_feats, .(feature, side, definition, used = fifelse(clustering == "cluster", "yes", "no"), reliability, split_half_r)]
  ft <- ft[order(used != "yes", side, match(feature, scr_feats))]
  cov_feats <- dict[grepl("(drop|show|switch|under)_share$", feature)]
  n_cov_out <- cov_feats[clustering != "cluster", .N]
  def_cl <- dict[side == "defense" & clustering == "cluster"]
  n_mu <- def_cl[grepl("assigned|his man|guarding", definition), .N]
  SECTION("cv-people", "Who is in the screen",
          P("Coverage by the size of the four players. Each player's archetype is grouped into guard, wing or big. The archetypes are not refitted."),
          H("Guard, wing or big"),
          BUL("**Guard.** Primary Ball Handler, Secondary Ball Handler and Slasher",
              "**Wing.** Off Screen Shooter, Movement Shooter, Stationary Shooter and Athletic Finisher",
              "**Big.** Post Scorer, Roll & Cut Big and Versatile Big",
              sprintf("**Offense sets the group.** A player's offensive archetype sets his group, and %s of the %d players in these picks have one. The defensive archetypes are a check (Chaser counts as guard). %d of %d Anchor Bigs are offensive bigs, and %d of %d Chasers are offensive guards", if (n_off == n_players) "all" else as.character(n_off), n_players, n_big_anchor$k, n_big_anchor$n, n_chaser$k, n_chaser$n)),
          DETAILS("How the archetypes map to positions",
                  TABLE("Archetypes and their group", limit = 14, rows = arch_tab, cols = list(col("archetype", "Archetype", title = "Archetype from archetypes/03_outputs"), col("side", "Side", title = "Offensive or defensive archetype"),
                                                                                                col("group", "Group", title = "Guard, wing or big"), col("players", "Players", "int", title = "Players with this archetype (season)"))),
                  TABLE("Offensive group (rows) against defensive archetype (columns)", limit = 4, rows = xt, cols = c(list(col("grp", "Offensive group", title = "Group from the offensive archetype")),
                                                                                                                       lapply(names(POS_DEF), function(k) col(k, k, "int", group = "Defensive archetype", title = sprintf("Players whose defensive archetype is %s", k)))))),
          H("Coverage by position"),
          mix_tab(E, "sd_pos", "Screener's defender", "By the screener's defender's position", POS_LV, "Guard, wing or big, from his archetype"),
          mix_tab(E, "bd_pos", "Handler's defender", "By the handler's defender's position", POS_LV, "Guard, wing or big, from his archetype"),
          mix_tab(E, "gap_lab", "Size gap", "By the size gap between the two defenders", c("same size", "one step apart", "guard and big"), "Same size, one step apart (guard and wing or wing and big), or a guard and a big"),
          mix_tab(E, "pair_lab", "Defenders", "By both defenders (handler's defender · screener's defender, 10+ picks)", NULL, "Handler's defender's position · screener's defender's position", min_n = 10),
          mix_tab(E, "hs_lab", "Attackers", "By both attackers (handler · screener, 10+ picks)", NULL, "Handler's position · screener's position", min_n = 10),
          mix_tab(E, "sd_def_arch", "Screener's defender", "By the screener's defender's defensive archetype", c("Point of Attack", "Chaser", "Helper", "Anchor Big"), "His defensive archetype"),
          mix_tab(E, "sd_off_arch", "Screener's defender", "By the screener's defender's offensive archetype (15+ picks)", NULL, "His offensive archetype", min_n = 15),
          GRID(RATES("Switch rate by the screener's defender's position", rate_by(L5, "sd_pos", POS_LV, is_sw), ref = sw_all, unit = "of picks switched", label_width = 70),
               RATES("Switch rate by the handler's defender's position", rate_by(L5, "bd_pos", POS_LV, is_sw), ref = sw_all, unit = "of picks switched", label_width = 70),
               RATES("Switch rate by the size gap between the defenders", rate_by(L5, "gap_lab", c("same size", "one step apart", "guard and big"), is_sw), ref = sw_all, unit = "of picks switched", label_width = 110),
               RATES("Show rate by the screener's defender's position", rate_by(L5, "sd_pos", POS_LV, function(x) x$scov == "show"), ref = mean(L5$scov == "show"), unit = "of picks shown", label_width = 70),
               RATES("Under rate by the handler's defender's position (over and under picks)", rate_by(OU5, "bd_pos", POS_LV, function(x) x$cov == "under"), ref = mean(OU5$cov == "under"), unit = "went under", label_width = 70)),
          TAKE(sprintf("**Bigs rarely switch.** The screen switches on %s of picks when the screener's defender is a big, %s when he is a wing and %s when he is a guard",
                       pct(s_sd[sd_pos == "big", k / n]), pct(s_sd[sd_pos == "wing", k / n]), pct(s_sd[sd_pos == "guard", k / n])),
               sprintf("**Same-size defenders switch most.** %s of picks switch when the two defenders are the same size and %s when a guard and a big defend the screen",
                       pct(s_gap[gap_lab == "same size", k / n]), pct(s_gap[gap_lab == "guard and big", k / n])),
               sprintf("**The most common screen switches least.** A guard on the ball and a big on the screener is %s of picks. It switches %s of the time", pct(nrow(gb) / n5), pct(mean(gb$joint7 == "switch"))),
               sprintf("**Size moves switches far more than show or under.** The show rate only ranges from %s to %s across the screener's defender's position", pct(min(s_sd$show)), pct(max(s_sd$show)))),
          H("Do the archetypes already know coverage?"),
          BUL(sprintf("**Screen volume goes in.** The defensive archetypes use %d features. Several count screens defended (as the handler's or the screener's defender) and where he meets the handler", nrow(def_cl)),
              sprintf("**Coverage habits stay out.** The %d coverage-share features (how often he drops, shows, goes under or switches) are left out of the clusters. Over ten games they are too noisy, with split-half correlations from %.2f to %.2f",
                      n_cov_out, min(cov_feats$split_half_r, na.rm = TRUE), max(cov_feats$split_half_r, na.rm = TRUE)),
              "**So archetypes carry coverage through size and role.** Bigs who anchor the paint and guards who pick up the ball defend screens differently, as the tables above show"),
          TABLE("Screen features in the archetype files", limit = 20, rows = ft, cols = list(col("feature", "Feature", title = "Name in archetypes/03_outputs/feature_dictionary.csv"), col("side", "Side", title = "Offensive or defensive feature"),
                                                                                             col("definition", "Definition", title = "What the feature measures"),
                                                                                             col("used", "In the clusters", title = "Whether the feature is used to fit the archetypes"),
                                                                                             col("reliability", "Reliability", "num2", title = "Share of the spread between players that is real rather than noise"),
                                                                                             col("split_half_r", "Split-half r", "num2", title = "Correlation between two halves of the tracked games"))),
          H("Would archetypes leak into the model?"),
          BUL("**No coverage label goes in.** No coverage share enters the clusters, so an archetype never holds the answer directly",
              sprintf("**A small side door through matchups.** %d defensive clustering features use who he was assigned to guard (the matchups table). After a switch a big is assigned to a guard, so a big who switches a lot drifts toward guard-like values", n_mu),
              "**The graded game is inside the fit.** The archetypes were fitted on all ten games and on season files that include them (and later games). A model graded on a held-out game would use groups shaped partly by that game",
              "**Safest form.** The guard, wing or big group from the offensive archetype. It rests on how a player scores and moves on offense, the furthest from coverage. For zero leakage, refit the archetypes without the graded game in each fold",
              "**Fair for a coach's question.** A scout knows who is a guard, a wing or a big before tip-off. Position is a fair input as long as it comes from data outside the graded game"),
          CAVEAT(sprintf("Guard screener's defenders appear on only %d picks, so their rates carry wide intervals", s_sd[sd_pos == "guard", n])))
})

sec_before <- function(E) in_E(E, {
  # Earlier actions in the possession against the switch rate and the coverage mix.
  acts <- list(c("sw_before", "Earlier switch in the possession"), c("cross", "Cross-matched coming in"),
               c("re_pick", "Earlier pick in the possession"), c("obs_before", "Earlier off-ball screen"),
               c("ho_before", "Earlier handoff"), c("drive_before", "Earlier drive"), c("cut3", "Cut in the last 3 s"),
               c("transition", "Transition chance"))
  act_tab <- rbindlist(lapply(acts, function(a2) {
    f <- L5[[a2[1]]] %in% TRUE
    data.table(action = a2[2], yes = sum(f), share = mean(f), sw_yes = mean(L5$joint7[f] == "switch"), sw_no = mean(L5$joint7[!f] == "switch"),
               un_yes = mean(L5$cov[f] == "under"), un_no = mean(L5$cov[!f] == "under"))
  }))
  act_tab[, ratio := sw_yes / sw_no]
  act_mix <- rbindlist(c(list(mix_by(copy(L)[, grp := "All picks"], "grp")),
                         lapply(acts, function(a2) mix_by(L[get(a2[1]) %in% TRUE][, grp := a2[2]], "grp"))), fill = TRUE)
  for (k in c("sw_before", "cross", "re_pick", "obs_before")) L5[, (paste0(k, "_yn")) := yn(get(k))]
  ov <- L5[sw_before == TRUE, mean(cross)]
  sr <- function(flag, v = TRUE) mean(L5[get(flag) %in% v]$joint7 == "switch")
  ur <- function(flag, v = TRUE) mean(L5[get(flag) %in% v]$cov == "under")
  pb <- L5[, .(k = sum(joint7 == "switch"), n = .N), by = pass_band]
  pass_lv <- c("0", "1", "2", "3", "4 or more")
  SECTION("cv-before", "What comes before the screen",
          P("Actions earlier in the same possession, before the pick frame. Assignments come from the matchups table and stop 1 s before the pick frame, so the pick's own switch is never counted."),
          BUL("**Earlier switch.** An off-ball screen, handoff or pick earlier in the possession was switched",
              "**Cross-matched coming in.** Earlier in the possession the handler or the screener was guarded by someone other than his defender at the pick",
              "**Assignment changes.** How many times the handler's or the screener's defender changed in the 5 s before (up to 1 s before the pick frame)",
              "**Screens, handoffs, drives and passes.** Counted in the possession before the pick frame. Cuts are the play viewer's cut markers in the last 3 s"),
          TABLE("Switch rate with and without each action (five main coverages)", limit = 10, rows = act_tab,
                cols = list(col("action", "Before the pick", title = "What happened earlier in the possession"),
                            col("yes", "Picks with it", "int", title = "Picks with this action earlier in the possession"),
                            col("share", "Share", "pct", title = "Share of picks with this action earlier"),
                            col("sw_yes", "With", "pct", ref = sw_all, scale = 0.15, group = "Switch rate", title = "Switch rate when the action came first"),
                            col("sw_no", "Without", "pct", ref = sw_all, scale = 0.15, group = "Switch rate", title = "Switch rate otherwise"),
                            col("ratio", "Ratio", "num2", group = "Switch rate", title = "Switch rate with the action divided by the rate without it"),
                            col("un_yes", "With", "pct", ref = mean(L5$cov == "under"), scale = 0.15, group = "Under rate", title = "Under rate when the action came first"),
                            col("un_no", "Without", "pct", ref = mean(L5$cov == "under"), scale = 0.15, group = "Under rate", title = "Under rate otherwise"))),
          MIXTABLE("Coverage mix when each action came first (rows overlap)", act_mix, list(col("grp", "Before the pick", title = "What happened earlier in the possession")),
                   base = base, b5 = b5),
          GRID(RATES("Switch rate after an earlier switch in the possession", rate_by(L5, "sw_before_yn", c("yes", "no"), is_sw), ref = sw_all, unit = "of picks switched", label_width = 50),
               RATES("Switch rate when cross-matched coming in", rate_by(L5, "cross_yn", c("yes", "no"), is_sw), ref = sw_all, unit = "of picks switched", label_width = 50),
               RATES("Switch rate by assignment changes in the 5 s before", rate_by(L5, "chg_band", c("0", "1", "2 or more"), is_sw), ref = sw_all, unit = "of picks switched", label_width = 80),
               RATES("Switch rate by passes earlier in the possession", rate_by(L5, "pass_band", pass_lv, is_sw), ref = sw_all, unit = "of picks switched", label_width = 80),
               RATES("Switch rate after an earlier pick in the possession", rate_by(L5, "re_pick_yn", c("yes", "no"), is_sw), ref = sw_all, unit = "of picks switched", label_width = 50),
               RATES("Switch rate after an earlier off-ball screen", rate_by(L5, "obs_before_yn", c("yes", "no"), is_sw), ref = sw_all, unit = "of picks switched", label_width = 50)),
          TAKE(sprintf("**An earlier switch doubles the switch rate.** %s after an earlier switch in the possession, %s otherwise. A defense that switches one action tends to switch the next", pct(sr("sw_before")), pct(sr("sw_before", FALSE))),
               sprintf("**Cross-matches carry over.** %s of picks switch when the handler or the screener is already cross-matched, against %s", pct(sr("cross")), pct(sr("cross", FALSE))),
               sprintf("**Under nearly disappears.** After an earlier switch only %s of picks go under (%s otherwise)", pct(ur("sw_before")), pct(ur("sw_before", FALSE))),
               sprintf("**Re-screens switch more.** %s with an earlier pick in the possession, %s on the first", pct(sr("re_pick")), pct(sr("re_pick", FALSE))),
               sprintf("**Ball movement adds a little.** %s of picks switch after 0 or 1 passes and %s after 4 or more. More passes also means less shot clock",
                       pct(pb[pass_band %in% c("0", "1"), sum(k) / sum(n)]), pct(pb[pass_band == "4 or more", sum(k) / sum(n)])),
               sprintf("**Cuts and drives add nothing.** %s of picks switch after a cut in the last 3 s and %s after an earlier drive, close to the %s overall", pct(sr("cut3")), pct(sr("drive_before")), pct(sw_all))),
          CAVEAT(sprintf("These flags overlap. %s of picks after an earlier switch are also cross-matched", pct(ov)),
                 "The matchups table is SkillCorner's assignment model, so a cross-match is its reading of who guards whom"))
})

sec_switch <- function(E) in_E(E, {
  # When the hand-over happens, what the live model reads, and a quick held-out check of extra signals.
  hb <- c("before −0.5 s", "−0.5 to 0 s", "0 to 0.5 s", "0.5 to 1 s", "1 to 2 s", "2 to 3 s", "none by +3 s")
  SWI <- L5[joint7 == "switch"]
  SWI[, hband := fifelse(is.na(t_hand), hb[7], as.character(cut(t_hand, c(-Inf, -0.5, 0, 0.5, 1, 2, Inf), labels = hb[1:6])))]
  OUh <- L5[joint7 != "switch"]
  blocks <- list(P("Why switches are hard to read, what the live model gets, and which inputs could help."),
                 H("When the switch happens"),
                 KPIS(KPI("Switch hand-over", sprintf("+%.1f s", median(SWI$t_hand, na.rm = TRUE)), "median, after the pick frame (matchups table)"),
                      KPI("By the pick frame", pct(mean(SWI$t_hand <= 0, na.rm = TRUE) * mean(!is.na(SWI$t_hand))), "of switches already handed over"),
                      KPI("No hand-over by +3 s", pct(mean(is.na(SWI$t_hand))), sprintf("%d of %d switches", sum(is.na(SWI$t_hand)), nrow(SWI))),
                      KPI("Other picks handed over", pct(mean(!is.na(OUh$t_hand))), "over and under picks, −1 s to +3 s")),
                 COLS("When the matchups table hands the handler to the screener's defender (switches)", hb, labels = TRUE,
                      list(SERIES1("share of switches", sapply(hb, function(b) mean(SWI$hband == b)), PAL[5])), xlabel = "seconds from the pick frame"),
                 BUL(sprintf("**The switch lands after the screen.** The handler is handed to the screener's defender a median %.1f s after the pick frame", median(SWI$t_hand, na.rm = TRUE)),
                     "**Until then a switch looks like over.** The handler's defender stays above the screen and the screener's defender stays near his man (the level charts in What each coverage looks like)",
                     sprintf("**Some switches never show in the matchups.** %s of switches have no hand-over by +3 s. They may be late switches or label noise worth a film check", pct(mean(is.na(SWI$t_hand))))))
  if (!is.null(MR)) {
    M <- merge(L5, MR, by = "id")
    mr_row <- function(lab, d) data.table(grp = lab, n = nrow(d), sw = mean(d$joint7 == "switch"), p = mean(d$p_sw),
                                          rec = sum(d$read_sw * (d$joint7 == "switch")) / sum(d$joint7 == "switch"),
                                          fa = sum(d$read_sw * (d$joint7 != "switch")) / sum(d$joint7 != "switch"))
    none <- M[sd_pos == "big" & !cross & !sw_before & !re_pick]
    mr <- rbind(mr_row("All screens", M), mr_row("Screener's defender a guard", M[sd_pos == "guard"]), mr_row("Screener's defender a wing", M[sd_pos == "wing"]),
                mr_row("Screener's defender a big", M[sd_pos == "big"]), mr_row("Defenders the same size", M[size_gap == 0L]),
                mr_row("Cross-matched coming in", M[cross == TRUE]), mr_row("Earlier switch in the possession", M[sw_before == TRUE]),
                mr_row("Earlier pick in the possession", M[re_pick == TRUE]), mr_row("None of these (big on the screener, no history)", none))
    SC <- switch_check(M)
    tb <- SC$tab
    p_all <- mean(M$p_sw)
    flag_row <- function(lab, f, y = M$joint7 == "switch") data.table(rule = lab, flagged = mean(f), rec = sum(f & y) / sum(y), prec = if (sum(f)) sum(f & y) / sum(f) else NA_real_)
    fl <- rbind(data.table(rule = "Top coverage, frame by frame (the live card)", flagged = mean(M$read_sw), rec = mr$rec[1],
                           prec = sum(M$read_sw * (M$joint7 == "switch")) / sum(M$read_sw)),
                flag_row("Model switch probability 20%+", M$p_sw >= 0.2), flag_row("Model switch probability 30%+", M$p_sw >= 0.3),
                flag_row("Model + signals 20%+", SC$p_plus >= 0.2), flag_row("Model + signals 30%+", SC$p_plus >= 0.3))
    od <- SC$odds
    blocks <- c(blocks, list(
      H("What the model reads"),
      P(sprintf("The live model's held-out read on the %s scored screens, averaged over the main time-weight curve (−1.8 s to +0.5 s). The model sees the ten players' last 1.6 s and no names.", int(nrow(M)))),
      TABLE("Switches and the model's switch read by group", limit = 12, rows = mr,
            cols = list(col("grp", "Group", title = "Screens in the group"), col("n", "Screens", "int", title = "Scored screens in the group"),
                        col("sw", "Switched", "pct", ref = sw_all, scale = 0.15, title = "Share of the group's screens that were switched"),
                        col("p", "Model's switch %", "pct", ref = p_all, scale = 0.15, title = "The model's average switch probability on the group's screens"),
                        col("rec", "Switches read", "pct", title = "Share of the group's switches read as switch (top coverage, frames weighted by the main curve)"),
                        col("fa", "False switch reads", "pct", low = TRUE, title = "Share of the group's other screens read as switch"))),
      TAKE(sprintf("**The model barely reacts to who is in the screen.** With a guard as the screener's defender %s of picks switch and the model averages %s. With a big %s switch and the model averages %s",
                   pct(mr$sw[2]), pct(mr$p[2]), pct(mr$sw[4]), pct(mr$p[4])),
           sprintf("**It misses the possession's history too.** After an earlier switch %s switch and the model averages %s. Its window only covers the last 1.6 s", pct(mr$sw[7]), pct(mr$p[7])),
           sprintf("**Most switches still lose to over.** Only %s of switches are read as switch, and %s of other screens are wrongly read as switch", pct(mr$rec[1]), pct(mr$fa[1]))),
      H("A quick check: do these signals add to the model?"),
      P("A small logistic on the model's switch probability plus five signals, fitted on nine games and scored on the tenth. The signals are a guard or wing as the screener's defender, same-size defenders, a cross-match, an earlier switch and an earlier pick. It scores switch or not."),
      TABLE("Switch or not, held out by game (lower log loss is better)", limit = 6, rows = tb,
            cols = list(col("check", "Inputs", title = "What the small logistic is given"),
                        col("ll", "Log loss", "num2", ref = tb$ll[1], scale = 0.03, low = TRUE, title = "Held-out log loss on switch or not. Always guessing the switch rate scores the value in the note"),
                        col("auc", "AUC", "num2", ref = tb$auc[1], scale = 0.05, title = "How often a random switch gets a higher score than a random other screen"),
                        col("better", "Games better", "int", title = "Held-out games (of 10) where adding the signals lowered log loss")),
            note = sprintf("Always guessing the switch rate scores %.3f.", SC$base_ll)),
      TABLE("Flagging switches", limit = 6, rows = fl,
            cols = list(col("rule", "Rule", title = "When a screen counts as read as switch"),
                        col("flagged", "Screens flagged", "pct", title = "Share of screens read as switch"),
                        col("rec", "Switches caught", "pct", title = "Share of switches read as switch (recall)"),
                        col("prec", "Flags right", "pct", title = "Share of switch reads that were switches (precision)"))),
      TAKE(sprintf("**They help a little.** Switch log loss falls from %.3f to %.3f and AUC rises from %.2f to %.2f. %d of 10 games improve", tb$ll[1], tb$ll[3], tb$auc[1], tb$auc[3], tb$better[3]),
           sprintf("**More before the screen.** From %.3f to %.3f with the model's read before the pick frame (AUC %.2f to %.2f)", tb$ll[4], tb$ll[5], tb$auc[4], tb$auc[5]),
           sprintf("**Size matters most.** At the same model read, a guard or wing on the screener multiplies the odds of a switch by %.1f. A cross-match multiplies them by %.1f and an earlier pick by %.1f",
                   od[["sd_smallTRUE"]], od[["crossTRUE"]], od[["re_pickTRUE"]]),
           sprintf("**A lower bar catches more.** Flagging screens at a 20%% model switch probability catches %s of switches with %s of flags right", pct(fl$rec[2]), pct(fl$prec[2])))))
  }
  blocks <- c(blocks, list(
    H("Ways to read switches better"),
    BUL("**Give the model the players' size.** Guard, wing or big for the four screen players. It is the largest single signal here. Take it from data outside the graded game",
        "**Give it the possession's memory.** Cross-matched now, an earlier switch, an earlier pick. The 1.6 s window cannot see them",
        "**Give it who guards whom right now.** The current matchups assignment of the four players, read only up to the moment of prediction",
        "**Lower the bar for switch.** Over · show and over · drop win most close frames. A switch threshold, or dividing each coverage's probability by its share, catches more switches at some cost in false alarms",
        sprintf("**Film-check switches with no hand-over.** %d labelled switches never hand the handler over in the matchups table by +3 s", sum(is.na(SWI$t_hand)))),
    CAVEAT("Positions come from archetypes fitted on all ten games (see Who is in the screen)",
           sprintf("%d switches in ten games. The five signals were chosen after looking at this page, so the check's gain is an upper bound", nrow(SWI)))))
  do.call(SECTION, c(list("cv-switch", "Reading switches"), blocks))
})





## ═════════════════════════════════════════════════════════════════════════════
## 08 - SECTIONS: ICE AND BLITZ, GEOMETRY --------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Both read the screen features of the archived screen_coverage/zz_Archive/01_scripts/08_geometry_context.R. Returns
# list(rare, geo); geo is NULL when the archive's files are missing.
sec_rare_geo <- function(E) in_E(E, {
  feat_path <- file.path(a$root, "screen_coverage", "zz_Archive", "03_outputs", "context", "screen_features.csv")
  test_path <- file.path(a$root, "screen_coverage", "zz_Archive", "03_outputs", "context", "predictive_test.csv")
  if (!file.exists(feat_path)) {
    return(list(rare = SECTION("cv-rare", "Ice and blitz",
                               CAVEAT("The screen features this section uses come from the archived screen_coverage/zz_Archive/01_scripts/08_geometry_context.R (screen_coverage/zz_Archive/03_outputs/context/)")),
                geo = NULL))
  }
  FT <- fread(feat_path)
  G <- FT[off == 0 & call != "over + none"]
  G[, joint7 := sub(" + ", " · ", call, fixed = TRUE)]
  G[, `:=`(sx = 14 * M_FT - dist_baseline, sy = (7.5 * M_FT - dist_sideline) * fifelse(side_left == 1L, 1, -1),
           spot_lab = c(middle = "middle", stepUp = "step-up", wing = "wing")[spot],
           side_lab = fifelse(side_left == 1L, "offense's left", "offense's right"),
           sideline_band = cut(dist_sideline, c(-Inf, 10, 15, 20, Inf), labels = c("under 10 ft", "10-15 ft", "15-20 ft", "20+ ft")),
           shoulder = cut(lateral_mid, c(-Inf, -2, 2, 5, Inf), labels = c("sideline side, 2+ ft", "on the line (±2 ft)", "middle side, 2-5 ft", "middle side, 5+ ft")),
           tta_band = cut(time_to_act, c(-Inf, 6, 10, 14, 18, Inf), labels = c("0-6 s", "6-10 s", "10-14 s", "14-18 s", "18-24 s")),
           approach_lab = fifelse(s_still == 1L, "one of them nearly still", as.character(cut(approach, c(-1, 60, 120, 181),
                                                                                              labels = c("same direction (under 60°)", "across (60-120°)", "head-on (120°+)")))),
           screen_lab = fifelse(rescreen == 0L, "first screen of the possession", fifelse(same_pair == 1L, "re-screen, same pair", "re-screen, new pair")))]
  n_g <- nrow(G)
  n_ice <- G[call == "ice", .N]
  n_blz <- G[call == "blitz", .N]
  ice_all <- n_ice / n_g
  rate_rows <- function(by, lev, what = "ice") {
    d <- G[!is.na(get(by)), .(k = sum(call == what), n = .N), by = c(by)]
    setnames(d, by, "g")
    d <- d[order(match(as.character(g), lev))]
    lapply(seq_len(nrow(d)), function(i) rrow(as.character(d$g[i]), d$k[i], d$n[i]))
  }
  teams_ice <- G[, .(ice = sum(call == "ice"), blitz = sum(call == "blitz"), n = .N), by = def_name][order(-ice, -blitz, def_name)]
  rare <- G[call %in% c("ice", "blitz")][order(call, game_id, f0)]
  rare[, `:=`(rescreen_lab = fifelse(rescreen == 1L, "yes", "no"), link = paste0("#/play/", poss))]
  flag <- G[lateral_mid >= 3 & dist_sideline <= 15]
  flag_t <- G[lateral_mid >= 3 & dist_sideline <= 15 & def_name %in% teams_ice[ice >= 2]$def_name]
  feats_lbl <- c(lateral_mid = "Shoulder: screener toward the middle of the handler's line (ft)",
                 dist_sideline = "Distance to the nearer sideline (ft)", spot_angle = "Angle around the hoop (degrees)",
                 dist_baseline = "Distance to the baseline (ft)", approach = "Approach angle (degrees)",
                 time_to_act = "Time to act (s)", since_prev = "Seconds since the previous screen")
  ice_auc <- rbindlist(lapply(names(feats_lbl), function(f) {
    a1 <- auc(G[[f]], G$call == "ice")
    data.table(feature = feats_lbl[[f]], ice_med = G[call == "ice", median(get(f))], other_med = G[!call %in% c("ice", "blitz"), median(get(f))],
               blitz_med = G[call == "blitz", median(get(f))], sep = max(a1, 1 - a1))
  }))[order(-sep)]
  SH2 <- S[h_tot >= 150, .(name, picks = h_tot, ice = h_ice / h_tot, blitz = h_blitz / h_tot)]
  sea_ice <- sum(S$h_ice) / sum(S$h_tot)
  sea_blz <- sum(S$h_blitz) / sum(S$h_tot)
  left_all <- G[!call %in% c("ice", "blitz"), mean(side_left)]
  lm_row <- ice_auc[feature == feats_lbl[["lateral_mid"]]]
  ds_row <- ice_auc[feature == feats_lbl[["dist_sideline"]]]

  rare_sec <- SECTION("cv-rare", "Ice and blitz",
                      P("The model leaves ice and blitz out because there are only a handful. This section asks whether they come in recognisable spots. Screen position and angle are measured at the pick frame from the tracking (screen_coverage/zz_Archive/01_scripts/08_geometry_context.R)."),
                      KPIS(KPI("Ice", sprintf("%d screens", n_ice), sprintf("%s of the ten games' screens", pct(ice_all, 1))),
                           KPI("Blitz", sprintf("%d screens", n_blz), sprintf("%s of the ten games' screens", pct(n_blz / n_g, 1))),
                           KPI("Season, direct picks", sprintf("%s ice · %s blitz", pct(sea_ice, 1), pct(sea_blz, 1)), sprintf("of %s direct picks in 293 games", int(sum(S$h_tot)))),
                           KPI("Icing defenses", sprintf("%d of 18", teams_ice[ice > 0, .N]), sprintf("%d teams account for %d of %d", teams_ice[ice >= 2, .N], teams_ice[ice >= 2, sum(ice)], n_ice))),
                      TABLE("Every ice and blitz in the ten games", limit = 20, rows = rare, cols = list(col("call", "Coverage", title = "The joint coverage"), col("def_name", "Defense", title = "The defending team"),
                                                                                                         col("h_name", "Ball handler", title = "The ball handler"), col("s_name", "Screener", title = "The screener"),
                                                                                                         col("spot_lab", "Location type", title = "SkillCorner's locationType"),
                                                                                                         col("dist_sideline", "To sideline (ft)", "num1", title = "Screener's distance to the nearer sideline at the pick frame"),
                                                                                                         col("lateral_mid", "Shoulder (ft)", "num1", title = "Feet the screener stands toward the middle of the floor (+) or the sideline (−) of the handler's straight line to the hoop"),
                                                                                                         col("time_to_act", "Time to act (s)", "num1", title = "Shot clock or game clock, whichever runs out first"),
                                                                                                         col("period", "Period", "int", title = "Quarter"), col("rescreen_lab", "Re-screen", title = "An earlier screen in the same possession"),
                                                                                                         col("link", "Dashboard", title = "Paste after the site address to open the possession in the play viewer"))),
                      GRID(RATES("Ice rate by which shoulder the screen is on", rate_rows("shoulder", levels(G$shoulder)), ref = ice_all, fmt = "pct1", unit = "of screens iced", label_width = 150),
                           RATES("Ice rate by distance to the sideline", rate_rows("sideline_band", levels(G$sideline_band)), ref = ice_all, fmt = "pct1", unit = "of screens iced", label_width = 110),
                           RATES("Ice rate by location type", rate_rows("spot_lab", c("middle", "step-up", "wing")), ref = ice_all, fmt = "pct1", unit = "of screens iced", label_width = 90),
                           RATES("Ice rate by side of the floor", rate_rows("side_lab", c("offense's left", "offense's right")), ref = ice_all, fmt = "pct1", unit = "of screens iced", label_width = 110),
                           RATES("Ice rate by defense (teams that iced)", lapply(seq_len(teams_ice[ice > 0, .N]), function(i) {
                             r <- teams_ice[ice > 0][i]
                             rrow(r$def_name, r$ice, r$n)
                           }),
                                 ref = ice_all, fmt = "pct1", unit = "of the defense's screens iced", label_width = 160),
                           RATES("Blitz rate by time to act", rate_rows("tta_band", levels(G$tta_band), "blitz"), ref = n_blz / n_g, fmt = "pct1", unit = "of screens blitzed", label_width = 90)),
                      GRID(COURT("Where ices were set", G[call == "ice"]$sx, G[call == "ice"]$sy),
                           COURT("Where all other screens were set", G[!call %in% c("ice", "blitz")]$sx, G[!call %in% c("ice", "blitz")]$sy)),
                      TABLE("How each measure differs for ice (screens at the pick frame)", limit = 8, rows = ice_auc, cols = list(col("feature", "Measure", title = "Measured at the pick frame"),
                                                                                                                                  col("ice_med", "Ice", "num1", title = "Median for the iced screens"),
                                                                                                                                  col("other_med", "Other five coverages", "num1", title = "Median for over, under and switch screens"),
                                                                                                                                  col("blitz_med", "Blitz", "num1", title = "Median for the four blitzes"),
                                                                                                                                  col("sep", "Separation (AUC)", "num2", title = "How often the measure ranks a random ice and a random other screen the right way round, either direction. 0.5 is none and 1 is perfect"))),
                      H("Season: who gets iced or blitzed?"),
                      GRID(TABLE("Handlers most often iced (150+ direct picks, season)", limit = 8, rows = SH2[order(-ice)][1:8], cols = list(col("name", "Ball handler", title = "Season, all teams"), col("picks", "Direct picks", "int", title = "Season direct picks as ball handler"),
                                                                                                                                              col("ice", "Iced", "pct1", title = "Share of his direct picks defended with ice"), col("blitz", "Blitzed", "pct1", title = "Share blitzed"))),
                           TABLE("Handlers most often blitzed (150+ direct picks, season)", limit = 8, rows = SH2[order(-blitz)][1:8], cols = list(col("name", "Ball handler", title = "Season, all teams"), col("picks", "Direct picks", "int", title = "Season direct picks as ball handler"),
                                                                                                                                                   col("ice", "Iced", "pct1", title = "Share of his direct picks defended with ice"), col("blitz", "Blitzed", "pct1", title = "Share blitzed")))),
                      TAKE(sprintf("**Ice has a clear shape.** The screener stands a median %.1f ft toward the middle of the handler's line to the hoop (other screens %.1f ft), and the screen sits nearer the sideline (%.1f ft against %.1f ft). The shoulder alone separates ice from the rest %.2f of the time",
                                   lm_row$ice_med, lm_row$other_med, ds_row$ice_med, ds_row$other_med, lm_row$sep),
                           sprintf("**Ice is a team choice.** %d of %d ices came from %d defenses (%s). %d of the 18 defenses never iced. None came in transition",
                                   teams_ice[ice >= 2, sum(ice)], n_ice, teams_ice[ice >= 2, .N], paste(teams_ice[ice >= 2]$def_name, collapse = ", "), teams_ice[ice == 0, .N]),
                           sprintf("**Ice leans to one side.** %d of %d ices were on the offense's left half, against %s of other screens. With 14 cases that may be chance or the icing teams' habit",
                                   G[call == "ice", sum(side_left)], n_ice, pct(left_all)),
                           sprintf("**A simple rule would mostly be wrong.** Screens on the middle shoulder (3+ ft) within 15 ft of a sideline number %d, and %d of them were iced (%s right, catching %d of %d). Limited to the icing defenses, %d screens and %d iced (%s)",
                                   nrow(flag), flag[call == "ice", .N], pct(flag[call == "ice", .N] / nrow(flag)), flag[call == "ice", .N], n_ice,
                                   nrow(flag_t), flag_t[call == "ice", .N], pct(flag_t[call == "ice", .N] / max(1, nrow(flag_t)))),
                           sprintf("**Blitz has no clear shape.** The %d blitzes came from %d defenses with a median %.1f s to act (other screens %.1f s). No season handler with 150+ direct picks is blitzed on more than %s of them, so the attacker does not predict it either",
                                   n_blz, uniqueN(G[call == "blitz"]$def_name), G[call == "blitz", median(time_to_act)], G[!call %in% c("ice", "blitz"), median(time_to_act)], pct(max(SH2$blitz), 1))),
                      CAVEAT("14 ices and 4 blitzes. Every rate here has a wide interval, and the season files cannot cross coverage with location",
                             "A separate ice detector (shoulder, sideline distance and the defense's scheme) is plausible. Blitz needs more games"))

  # Geometry and context against the five main coverages.
  G5 <- G[!call %in% c("ice", "blitz")]
  gmix <- function(by, label, title, lev, key_title) {
    w <- mix_by(G5, by, lv = FIVE_LV)
    setnames(w, by, "grp")
    w <- w[!is.na(grp)][order(match(as.character(grp), lev))]
    MIXTABLE(title, w, list(col("grp", label, title = key_title)), base = base, b5 = b5, joint = FIVE_LV, limit = 10, n_title = "Screens in the group")
  }
  FTm <- FT[off %in% c(-10L, 0L) & !call %in% c("ice", "blitz", "over + none")]
  gfe <- c(lateral_mid = "shoulder (toward the middle)", dist_sideline = "distance to the sideline", dist_baseline = "distance to the baseline",
           spot_angle = "angle around the hoop", approach = "approach angle", time_to_act = "time to act", since_prev = "seconds since the previous screen")
  gsep <- rbindlist(lapply(names(gfe), function(f) FTm[, {
    ou <- cov %in% c("over", "under")
    ss <- ou & scov %in% c("show", "drop")
    a_uo <- auc(get(f)[ou], cov[ou] == "under")
    a_ss <- auc(get(f)[ss], scov[ss] == "show")
    a_sw <- auc(get(f), call == "switch")
    .(measure = gfe[[f]], uo = max(a_uo, 1 - a_uo), ss = max(a_ss, 1 - a_ss), sw = max(a_sw, 1 - a_sw))
  }, by = t]))
  gsep_w <- dcast(gsep, measure ~ t, value.var = c("uo", "ss", "sw"))
  setnames(gsep_w, names(gsep_w), sub("_-0.4$", "_m04", names(gsep_w)))
  gsep_w <- gsep_w[order(match(measure, unname(gfe)))]
  PT <- if (file.exists(test_path)) fread(test_path) else NULL
  n_tta_diff <- G[abs(time_to_act - shot_clock) > 0.01, .N]

  geo_sec <- SECTION("cv-geometry", "Screen geometry",
                     P("Where and how a screen is set, and its place in the possession, measured from the tracking (positions then and 0.48 s before). The tables use the pick frame. The separation table and the model test also use 0.4 s before it."),
                     BUL("**Shoulder.** Feet the screener stands toward the middle of the floor (+) or the sideline (−) of the ball handler's straight line to the hoop",
                         "**Distance to the sideline and baseline**, **angle around the hoop** (0° is straight out, 90° along the baseline) and **side of the floor** (from the offense's view)",
                         "**Approach angle.** Between the screener's and the handler's movement over the last 0.48 s. 0° is moving the same way and 180° is head-on",
                         "**Re-screen.** An earlier screen in the same possession, by the same pair or a new one",
                         sprintf("**Time to act.** The shot clock or the game clock, whichever runs out first, capped at 24 s. It differs from the shot clock on %d of %s screens (end of a period, shot clock off)", n_tta_diff, int(n_g))),
                     gmix("shoulder", "Shoulder", "By shoulder", levels(G$shoulder), "Which side of the handler's line to the hoop the screener stands on"),
                     gmix("sideline_band", "To sideline", "By distance to the sideline", levels(G$sideline_band), "Screener's distance to the nearer sideline"),
                     gmix("side_lab", "Side", "By side of the floor", c("offense's left", "offense's right"), "Half of the floor, from the offense's view"),
                     gmix("approach_lab", "Approach", "By approach angle", c("same direction (under 60°)", "across (60-120°)", "head-on (120°+)", "one of them nearly still"), "Angle between the screener's and the handler's movement"),
                     gmix("screen_lab", "Screen", "First screen or re-screen", c("first screen of the possession", "re-screen, same pair", "re-screen, new pair"), "An earlier screen in the same possession"),
                     gmix("tta_band", "Time to act", "By time to act", levels(G$tta_band), "Shot clock or game clock, whichever runs out first"),
                     TABLE("How well each measure separates the coverages on its own (AUC, either direction)", limit = 10, rows = gsep_w, cols = list(col("measure", "Measure", title = "Measured at that moment"),
                                                                                                                                                     col("uo_m04", "−0.4 s", "num2", group = "Under or over", title = "0.4 s before the pick frame"), col("uo_0", "Pick", "num2", group = "Under or over", title = "At the pick frame"),
                                                                                                                                                     col("ss_m04", "−0.4 s", "num2", group = "Show or drop", title = "0.4 s before the pick frame"), col("ss_0", "Pick", "num2", group = "Show or drop", title = "At the pick frame"),
                                                                                                                                                     col("sw_m04", "−0.4 s", "num2", group = "Switch or not", title = "0.4 s before the pick frame"), col("sw_0", "Pick", "num2", group = "Switch or not", title = "At the pick frame"))),
                     if (!is.null(PT)) TABLE("Adding them to the four-player logistic model (held-out log loss, lower is better)", limit = 40,
                                             rows = PT[model != "base (shot clock)"], cols = list(col("t", "Seconds", "num1", title = "Seconds from the pick frame"), col("model", "Model", title = "What the base model gets added"),
                                                                                                  col("logloss", "Log loss", "num2", title = "Held-out log loss on the 1,464 scored screens"),
                                                                                                  col("change_vs_tta", "Change", "num2", title = "Paired change against the base with time to act (below zero means it helped)"),
                                                                                                  col("lo", "Low", "num2", title = "95% interval from resampling whole games"), col("hi", "High", "num2", title = "95% interval from resampling whole games"),
                                                                                                  col("games_better", "Games better", "int", title = "Held-out games (of 10) where the added inputs helped"))),
                     TAKE("**Geometry adds nothing measurable to the five main coverages.** From −1 s to +0.4 s the change in log loss stays between −0.003 and +0.010. Every interval clear of zero is a small loss (geometry at −1 s)",
                          sprintf("**Single measures stay near a coin flip.** Separations sit near 0.5 to 0.6 and the best is %.2f. The defenders' own levels and distances already carry what the geometry implies",
                                  max(unlist(gsep_w[, -1]), na.rm = TRUE)),
                          "**Time to act and the shot clock score the same** (differences of 0.0002). They only differ in the last seconds of a period. The models use time to act since it is the right clock",
                          "**Geometry matters for ice**, the one coverage it describes well"),
                     CAVEAT("These measures enter a linear model here. A transformer sees the same positions directly"))
  list(rare = rare_sec, geo = geo_sec)
})





## ═════════════════════════════════════════════════════════════════════════════
## 09 - SECTIONS: TEAMS, OUTCOMES, DATA, THE MODEL -----------------------------
## ═════════════════════════════════════════════════════════════════════════════

sec_who <- function(E) in_E(E, {
  # Each defense's mix, its defenders' mixes, streaks, and what the attackers' season shooting changes.
  team_g <- mix_by(L, c("game", "def_name"))
  team_g[, top := do.call(pmax, .SD), .SDcols = JOINT_LV]
  sd_mix <- mix_by(L, c("sd_canon", "sd_name", "def_name"), min_n = 20)
  sd_mix[, show_ou := (`over · show` + `under · show`) / pmax(1e-9, 1 - switch - ice - blitz)]
  bd_mix <- mix_by(L, c("bd_canon", "bd_name", "def_name"), min_n = 20)
  bd_mix[, under_ou := (`under · drop` + `under · show`) / pmax(1e-9, 1 - switch - ice - blitz)]
  LL <- copy(L)
  setorder(LL, game, def_team, f0)
  LL[, prev := shift(joint7), by = .(game, def_team)]
  LL[, prev_sd := shift(joint7), by = .(game, def_team, SD)]
  rep_all <- LL[!is.na(prev), mean(joint7 == prev)]
  rep_exp <- LL[!is.na(prev), .(N = .N, e = sum((table(joint7) / .N)^2)), by = .(game, def_team)][, sum(N * e) / sum(N)]
  rep_sd <- LL[!is.na(prev_sd), mean(joint7 == prev_sd)]
  SH <- S[h_called >= 100 & !is.na(od3_100)]
  SH[, `:=`(under = h_under / h_called, od3p = od3m / pmax(1, od3))]
  lg_od3p <- S[, sum(od3m, na.rm = TRUE) / sum(od3, na.rm = TRUE)]
  SS <- S[s_called >= 80]
  SS[, drop := s_drop / s_called]
  r_under <- SH[, cor(od3_100, under)]
  r_drop <- SS[, cor(pop, drop)]
  LL <- merge(LL, S[, .(h_canon = canon, h_od3 = od3_100)], by = "h_canon", all.x = TRUE)
  LL <- merge(LL, S[, .(s_canon = canon, s_pop = pop)], by = "s_canon", all.x = TRUE)
  h_lv <- c("under 3 per 100", "3-8 per 100", "8+ per 100")
  s_lv <- c("rarely (under 2%)", "sometimes (2-8%)", "often (8%+)")
  LL[, h_tier := fifelse(is.na(h_od3), NA_character_, fifelse(h_od3 >= 8, h_lv[3], fifelse(h_od3 >= 3, h_lv[2], h_lv[1])))]
  LL[, s_tier := fifelse(is.na(s_pop), NA_character_, fifelse(s_pop >= 0.08, s_lv[3], fifelse(s_pop >= 0.02, s_lv[2], s_lv[1])))]
  OU <- LL[cov %in% c("over", "under")]
  SECTION("cv-who", "Team plans and attackers",
          P("Coverage is a team plan adjusted for matchups. With ten games each defense is seen once (Zaragoza, Breogan and Gran Canaria twice), so the tracked games alone cannot teach a model a team's scheme."),
          MIXTABLE("Each defense, game by game", team_g, list(col("def_name", "Defense", title = "The defending team"), col("game", "Game", title = "SkillCorner game id")),
                   base = base, b5 = b5, extra = list(col("top", "Main coverage", "pct", title = "Share of its picks that got its most common coverage")),
                   extra_in = list(full = "top"), n_title = "Picks it defended in that game"),
          BUL(sprintf("**Defenses differ.** A defense's most common coverage covers %s to %s of its picks in a game, and the most common coverage itself changes from defense to defense", pct(min(team_g$top)), pct(max(team_g$top))),
              sprintf("**No streaks.** A defense repeats its previous coverage in the same game %s of the time. In random order its mix would repeat %s of the time, so coverages are no streakier than the mix", pct(rep_all), pct(rep_exp)),
              sprintf("**Same for each defender.** The same screener's defender repeats his own previous coverage %s of the time", pct(rep_sd))),
          MIXTABLE("Screener's defenders with 20+ picks", sd_mix[order(-n)], list(col("sd_name", "Screener's defender", title = "The defender of the screener (screenerDefId)"), col("def_name", "Team", title = "His team")),
                   base = base, b5 = b5, limit = 15, extra = list(col("show_ou", "Show share", "pct", title = "Among his over and under picks, the share where he showed")),
                   extra_in = list(full = "show_ou", s = "show_ou"), n_title = "Picks in which he guarded the screener"),
          MIXTABLE("Ball handler's defenders with 20+ picks", bd_mix[order(-n)], list(col("bd_name", "Handler's defender", title = "The defender of the ball handler (ballhandlerDefId)"), col("def_name", "Team", title = "His team")),
                   base = base, b5 = b5, limit = 15, extra = list(col("under_ou", "Under share", "pct", title = "Among his over and under picks, the share where he went under")),
                   extra_in = list(full = "under_ou", h = "under_ou"), n_title = "Picks in which he guarded the ball handler"),
          H("Does the attacker's shooting change the coverage? (whole season)"),
          P("The season files give, for every ACB player, the coverages he faced as a handler and as a screener over 293 games. Coaching logic says defenders go under non-shooters and drop against rollers more than poppers."),
          GRID(SCAT("Handlers: going under against off-the-dribble three volume", points = SH[, .(x = r2(od3_100, 1), y = r2(under, 3), g = as.integer(od3p < lg_od3p),
                                                                                                  tip = sprintf("%s\n%d picks with a coverage as handler\n%.1f off-dribble 3PA per 100 possessions\n%.0f%% under", name, h_called, od3_100, 100 * under))],
                    groups = c("off-dribble 3P% at or above league", "below league"), xlabel = "season off-dribble 3PA per 100 possessions",
                    ylabel = "share of his picks defended under", yfmt = "pct", radius = 4,
                    note = sprintf("Handlers with 100+ direct picks with a coverage (%d). Correlation %.2f", nrow(SH), r_under)),
               SCAT("Screeners: drop against how often he pops for three", points = SS[, .(x = r2(pop, 3), y = r2(drop, 3), g = 0L,
                                                                                          tip = sprintf("%s\n%d picks with a coverage as screener\n%.1f%% of his picks end in his own three\n%.0f%% drop", name, s_called, 100 * pop, 100 * drop))],
                    groups = c("screeners"), xlabel = "share of his picks ending in his own three-point attempt", ylabel = "share of his picks defended drop",
                    xfmt = "pct", yfmt = "pct", radius = 4, note = sprintf("Screeners with 80+ direct picks with a coverage (%d). Correlation %.2f", nrow(SS), r_drop))),
          GRID(RATES("Ten games: under rate by the handler's season off-dribble 3PA", lapply(h_lv, function(l) {
            d <- LL[h_tier %in% l & cov %in% c("over", "under")]
            rrow(l, sum(d$cov == "under"), nrow(d))
          }),
                     ref = mean(OU$cov == "under"), unit = "of over and under picks went under", label_width = 130),
               RATES("Ten games: drop rate by how often the screener pops (season)", lapply(s_lv, function(l) {
                 d <- LL[s_tier %in% l & scov %in% c("show", "drop")]
                 rrow(l, sum(d$scov == "drop"), nrow(d))
               }),
                     ref = mean(LL[scov %in% c("show", "drop")]$scov == "drop"), unit = "of show and drop picks were drop", label_width = 140)),
          TAKE(sprintf("**A team's mix matters, its last coverage adds nothing.** Within a game the order looks random (%s repeats against %s by chance)", pct(rep_all), pct(rep_exp)),
               sprintf("**Shooters see less under.** Season-wide, handlers who take more off-the-dribble threes are defended under %s often (correlation %.2f)", if (r_under < 0) "less" else "more", r_under),
               sprintf("**Poppers see %s drop.** Correlation %.2f between how often a screener pops and how often his defender drops", if (r_drop < 0) "less" else "more", r_drop)),
          CAVEAT("The season files include the ten games (10 of 293). A small overlap, but a leak if used as model input without care",
                 "There is no defensive season file, so a defense's own season scheme cannot be measured, only what each attacker faced"))
})

sec_outcomes <- function(E) in_E(E, {
  # What followed each coverage (never a model input).
  LL <- copy(L)
  LL[, `:=`(h_shot = grepl("FG[MX]", bout), h_three = grepl("FG[MX]3", bout), s_shot = grepl("FG[MX]", sout),
            any_to = grepl("(^|\\|)TO(\\||$)", bout) | grepl("(^|\\|)TO(\\||$)", sout))]
  by_cov <- function(f) lapply(JOINT_LV, function(l) f(l, LL[joint7 == l]))
  SECTION("cv-outcomes", "What each coverage gives up",
          P("What happened after the coverage in these games, to set beside a coaching table's 'what it gives up'. All of it is recorded after the pick, so none of it can be a model input."),
          GRID(RATES("Handler shot after the pick", by_cov(function(l, d) rrow(l, sum(d$h_shot), nrow(d))), ref = mean(LL$h_shot), unit = "of picks (bhrOutcomes has a shot)"),
               RATES("Handler took a three", by_cov(function(l, d) rrow(l, sum(d$h_three), nrow(d))), ref = mean(LL$h_three), unit = "of picks"),
               RATES("Screener shot after the pick", by_cov(function(l, d) rrow(l, sum(d$s_shot), nrow(d))), ref = mean(LL$s_shot), unit = "of picks (scrOutcomes has a shot)"),
               RATES("Turnover by the handler or screener", by_cov(function(l, d) rrow(l, sum(d$any_to), nrow(d))), ref = mean(LL$any_to), unit = "of picks"),
               RATES("Points in the chance", by_cov(function(l, d) mrow(l, d[in_pop == TRUE]$pts)), fmt = "num2", ref = mean(LL[in_pop == TRUE]$pts), unit = "points per chance"),
               RATES("Direct pick (SkillCorner)", by_cov(function(l, d) rrow(l, sum(d$direct), nrow(d))), ref = mean(LL$direct), unit = "led straight to a shot, assist or foul")),
          CAVEAT("Points per chance counts every pick in the chance, so chances with re-screens count more than once",
                 "SkillCorner's direct flag depends on what happened after the pick, so it cannot be a model input either"))
})

sec_ready <- function(E) in_E(E, {
  # Tracking coverage around the pick, picks per game, and the frequency baselines.
  WR <- W[, .(have4 = mean(have4), all10 = mean(all10), det4 = mean(det4) / 4), by = t][order(t)]
  short <- P[, mean(since_poss < 3)]
  per_game <- dcast(L[, .N, by = .(game, joint7)], game ~ joint7, value.var = "N", fill = 0)
  for (l in JOINT_LV) if (!l %in% names(per_game)) per_game[, (l) := 0L]
  per_game[, n := rowSums(.SD), .SDcols = JOINT_LV]
  per_game[, `:=`(c_over = `over · drop` + `over · show`, c_under = `under · drop` + `under · show`, c_drop = `over · drop` + `under · drop`,
                  c_show = `over · show` + `under · show`, c_switch = switch)]
  teams <- unique(L[, .(game, off_name)])[order(off_name)][, .(match = paste(off_name, collapse = " – ")), by = game]
  per_game <- mix_rows(merge(per_game, teams, by = "game"))
  BS <- cov_baselines(copy(L), S)
  ll_unif <- log(length(JOINT_LV))
  ho <- rbindlist(lapply(BL_ref, function(B) B$handoffs[, .(cov)]))
  ho_tab <- sort(table(ho$cov), decreasing = TRUE)
  cnt_col <- function(k, l, g) col(k, l, "int", group = g, title = sprintf("Picks with %s", l))
  SECTION("cv-ready", "Data and baselines",
          P("How much tracking there is around each pick, how the picks spread over the games, and the bar a model must beat."),
          H("Tracking around the pick"),
          TABLE("Tracking available at each moment", limit = 30, rows = WR[t %in% c(-3, -2, -1.6, -1.2, -0.8, -0.4, 0, 0.4, 0.8, 1.2, 1.6, 2)], cols = list(col("t", "Seconds", "num1", title = "Seconds from the pick frame"),
                                                                                                                                                       col("have4", "Four players", "pct", title = "Share of picks with the handler, screener and both defenders tracked, inside the same possession"),
                                                                                                                                                       col("all10", "All ten", "pct", title = "Share of picks with all ten players tracked, inside the same possession"),
                                                                                                                                                       col("det4", "Detected", "pct", title = "Share of the four players' positions seen on camera (the rest are extrapolated)"))),
          BUL(sprintf("**Short histories.** %s of picks come within 3 s of the possession's start, so their 3 s history is cut short", pct(short)),
              sprintf("**Transition and quality.** %s of picks are in transition and %s in chances with quality index 3 or more", pct(mean(P$transition, na.rm = TRUE)), pct(mean(P$q >= 3, na.rm = TRUE))),
              sprintf("**Handoffs as extra examples.** %s handoffs carry a similar coverage on the receiver's defender (%s)", int(nrow(ho)),
                      paste(sprintf("%s %d", names(ho_tab), as.integer(ho_tab)), collapse = ", "))),
          H("Picks per game"),
          TABLE("Coverages in each game", limit = 12, rows = per_game,
                cols = c(list(col("game", "Game", title = "SkillCorner game id"), col("match", "Teams", title = "The two teams"),
                              col("n", "Picks", "int", title = "Labelled picks")),
                         lapply(JOINT_LV, function(l) col(KEYS[[l]], l, "int", group = "Picks per coverage", title = sprintf("Picks defended with %s", l))),
                         list(cnt_col("c_over", "over", "Handler's defender"), cnt_col("c_under", "under", "Handler's defender"), cnt_col("c_switch", "switch", "Handler's defender"),
                              cnt_col("c_drop", "drop", "Screener's defender"), cnt_col("c_show", "show", "Screener's defender"))),
                views = list(list(label = "Full coverage", keys = c("game", "match", "n", unname(KEYS))),
                             list(label = "Handler's defender", keys = c("game", "match", "n", "c_over", "c_under", "c_switch")),
                             list(label = "Screener's defender", keys = c("game", "match", "n", "c_drop", "c_show", "c_switch")))),
          H("Simple baselines"),
          BUL("**How they work.** Each baseline predicts a pick's coverage from the shares in a reference group, with one pick of each coverage added so nothing gets probability zero, and the league mix added with the weight of five picks",
              "**No peeking.** Groups built from games leave out the pick's own game. 'Earlier coverages' and 'previous coverage' use only picks before this one in the same game",
              "**Season baseline.** The handler's season share of over, under, switch, ice and blitz times the screener's season share of show and drop, each pulled toward the league with the weight of 20 picks",
              sprintf("**Scores.** Accuracy is how often the most likely coverage was right. Log loss is the average of minus the log of the probability given to the true coverage. Lower is better, and guessing all seven equally scores %.2f", ll_unif)),
          TABLE("Baselines on the seven-coverage label", limit = 8, rows = BS, cols = list(col("base", "Baseline", title = "Where the coverage shares come from"), col("n", "Picks", "int", title = "Picks scored"),
                                                                                            col("acc", "Accuracy", "pct", title = "Share of picks where the most likely coverage was the true one"),
                                                                                            col("ll", "Log loss", "num2", ref = BS$ll[1], scale = 0.15, low = TRUE, title = "Average of minus the log of the probability given to the true coverage. Lower is better"))),
          TAKE(sprintf("**The bar from league shares alone is %.2f.** Its accuracy is only %s because over · drop and over · show are nearly tied, so which one it picks flips from game to game", BS$ll[1], pct(BS$acc[1])),
               sprintf("**Context alone says little.** No honest look-up moves log loss by more than %.2f (best is '%s' at %.2f)", BS$ll[1] - min(BS$ll[1:6]), BS$base[which.min(BS$ll[1:6])], min(BS$ll[1:6])),
               sprintf("**A team's game plan is worth at most %.2f.** That is the score with the defense's whole-game mix, which includes the answer", BS$ll[7]),
               "**So the signal has to come from the tracking around the screen** (When it shows)",
               sprintf("**Ice (%d) and blitz (%d) cannot be learned from %s picks.** The model leaves them out", cnt[["ice"]], cnt[["blitz"]], int(n7))))
})

sec_plan <- function(E) in_E(E, {
  SECTION("cv-plan", "What this means for the model",
          BUL(sprintf("**Label.** Five coverages. Ice (%d) and blitz (%d) are too rare to learn", cnt[["ice"]], cnt[["blitz"]]),
              "**Timing.** Show or drop reads before the screen. Under or over and switch mostly show after it, so a read before the screen leans on set-up and context",
              "**Switches are the gap.** The size of the screener's defender, a cross-match and an earlier switch all move the switch rate, and the model sees none of them (Reading switches)",
              "**Personnel needs care.** Guard, wing or big is fair for a coach's question, but it should come from data outside the graded game (Who is in the screen)",
              "**Never inputs.** bhrOutcomes, scrOutcomes, direct, and anything about the shot or points. All are recorded after the coverage",
              sprintf("**Size.** %s labelled picks, about %d per game, with most defenses seen in one game only. Split by game and report each held-out game", int(n7), round(n7 / 10))))
})





## ═════════════════════════════════════════════════════════════════════════════
## 10 - THE TAB ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

topic_coverage <- function(BL) {
  E <- cov_prepare(BL)
  E$BL_ref <- BL
  rg <- sec_rare_geo(E)
  sections <- list(sec_label(E), sec_motion(E), sec_timing(E), sec_context(E), sec_people(E), sec_before(E), sec_switch(E),
                   rg$rare, rg$geo, sec_who(E), sec_outcomes(E), sec_ready(E), sec_plan(E))
  DOC("coverage", "Pick coverage",
      "How defenses guard on-ball screens in the ten tracked games. What each coverage looks like, when it shows, who is in the screen, what comes before it, and why switches are hard to read.",
      Filter(Negate(is.null), sections),
      meta = "Descriptive, plus the live screen coverage model's held-out reads and one small held-out check (Reading switches).")
}
