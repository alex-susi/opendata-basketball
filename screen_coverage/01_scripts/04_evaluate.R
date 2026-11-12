## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 4: how good is the live model, against its baseline and against the version it replaced?
#   Rscript screen_coverage/01_scripts/04_evaluate.R
#
# Needs 01_logistic_baseline.R and 03_train_transformer.R (all ten folds) under the current rules, and the v1 snapshot
# screen_coverage/02_cache/v1_2026-11-11/ (v1's logistic_per_frame.rds and seqheads_<game>.rds folds).
#
# Models, all held out by game and scored on the same 1,463 screens and frames:
#   live transformer, v2       the time-aware transformer under the past-only rules (R/past_only.R)
#   live transformer, v1       the same model before 2026-11-12 (positions could be filled from up to two frames
#                              later; "so far" counted every earlier tag and leaned on the other games' mix)
#   logistic baseline, v2/v1   the four-player logistic model that, like the transformer, is never told when the
#                              screen comes ("no timing, + closeness")
#   logistic, no so far, v2    the baseline without the defense's calls so far
# Baselines without positions: league mix (held out), even split, the defense so far (v1: per screen; v2: at each
# frame). The logistic models that are told when the screen comes are not used: that is hindsight a live model does
# not have.
#
# Also: each call caught at -0.4 s, each defender's part read before the screen, the 33 screens left out of the scored
# set, and probability strips for the film-check screens (the list made by the archived snapshot step) with the
# worked example.
#
# Writes screen_coverage/03_outputs/evaluation/: window_summary.csv, paired_changes.csv, scores_by_frame.csv,
# paired_change_by_frame.csv, accuracy_by_frame.csv, defender_accuracy.csv, per_call_at_minus_0.4s.csv,
# left_out_screens.csv, strips.csv, figures/scores_by_frame.png, figures/strips/<nn>_<pick>.png.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "strips.R"))
cache_dir <- file.path(root, "screen_coverage", "02_cache")
v1_dir <- file.path(cache_dir, "v1_2026-11-11")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "evaluation")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)
FPS <- 25





## ═════════════════════════════════════════════════════════════════════════════
## 01 - BOTH VERSIONS ON THE SAME ROWS -----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# v2 rows define the comparison; v1's predictions are looked up by (screen, frame).
L2 <- load_logistic(root)
L1 <- readRDS(file.path(v1_dir, "logistic_per_frame.rds"))
X <- copy(L2$X)
P <- L2$P
CALLS <- L2$calls
r1 <- match(paste(X$id, X$off), paste(L1$X$id, L1$X$off))
stopifnot(!anyNA(r1), identical(L1$calls, CALLS))
# v1's live transformer, gathered from the snapshot's fold files into v1's row order.
seq_v1 <- matrix(NA_real_, nrow(L1$X), 5)
for (g in sort(unique(L1$X$game_id))) {
  o <- readRDS(file.path(v1_dir, "tf", sprintf("seqheads_%d.rds", g)))
  seq_v1[o$rows, ] <- o$prob
}
SQ2 <- load_seqheads(root)
TF1 <- "live transformer, v1 (until 2026-11-12)"
TF2 <- "live transformer, v2 (past-only)"
LB1 <- "logistic baseline, v1"
LB2 <- "logistic baseline, v2"
LB0 <- "logistic baseline without so far, v2"
prob <- list(seq_v1[r1, ], SQ2$prob, L1$prob[["pooled, no timing, + closeness"]][r1, ], L2$prob[["no timing, + closeness"]],
             L2$prob[["no timing, + closeness, no so far"]])
names(prob) <- c(TF1, TF2, LB1, LB2, LB0)
stopifnot(!anyNA(unlist(prob)))
# Baselines as probability matrices: even split, the defense so far in each version. The league mix (the other
# games' calls, held out) comes from 01_logistic_baseline.R as a log loss per screen.
sf1 <- as.matrix(L1$P[match(X$id, L1$P$id), paste0("so_far_", 1:5), with = FALSE])
sf2 <- as.matrix(X[, paste0("so_far_", 1:5), with = FALSE])
base <- list(`baseline: even split` = matrix(0.2, nrow(X), 5), `baseline: defense so far, v1` = sf1,
             `baseline: defense so far, v2` = sf2)
y <- match(X$call, CALLS)
ll_of <- function(Pm) -log(pmax(Pm[cbind(seq_len(nrow(X)), y)], 1e-12))
for (k in names(c(prob, base))) set(X, j = k, value = ll_of(c(prob, base)[[k]]))
X[, `baseline: league mix` := L2$lg_ll[idx]]
ALL <- c(names(prob), names(base), "baseline: league mix")          # every scored column of X
X[, window := fifelse(off < 0, "before the screen (-2.0 to -0.04 s)", "at and after the screen (0 to +1.0 s)")]

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





## ═════════════════════════════════════════════════════════════════════════════
## 02 - LOG LOSS BY WINDOW, AT -0.4 S, AND BY FRAME ----------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Each screen's frames are averaged within the window first, so every screen counts once.
ws <- X[, c(lapply(.SD, mean), list(game_id = game_id[1])), by = .(window, idx), .SDcols = ALL]
win <- melt(ws[, lapply(.SD, mean), by = window, .SDcols = ALL], id.vars = "window", variable.name = "model",
            value.name = "logloss")
at04 <- X[off == -10L, lapply(.SD, mean), .SDcols = ALL]
win <- merge(win, melt(at04, measure.vars = ALL, variable.name = "model", value.name = "logloss_at_minus_0.4s"),
             by = "model")
fwrite(win[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)][order(window, logloss)],
       file.path(out_dir, "window_summary.csv"))
cat("Log loss by window (lower is better), 1,463 screens:\n")
print(dcast(win, model ~ window, value.var = "logloss")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)])

# Paired changes, game bootstrap: what the rebuild changed, the live model against its baseline, and what the
# defense's calls so far add to the baseline.
PAIRS <- list(c(TF2, TF1, "live transformer: v2 minus v1"), c(LB2, LB1, "logistic baseline: v2 minus v1"),
              c(TF2, LB2, "v2: live transformer minus logistic baseline"),
              c(LB0, LB2, "v2 logistic baseline: without so far minus with"))
pairs <- rbindlist(lapply(PAIRS, function(pp) ws[, {
  d <- get(pp[1]) - get(pp[2])
  ci <- boot_ci(d, game_id)
  .(comparison = pp[3], change = round(ci[1], 4), lo = round(ci[2], 4), hi = round(ci[3], 4),
    games_lower = sum(tapply(d, game_id, mean) < 0), games = uniqueN(game_id))
}, by = window]))
fwrite(pairs, file.path(out_dir, "paired_changes.csv"))
cat("\nPaired changes in log loss (below zero = the first model is better; 95% game bootstrap):\n")
print(pairs)

# Mean log loss at every frame.
sc <- X[, lapply(.SD, mean), by = off, .SDcols = ALL][, t := off / FPS]
fwrite(sc[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "scores_by_frame.csv"))
cat("\nLog loss at selected moments:\n")
print(sc[off %in% c(-50, -25, -10, 0, 10, 25), c("t", TF1, TF2, LB2, LB0), with = FALSE][, lapply(.SD, round, 3)])





## ═════════════════════════════════════════════════════════════════════════════
## 03 - TOP CALL, EACH CALL, AND EACH DEFENDER ON HIS OWN ----------------------
## ═════════════════════════════════════════════════════════════════════════════

# The ball defender's and the big's part of each joint call.
BD_OF <- c("over", "over", "under", "under", "switch")
BIG_OF <- c("show", "soft", "soft", "show", "switch")
part_call <- function(Pm, of) {
  lv <- unique(of)
  lv[max.col(sapply(lv, function(l) rowSums(Pm[, of == l, drop = FALSE])), ties.method = "first")]
}
ACC <- c(prob[c(TF1, TF2, LB2)], list(`always over + show` = matrix(rep(c(1, 0, 0, 0, 0), each = nrow(X)), nrow(X))),
         base[c("baseline: defense so far, v1", "baseline: defense so far, v2")])
top <- lapply(ACC, function(Pm) max.col(Pm, ties.method = "first"))
acc <- rbindlist(lapply(names(ACC), function(m) X[, .(model = m, accuracy = mean(top[[m]][.I] == y[.I])), by = off]))
acc[, t := off / FPS]
fwrite(acc[, .(model, off, t, accuracy = round(accuracy, 4))], file.path(out_dir, "accuracy_by_frame.csv"))
cat("\nTop call right, at selected moments:\n")
print(dcast(acc[off %in% c(-25, -15, -10, -5, 0, 10)], model ~ t, value.var = "accuracy")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])
# Each call's share caught (recall) at -0.4 s.
w04 <- X$off == -10L
pc <- rbindlist(lapply(c(TF1, TF2, LB2), function(m) data.table(model = m, call = CALLS, screens = as.vector(table(factor(y[w04], 1:5))),
  caught = vapply(1:5, function(k) mean(top[[m]][w04][y[w04] == k] == k), 0))))
fwrite(pc[, caught := round(caught, 4)], file.path(out_dir, "per_call_at_minus_0.4s.csv"))
# Each defender before the screen: model parts against "always over" and the defense's habit for the big.
pre <- X$off < 0
dacc <- rbindlist(lapply(names(ACC), function(m) data.table(
  model = m, window = "before the screen", top_call = mean(top[[m]][pre] == y[pre]),
  ball_defender = mean(part_call(ACC[[m]][pre, ], BD_OF) == BD_OF[y[pre]]),
  big = mean(part_call(ACC[[m]][pre, ], BIG_OF) == BIG_OF[y[pre]]))))
fwrite(dacc[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "defender_accuracy.csv"))
cat("\nBefore the screen, share right:\n")
print(dacc[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])





## ═════════════════════════════════════════════════════════════════════════════
## 04 - THE SCREENS LEFT OUT OF THE SCORED SET ---------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Five-call screens whose four players are untracked somewhere from -2 s to +1 s: where the gap falls, and whether
# the possession starts after -2 s or ends before +1 s.
feat <- readRDS(file.path(cache_dir, "per_frame_features.rds"))
P5 <- feat$P[call %in% CALLS]
E <- feat$Fe[id %in% setdiff(P5$id, P$id)]
lo <- E[, .(missing_frames = sum(!tracked), first_missing_s = min(off[!tracked]) / FPS,
            last_missing_s = max(off[!tracked]) / FPS, tracked_at_tag = tracked[off == 0]), by = id]
lo <- merge(lo, P5[, .(id, game_id, f0, poss, call)], by = "id")
pe <- rbindlist(lapply(unique(lo$game_id), function(g) {
  readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))$poss[, .(poss, pf0 = f0, pf1 = f1)]
}))
lo <- merge(lo, pe, by = "poss", all.x = TRUE)
lo[, `:=`(gap_where = fifelse(first_missing_s >= 0, "after the tag", "before the tag"),
          possession_starts_after_minus_2s = pf0 > f0 - 50, possession_ends_before_plus_1s = pf1 < f0 + 25)]
fwrite(lo[order(game_id, f0), .(id, game_id, call, gap_where, missing_frames, first_missing_s, last_missing_s,
                                tracked_at_tag, possession_starts_after_minus_2s, possession_ends_before_plus_1s)],
       file.path(out_dir, "left_out_screens.csv"))
cat("\nScreens left out:", nrow(lo), "| gap before the tag:", lo[gap_where == "before the tag", .N],
    "| after the tag:", lo[gap_where == "after the tag", .N], "| tracked frames:", E[, sum(tracked)], "of", nrow(E), "\n")





## ═════════════════════════════════════════════════════════════════════════════
## 05 - FIGURE -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Top: log loss by frame for the live transformer and the logistic baseline, v1 dashed and v2 solid.
FAM_T <- "live transformer"
FAM_L <- "logistic baseline"
long <- melt(sc[, c("off", "t", TF1, TF2, LB1, LB2), with = FALSE], id.vars = c("off", "t"), variable.name = "series",
             value.name = "logloss")
long[, family := fifelse(series %in% c(TF1, TF2), FAM_T, FAM_L)]
long[, version := fifelse(series %in% c(TF1, LB1), "v1 (until 2026-11-12)", "v2 (past-only)")]
FCOL <- setNames(c("#c7374a", "#1f5fd1"), c(FAM_T, FAM_L))
bl <- data.table(label = c("league mix", "defense so far, v2"),
                 logloss = c(mean(X$`baseline: league mix`), mean(X$`baseline: defense so far, v2`)))
p1 <- ggplot(long, aes(t, logloss, colour = family, linetype = version)) +
  geom_hline(data = bl, aes(yintercept = logloss), colour = "#9a9a96", linetype = "dotted", inherit.aes = FALSE) +
  annotate("text", x = 0.98, y = bl$logloss, label = bl$label, hjust = 1, vjust = c(-0.5, 1.5), size = 3.2, colour = "#6b6b68") +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_line(linewidth = 0.8) +
  scale_colour_manual(values = FCOL, name = NULL) +
  scale_linetype_manual(values = c(`v1 (until 2026-11-12)` = "22", `v2 (past-only)` = "solid"), name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  guides(colour = guide_legend(nrow = 2), linetype = guide_legend(nrow = 2)) +
  labs(title = "Screen coverage: the live transformer and its logistic baseline, v2 against v1 on the same 1,463 screens",
       subtitle = "Held-out log loss (lower is better). Neither model is told when the screen comes. v2 inputs use only what had happened by each frame.",
       x = NULL, y = "Held-out log loss") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(size = 9))
# Bottom: the paired v2 - v1 change at each frame for both models, with game-bootstrap bands.
pcf <- rbindlist(lapply(list(c(TF2, TF1, FAM_T), c(LB2, LB1, FAM_L)), function(pp) X[, {
  ci <- boot_ci(get(pp[1]) - get(pp[2]), game_id)
  .(t = off[1] / FPS, family = pp[3], change = ci[1], lo = ci[2], hi = ci[3])
}, by = off]))
fwrite(pcf[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "paired_change_by_frame.csv"))
p2 <- ggplot(pcf, aes(t, change, colour = family, fill = family)) +
  geom_hline(yintercept = 0, colour = "grey40") +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.15, colour = NA) +
  geom_line(linewidth = 0.8) +
  scale_colour_manual(values = FCOL, name = NULL) +
  scale_fill_manual(values = FCOL, name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  labs(subtitle = "Paired change, v2 minus v1 (below zero = v2 better; band: 95% interval from resampling whole games)",
       x = "Seconds relative to the screen tag", y = "Change") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "none", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9))
ggsave(file.path(out_dir, "figures", "scores_by_frame.png"), p1 / p2 + plot_layout(heights = c(1.5, 1)),
       width = 11, height = 8.5, dpi = 150, bg = "white")





## ═════════════════════════════════════════════════════════════════════════════
## 06 - PROBABILITY STRIPS FOR THE FILM-CHECK SCREENS --------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The film list (which screens to watch) was made by the archived snapshot step; the forecast noted on each strip is
# now the live v2 model's own call at -0.4 s. Archetypes are labels on the strip only, never model inputs.
film_ids <- fread(file.path(root, "screen_coverage", "zz_Archive", "03_outputs", "film_check_4players.csv"))$id
ids <- unique(c("pick-188630-1-12", film_ids))
ids <- ids[ids %in% P$id]
k04 <- match(ids, X$id[w04])
r04 <- which(w04)[k04]
film <- data.table(id = ids, forecast_call = CALLS[top[[TF2]][r04]], forecast_p = SQ2$prob[cbind(r04, top[[TF2]][r04])],
                   right = top[[TF2]][r04] == y[r04])[id != "pick-188630-1-12"]
mem <- fread(file.path(root, "archetypes", "03_outputs", "offense_membership.csv"), select = c("pid", "archetype"))
PS <- copy(P)
PS[mem, on = .(h_canon = pid), h_arch := i.archetype]
PS[mem, on = .(s_canon = pid), s_arch := i.archetype]
PS[is.na(h_arch), h_arch := "unassigned"]
PS[is.na(s_arch), s_arch := "unassigned"]
draw_strips(X, SQ2$prob, PS, ids, film, "live time-aware transformer, v2 (past-only; never told when the screen comes)",
            file.path(out_dir, "strips.csv"), file.path(out_dir, "figures", "strips"), L2$offs, FPS)
cat("\nStrips drawn for", length(ids), "screens. Wrote", out_dir, "\n")
