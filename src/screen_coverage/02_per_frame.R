# Screen coverage, step 2: a prediction at every frame, so the probabilities update continuously.
#   Rscript src/screen_coverage/02_per_frame.R [--rebuild] [--workers=8]
#
# Step 1 scored four moments (-0.8, -0.4, 0, +0.4 s around the screen tag). Here the same kind of model is fitted at
# every frame (25 per second) from -2 s to +1 s: 76 separate models, each seeing only the positions at its own frame
# and 0.24 s before it. Strung together they give, for one screen, a probability for each call that updates frame
# by frame. Consecutive frames are nearly identical, so 76 predictions per screen are not 76 independent checks; the
# uncertainty still comes from resampling whole games.
#
# Inputs at each frame (the step-1 four-player model, which beat the ten-player one):
#   d_hs, d_bd, d_sd, d_def, bd_lvl, sd_lvl, h_lvl, s_hoop, bd_lvl_v, sd_lvl_v   (as in step 1)
#   sc_now        the shot clock AT THAT FRAME, from the tracking (step 1 used the value at the tag, which an early
#                 prediction would not know yet). Missing = 24.
#   defense so far   logs of this defense's earlier-call shares in the game (online, league mix worth 5 picks)
#   archetypes    the ball handler's and the screener's offensive archetype (outputs/archetypes/offense_membership.csv),
#                 one indicator each; an archetype with fewer than MIN_ARCH screens in that role is pooled as "other".
#                 The archetypes were clustered without any coverage information (the coverage-faced shares were
#                 built but never entered the clustering); part of each player's profile comes from the ten tracked
#                 games, a mild same-games overlap that does not contain the calls.
#
# Models, all leave-one-game-out, all scored on the same screens and frames:
#   4 players + so far                 one model per frame
#   4 players + so far + archetypes    one model per frame
#   pooled, no timing                  ONE model trained on every frame of the window at once, with no input saying
#                                      how far the screen is: the hindsight test. Each per-frame model knows "the
#                                      screen tag is exactly t seconds away"; a live system would not. If the pooled
#                                      model scores about as well, that knowledge is not doing the work. (Each frame of
#                                      a screen gets weight 1/76 in its fit, so the screens, not the frames, count.)
#   pooled, no timing, + closeness     the same, but every four-player measure is also multiplied by a closeness
#                                      weight from the visible handler-screener distance, so the model can let the
#                                      positions count more as the screen nears without being told the time. The
#                                      plain pooled model has one set of weights for -2 s and +1 s alike, so part of
#                                      its gap is inflexibility, not hindsight; this version separates the two.
#
# The screener's and defenders' identities still come from the tag: every result reads "given that this screen
# happens, with these four players".
#
# Smoothing in the strips: a trailing average over the last 0.2 s (5 frames), so a smoothed value never uses a
# later frame.
#
# Writes outputs/screen_coverage/per_frame/: scores_by_frame.csv, archetype_effect.csv, hindsight_test.csv,
# window_summary.csv, archetype_counts.csv, commitment_auc_by_frame.csv, strips.csv,
# figures/scores_by_frame.png, figures/strips/<nn>_<pick>.png. Features are cached in
# outputs/cache/screen_coverage/per_frame_features.rds (--rebuild recomputes them).

suppressPackageStartupMessages({ library(data.table); library(nnet); library(ggplot2); library(patchwork); library(parallel) })
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
targs <- commandArgs(TRUE)
REBUILD <- "--rebuild" %in% targs
hit <- grep("^--workers=", targs, value = TRUE)
WORKERS <- if (length(hit)) as.integer(sub("^--workers=", "", hit)) else 8L
out_dir <- file.path(root, "outputs", "screen_coverage", "per_frame")
cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
for (d in c(file.path(out_dir, "figures", "strips"), cache_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

FPS <- 25
FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M
OFFS <- -50:25                                   # frames relative to the tag: -2.0 s to +1.0 s
VLAG <- 6L
CALLS <- c("over + show", "over + soft", "under + soft", "under + show", "switch")
CALL_COLS <- c(`over + show` = "#2a78d6", `over + soft` = "#eb6834", `under + soft` = "#1baf7a",
               `under + show` = "#eda100", switch = "#e87ba4")
PRIOR_W <- 5
DECAY <- 1
MIN_ARCH <- 40L
SMOOTH <- 5L
hoop_dist <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)

games <- as.integer(jsonlite::fromJSON(file.path(root, "data", "matches.json"))$id)
bundle <- function(g) readRDS(file.path(root, "outputs", "cache", "explore", sprintf("bundle_%d.rds", g)))

pos_at <- function(B, frames, pids) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_, poss = NA_character_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    hit <- B$P[.(frames[miss] + d, pids[miss]), .(x, y, poss), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y, poss = hit$poss)]
  }
  out
}

# ---- features at every frame (cached) ----------------------------------------------------------------

feat_path <- file.path(cache_dir, "per_frame_features.rds")
if (REBUILD || !file.exists(feat_path)) {
  build_game <- function(g) {
    B <- bundle(g)
    p <- B$picks[, .(id, chance, f0, H = actor, BD = adef, S = screener, SD = sdef, cov, scov)]
    if (!nrow(p)) return(NULL)
    ev <- jsonlite::fromJSON(file.path(root, "data", "matches", g, paste0(g, "_dynamic_events.json")))$picks
    p[as.data.table(ev)[, .(id, def_team = defTeamId, period)], on = "id", `:=`(def_team = i.def_team, period = i.period)]
    p[B$ch, on = "chance", poss := i.poss]
    p[, `:=`(game_id = g, call = fifelse(cov %in% c("switch", "ice", "blitz"), cov, paste(cov, scov, sep = " + ")))]
    p[B$roster, on = .(H = pid), h_canon := i.canon]
    p[B$roster, on = .(S = pid), s_canon := i.canon]
    nm <- function(id) B$roster$name[match(id, B$roster$pid)]
    p[, `:=`(h_name = nm(H), s_name = nm(S), bd_name = nm(BD), sd_name = nm(SD))]
    fe <- rbindlist(lapply(OFFS, function(o) {
      f <- p$f0 + o
      now <- lapply(c(H = "H", S = "S", BD = "BD", SD = "SD"), function(r) pos_at(B, f, p[[r]]))
      bef <- lapply(c(H = "H", S = "S", BD = "BD", SD = "SD"), function(r) pos_at(B, f - VLAG, p[[r]]))
      ok <- Reduce(`&`, lapply(c(now, bef), function(h) !is.na(h$x) & !is.na(h$poss) & h$poss == p$poss))
      lv <- function(P, r) hoop_dist(P[[r]]$x, P[[r]]$y) - hoop_dist(P$S$x, P$S$y)
      dd <- function(P, a, b) sqrt((P[[a]]$x - P[[b]]$x)^2 + (P[[a]]$y - P[[b]]$y)^2)
      fr <- B$Fr[.(f), .(sc, gc), nomatch = NA]
      data.table(id = p$id, off = o, tracked = ok,
                 d_hs = dd(now, "H", "S"), d_bd = dd(now, "H", "BD"), d_sd = dd(now, "H", "SD"), d_def = dd(now, "BD", "SD"),
                 bd_lvl = lv(now, "BD"), sd_lvl = lv(now, "SD"), h_lvl = lv(now, "H"), s_hoop = hoop_dist(now$S$x, now$S$y),
                 bd_lvl_v = (lv(now, "BD") - lv(bef, "BD")) / (VLAG / FPS),
                 sd_lvl_v = (lv(now, "SD") - lv(bef, "SD")) / (VLAG / FPS),
                 sc_now = fr$sc, gc_now = fr$gc, frame = f)
    }))
    list(p = p, f = fe)
  }
  t0 <- Sys.time()
  built <- lapply(games, build_game)
  saveRDS(list(P = rbindlist(lapply(built, `[[`, "p"), fill = TRUE), Fe = rbindlist(lapply(built, `[[`, "f"))), feat_path)
  message(sprintf("Features built in %.0f s", as.numeric(Sys.time() - t0, units = "secs")))
}
cached <- readRDS(feat_path)
Pall <- cached$P[order(game_id, f0)]
Fe <- cached$Fe

# ---- the screens to score ---------------------------------------------------------------------------

P5 <- Pall[call %in% CALLS]
trk <- Fe[id %in% P5$id, .(all_frames = all(tracked)), by = id]
cat("Screens with one of the five calls:", nrow(P5), "| four players tracked at every frame from -2 s to +1 s:",
    trk[, sum(all_frames)], "\n")

# defense so far: computed over every five-call screen in order (tracked or not), then kept for the scored set
cnt <- function(v) as.numeric(table(factor(v, CALLS)))
SOFAR <- paste0("so_far_", seq_along(CALLS)); LSF <- paste0("lsf_", seq_along(CALLS))
P5[, (SOFAR) := NA_real_]
for (g in unique(P5$game_id)) {
  lg <- cnt(P5[game_id != g]$call); lg <- lg / sum(lg)
  for (dt in unique(P5[game_id == g]$def_team)) {
    r <- P5[game_id == g & def_team == dt, which = TRUE]
    for (j in seq_along(r)) {
      before <- if (j > 1) cnt(P5$call[r[seq_len(j - 1)]]) else rep(0, length(CALLS))
      set(P5, r[j], SOFAR, as.list((before + PRIOR_W * lg) / (sum(before) + PRIOR_W)))
    }
  }
}
for (k in seq_along(SOFAR)) set(P5, j = LSF[k], value = log(P5[[SOFAR[k]]]))
P <- P5[id %in% trk[all_frames == TRUE]$id]
cat("Scored set:", nrow(P), "screens x", length(OFFS), "frames\n")

# archetypes of the ball handler and the screener
mem <- fread(file.path(root, "data", "..", "outputs", "archetypes", "offense_membership.csv"), select = c("pid", "archetype"))
P[mem, on = .(h_canon = pid), h_arch := i.archetype]
P[mem, on = .(s_canon = pid), s_arch := i.archetype]
P[is.na(h_arch), h_arch := "unassigned"]; P[is.na(s_arch), s_arch := "unassigned"]
arch_counts <- rbind(P[, .(screens = .N), by = .(archetype = h_arch)][, role := "ball handler"],
                     P[, .(screens = .N), by = .(archetype = s_arch)][, role := "screener"])[order(role, -screens)]
setcolorder(arch_counts, "role")
pool <- function(v) { keep <- names(which(table(v) >= MIN_ARCH)); fifelse(v %in% keep, v, "other") }
P[, `:=`(h_grp = pool(h_arch), s_grp = pool(s_arch))]
arch_counts[, used_as := fifelse(screens >= MIN_ARCH, archetype, "other")]
fwrite(arch_counts, file.path(out_dir, "archetype_counts.csv"))
cat("\nArchetypes in the scored set (fewer than", MIN_ARCH, "screens in a role are pooled as 'other'):\n"); print(arch_counts)
# indicators, the most common level of each role as the reference
ind <- function(v, prefix) {
  lv <- names(sort(table(v), decreasing = TRUE))[-1]
  m <- sapply(lv, function(l) as.numeric(v == l)); colnames(m) <- paste0(prefix, make.names(lv)); m
}
AR <- cbind(ind(P$h_grp, "h_"), ind(P$s_grp, "s_"))
P <- cbind(P, AR)
ARCH <- colnames(AR)

GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "sc_now")
FEATS_A <- c(GEOM, LSF)
FEATS_B <- c(GEOM, LSF, ARCH)
# Hindsight test, fairer version: the pooled model may also learn that the positions matter more as the screen gets
# close, but only from what is visible at that frame (d_hs, the handler-screener distance): every four-player measure
# times a "closeness" weight 1 / (1 + d_hs / 5), which is about 1 at the screen and 0.25 at 15 ft.
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "sc_now")), "_close")
FEATS_P2 <- c(FEATS_A, "closeness", CLOSE)

X <- merge(Fe[id %in% P$id], P[, c("id", "game_id", "call", LSF, ARCH), with = FALSE], by = "id")
X[is.na(sc_now), sc_now := 24]
X[, idx := match(id, P$id)]
X[, closeness := 1 / (1 + d_hs / 5)]
for (v in setdiff(GEOM, c("d_hs", "sc_now"))) set(X, j = paste0(v, "_close"), value = X[[v]] * X$closeness)
setorder(X, off, idx)
y <- P$call

# ---- fits -------------------------------------------------------------------------------------------

fit_predict <- function(train, test, feats, w = NULL) {
  Xtr <- as.matrix(train[, ..feats]); mu <- colMeans(Xtr); sdv <- apply(Xtr, 2, sd); sdv[sdv == 0] <- 1
  dtr <- data.frame(y = factor(train$call, CALLS), scale(Xtr, mu, sdv))
  fit <- if (is.null(w)) multinom(y ~ ., data = dtr, decay = DECAY, trace = FALSE, maxit = 2000)
         else multinom(y ~ ., data = dtr, weights = w, decay = DECAY, trace = FALSE, maxit = 2000)
  predict(fit, newdata = data.frame(scale(as.matrix(test[, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
}
per_frame <- function(o, feats) {
  d <- X[off == o]
  Pm <- matrix(NA_real_, nrow(d), length(CALLS))
  for (g in unique(d$game_id)) Pm[d$game_id == g, ] <- fit_predict(d[game_id != g], d[game_id == g], feats)
  Pm
}
pooled_fold <- function(g, feats) {
  tr <- X[game_id != g]; te <- X[game_id == g]
  list(rows = which(X$game_id == g), P = fit_predict(tr, te, feats, w = rep(1 / length(OFFS), nrow(tr))))
}

t0 <- Sys.time()
cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({ library(data.table); library(nnet) })))
clusterExport(cl, c("X", "CALLS", "DECAY", "OFFS", "fit_predict", "per_frame", "pooled_fold", "FEATS_A", "FEATS_B", "FEATS_P2"))
pa <- parLapply(cl, OFFS, function(o) per_frame(o, FEATS_A))
pb <- parLapply(cl, OFFS, function(o) per_frame(o, FEATS_B))
pp <- parLapply(cl, sort(unique(X$game_id)), function(g) pooled_fold(g, FEATS_A))
pp2 <- parLapply(cl, sort(unique(X$game_id)), function(g) pooled_fold(g, FEATS_P2))
stopCluster(cl)
cat(sprintf("\nFits done in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))

PA <- do.call(rbind, pa); PB <- do.call(rbind, pb)              # rows in X order (off, then screen)
PP <- matrix(NA_real_, nrow(X), length(CALLS))
for (r in pp) PP[r$rows, ] <- r$P
PP2 <- matrix(NA_real_, nrow(X), length(CALLS))
for (r in pp2) PP2[r$rows, ] <- r$P
ll_of <- function(Pm, yy) -log(pmax(Pm[cbind(seq_along(yy), match(yy, CALLS))], 1e-12))
X[, `:=`(ll_a = ll_of(PA, call), ll_b = ll_of(PB, call), ll_p = ll_of(PP, call), ll_p2 = ll_of(PP2, call))]

# baselines that ignore positions
lg_ll <- numeric(nrow(P))
for (g in unique(P$game_id)) {
  lg <- cnt(P5[game_id != g]$call); lg <- lg / sum(lg)
  lg_ll[P$game_id == g] <- -log(lg[match(y[P$game_id == g], CALLS)])
}
sf_ll <- -log(as.matrix(P[, ..SOFAR])[cbind(seq_len(nrow(P)), match(y, CALLS))])

# ---- scores -----------------------------------------------------------------------------------------

boot_ci <- function(score, game, reps = 2000L) {
  set.seed(1); s <- split(score, game); sums <- vapply(s, sum, 0); ns <- lengths(s)
  b <- replicate(reps, { k <- sample(names(s), length(s), TRUE); sum(sums[k]) / sum(ns[k]) })
  c(mean(score), quantile(b, c(0.025, 0.975)))
}
M_A <- "4 players + so far"; M_B <- "+ archetypes"; M_P <- "pooled, no timing"; M_P2 <- "pooled, no timing, + closeness"
sc_tab <- X[, .(t = off[1] / FPS, `4 players + so far` = mean(ll_a), `+ archetypes` = mean(ll_b),
                `pooled, no timing` = mean(ll_p), `pooled, no timing, + closeness` = mean(ll_p2)), by = off]
fwrite(sc_tab[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "scores_by_frame.csv"))

paired <- function(col) X[, { ci <- boot_ci(get(col) - ll_a, game_id); .(t = off[1] / FPS, change = ci[1], lo = ci[2], hi = ci[3]) }, by = off]
arch_eff <- paired("ll_b"); hind <- paired("ll_p"); hind2 <- paired("ll_p2")
fwrite(arch_eff[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "archetype_effect.csv"))
fwrite(rbind(hind[, model := M_P], hind2[, model := M_P2])[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)],
       file.path(out_dir, "hindsight_test.csv"))

# window summaries: forecast (-2 s to just before the tag) and recognition (the tag to +1 s); a screen's frames are
# averaged first, so each screen counts once
X[, window := fifelse(off < 0, "forecast: -2.0 to -0.04 s", "recognition: 0 to +1.0 s")]
ws <- X[, .(ll_a = mean(ll_a), ll_b = mean(ll_b), ll_p = mean(ll_p), ll_p2 = mean(ll_p2), game_id = game_id[1]), by = .(window, idx)]
win <- ws[, {
  b1 <- boot_ci(ll_b - ll_a, game_id); b2 <- boot_ci(ll_p - ll_a, game_id); b3 <- boot_ci(ll_p2 - ll_a, game_id)
  .(screens = .N, `4 players + so far` = round(mean(ll_a), 4), `+ archetypes` = round(mean(ll_b), 4),
    `pooled, no timing` = round(mean(ll_p), 4),
    archetypes_change = round(b1[1], 4), archetypes_lo = round(b1[2], 4), archetypes_hi = round(b1[3], 4),
    no_timing_change = round(b2[1], 4), no_timing_lo = round(b2[2], 4), no_timing_hi = round(b2[3], 4),
    `pooled, no timing, + closeness` = round(mean(ll_p2), 4),
    closeness_change = round(b3[1], 4), closeness_lo = round(b3[2], 4), closeness_hi = round(b3[3], 4))
}, by = window]
win <- rbind(win, data.table(window = c("baseline: league", "baseline: defense so far"), screens = nrow(P),
                             `4 players + so far` = round(c(mean(lg_ll), mean(sf_ll)), 4)), fill = TRUE)
fwrite(win, file.path(out_dir, "window_summary.csv"))
cat("\nAverage log loss by window, with paired changes vs '4 players + so far' (95% game bootstrap):\n"); print(win)
cat("\nAt selected frames:\n")
print(merge(sc_tab, arch_eff[, .(off, arch_change = round(change, 4))], by = "off")[
  , pooled_gap := round(`pooled, no timing` - `4 players + so far`, 4)][off %in% c(-50, -38, -25, -20, -10, 0, 10, 25)][
  , lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)])

# commitment: single-measure AUC at every frame
auc <- function(x, g) { r <- rank(x); n1 <- sum(g); n0 <- sum(!g); (sum(r[g]) - n1 * (n1 + 1) / 2) / (n1 * n0) }
X[P, on = .(id), `:=`(cov = i.cov, scov = i.scov)]
com <- X[, .(t = off[1] / FPS,
             over_vs_under_bd_lvl = auc(bd_lvl[cov %in% c("over", "under")], cov[cov %in% c("over", "under")] == "over"),
             show_vs_soft_sd_lvl = auc(sd_lvl[cov %in% c("over", "under")], scov[cov %in% c("over", "under")] == "show")), by = off]
fwrite(com[, lapply(.SD, function(v) round(v, 3))], file.path(out_dir, "commitment_auc_by_frame.csv"))

# ---- figure: scores by frame ----------------------------------------------------------------------

long <- melt(sc_tab, id.vars = c("off", "t"), variable.name = "model", value.name = "logloss")
long[, model := factor(model, levels = c(M_A, M_B, M_P, M_P2))]
MCOL <- c(`4 players + so far` = "#2a78d6", `+ archetypes` = "#eb6834", `pooled, no timing` = "#1baf7a",
          `pooled, no timing, + closeness` = "#6250d6")
base <- data.table(model = c("league", "defense so far"), logloss = c(mean(lg_ll), mean(sf_ll)))
p1 <- ggplot(long, aes(t, logloss, colour = model)) +
  geom_hline(data = base, aes(yintercept = logloss), linetype = "dashed", colour = c("#9a9a96", "#c98500")) +
  annotate("text", x = 0.98, y = base$logloss, label = base$model, hjust = 1, vjust = c(-0.5, 1.5), size = 3.2,
           colour = c("#9a9a96", "#c98500")) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_line(linewidth = 0.8) +
  scale_colour_manual(values = MCOL, name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  labs(title = "Screen coverage predicted at every frame: held-out log loss (lower is better)",
       subtitle = sprintf("%s screens, all four players tracked from -2 s to +1 s; each frame is its own model except 'pooled, no timing' (one model, never told when the screen comes).",
                          format(nrow(P), big.mark = ",")),
       x = NULL, y = "Held-out log loss") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(size = 9))
dl <- rbind(arch_eff[, .(t, change, lo, hi, what = "+ archetypes minus 4 players + so far")],
            hind[, .(t, change, lo, hi, what = "pooled, no timing minus 4 players + so far")],
            hind2[, .(t, change, lo, hi, what = "pooled, no timing, + closeness minus 4 players + so far")])
p2 <- ggplot(dl, aes(t, change, colour = what, fill = what)) +
  geom_hline(yintercept = 0, colour = "grey40") + geom_vline(xintercept = 0, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.18, colour = NA) + geom_line(linewidth = 0.8) +
  scale_colour_manual(values = c("#eb6834", "#1baf7a", "#6250d6"), name = NULL) +
  guides(colour = guide_legend(ncol = 1), fill = guide_legend(ncol = 1)) +
  scale_fill_manual(values = c("#eb6834", "#1baf7a", "#6250d6"), name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  labs(subtitle = "Paired change in log loss vs '4 players + so far' (below zero = better; band: 95% interval from resampling whole games)",
       x = "Seconds relative to the screen tag", y = "Change") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9))
ggsave(file.path(out_dir, "figures", "scores_by_frame.png"), p1 / p2 + plot_layout(heights = c(1.4, 1)),
       width = 11, height = 8.5, dpi = 150, bg = "white")

# ---- probability strips for the film-check screens ----------------------------------------------------

STRIP_MODEL <- if (win[window %like% "forecast", `+ archetypes` < `4 players + so far`]) M_B else M_A
PS <- if (STRIP_MODEL == M_B) PB else PA
film <- fread(file.path(root, "outputs", "screen_coverage", "film_check_4players.csv"))
strip_ids <- unique(c("pick-188630-1-12", film$id))
strip_ids <- strip_ids[strip_ids %in% P$id]
S <- X[id %in% strip_ids, .(id, off, t = off / FPS, frame, gc_now, sc_now, bd_lvl, sd_lvl)]
S <- cbind(S, as.data.table(PS[X$id %in% strip_ids, , drop = FALSE]))
setnames(S, paste0("V", seq_along(CALLS)), CALLS)
setorder(S, id, off)
for (cl_ in CALLS) S[, (paste0(cl_, " (smoothed)")) := frollmean(get(cl_), SMOOTH, align = "right", adaptive = FALSE), by = id]
S[P, on = "id", `:=`(call = i.call, poss = i.poss, h_name = i.h_name, s_name = i.s_name, bd_name = i.bd_name,
                     sd_name = i.sd_name, period = i.period, h_arch = i.h_arch, s_arch = i.s_arch)]
fwrite(S[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "strips.csv"))

clock <- function(gc, per) ifelse(is.na(gc), "?", sprintf("Q%d %d:%02d", per, floor(gc / 60), floor(gc %% 60)))
unlink(list.files(file.path(out_dir, "figures", "strips"), full.names = TRUE))
last <- function(s) sub(".* ", "", s)
for (k in seq_along(strip_ids)) {
  s <- S[id == strip_ids[k]]
  info <- s[off == 0]
  lab_film <- if (strip_ids[k] %in% film$id) {
    f <- film[id == strip_ids[k]]
    sprintf("Film check: the step-1 model's -0.4 s call was %s (%.0f%%), %s.", f$forecast_call, 100 * f$forecast_p,
            if (f$right) "right" else "wrong")
  } else "Worked example."
  stack <- function(cols, ttl) {
    d <- melt(s[, c("t", cols), with = FALSE], id.vars = "t", variable.name = "call", value.name = "p")
    d[, call := factor(sub(" \\(smoothed\\)", "", call), levels = rev(CALLS))]
    ggplot(d[!is.na(p)], aes(t, p, fill = call)) + geom_area(colour = "white", linewidth = 0.25) +
      geom_vline(xintercept = 0, colour = "grey15", linetype = "dashed") +
      scale_fill_manual(values = CALL_COLS, breaks = CALLS, name = NULL) +
      scale_y_continuous(labels = function(v) paste0(100 * v, "%"), expand = c(0, 0)) +
      scale_x_continuous(limits = range(OFFS) / FPS, breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v), expand = c(0, 0)) +
      labs(subtitle = ttl, x = NULL, y = NULL) + theme_minimal(base_size = 10.5) +
      theme(panel.grid.minor = element_blank(), legend.position = "top", plot.subtitle = element_text(size = 9.5))
  }
  a <- stack(paste0(CALLS, " (smoothed)"), "Probability of each call, smoothed (average of the last 0.2 s; never uses a later frame)")
  b <- stack(CALLS, "Raw, frame by frame") + theme(legend.position = "none")
  lv <- melt(s[, .(t, `ball defender's level (bd_lvl)` = bd_lvl, `big's level (sd_lvl)` = sd_lvl)], id.vars = "t")
  c3 <- ggplot(lv, aes(t, value, colour = variable)) + geom_hline(yintercept = 0, colour = "grey40") +
    geom_vline(xintercept = 0, colour = "grey15", linetype = "dashed") + geom_line(linewidth = 0.8) +
    scale_colour_manual(values = c("#e34948", "#6250d6"), name = NULL) +
    scale_x_continuous(limits = range(OFFS) / FPS, breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v), expand = c(0, 0)) +
    labs(subtitle = "The raw positions: feet above (+) or below (-) the screener's distance from the hoop",
         x = "Seconds relative to the screen tag (dashed line)", y = "ft") +
    theme_minimal(base_size = 10.5) + theme(legend.position = "top", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9.5))
  g <- a / b / c3 + plot_layout(heights = c(2, 1, 1.2)) +
    plot_annotation(title = sprintf("Called %s: %s (%s) screens for %s (%s)", toupper(info$call), last(info$s_name), info$s_arch,
                                    last(info$h_name), info$h_arch),
                    subtitle = sprintf("%s guards the ball, %s guards the screener. Tag at %s, shot clock %.0f. Dashboard: #/play/%s\n%s Model: %s.",
                                       last(info$bd_name), last(info$sd_name), clock(info$gc_now, info$period),
                                       info$sc_now, info$poss, lab_film, STRIP_MODEL),
                    theme = theme(plot.title = element_text(face = "bold", size = 13), plot.subtitle = element_text(size = 9.5)))
  ggsave(file.path(out_dir, "figures", "strips", sprintf("%02d_%s.png", k - 1, strip_ids[k])), g,
         width = 11, height = 8, dpi = 140, bg = "white")
}
cat("\nStrips drawn with:", STRIP_MODEL, "for", length(strip_ids), "screens\n")

# ---- export for the play viewer: live coverage probabilities -------------------------------------------
# web/public/data/coverage_frames.json, read by the viewer's Coverage Read card (web/src/components/Annotations.svelte).
# Per possession, every scored screen with its tag frame, the four players, the call, and the held-out probability of
# each call (whole percent) at every frame from -2 s to +1 s, raw (the card smooths them itself over the last 0.2 s).
web_model <- M_A
PW <- if (web_model == M_B) PB else PA
ex <- lapply(split(seq_len(nrow(X)), X$idx), function(r) r[order(X$off[r])])
screens <- lapply(seq_len(nrow(P)), function(k) {
  r <- ex[[as.character(k)]]
  list(id = P$id[k], f0 = P$f0[k], h = P$H[k], s = P$S[k], bd = P$BD[k], sd = P$SD[k], call = P$call[k],
       p = lapply(seq_along(CALLS), function(j) as.integer(round(100 * PW[r, j]))))
})
by_poss <- split(screens, P$poss)
jsonlite::write_json(list(model = web_model, smooth_frames = SMOOTH, offsets = range(OFFS), calls = CALLS,
                          generated = format(Sys.time(), "%Y-%m-%d %H:%M"), possessions = by_poss),
                     file.path(root, "web", "public", "data", "coverage_frames.json"), auto_unbox = TRUE)
cat("Wrote web/public/data/coverage_frames.json:", length(screens), "screens in", length(by_poss), "possessions\n")
