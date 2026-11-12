## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 1: the screens, their frame rows, and the logistic baseline.
#   Rscript screen_coverage/01_scripts/01_logistic_baseline.R [--rebuild] [--workers=8]
#
# Builds the rows every later step uses: one per scored screen and frame from -2 s to +1 s around the screen tag
# (25 per second). It then fits the baseline the live transformer is compared with: a multinomial logistic model that,
# like the transformer, is NEVER told when the screen comes. (Until 2026-11-12 the reference was a logistic model with
# one fit per frame offset, which knows "the screen is exactly t seconds away"; that is hindsight a live system does
# not have, so it is no longer used. It and the other per-frame variants are in zz_Archive/.)
#
# Inputs at each frame, from the four players of the screen (ball handler, screener, their two defenders), all
# past-only (R/past_only.R):
#   d_hs, d_bd, d_sd, d_def   distances: handler-screener, handler-his defender, handler-screener's defender, between
#                             the two defenders (ft)
#   bd_lvl, sd_lvl, h_lvl     level: distance from the hoop minus the screener's (+ = above the screen, - = below)
#   s_hoop                    the screener's distance from the hoop
#   bd_lvl_v, sd_lvl_v        how fast each defender's level is changing over the last 0.24 s (ft/s)
#   tta_now                   time to act: the shot clock or the game clock, whichever runs out first, capped at 24 s
#   defense so far            logs of this defense's earlier-call shares in the game AT THAT FRAME: only screens whose
#                             call was readable by then (1 s after their tag) count, shrunk toward an even split (20%
#                             each) worth 5 screens; no other game's calls enter (so_far_shares)
#   closeness                 1 / (1 + d_hs / 5): about 1 at the screen and 0.25 at 15 ft. Every four-player measure
#                             is also entered times closeness, so the positions can count more as the screen nears
#                             without the model being told the time.
#
# Models, one fit per held-out game on every frame of the other nine (each frame weighted 1/76 so screens count
# equally), scored on the same screens and frames:
#   no timing, + closeness             the baseline
#   no timing, + closeness, no so far  the same without the defense's calls so far (how much they add)
#
# Every result reads "given that this screen happens, with these four players": the screen and its players come from
# the tag. The scored set is the screens whose four players are tracked at every frame from -2 s to +1 s.
#
# Writes screen_coverage/03_outputs/logistic/: window_summary.csv, scores_by_frame.csv. Caches the four-player
# measures in screen_coverage/02_cache/per_frame_features.rds (--rebuild recomputes them) and the screens, rows
# and predictions in screen_coverage/02_cache/logistic_per_frame.rds.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(parallel)
})
# Command-line options: --rebuild recomputes the cached features; --workers sets the number of parallel fits.
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
targs <- commandArgs(TRUE)
REBUILD <- "--rebuild" %in% targs
hit <- grep("^--workers=", targs, value = TRUE)
WORKERS <- if (length(hit)) as.integer(sub("^--workers=", "", hit)) else 8L
out_dir <- file.path(root, "screen_coverage", "03_outputs", "logistic")
cache_dir <- file.path(root, "screen_coverage", "02_cache")
for (d in c(out_dir, cache_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# Past-only lookups and the defense-so-far shares (also defines FPS, HOOP_X, hoop_dist, PRIOR_W, PAST_ONLY_RULES).
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
# OFFS spans -2 s to +1 s around the tag; VLAG is the velocity lag in frames; DECAY is the logistic penalty.
OFFS <- -50:25
VLAG <- 6L
CALLS <- c("over + show", "over + soft", "under + soft", "under + show", "switch")
DECAY <- 1

games <- as.integer(jsonlite::fromJSON(file.path(root, "data", "matches.json"))$id)
bundle <- function(g) readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - FOUR-PLAYER MEASURES AT EVERY FRAME (CACHED) ---------------------------
## ═════════════════════════════════════════════════════════════════════════════

feat_path <- file.path(cache_dir, "per_frame_features.rds")
# Build once and cache: for each game, every screen's four players measured at every frame offset. A cache built
# under other lookup rules is rebuilt.
stale <- file.exists(feat_path) && !identical(readRDS(feat_path)$rules, PAST_ONLY_RULES)
if (REBUILD || stale || !file.exists(feat_path)) {
  # One game: the picks with their call and names, then the four-player measures at each offset.
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
    # One offset: positions at the frame and VLAG frames earlier, past-only. Tracked only when all eight lookups are
    # in the screen's possession.
    fe <- rbindlist(lapply(OFFS, function(o) cbind(off = o, four_player_features(B, p, p$f0 + o, VLAG))))
    setcolorder(fe, c("id", "off"))
    list(p = p, f = fe)
  }
  t0 <- Sys.time()
  built <- lapply(games, build_game)
  saveRDS(list(P = rbindlist(lapply(built, `[[`, "p"), fill = TRUE), Fe = rbindlist(lapply(built, `[[`, "f")),
               rules = PAST_ONLY_RULES), feat_path)
  message(sprintf("Features built in %.0f s", as.numeric(Sys.time() - t0, units = "secs")))
}
# Screens in game order, and their per-frame measures.
cached <- readRDS(feat_path)
Pall <- cached$P[order(game_id, f0)]
Fe <- cached$Fe





## ═════════════════════════════════════════════════════════════════════════════
## 02 - THE SCREENS AND FRAME ROWS ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Every five-call screen counts toward "so far"; the scored ones are tracked at every frame of the window.
P5 <- Pall[call %in% CALLS]
trk <- Fe[id %in% P5$id, .(all_frames = all(tracked)), by = id]
cat("Screens with one of the five calls:", nrow(P5), "| four players tracked at every frame from -2 s to +1 s:",
    trk[, sum(all_frames)], "\n")
cat("Position lookups filled from an earlier frame in the scored rows:",
    Fe[id %in% trk[all_frames == TRUE]$id, sum(n_filled)], "\n")
cnt <- function(v) as.numeric(table(factor(v, CALLS)))
SOFAR <- paste0("so_far_", seq_along(CALLS))
LSF <- paste0("lsf_", seq_along(CALLS))
P <- P5[id %in% trk[all_frames == TRUE]$id]
cat("Scored set:", nrow(P), "screens x", length(OFFS), "frames\n")

# Inputs: the four players' geometry, time to act, closeness and its interactions, and the defense so far.
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
FEATS <- c(GEOM, LSF, "closeness", CLOSE)
FEATS_0 <- c(GEOM, "closeness", CLOSE)

# One row per screen and frame: measures and call.
X <- merge(Fe[id %in% P$id], P[, .(id, game_id, call, def_team, f0)], by = "id")
# Time to act is the earlier of the shot clock and the game clock, capped at 24 s.
X[, tta_now := pmin(sc_now, gc_now, 24, na.rm = TRUE)]
X[is.na(sc_now), sc_now := 24]
X[, idx := match(id, P$id)]
X[, closeness := 1 / (1 + d_hs / 5)]
for (v in setdiff(GEOM, c("d_hs", "tta_now"))) set(X, j = paste0(v, "_close"), value = X[[v]] * X$closeness)
setorder(X, off, idx)

# Defense so far at each row's own frame (R/past_only.R, so_far_shares). Shares and their logs go on the row.
SF <- so_far_shares(P5, X, CALLS)
for (k in seq_along(CALLS)) {
  set(X, j = SOFAR[k], value = SF[, k])
  set(X, j = LSF[k], value = log(SF[, k]))
}
X[, n_so_far := attr(SF, "n_counted")]
cat("Earlier calls counted per row, mean at -2 s and at +1 s:", round(X[off == min(OFFS), mean(n_so_far)], 1),
    round(X[off == max(OFFS), mean(n_so_far)], 1), "\n")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - FITS -------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Multinomial logit on inputs standardised with the training rows, weighted. Returns the test rows' probabilities.
fit_predict <- function(train, test, feats, w) {
  Xtr <- as.matrix(train[, ..feats])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  dtr <- data.frame(y = factor(train$call, CALLS), scale(Xtr, mu, sdv))
  fit <- multinom(y ~ ., data = dtr, weights = w, decay = DECAY, trace = FALSE, maxit = 2000)
  predict(fit, newdata = data.frame(scale(as.matrix(test[, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
}
# One held-out game: every frame of the other games at once, each weighted 1/76 so that screens count equally.
fold <- function(g, feats) {
  tr <- X[game_id != g]
  list(rows = which(X$game_id == g), P = fit_predict(tr, X[game_id == g], feats, w = rep(1 / length(OFFS), nrow(tr))))
}

# Fit both models' ten folds in parallel worker processes and collect the predictions in X's row order.
t0 <- Sys.time()
cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})))
clusterExport(cl, c("X", "CALLS", "DECAY", "OFFS", "fit_predict", "fold", "FEATS", "FEATS_0"))
gs <- sort(unique(X$game_id))
f1 <- parLapply(cl, gs, function(g) fold(g, FEATS))
f0 <- parLapply(cl, gs, function(g) fold(g, FEATS_0))
stopCluster(cl)
cat(sprintf("\nFits done in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
gather <- function(fl) {
  Pm <- matrix(NA_real_, nrow(X), length(CALLS))
  for (r in fl) Pm[r$rows, ] <- r$P
  Pm
}
PL <- gather(f1)
PL0 <- gather(f0)

# Baselines that ignore positions. League: the other games' mix (a held-out reference, never a model input). Even
# split: 20% each. Defense so far: the shares on each row, at that row's frame.
lg_ll <- numeric(nrow(P))
for (g in unique(P$game_id)) {
  lg <- cnt(P5[game_id != g]$call)
  lg <- lg / sum(lg)
  lg_ll[P$game_id == g] <- -log(lg[match(P$call[P$game_id == g], CALLS)])
}
even_ll <- log(length(CALLS))
sf_ll <- -log(as.matrix(X[, ..SOFAR])[cbind(seq_len(nrow(X)), match(X$call, CALLS))])

# The screens, the frame rows and both models' predictions, in X's row order (used by every later step).
M_L <- "no timing, + closeness"
M_L0 <- "no timing, + closeness, no so far"
saveRDS(list(P = P, X = X, prob = setNames(list(PL, PL0), c(M_L, M_L0)), lg_ll = lg_ll, even_ll = even_ll,
             sf_ll = sf_ll, calls = CALLS, offs = OFFS, rules = PAST_ONLY_RULES),
        file.path(cache_dir, "logistic_per_frame.rds"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - SCORES -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Mean with a 95% interval from resampling whole games.
boot_ci <- function(score, game, reps = 2000L) {
  set.seed(1)
  s <- split(score, game)
  sums <- vapply(s, sum, 0)
  ns <- lengths(s)
  b <- replicate(reps, {
    k <- sample(names(s), length(s), TRUE)
    sum(sums[k]) / sum(ns[k])
  })
  c(mean(score), quantile(b, c(0.025, 0.975)))
}
ll_of <- function(Pm) -log(pmax(Pm[cbind(seq_len(nrow(X)), match(X$call, CALLS))], 1e-12))
X[, `:=`(ll_l = ll_of(PL), ll_l0 = ll_of(PL0), ll_sf = sf_ll)]
sc_tab <- X[, .(t = off[1] / FPS, baseline = mean(ll_l), no_so_far = mean(ll_l0), defense_so_far = mean(ll_sf)), by = off]
setnames(sc_tab, c("baseline", "no_so_far"), c(M_L, M_L0))
fwrite(sc_tab[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "scores_by_frame.csv"))

# Window summaries: before the screen (-2 s to just before the tag) and at and after it (the tag to +1 s); a screen's
# frames are averaged first, so each screen counts once.
X[, window := fifelse(off < 0, "before the screen (-2.0 to -0.04 s)", "at and after the screen (0 to +1.0 s)")]
ws <- X[, .(ll_l = mean(ll_l), ll_l0 = mean(ll_l0), ll_sf = mean(ll_sf), game_id = game_id[1]), by = .(window, idx)]
win <- ws[, {
  b <- boot_ci(ll_l0 - ll_l, game_id)
  .(screens = .N, baseline = round(mean(ll_l), 4), no_so_far = round(mean(ll_l0), 4),
    no_so_far_minus_baseline = round(b[1], 4), lo = round(b[2], 4), hi = round(b[3], 4),
    games_so_far_helps = sum(tapply(ll_l0 - ll_l, game_id, mean) > 0), defense_so_far_alone = round(mean(ll_sf), 4),
    league_mix = round(mean(lg_ll), 4), even_split = round(even_ll, 4))
}, by = window]
setnames(win, c("baseline", "no_so_far"), c(M_L, M_L0))
fwrite(win, file.path(out_dir, "window_summary.csv"))
cat("\nAverage log loss by window; the change from dropping the defense so far (95% game bootstrap):\n")
print(win)
