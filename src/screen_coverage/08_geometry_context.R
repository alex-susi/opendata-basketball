# Screen coverage, step 8: screen geometry and context. Where and when is each screen set, and does knowing that
# help predict the call?
#   Rscript src/screen_coverage/08_geometry_context.R
#
# Part 1 builds the features for EVERY tagged screen (all seven calls, ice and blitz included), at several moments
# around the screen tag, from positions at that moment and 0.48 s before (nothing later):
#   dist_sideline   ft from the screener to the nearer sideline (the court is 49.2 ft wide)
#   dist_baseline   ft from the screener to the baseline the offense attacks
#   side_left       1 if the screener is on the offense's left half of the floor (+y), 0 if on its right
#   spot_angle      where the screen is around the hoop: 0 degrees = straight out from the hoop, 90 = level with it
#                   along the baseline
#   lateral_mid     ft the screener stands toward the middle of the floor (+) or toward the sideline (-) of the ball
#                   handler's straight line to the hoop: which shoulder the screen is set on
#   approach        angle between the screener's and the ball handler's movement over the last 0.48 s (0 = moving the
#                   same way, 180 = coming head-on); 90 when either is nearly still (moved < 1 ft), flagged by s_still
#   time_to_act     the shot clock or the game clock, whichever runs out first, capped at 24 s (the shot clock is off
#                   in the last seconds of a period)
#   rescreen        1 if an earlier screen was tagged in the same possession; same_pair: by the same handler and
#                   screener; since_prev: seconds since that earlier screen (capped at 24)
# Written to outputs/screen_coverage/context/screen_features.csv (one row per screen and moment). The Pick coverage
# tab (web/scripts/explore/coverage.R) reads it for its rare-call and geometry sections.
#
# Part 2 tests predictive power. On the 1,464 scored screens and the same held-out games as 02_per_frame.R, a
# logistic model per moment is fitted with:
#   base        the four-player measures + defense so far + SHOT CLOCK (as in 02)
#   base, tta   the same with time to act in place of the shot clock
#   + geometry  base, tta plus dist_sideline, dist_baseline, side_left, spot_angle, lateral_mid, approach, s_still
#   + context   base, tta plus rescreen, same_pair, since_prev
#   + both      base, tta plus both groups
# Paired change in log loss against "base, tta" with a 95% interval from resampling whole games.
# Writes outputs/screen_coverage/context/predictive_test.csv and figures/predictive_test.png.

suppressPackageStartupMessages({ library(data.table); library(nnet); library(ggplot2) })
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
out_dir <- file.path(root, "outputs", "screen_coverage", "context")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)

FPS <- 25
FT <- 3.28084
HOOP_X <- (14 - 1.575) * FT
BASELINE_X <- 14 * FT
HALF_W <- 7.5 * FT
LOOK <- 12L                                     # 0.48 s
OFFS <- c(-25L, -20L, -15L, -10L, -5L, 0L, 10L)  # -1.0, -0.8, -0.6, -0.4, -0.2, 0, +0.4 s
CALLS <- c("over + show", "over + soft", "under + soft", "under + show", "switch")
games <- as.integer(jsonlite::fromJSON(file.path(root, "data", "matches.json"))$id)
bundle <- function(g) readRDS(file.path(root, "outputs", "cache", "explore", sprintf("bundle_%d.rds", g)))

pos_at <- function(B, frames, ids) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_, poss = NA_character_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    hit <- B$P[.(frames[miss] + d, ids[miss]), .(x, y, poss), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y, poss = hit$poss)]
  }
  out
}

# ---- part 1: features for every screen --------------------------------------------------------------------

build_game <- function(g) {
  B <- bundle(g)
  p <- B$picks[, .(id, chance, f0, H = actor, BD = adef, S = screener, SD = sdef, cov, scov, spot, ex = x, ey = y)]
  if (!nrow(p)) return(NULL)
  ev <- as.data.table(jsonlite::fromJSON(file.path(root, "data", "matches", g, paste0(g, "_dynamic_events.json")))$picks)
  p[ev[, .(id, period, def_team = defTeamId, off_team = offTeamId, hop = handoffPick)], on = "id",
    `:=`(period = i.period, def_team = i.def_team, off_team = i.off_team, hop = i.hop)]
  p[B$ch, on = "chance", `:=`(poss = i.poss, transition = i.transition)]
  p[, `:=`(game_id = g, call = fifelse(cov %in% c("switch", "ice", "blitz"), cov, paste(cov, scov, sep = " + ")))]
  nm <- function(id) B$roster$name[match(id, B$roster$pid)]
  tm <- unique(B$roster[, .(team, team_name)])
  p[, `:=`(h_name = nm(H), s_name = nm(S), def_name = tm$team_name[match(def_team, tm$team)])]
  # re-screens within the possession
  setorder(p, f0)
  p[, `:=`(k_poss = seq_len(.N), prev_f = shift(f0), prev_h = shift(H), prev_s = shift(S)), by = poss]
  p[, `:=`(rescreen = as.integer(k_poss > 1L), same_pair = as.integer(k_poss > 1L & prev_h == H & prev_s == S),
           since_prev = fifelse(k_poss > 1L, pmin(24, (f0 - prev_f) / FPS), 24))]
  rbindlist(lapply(OFFS, function(o) {
    f <- p$f0 + o
    hn <- pos_at(B, f, p$H); hb <- pos_at(B, f - LOOK, p$H)
    sn <- pos_at(B, f, p$S); sb <- pos_at(B, f - LOOK, p$S)
    ok <- !is.na(hn$x) & !is.na(sn$x) & hn$poss %in% p$poss & sn$poss == p$poss
    sx <- fifelse(is.na(sn$x), p$ex, sn$x); sy <- fifelse(is.na(sn$y), p$ey, sn$y)
    fr <- B$Fr[.(f), .(sc, gc), nomatch = NA]
    # which shoulder: the screener against the handler's straight line to the hoop
    ux <- HOOP_X - hn$x; uy <- -hn$y; ul <- pmax(sqrt(ux^2 + uy^2), 1e-6); ux <- ux / ul; uy <- uy / ul
    proj <- (sx - hn$x) * ux + (sy - hn$y) * uy
    line_y <- hn$y + proj * uy
    smx <- sn$x - sb$x; smy <- sn$y - sb$y; hmx <- hn$x - hb$x; hmy <- hn$y - hb$y
    s_d <- sqrt(smx^2 + smy^2); h_d <- sqrt(hmx^2 + hmy^2)
    still <- is.na(s_d) | is.na(h_d) | s_d < 1 | h_d < 1
    ang <- acos(pmin(1, pmax(-1, (smx * hmx + smy * hmy) / pmax(s_d * h_d, 1e-6)))) * 180 / pi
    data.table(id = p$id, off = o, t = o / FPS, tracked = ok,
               dist_sideline = HALF_W - abs(sy), dist_baseline = BASELINE_X - sx, side_left = as.integer(sy > 0),
               spot_angle = atan2(abs(sy), HOOP_X - sx) * 180 / pi,
               lateral_mid = abs(line_y) - abs(sy), approach = fifelse(still, 90, ang), s_still = as.integer(still),
               time_to_act = pmin(fr$sc, fr$gc, 24, na.rm = TRUE), shot_clock = fifelse(is.na(fr$sc), 24, fr$sc))
  }))[p[, .(id, game_id, poss, period, f0, call, cov, scov, spot, hop, transition, rescreen, same_pair, since_prev,
            def_name, h_name, s_name, H, S)], on = "id"]
}
FEAT <- rbindlist(lapply(games, build_game))
FEAT[is.infinite(time_to_act), time_to_act := 24]
fwrite(FEAT[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "screen_features.csv"))
cat("Screen features:", uniqueN(FEAT$id), "screens x", length(OFFS), "moments\n")
print(FEAT[off == 0, .N, by = call][order(-N)])

# ---- part 2: do the new features help? ---------------------------------------------------------------------

L <- readRDS(file.path(root, "outputs", "cache", "screen_coverage", "logistic_per_frame.rds"))
P <- L$P; X <- L$X
GEOM4 <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v")
LSF <- paste0("lsf_", seq_along(CALLS))
G_GEO <- c("dist_sideline", "dist_baseline", "side_left", "spot_angle", "lateral_mid", "approach", "s_still")
G_CTX <- c("rescreen", "same_pair", "since_prev")
SETS <- list(`base (shot clock)` = c(GEOM4, "sc_now", LSF), `base, time to act` = c(GEOM4, "time_to_act", LSF),
             `+ geometry` = c(GEOM4, "time_to_act", LSF, G_GEO), `+ context` = c(GEOM4, "time_to_act", LSF, G_CTX),
             `+ geometry + context` = c(GEOM4, "time_to_act", LSF, G_GEO, G_CTX))

logo <- function(d, feats) {
  Pm <- matrix(NA_real_, nrow(d), length(CALLS))
  for (g in unique(d$game_id)) {
    tr <- d$game_id != g; te <- !tr
    Xtr <- as.matrix(d[tr, ..feats]); mu <- colMeans(Xtr); sdv <- apply(Xtr, 2, sd); sdv[sdv == 0] <- 1
    fit <- multinom(y ~ ., data = data.frame(y = factor(d$call[tr], CALLS), scale(Xtr, mu, sdv)), decay = 1, trace = FALSE, maxit = 2000)
    Pm[te, ] <- predict(fit, newdata = data.frame(scale(as.matrix(d[te, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
  }
  Pm
}
boot_ci <- function(score, game, reps = 2000L) {
  set.seed(1); s <- split(score, game); sums <- vapply(s, sum, 0); ns <- lengths(s)
  b <- replicate(reps, { k <- sample(names(s), length(s), TRUE); sum(sums[k]) / sum(ns[k]) })
  c(mean(score), quantile(b, c(0.025, 0.975)))
}
res <- rbindlist(lapply(OFFS, function(o) {
  d <- X[off == o]
  d <- merge(d, FEAT[off == o, c("id", "time_to_act", G_GEO, G_CTX), with = FALSE], by = "id", sort = FALSE)
  stopifnot(nrow(d) == nrow(P))
  ll <- lapply(SETS, function(fs) { Pm <- logo(d, fs); -log(pmax(Pm[cbind(seq_len(nrow(d)), match(d$call, CALLS))], 1e-12)) })
  base <- ll[["base, time to act"]]
  rbindlist(lapply(names(SETS), function(s) {
    ci <- boot_ci(ll[[s]] - base, d$game_id)
    data.table(t = o / FPS, model = s, logloss = mean(ll[[s]]), change_vs_tta = ci[1], lo = ci[2], hi = ci[3],
               games_better = sum(tapply(ll[[s]] - base, d$game_id, mean) < 0))
  }))
}))
fwrite(res[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "predictive_test.csv"))
cat("\nLog loss by moment, and change against 'base, time to act' (95% game bootstrap):\n")
print(res[, .(t, model, logloss = round(logloss, 4), change = round(change_vs_tta, 4), lo = round(lo, 4), hi = round(hi, 4), games_better)])

pd <- res[model != "base, time to act"][, model := factor(model, levels = setdiff(names(SETS), "base, time to act"))]
pg <- ggplot(pd, aes(t, change_vs_tta, colour = model, fill = model)) +
  geom_hline(yintercept = 0, colour = "grey40") + geom_vline(xintercept = 0, colour = "grey70") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.12, colour = NA) + geom_line(linewidth = 0.9) + geom_point(size = 2) +
  scale_colour_manual(values = c("#9a9a96", "#2a78d6", "#eb6834", "#6250d6"), name = NULL) +
  scale_fill_manual(values = c("#9a9a96", "#2a78d6", "#eb6834", "#6250d6"), name = NULL) +
  scale_x_continuous(breaks = OFFS / FPS, labels = function(v) sprintf("%+.1f s", v)) +
  labs(title = "Do screen geometry and context help? Change in held-out log loss",
       subtitle = "Against the four-player logistic model with time to act (below zero = the added inputs helped; band: 95% interval from resampling whole games)",
       x = "Seconds relative to the screen tag", y = "Change in log loss") +
  theme_minimal(base_size = 11) + theme(legend.position = "top", panel.grid.minor = element_blank(),
                                        plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9))
ggsave(file.path(out_dir, "figures", "predictive_test.png"), pg, width = 10, height = 5.8, dpi = 150, bg = "white")
