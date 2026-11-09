# Topic: pick-and-roll coverage, the EDA before trying to predict it (no model here).
#
# The label. SkillCorner calls two coverages on every on-ball screen (picks.bhrDefType on the ball handler's
# defender, picks.scrDefType on the screener's defender). Together they form one joint call: "over · soft",
# "over · show", "under · soft", "under · show", or a call both defenders share (switch, ice, blitz). In the ten
# games the shared calls never mix with anything else, so the joint call is the label a model would predict.
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
#   sd_lvl   SD's hoop distance minus the screen spot's (ft): + up at the ball (show), - dropped (soft)
# The screen spot is S's tracked position at time 0 (the event location when he is not tracked).
#
# Separation over time is shown with a rank statistic (AUC): pick one pick of each of two coverages at random; the
# AUC is how often the measure ranks them the right way round. 0.5 = no information, 1 = perfect. It is computed
# separately at each time step, so it says WHEN the coverages start to look different, not how well a model would do.
#
# Baselines are frequency look-ups, not fitted models: predict each pick's call from the shares in some reference
# group (with one pick of each call added, so no call gets probability 0), scored by accuracy and log loss.

COV <- list(t = round(seq(-3, 2, by = 0.2), 1), min_team = 25L)
JOINT_LV <- c("over · soft", "over · show", "under · soft", "under · show", "switch", "ice", "blitz")

#' Every pick of the ten games with its label, context and tracking window.
cov_data <- function(BL) {
  PK <- list(); WIN <- list()
  for (B in BL) {
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

    # Tracking window.
    q <- CJ(i = seq_len(nrow(p)), t = COV$t)
    q[, frame := p$f0[i] + as.integer(round(t * FPS))]
    q[, poss0 := p$poss[i]]
    q[, possf := B$Fr$poss[match(frame, B$Fr$frame)]]
    look <- function(role) {
      pp <- pos_at(B, q$frame, p[[role]][q$i])
      list(x = pp$x, y = pp$y, det = pp$det)
    }
    h <- look("H"); s <- look("S"); bd <- look("BD"); sd <- look("SD")
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
  P[, joint := fifelse(cov %in% c("switch", "ice", "blitz"), cov, paste(cov, scov, sep = " · "))]
  P[, joint7 := fifelse(joint %in% JOINT_LV, joint, NA_character_)]
  P[, scheme := fifelse(cov %in% c("switch", "ice", "blitz"), cov, "over/under")]
  # Context bands.
  P[, sc_band := cut(sc, c(-Inf, 6, 10, 14, 18, Inf), labels = c("0-6 s", "6-10 s", "10-14 s", "14-18 s", "18-24 s"))]
  P[, clutch := period >= 4 & gc <= 120]
  P[, side := fifelse(abs(y) <= 6, "middle of the floor", "side of the floor")]
  P[, spot_lab := c(middle = "middle", stepUp = "step-up", wing = "wing")[spot]]
  list(P = P, W = W)
}

#' Shares of each joint call by a grouping (wide: one column per call, plus n).
mix_by <- function(P, by, lv = JOINT_LV, min_n = 1) {
  d <- P[!is.na(joint7)]
  t <- d[, .(n = .N), by = c(by, "joint7")]
  w <- dcast(t, as.formula(paste(paste(by, collapse = "+"), "~ joint7")), value.var = "n", fill = 0)
  for (l in lv) if (!l %in% names(w)) w[, (l) := 0]
  w[, n := rowSums(.SD), .SDcols = lv]
  for (l in lv) w[, (l) := get(l) / n]
  w[n >= min_n]
}
#' Mann-Whitney AUC of x for group a (TRUE) vs b (FALSE).
auc <- function(x, g) {
  ok <- !is.na(x) & !is.na(g)
  x <- x[ok]; g <- g[ok]
  n1 <- sum(g); n0 <- sum(!g)
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
#' Probabilities from counts with one of each call added.
smooth_counts <- function(cnt) (cnt + 1) / sum(cnt + 1)

KEYS <- setNames(c("o_soft", "o_show", "u_soft", "u_show", "switch", "ice", "blitz"), JOINT_LV)
#' Table columns for the seven call shares (tinted against the overall share).
mix_cols <- function(base) {
  lapply(JOINT_LV, function(l) col(KEYS[[l]], l, "pct", ref = base[[l]], scale = 0.25, group = "Share of the defense's calls",
                                   title = sprintf("Share of the group's picks called %s", l)))
}
mix_rows <- function(w) { setnames(w, JOINT_LV, unname(KEYS[JOINT_LV]), skip_absent = TRUE); w }

#' Season aggregates (offense-only): what each attacker faced as a handler and as a screener, and how he shoots.
cov_season <- function() {
  al <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
  canon <- function(p) { m <- al$canonical_player_id[match(p, al$player_id)]; fifelse(is.na(m), p, m) }
  rows <- function(d) {
    d <- copy(d); d[, canon := canon(player_id)]
    tot <- d[is.na(team_id) | team_name == "total"]
    d[!(canon %in% tot$canon) | is.na(team_id) | team_name == "total"]
  }
  pk <- rows(fread(file.path(a$root, "data", "aggregates", "acb_picksaggregates_20252026.csv")))
  sh <- rows(fread(file.path(a$root, "data", "aggregates", "acb_shotsaggregates_20252026.csv")))
  hv <- c("blitz", "ice", "over", "switch", "under"); sv <- c("blitz", "ice", "show", "soft", "switch")
  p <- pk[, c(list(name = player_name[1], h_tot = sum(handler_total_picks), s_tot = sum(screener_total_picks),
                   s_three = sum(screener_score_3pt + screener_miss_3pt), s_two = sum(screener_score_2pt + screener_miss_2pt)),
              setNames(lapply(hv, function(v) sum(get(paste0("handler_picks_vs_", v)))), paste0("h_", hv)),
              setNames(lapply(sv, function(v) sum(get(paste0("screener_picks_vs_", v)))), paste0("s_", sv))), by = canon]
  s <- sh[, .(poss = sum(possessions_played), od3 = sum(od_three_attempts), od3m = sum(od_three_mades),
              three_att = sum(three_attempts), three_made = sum(three_mades)), by = canon]
  out <- merge(p, s, by = "canon", all.x = TRUE)
  out[, `:=`(h_called = h_blitz + h_ice + h_over + h_switch + h_under, s_called = s_blitz + s_ice + s_show + s_soft + s_switch)]
  out[, `:=`(od3_100 = 100 * od3 / pmax(1, poss), pop = s_three / pmax(1, s_tot))]
  attr(out, "hv") <- hv; attr(out, "sv") <- sv
  out
}

#' Frequency baselines on the joint call (see the header). Returns one row per baseline and the pick table in the
#' order scored.
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
  # Online, within the game: the defense's own earlier calls (league mix of the other games worth 5 picks).
  pr_game <- matrix(NA_real_, nrow(L), length(lv)); pr_last <- pr_game
  for (g in unique(L$game)) {
    lg <- cnt_of(L$joint7[L$game != g]); lgp <- 5 * lg / sum(lg)
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
  # Season files: the handler's faced over/under/switch/ice/blitz mix times the screener's show/soft split, each
  # pulled toward the league mix with 20 picks of weight. These include the ten games (10 of 293).
  W0 <- 20
  z <- function(v) { v[is.na(v)] <- 0; v }
  hs <- S[match(L$h_canon, S$canon)]; ss <- S[match(L$s_canon, S$canon)]
  hk <- c("h_over", "h_under", "h_switch", "h_ice", "h_blitz")
  lgh <- colSums(S[, ..hk]); lgh <- lgh / sum(lgh)
  lgs <- sum(S$s_show) / (sum(S$s_show) + sum(S$s_soft))
  h_n <- z(hs$h_called)
  ph <- sapply(hk, function(k) (z(hs[[k]]) + W0 * lgh[[k]]) / (h_n + W0))
  pshow <- (z(ss$s_show) + W0 * lgs) / (z(ss$s_show) + z(ss$s_soft) + W0)
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
  rbindlist(list(
    c(list(base = "League shares (other nine games)"), score(logo(rep("all", nrow(L))), y)),
    c(list(base = "By pick location type"), score(logo(L$spot_lab), y)),
    c(list(base = "By shot-clock band"), score(logo(as.character(L$sc_band)), y)),
    c(list(base = "This defense's earlier calls in the game"), score(pr_game, y)),
    c(list(base = "This defense's previous call"), score(pr_last, y)),
    c(list(base = "Handler's and screener's season (aggregates)"), score(pr_season, y)),
    c(list(base = "Ceiling: the defense's mix over its whole game (uses the answers)"), score(pr_full, y))))
}

topic_coverage <- function(BL) {
  D <- cov_data(BL)
  P <- D$P
  S <- cov_season()
  L <- copy(P[!is.na(joint7)])
  n_all <- nrow(P); n7 <- nrow(L)
  cnt <- vapply(JOINT_LV, function(l) sum(L$joint7 == l), 0L)
  base <- as.list(cnt / n7)
  W <- merge(D$W, P[, .(id, joint7, cov, scov, scheme)], by = "id")
  pct_of <- function(k, n) if (n) k / n else NA_real_

  # ---- the label ----
  cross <- dcast(P[, .N, by = .(cov, scov)], cov ~ scov, value.var = "N", fill = 0)
  cross <- cross[match(c("over", "under", "switch", "ice", "blitz"), cov)]
  scov_lv <- intersect(c("soft", "show", "switch", "ice", "blitz", "none"), names(cross))
  cross[, n := rowSums(.SD), .SDcols = scov_lv]
  cnt_tab <- data.table(call = JOINT_LV, n = as.integer(cnt), share = as.numeric(cnt) / n7,
                        bhr = c("over", "over", "under", "under", "switch", "ice", "blitz"),
                        scr = c("soft", "show", "soft", "show", "switch", "ice", "blitz"),
                        games = vapply(JOINT_LV, function(l) uniqueN(L[joint7 == l]$game), 0L))
  hv <- attr(S, "hv"); sv <- attr(S, "sv")
  sea_h <- colSums(S[, paste0("h_", hv), with = FALSE]); names(sea_h) <- hv
  sea_s <- colSums(S[, paste0("s_", sv), with = FALSE]); names(sea_s) <- sv
  h_share_sea <- sea_h / sum(S$h_tot); s_share_sea <- sea_s / sum(S$s_tot)
  dir10 <- P[direct == TRUE]
  h_cmp_lv <- c("over", "under", "switch", "ice", "blitz"); s_cmp_lv <- c("soft", "show", "switch", "ice", "blitz")

  # ---- tracking traces ----
  lines_lv <- setdiff(JOINT_LV, "blitz")
  mcols <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl")
  AG <- W[joint7 %in% lines_lv, lapply(.SD, mean, na.rm = TRUE), by = .(joint7, t), .SDcols = mcols]
  ag <- function(j, tt, m) AG[joint7 == j & t == tt][[m]]
  zero_line <- function(lo, hi) LINE(c(0, 0), c(lo, hi), color = "var(--muted)", dashed = TRUE)
  trace_chart <- function(m, title, ylab) {
    v <- AG[[m]]; lo <- floor(min(v, na.rm = TRUE)); hi <- ceiling(max(v, na.rm = TRUE))
    SCAT(title, lines = c(LINES_BY(AG, "t", m, "joint7", lines_lv), list(zero_line(lo, hi))),
         xlabel = "seconds from the pick (0 = picks.frame)", ylabel = ylab, xdomain = c(-3, 2), ydomain = c(lo, hi))
  }
  closest <- W[!is.na(d_hs), .SD[which.min(d_hs)], by = id]
  mk <- P[!is.na(mk_post), .(n = .N, sd = mean(mk_post == SD), bd = mean(mk_post == BD)), by = scheme][order(-n)]
  mk_pre <- P[, mean(mk_pre == BD, na.rm = TRUE)]

  # ---- separation over time ----
  meas <- c(bd_lvl = "handler's defender: level vs screen", sd_lvl = "screener's defender: level vs screen",
            d_bd = "handler to his own defender", d_sd = "handler to screener's defender", d_def = "defender to defender",
            h_lvl = "handler: level vs screen")
  contrasts <- list(
    list(name = "Under or over (the handler's defender)", ids = P[cov %in% c("over", "under"), .(id, g = cov == "under")]),
    list(name = "Show or soft (the screener's defender, over and under picks)", ids = P[cov %in% c("over", "under") & scov %in% c("show", "soft"), .(id, g = scov == "show")]),
    list(name = "Switch or not (switch against over and under picks)", ids = P[scheme %in% c("switch", "over/under"), .(id, g = scheme == "switch")]))
  CN <- vapply(contrasts, `[[`, "", "name")
  SEP <- rbindlist(lapply(contrasts, function(cc) {
    d <- merge(W[, c("id", "t", names(meas)), with = FALSE], cc$ids, by = "id")
    rbindlist(lapply(names(meas), function(m) d[, .(contrast = cc$name, m = m, auc = auc(get(m), g)), by = t]))
  }))
  SEP[, `:=`(sep = pmax(auc, 1 - auc), lab = meas[m])]
  sep_at <- function(k, mm, tt) SEP[contrast == CN[k] & m == mm & t == tt]$sep
  best_at <- function(k, tt) SEP[contrast == CN[k] & t == tt][which.max(sep)]
  sep_chart <- function(k) {
    SCAT(CN[k], lines = c(LINES_BY(SEP[contrast == CN[k]], "t", "sep", "lab", unname(meas)), list(zero_line(0.5, 1))),
         xlabel = "seconds from the pick", ylabel = "separation (AUC; 0.5 = none, 1 = perfect)", xdomain = c(-3, 2),
         ydomain = c(0.5, 1), yfmt = "num2")
  }
  best_tab <- rbindlist(lapply(c(-2, -1, -0.4, 0, 0.4, 1, 2), function(tt) {
    b <- lapply(1:3, function(k) best_at(k, tt))
    data.table(t = tt, uo = b[[1]]$sep, uo_m = b[[1]]$lab, ss = b[[2]]$sep, ss_m = b[[2]]$lab, sw = b[[3]]$sep, sw_m = b[[3]]$lab)
  }))

  # ---- context ----
  L[, `:=`(k_lab = fifelse(k_in_chance == 1L, "first pick of the chance", "re-screen (2nd+ pick)"),
           hop_lab = fifelse(hop, "handoff-pick", "plain pick"),
           clutch_lab = fifelse(clutch, "last 2 min of Q4 / OT", "rest of the game"))]
  mix_tab <- function(by, label, title, lev = NULL, key_title = label) {
    w <- mix_by(L, by)
    setnames(w, by, "grp")
    w <- w[!is.na(grp)]
    if (!is.null(lev)) w <- w[order(match(as.character(grp), lev))]
    TABLE(title, limit = 20, rows = mix_rows(w),
          cols = c(list(col("grp", label, title = key_title), col("n", "Picks", "int", title = "Picks in the group")), mix_cols(base)))
  }
  sw_sc <- L[!is.na(sc_band), .(k = sum(joint7 == "switch"), n = .N), by = sc_band][order(sc_band)]
  OU <- L[cov %in% c("over", "under")]
  un_spot <- OU[, .(k = sum(cov == "under"), n = .N), by = spot_lab][order(match(spot_lab, c("middle", "step-up", "wing")))]
  hl <- merge(W[t == -1 & cov %in% c("over", "under") & !is.na(h_lvl), .(id, h_lvl)], P[, .(id, cov)], by = "id")
  hl[, band := cut(h_lvl, c(-Inf, 3, 8, 13, Inf), labels = c("under 3 ft", "3-8 ft", "8-13 ft", "13+ ft"))]
  sw_rate <- function(b) { r <- sw_sc[sc_band == b]; r$k / r$n }
  un_band <- function(b) mean(hl[band == b]$cov == "under")

  # ---- who decides ----
  team_g <- mix_by(L, c("game", "def_name"))
  team_g[, top := do.call(pmax, .SD), .SDcols = JOINT_LV]
  sd_mix <- mix_by(L, c("sd_canon", "sd_name", "def_name"), min_n = 20)
  sd_mix[, show_ou := (`over · show` + `under · show`) / pmax(1e-9, 1 - switch - ice - blitz)]
  bd_mix <- mix_by(L, c("bd_canon", "bd_name", "def_name"), min_n = 20)
  bd_mix[, under_ou := (`under · soft` + `under · show`) / pmax(1e-9, 1 - switch - ice - blitz)]
  setorder(L, game, def_team, f0)
  L[, prev := shift(joint7), by = .(game, def_team)]
  L[, prev_sd := shift(joint7), by = .(game, def_team, SD)]
  rep_all <- L[!is.na(prev), mean(joint7 == prev)]
  rep_exp <- L[!is.na(prev), .(N = .N, e = sum((table(joint7) / .N)^2)), by = .(game, def_team)][, sum(N * e) / sum(N)]
  rep_sd <- L[!is.na(prev_sd), mean(joint7 == prev_sd)]
  SH <- S[h_called >= 100 & !is.na(od3_100)]
  SH[, `:=`(under = h_under / h_called, od3p = od3m / pmax(1, od3))]
  lg_od3p <- S[, sum(od3m, na.rm = TRUE) / sum(od3, na.rm = TRUE)]
  SS <- S[s_called >= 80]
  SS[, soft := s_soft / s_called]
  r_under <- SH[, cor(od3_100, under)]; r_soft <- SS[, cor(pop, soft)]
  L <- merge(L, S[, .(h_canon = canon, h_od3 = od3_100)], by = "h_canon", all.x = TRUE)
  L <- merge(L, S[, .(s_canon = canon, s_pop = pop)], by = "s_canon", all.x = TRUE)
  h_lv <- c("under 3 per 100", "3-8 per 100", "8+ per 100"); s_lv <- c("rarely (under 2%)", "sometimes (2-8%)", "often (8%+)")
  L[, h_tier := fifelse(is.na(h_od3), NA_character_, fifelse(h_od3 >= 8, h_lv[3], fifelse(h_od3 >= 3, h_lv[2], h_lv[1])))]
  L[, s_tier := fifelse(is.na(s_pop), NA_character_, fifelse(s_pop >= 0.08, s_lv[3], fifelse(s_pop >= 0.02, s_lv[2], s_lv[1])))]

  # ---- outcomes after the call ----
  L[, `:=`(h_shot = grepl("FG[MX]", bout), h_three = grepl("FG[MX]3", bout), s_shot = grepl("FG[MX]", sout),
           any_to = grepl("(^|\\|)TO(\\||$)", bout) | grepl("(^|\\|)TO(\\||$)", sout))]
  by_call <- function(f) lapply(JOINT_LV, function(l) f(l, L[joint7 == l]))

  # ---- readiness and baselines ----
  WR <- W[, .(have4 = mean(have4), all10 = mean(all10), det4 = mean(det4) / 4), by = t][order(t)]
  short <- P[, mean(since_poss < 3)]
  per_game <- dcast(L[, .N, by = .(game, joint7)], game ~ joint7, value.var = "N", fill = 0)
  for (l in JOINT_LV) if (!l %in% names(per_game)) per_game[, (l) := 0L]
  per_game[, n := rowSums(.SD), .SDcols = JOINT_LV]
  teams <- unique(L[, .(game, off_name)])[order(off_name)][, .(match = paste(off_name, collapse = " – ")), by = game]
  per_game <- mix_rows(merge(per_game, teams, by = "game"))
  BS <- cov_baselines(copy(L), S)
  ll_unif <- log(length(JOINT_LV))
  maj <- JOINT_LV[which.max(cnt)]
  ho <- rbindlist(lapply(BL, function(B) B$handoffs[, .(cov)]))
  ho_tab <- sort(table(ho$cov), decreasing = TRUE)

  sections <- list(
    SECTION("cv-question", "The question and the label",
      P("Before training a model to predict how two defenders play an on-ball screen, this tab checks what the label is, how often each call happens, what each call looks like in the tracking, when it becomes visible, what it depends on and whether there is enough data. No model is fitted."),
      KPIS(KPI("Picks", int(n_all), "on-ball screens in the ten games"),
           KPI("Usable joint calls", int(n7), sprintf("%d with screener call 'none' left out", n_all - n7)),
           KPI("Most common call", maj, sprintf("%s of picks", pct(max(cnt) / n7))),
           KPI("Rarest calls", sprintf("%d ice · %d blitz", cnt[["ice"]], cnt[["blitz"]]), "too few to learn from")),
      BUL("SkillCorner labels every pick twice. **bhrDefType** is the ball handler's defender: over, under, switch, ice or blitz ('none' is documented but never used in these games). **scrDefType** is the screener's defender: soft, show, switch, ice, blitz or none",
          "**Switch, ice and blitz are always called for both defenders together**, and over or under always pairs with soft, show or none. So the two fields are really one call with seven values",
          "The seven joint calls match the rows of the coaching table: over · soft (drop), over · show (hedge), under · soft, under · show, switch, ice and blitz"),
      TABLE("Ball handler's call (rows) against screener's call (columns)", limit = 6, rows = cross,
            cols = c(list(col("cov", "Handler's defender", title = "bhrDefType, the call on the ball handler's defender")),
                     lapply(scov_lv, function(s) col(s, s, "int", group = "Screener's defender", title = sprintf("Picks where the screener's defender was called %s", s))),
                     list(col("n", "Picks", "int", title = "All picks with this call on the handler's defender")))),
      TABLE("The seven joint calls", limit = 8, rows = cnt_tab, cols = list(
        col("call", "Joint call", title = "The handler's call and the screener's call together"),
        col("bhr", "Handler's defender", title = "bhrDefType"), col("scr", "Screener's defender", title = "scrDefType"),
        col("n", "Picks", "int", title = "Picks with this call in the ten games"),
        col("share", "Share", "pct1", title = "Share of the picks with a usable joint call"),
        col("games", "Games", "int", title = "Games (of ten) in which it was called at least once"))),
      H("Are the ten games typical of the season?"),
      P("The season files count only direct picks (the handler or screener shot, assisted or was fouled right after) and only from the offense's side, so they give the league-wide mix of each call but not the joint call. The ten games' direct picks are compared with them."),
      GRID(
        COLS("Handler's defender: ten games vs season", h_cmp_lv, labels = TRUE,
             list(SERIES1("ten games (direct picks)", sapply(h_cmp_lv, function(l) mean(dir10$cov == l)), PAL[1]),
                  SERIES1("season, 293 games (direct picks)", h_share_sea[h_cmp_lv], PAL[2]))),
        COLS("Screener's defender: ten games vs season", s_cmp_lv, labels = TRUE,
             list(SERIES1("ten games (direct picks)", sapply(s_cmp_lv, function(l) mean(dir10$scov == l)), PAL[1]),
                  SERIES1("season, 293 games (direct picks)", s_share_sea[s_cmp_lv], PAL[2])))),
      TAKE(sprintf("Over · soft and over · show together are %s of the calls; always guessing the commoner one is right %s of the time", pct((cnt[["over · soft"]] + cnt[["over · show"]]) / n7), pct(max(cnt) / n7)),
           sprintf("The season mix is close to the sample's: over %s, under %s and switch %s of season direct picks. Only %s of %s season direct picks have no call on the handler's defender and %s none on the screener's",
                   pct(h_share_sea[["over"]]), pct(h_share_sea[["under"]]), pct(h_share_sea[["switch"]]),
                   int(sum(S$h_tot) - sum(sea_h)), int(sum(S$h_tot)), int(sum(S$s_tot) - sum(sea_s))),
           sprintf("Ice (%s of season direct picks) and blitz (%s) are rare league-wide, not just in this sample", pct(h_share_sea[["ice"]], 1), pct(h_share_sea[["blitz"]], 1)))),

    SECTION("cv-motion", "What each call looks like in the tracking",
      P("For every pick, the four players of the action are followed from 3 s before to 2 s after the pick frame. Lines are averages per joint call (blitz left out: 4 picks). The dashed line is the pick frame."),
      BUL(sprintf("**Time 0 is the screen.** The handler passes closest to the screener a median %.1f s after picks.frame (middle half %.1f to %.1f s)", median(closest$t), quantile(closest$t, .25), quantile(closest$t, .75)),
          "**Level vs screen** = the player's distance to the hoop minus the screen spot's, in feet. Positive is above the screen (farther from the hoop), negative below it. Over keeps the handler's defender above, under takes him below; show brings the screener's defender up toward the ball, soft keeps him back",
          sprintf("**Who is who.** ballhandlerDefId and screenerDefId name the defenders before any switch. The matchups table agrees on %s of picks just before the screen", pct(mk_pre))),
      GRID(
        trace_chart("bd_lvl", "Handler's defender: level vs the screen", "ft above (+) or below (−)"),
        trace_chart("sd_lvl", "Screener's defender: level vs the screen", "ft above (+) or below (−)"),
        trace_chart("d_bd", "Handler to his own defender", "ft"),
        trace_chart("d_sd", "Handler to the screener's defender", "ft"),
        trace_chart("d_def", "The two defenders' distance from each other", "ft"),
        trace_chart("h_lvl", "Handler: level vs the screen", "ft above (+) or below (−)")),
      TABLE("Who guards the handler 1.5 s after the pick (matchups table)", limit = 5, rows = mk, cols = list(
        col("scheme", "Call", title = "Over/under groups the four over and under calls"),
        col("n", "Picks", "int", title = "Picks with a matchup row for the handler 1.5 s after the pick"),
        col("sd", "Screener's defender", "pct", title = "Share where the handler's assigned defender is now the screener's defender"),
        col("bd", "Own defender", "pct", title = "Share where the handler's assigned defender is still his original defender"))),
      TAKE(sprintf("Under: the handler's defender is %.1f ft below the screen 0.4 s after the pick; with over he is still %.1f ft above it", -ag("under · soft", 0.4, "bd_lvl"), ag("over · soft", 0.4, "bd_lvl")),
           sprintf("Show: the screener's defender is %.1f ft from the handler 0.4 s after the pick, against %.1f ft for soft (both with over)", ag("over · show", 0.4, "d_sd"), ag("over · soft", 0.4, "d_sd")),
           sprintf("Switch: by +2 s the handler's own defender is %.1f ft away and the screener's defender %.1f ft", ag("switch", 2, "d_bd"), ag("switch", 2, "d_sd")),
           sprintf("Under picks start higher: 1 s before the pick the handler is %.1f ft above the screen on under · soft picks, %.1f ft on over · show", ag("under · soft", -1, "h_lvl"), ag("over · show", -1, "h_lvl")),
           sprintf("The matchups table backs the switch label: %s of switches hand the handler to the screener's defender, against %s of over/under picks", pct(mk[scheme == "switch"]$sd), pct(mk[scheme == "over/under"]$sd))),
      CAVEAT("Averages hide spread: single picks overlap a lot, which the next section measures",
             sprintf("The ice lines rest on %d picks", cnt[["ice"]]))),

    SECTION("cv-timing", "When does the call become visible?",
      P("This decides what a model can honestly claim. If the calls only differ after the screen, a model that sees frames after time 0 is recognising the coverage, not predicting it."),
      BUL("**Separation (AUC).** Take one pick of each kind at random. The AUC is how often a measure puts them the right way round: 0.5 is a coin flip, 1 is always right. It is computed for one measure at one moment at a time",
          "The charts show it for each measure from −3 s to +2 s, for three questions a model would face"),
      GRID(sep_chart(1), sep_chart(2), sep_chart(3), cols = 1),
      TABLE("Best single measure at each moment", limit = 10, rows = best_tab, cols = list(
        col("t", "Seconds", "num1", title = "Seconds from the pick frame"),
        col("uo", "AUC", "num2", group = "Under or over", title = "Best separation of any single measure at that moment"),
        col("uo_m", "Best measure", group = "Under or over", title = "The measure that separates best at that moment"),
        col("ss", "AUC", "num2", group = "Show or soft", title = "Best separation of any single measure at that moment"),
        col("ss_m", "Best measure", group = "Show or soft", title = "The measure that separates best at that moment"),
        col("sw", "AUC", "num2", group = "Switch or not", title = "Best separation of any single measure at that moment"),
        col("sw_m", "Best measure", group = "Switch or not", title = "The measure that separates best at that moment"))),
      TAKE(sprintf("Under or over is barely visible 1 s before the screen (best AUC %.2f) and nearly certain 0.4 s after it (%.2f)", best_at(1, -1)$sep, best_at(1, 0.4)$sep),
           sprintf("Show or soft shows earliest: the screener's defender's level separates %.2f at −0.4 s and %.2f at the pick frame", sep_at(2, "sd_lvl", -0.4), sep_at(2, "sd_lvl", 0)),
           sprintf("A switch shows last: best %.2f at the pick frame, %.2f at +1 s and %.2f at +2 s", best_at(3, 0)$sep, best_at(3, 1)$sep, best_at(3, 2)$sep),
           "So a before-the-screen model has to lean on the defenders' set-up and on context, which alone says little (section 7). A model allowed to look 0.5-1 s past the screen is mostly reading a label already visible in the tracking"),
      CAVEAT("One measure at one moment is a floor: a model combining measures and frames will separate better, especially before the screen",
             "SkillCorner's labels come from its own tracking model, so some of the after-screen separation is the labelling rule itself")),

    SECTION("cv-context", "Where and when each call happens",
      P("The coverage mix by the situation. Each share column is the share of that row's picks. Cells are blue when a call is more common than overall and red when less."),
      mix_tab("spot_lab", "Location type", "By pick location type (picks.locationType)", c("middle", "step-up", "wing"), "SkillCorner's locationType: middle, step-up or wing"),
      mix_tab("sc_band", "Shot clock", "By shot clock left at the pick", levels(P$sc_band), "Seconds left on the shot clock at the pick"),
      mix_tab("k_lab", "Pick in chance", "First pick or re-screen", NULL, "Whether an earlier pick happened in the same chance"),
      mix_tab("hop_lab", "Kind", "Plain pick or handoff-pick", NULL, "picks.handoffPick, a handoff combined with a pick"),
      mix_tab("clutch_lab", "Game time", "Late-game picks", NULL, "Last two minutes of the fourth quarter or overtime"),
      GRID(
        RATES("Switch rate by shot clock left", lapply(seq_len(nrow(sw_sc)), function(i) rrow(as.character(sw_sc$sc_band[i]), sw_sc$k[i], sw_sc$n[i])),
              ref = base[["switch"]], unit = "of picks switched", label_width = 90),
        RATES("Under rate by location type (over and under picks)", lapply(seq_len(nrow(un_spot)), function(i) rrow(un_spot$spot_lab[i], un_spot$k[i], un_spot$n[i])),
              ref = mean(OU$cov == "under"), unit = "went under", label_width = 90),
        RATES("Under rate by how far above the screen the handler is 1 s before", lapply(levels(hl$band), function(b) rrow(b, sum(hl[band == b]$cov == "under"), nrow(hl[band == b]))),
              ref = mean(hl$cov == "under"), unit = "went under", label_width = 110)),
      GRID(
        COURT("Where over picks were set", L[cov == "over"]$x, L[cov == "over"]$y),
        COURT("Where under picks were set", L[cov == "under"]$x, L[cov == "under"]$y),
        COURT("Where switches happened", L[joint7 == "switch"]$x, L[joint7 == "switch"]$y),
        COURT("Where the screener's defender showed", L[scov == "show"]$x, L[scov == "show"]$y)),
      TAKE(sprintf("Switches grow as the shot clock runs down: %s of picks with 18+ s left, %s with 6 s or less", pct(sw_rate("18-24 s")), pct(sw_rate("0-6 s"))),
           sprintf("Going under follows how high the handler starts: %s when he is 13+ ft above the screen 1 s before, %s when under 3 ft", pct(un_band("13+ ft")), pct(un_band("under 3 ft"))),
           sprintf("Location type moves the under rate only from %s to %s", pct(min(un_spot$k / un_spot$n)), pct(max(un_spot$k / un_spot$n))))),

    SECTION("cv-who", "Who decides: the defense, the defenders and the attackers",
      P("Coverage is a team plan adjusted for matchups. With ten games, each defense is seen once (Zaragoza, Breogan and Gran Canaria twice), so the tracked games alone cannot teach a model a team's scheme."),
      TABLE("Each defense, game by game", limit = 20, rows = mix_rows(copy(team_g)), cols = c(list(
        col("def_name", "Defense", title = "The defending team"), col("game", "Game", title = "SkillCorner game id"),
        col("n", "Picks", "int", title = "Picks it defended in that game"),
        col("top", "Main call", "pct", title = "Share of its picks that got its most common call")), mix_cols(base))),
      BUL(sprintf("**Defenses differ.** A defense's most common call covers %s to %s of its picks in a game, and the most common call itself changes from defense to defense", pct(min(team_g$top)), pct(max(team_g$top))),
          sprintf("**No streaks.** A defense's call equals its previous call in the same game %s of the time. If its calls in that game came in random order, the match rate would be %s, so calls are not streakier than the defense's overall mix", pct(rep_all), pct(rep_exp)),
          sprintf("The same screener's defender repeats his own previous call %s of the time", pct(rep_sd))),
      TABLE("Screener's defenders with 20+ picks", limit = 15, rows = mix_rows(copy(sd_mix))[order(-n)], cols = c(list(
        col("sd_name", "Screener's defender", title = "The defender of the screener (screenerDefId)"), col("def_name", "Team"),
        col("n", "Picks", "int", title = "Picks in which he guarded the screener"),
        col("show_ou", "Show share", "pct", title = "Among his over and under picks, the share where he showed rather than played soft")), mix_cols(base))),
      TABLE("Ball handler's defenders with 20+ picks", limit = 15, rows = mix_rows(copy(bd_mix))[order(-n)], cols = c(list(
        col("bd_name", "Handler's defender", title = "The defender of the ball handler (ballhandlerDefId)"), col("def_name", "Team"),
        col("n", "Picks", "int", title = "Picks in which he guarded the ball handler"),
        col("under_ou", "Under share", "pct", title = "Among his over and under picks, the share where he went under")), mix_cols(base))),
      H("Does the attacker's shooting change the call? (whole season)"),
      P("The season files give, for every ACB player, the calls he faced as a handler and as a screener over 293 games. The coaching logic says defenders go under non-shooters and drop (soft) against rollers rather than poppers."),
      GRID(
        SCAT("Handlers: going under against off-the-dribble three volume", points = SH[, .(x = r2(od3_100, 1), y = r2(under, 3), g = as.integer(od3p < lg_od3p),
             tip = sprintf("%s\n%d called picks as handler\n%.1f off-dribble 3PA per 100 possessions\n%.0f%% under", name, h_called, od3_100, 100 * under))],
             groups = c("off-dribble 3P% at or above league", "below league"), xlabel = "season off-dribble 3PA per 100 possessions",
             ylabel = "share of his picks defended under", yfmt = "pct", radius = 4,
             note = sprintf("Handlers with 100+ called direct picks (%d). Correlation %.2f", nrow(SH), r_under)),
        SCAT("Screeners: soft (drop) against how often he pops for three", points = SS[, .(x = r2(pop, 3), y = r2(soft, 3), g = 0L,
             tip = sprintf("%s\n%d called picks as screener\n%.1f%% of his picks end in his own three\n%.0f%% soft", name, s_called, 100 * pop, 100 * soft))],
             groups = c("screeners"), xlabel = "share of his picks ending in his own three-point attempt", ylabel = "share of his picks defended soft",
             xfmt = "pct", yfmt = "pct", radius = 4, note = sprintf("Screeners with 80+ called direct picks (%d). Correlation %.2f", nrow(SS), r_soft))),
      GRID(
        RATES("Ten games: under rate by the handler's season off-dribble 3PA", lapply(h_lv, function(l) { d <- L[h_tier %in% l & cov %in% c("over", "under")]; rrow(l, sum(d$cov == "under"), nrow(d)) }),
              ref = mean(OU$cov == "under"), unit = "of over and under picks went under", label_width = 130),
        RATES("Ten games: soft rate by how often the screener pops (season)", lapply(s_lv, function(l) { d <- L[s_tier %in% l & scov %in% c("show", "soft")]; rrow(l, sum(d$scov == "soft"), nrow(d)) }),
              ref = mean(L[scov %in% c("show", "soft")]$scov == "soft"), unit = "of show and soft picks were soft", label_width = 140)),
      TAKE(sprintf("Defenses lean on different calls, but within a game the order looks random: %s repeats against %s by chance. A team's mix matters; its last call adds nothing", pct(rep_all), pct(rep_exp)),
           sprintf("Season-wide, handlers who take more off-the-dribble threes are defended under %s often (correlation %.2f)", if (r_under < 0) "less" else "more", r_under),
           sprintf("Screeners who pop more see %s soft coverage (correlation %.2f)", if (r_soft < 0) "less" else "more", r_soft)),
      CAVEAT("The season files include the ten games (10 of 293): a small overlap, but a leak if used as model input without care",
             "There is no defensive season file, so a defense's own season scheme cannot be measured, only what each attacker faced")),

    SECTION("cv-outcomes", "What each call gave up in these games",
      P("What happened after the call, to set beside the coaching table's 'what it gives up'. These are recorded after the pick, so they can never be model inputs."),
      GRID(
        RATES("Handler shot after the pick", by_call(function(l, d) rrow(l, sum(d$h_shot), nrow(d))), ref = mean(L$h_shot), unit = "of picks (bhrOutcomes has a shot)"),
        RATES("Handler took a three", by_call(function(l, d) rrow(l, sum(d$h_three), nrow(d))), ref = mean(L$h_three), unit = "of picks"),
        RATES("Screener shot after the pick", by_call(function(l, d) rrow(l, sum(d$s_shot), nrow(d))), ref = mean(L$s_shot), unit = "of picks (scrOutcomes has a shot)"),
        RATES("Turnover by the handler or screener", by_call(function(l, d) rrow(l, sum(d$any_to), nrow(d))), ref = mean(L$any_to), unit = "of picks"),
        RATES("Points in the chance", by_call(function(l, d) mrow(l, d[in_pop == TRUE]$pts)), fmt = "num2", ref = mean(L[in_pop == TRUE]$pts), unit = "points per chance"),
        RATES("Direct pick (SkillCorner)", by_call(function(l, d) rrow(l, sum(d$direct), nrow(d))), ref = mean(L$direct), unit = "led straight to a shot, assist or foul")),
      CAVEAT("Points per chance counts every pick in the chance, so chances with re-screens count more than once",
             "SkillCorner's direct flag is decided by what happened after the pick, so it cannot be a model input either")),

    SECTION("cv-ready", "Is there enough data, and what is the bar to beat?",
      H("Tracking around the pick"),
      TABLE("Tracking available at each moment", limit = 30, rows = WR[t %in% c(-3, -2, -1.6, -1.2, -0.8, -0.4, 0, 0.4, 0.8, 1.2, 1.6, 2)], cols = list(
        col("t", "Seconds", "num1", title = "Seconds from the pick frame"),
        col("have4", "Four players", "pct", title = "Share of picks with the handler, screener and both defenders tracked, inside the same possession"),
        col("all10", "All ten", "pct", title = "Share of picks with all ten players tracked, inside the same possession"),
        col("det4", "Detected", "pct", title = "Share of the four players' positions seen on camera rather than extrapolated"))),
      BUL(sprintf("%s of picks come within 3 s of the possession's start, so their 3 s history is cut short", pct(short)),
          sprintf("%s of picks are in transition and %s in chances with quality index 3 or more", pct(mean(P$transition, na.rm = TRUE)), pct(mean(P$q >= 3, na.rm = TRUE))),
          sprintf("%s handoffs carry a similar call on the receiver's defender (%s), a possible source of extra examples", int(nrow(ho)),
                  paste(sprintf("%s %d", names(ho_tab), as.integer(ho_tab)), collapse = ", "))),
      H("Picks per game"),
      TABLE("Calls in each game", limit = 12, rows = per_game, cols = c(list(
        col("game", "Game", title = "SkillCorner game id"), col("match", "Teams", title = "The two teams"),
        col("n", "Picks", "int", title = "Picks with a usable joint call")),
        lapply(JOINT_LV, function(l) col(KEYS[[l]], l, "int", group = "Picks per call", title = sprintf("Picks called %s", l))))),
      H("Simple baselines"),
      BUL("Each baseline predicts a pick's call from the shares of calls in a reference group, with one pick of each call added so nothing gets probability zero, and the league mix added with the weight of five picks",
          "Groups built from games are built without the pick's own game (leave one game out). 'Earlier calls' and 'previous call' use only picks before this one in the same game",
          "The season baseline multiplies the handler's season share of over, under, switch, ice and blitz by the screener's season share of show and soft, each pulled toward the league with the weight of 20 picks",
          sprintf("**Accuracy** = how often the most likely call was right. **Log loss** = the average of minus the log of the probability given to the true call; lower is better, and guessing all seven calls equally scores %.2f", ll_unif)),
      TABLE("Baselines on the seven-call label", limit = 8, rows = BS, cols = list(
        col("base", "Baseline", title = "Where the call shares come from"), col("n", "Picks", "int", title = "Picks scored"),
        col("acc", "Accuracy", "pct", title = "Share of picks where the most likely call was the true call"),
        col("ll", "Log loss", "num2", ref = BS$ll[1], scale = 0.15, low = TRUE, title = "Average of minus the log of the probability given to the true call. Lower is better"))),
      TAKE(sprintf("The bar from league shares alone: log loss %.2f. Its accuracy is only %s because over · soft and over · show are nearly tied, so which one it picks flips from game to game", BS$ll[1], pct(BS$acc[1])),
           sprintf("No honest look-up moves log loss by more than %.2f (best: '%s', %.2f). Context alone says little about the call", BS$ll[1] - min(BS$ll[1:6]), BS$base[which.min(BS$ll[1:6])], min(BS$ll[1:6])),
           sprintf("Knowing a defense's whole-game mix (cheating, it includes the answer) would give %.2f: that is roughly the most a team-scheme prior could be worth", BS$ll[7]),
           "So the real signal must come from the tracking around the screen (section 3), which is the case for a sequence model",
           sprintf("Ice (%d) and blitz (%d) cannot be learned from %s picks; plan to merge or drop them", cnt[["ice"]], cnt[["blitz"]], int(n7)))),

    SECTION("cv-plan", "What this means for a transformer",
      BUL("**Decide the task first.** Predicting from frames up to the screen is forecasting. Letting the model see 0.5-1 s past it is mostly recognising a call already visible in the tracking (section 3). Both are useful, but they answer different coaching questions",
          sprintf("**Label.** Use the joint call. %d of the seven have under 20 picks, so a practical version has five values (over · soft, over · show, under · soft, under · show, switch), or two heads (handler: over, under or switch; screener: soft, show or switch)", sum(cnt < 20)),
          "**Tokens.** One token per player per frame, with fixed roles for the four players of the action (handler, screener and their two defenders) plus the other six. Coordinates in the viewer frame (attacking +x, screen y corrected), possibly also relative to the screen spot",
          "**Context.** The shot clock, how high the handler starts, and the handler's and screener's season shooting shift the mix, but only a little (section 7). The defense's earlier calls did not help. Context tokens are worth including, not worth relying on",
          "**Never inputs.** bhrOutcomes, scrOutcomes, direct, and anything about the shot or points: all are recorded after the call",
          sprintf("**Size.** %s labelled picks, about %d per game, with every defense but three seen in one game only. Split by game, report each held-out game, and compare against the baselines above", int(n7), round(n7 / 10)),
          "**Same lesson as the kickout model.** There a logistic model with a few good features tied the transformer. Fit the baselines and a small logistic model on hand-made features (the level and distance measures above) before the transformer"))
  )
  DOC("coverage", "Pick coverage",
      "Groundwork for predicting how two defenders play an on-ball screen: the label, what each call looks like in the tracking, when it becomes visible, what drives it, and the bar a model must beat.",
      sections)
}
