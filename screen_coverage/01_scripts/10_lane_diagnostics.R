## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, lane experiment: why did the roll-lane inputs not help? (added 2026-11-15)
#   Rscript screen_coverage/01_scripts/10_lane_diagnostics.R [--workers=8]
#
# Needs 01_logistic_baseline.R and 02_build_sequences.R --variant=B. Two checks that separate two explanations:
#   (a) the helpers' distance to the roll lane says little about the big's call (a weak basketball link), or
#   (b) it does say something, but the transformer already works it out from the positions it sees.
#
# Nearest helper: at each prediction row's own frame, the off-ball defender (of the three) closest to the roll lane,
# among those with a valid lane value; his gap (ft) and closing speed (ft/s), as in variant B.
#
# 1. Descriptive: the big's call (show, drop, switch) by the nearest helper's gap and by his closing speed, at -0.8 s
#    and -0.4 s, with 95% Wilson intervals. And a held-out version: a multinomial of the big's call on the gap alone
#    against one with no inputs, leave one game out, scored on the held-out game (game bootstrap).
# 2. The logistic baseline (01_logistic_baseline.R, "no timing, + closeness"; it sees only the four screen players)
#    refit with the nearest helper's gap added (and its closeness interaction), and again with his closing speed too.
#    Same rows, folds, weights and penalty. If the gap helps the logistic but did not help the transformer, the
#    transformer had already learned it (b); if it helps neither, the link is weak (a).
#
# Writes screen_coverage/03_outputs/experiments/lanes/diagnostics/: call_rates_by_gap.csv, call_rates_by_closing.csv,
# gap_alone_heldout.csv, logistic_plus_gap.csv, logistic_plus_gap_by_game.csv, figures/call_rates_by_gap.png.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(parallel)
  library(ggplot2)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
for (f in c("past_only.R", "lane_variants.R")) {
  source(file.path(root, "screen_coverage", "01_scripts", "R", f))
}
hit <- grep("^--workers=", commandArgs(TRUE), value = TRUE)
WORKERS <- if (length(hit)) as.integer(sub("^--workers=", "", hit)) else 8L
out_dir <- file.path(lane_out_dir(root), "diagnostics")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)
BOOT_SEED <- 20261115L
DECAY <- 1                                         # as in 01_logistic_baseline.R





## ═════════════════════════════════════════════════════════════════════════════
## 01 - ROWS, THE BIG'S CALL AND THE NEAREST HELPER ----------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
X <- copy(L$X)
CALLS <- L$calls
OFFS <- L$offs
BIG_OF <- c("show", "drop", "drop", "show", "switch")
BIG_LV <- c("show", "drop", "switch")
X[, big := BIG_OF[match(call, CALLS)]]

# Each row's three off-ball defenders at its own frame: the nearest valid one to the lane, and his closing speed.
SB <- readRDS(file.path(lane_dir(root, "B"), "sequences.rds"))
stopifnot(identical(SB$screen_ids, L$P$id))
k <- match(X$off, SB$base_offs)
D <- sapply(1:3, function(h) SB$roll_audit$distance[cbind(X$idx, k, h)])
C <- sapply(1:3, function(h) SB$roll_audit$closing[cbind(X$idx, k, h)])
rm(SB)
near <- apply(D, 1, function(d) if (all(is.na(d))) NA_integer_ else which.min(d))
X[, help_gap := D[cbind(seq_len(.N), near)]]
X[, help_closing := C[cbind(seq_len(.N), near)]]
X[, help_valid := rowSums(!is.na(D))]
cat("Rows with no valid helper:", X[is.na(help_gap), .N], "of", nrow(X), "\n")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - DESCRIPTIVE: THE BIG'S CALL BY THE NEAREST HELPER ----------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Wilson 95% interval for k of n.
wilson <- function(k, n, z = 1.96) {
  p <- k / n
  mid <- (p + z^2 / (2 * n)) / (1 + z^2 / n)
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)
  list(lo = mid - half, hi = mid + half)
}
#' Share of each big call per bin of `bin` among rows `keep`, with intervals.
rates <- function(keep, bin) {
  d <- data.table(t = X$off[keep] / FPS, bin = bin[keep], big = factor(X$big[keep], BIG_LV))[!is.na(bin)]
  r <- d[, .(n = .N, k = as.numeric(table(big)), outcome = BIG_LV), by = .(t, bin)]
  r[, share := k / n]
  r[, c("lo", "hi") := wilson(k, n)]
  r[order(t, bin, outcome)]
}
GAP_BREAKS <- c(0, 3, 6, 9, 12, Inf)
GAP_LABELS <- c("0-3 ft", "3-6 ft", "6-9 ft", "9-12 ft", "12+ ft")
X[, gap_bin := cut(help_gap, GAP_BREAKS, GAP_LABELS, right = FALSE)]
X[, closing_bin := cut(help_closing, c(-Inf, -1, 1, Inf), c("moving away (< -1 ft/s)", "steady", "closing (> +1 ft/s)"))]
two <- X$off %in% c(-20L, -10L)
by_gap <- rates(two, X$gap_bin)
by_close <- rates(two, X$closing_bin)
fwrite(by_gap[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "call_rates_by_gap.csv"))
fwrite(by_close[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "call_rates_by_closing.csv"))
cat("\nThe big's call by the nearest helper's gap to the roll lane:\n")
print(dcast(by_gap, t + bin + n ~ outcome, value.var = "share")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])
cat("\n... and by his closing speed:\n")
print(dcast(by_close, t + bin + n ~ outcome, value.var = "share")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])

# Mean log loss with a 95% interval from resampling whole games (ratio of sums, as the other evaluators).
boot_ci <- function(d, game, reps = 2000L) {
  set.seed(BOOT_SEED)
  s <- split(d, game)
  sums <- vapply(s, sum, 0)
  ns <- lengths(s)
  b <- replicate(reps, {
    g <- sample(names(s), length(s), TRUE)
    sum(sums[g]) / sum(ns[g])
  })
  c(mean(d), quantile(b, c(0.025, 0.975)))
}
# Held out: the big's call from the gap alone (bins as factors) against no inputs, one fit per held-out game.
alone <- rbindlist(lapply(c(-20L, -10L), function(o) {
  d <- X[off == o & !is.na(gap_bin), .(game_id, big = factor(big, BIG_LV), gap_bin)]
  ll <- rbindlist(lapply(sort(unique(d$game_id)), function(g) {
    tr <- d[game_id != g]
    te <- d[game_id == g]
    f1 <- multinom(big ~ gap_bin, data = tr, trace = FALSE)
    p1 <- predict(f1, newdata = te, type = "probs")[, BIG_LV, drop = FALSE]
    p0 <- matrix(as.numeric(table(tr$big)) / nrow(tr), nrow(te), 3, byrow = TRUE)
    y <- match(te$big, BIG_LV)
    data.table(game_id = g, gap = -log(pmax(p1[cbind(seq_len(nrow(te)), y)], 1e-12)),
               none = -log(pmax(p0[cbind(seq_len(nrow(te)), y)], 1e-12)))
  }))
  ci <- boot_ci(ll$gap - ll$none, ll$game_id)
  data.table(t = o / FPS, screens = nrow(ll), logloss_no_inputs = mean(ll$none), logloss_gap_alone = mean(ll$gap),
             delta = ci[1], lo = ci[2], hi = ci[3], games_improved = sum(ll[, mean(gap - none), by = game_id]$V1 < 0))
}))
fwrite(alone[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)],
       file.path(out_dir, "gap_alone_heldout.csv"))
cat("\nThe big's call from the gap alone vs no inputs (held out by game; below zero = the gap helps):\n")
print(alone[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)])

# Figure: share of each big call by gap bin, at -0.8 s and -0.4 s, with intervals and direct labels.
COL <- c(show = "#2a78d6", drop = "#eb6834", switch = "#1baf7a")
fig <- copy(by_gap)
fig[, panel := factor(sprintf("%+.1f s before the screen tag", t), sprintf("%+.1f s before the screen tag", sort(unique(t))))]
fig[, x := as.integer(bin)]
lab <- fig[bin == GAP_LABELS[length(GAP_LABELS)]]
nlab <- unique(fig[, .(panel, x, n)])
p <- ggplot(fig, aes(x, share, colour = outcome)) +
  geom_linerange(aes(ymin = lo, ymax = hi), linewidth = 0.6, alpha = 0.5, position = position_dodge(width = 0.3)) +
  geom_line(linewidth = 0.7, position = position_dodge(width = 0.3)) +
  geom_point(size = 2.6, position = position_dodge(width = 0.3)) +
  geom_text(data = lab, aes(x = x + 0.25, label = outcome, group = outcome), hjust = 0, size = 3.4, colour = "grey20") +
  geom_text(data = nlab, aes(x = x, y = -0.05, label = paste0("n=", n)), inherit.aes = FALSE, size = 3, colour = "grey45") +
  facet_wrap(~panel, nrow = 1) +
  scale_colour_manual(values = COL, name = "Big's call") +
  scale_x_continuous(breaks = seq_along(GAP_LABELS), labels = GAP_LABELS, expand = expansion(add = c(0.4, 0.9))) +
  scale_y_continuous(labels = function(v) paste0(round(100 * v), "%"), limits = c(-0.08, NA)) +
  labs(title = "The big's call by how close the nearest off-ball defender is to the roll lane",
       subtitle = paste("Share of screens with each call (bars: 95% interval). Nearest helper: the off-ball defender closest",
                        "to the line from the screener to the rim at that moment. 1,463 screens, 10 games."),
       x = "Nearest helper's gap to the roll lane", y = "Share of screens") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
        plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9, colour = "grey30"))
ggsave(file.path(out_dir, "figures", "call_rates_by_gap.png"), p, width = 11, height = 5.5, dpi = 150, bg = "white")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - THE LOGISTIC BASELINE WITH THE NEAREST HELPER'S GAP --------------------
## ═════════════════════════════════════════════════════════════════════════════

# The baseline's inputs (01_logistic_baseline.R), then the helper's gap and closing speed with their closeness terms.
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
FEATS <- c(GEOM, paste0("lsf_", 1:5), "closeness", CLOSE)
SETS <- list(`baseline (refit)` = FEATS,
             `baseline + helper gap` = c(FEATS, "help_gap", "help_gap_close"),
             `baseline + helper gap + closing` = c(FEATS, "help_gap", "help_gap_close", "help_closing", "help_closing_close"))

# One held-out game: a missing helper value takes the training rows' median; then as in 01_logistic_baseline.R
# (standardised with the training rows, every frame weighted 1/76, decay 1).
fold <- function(g, feats) {
  tr <- X[game_id != g]
  te <- X[game_id == g]
  for (v in c("help_gap", "help_closing")) {
    m <- median(tr[[v]], na.rm = TRUE)
    set(tr, which(is.na(tr[[v]])), v, m)
    set(te, which(is.na(te[[v]])), v, m)
  }
  tr[, `:=`(help_gap_close = help_gap * closeness, help_closing_close = help_closing * closeness)]
  te[, `:=`(help_gap_close = help_gap * closeness, help_closing_close = help_closing * closeness)]
  Xtr <- as.matrix(tr[, ..feats])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  fit <- multinom(y ~ ., data = data.frame(y = factor(tr$call, CALLS), scale(Xtr, mu, sdv)),
                  weights = rep(1 / length(OFFS), nrow(tr)), decay = DECAY, trace = FALSE, maxit = 2000)
  list(rows = which(X$game_id == g),
       P = predict(fit, newdata = data.frame(scale(as.matrix(te[, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE])
}
t0 <- Sys.time()
cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})))
clusterExport(cl, c("X", "CALLS", "OFFS", "DECAY", "fold"))
jobs <- CJ(set = names(SETS), g = sort(unique(X$game_id)), sorted = FALSE)
res <- parLapply(cl, seq_len(nrow(jobs)), function(i, jobs, SETS) fold(jobs$g[i], SETS[[jobs$set[i]]]), jobs, SETS)
stopCluster(cl)
cat(sprintf("\nLogistic fits done in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
PR <- lapply(names(SETS), function(s) {
  Pm <- matrix(NA_real_, nrow(X), length(CALLS))
  for (i in which(jobs$set == s)) Pm[res[[i]]$rows, ] <- res[[i]]$P
  Pm
})
names(PR) <- names(SETS)
# Check: the refit baseline reproduces the cached one.
dev <- max(abs(PR[["baseline (refit)"]] - L$prob[["no timing, + closeness"]]))
cat("Refit baseline vs cached baseline, largest probability difference:", signif(dev, 3), "\n")
stopifnot(dev < 1e-4)

# Paired changes against the refit baseline: big and five-call scores at -0.8 s, -0.4 s and over each window.
y <- match(X$call, CALLS)
yb <- match(X$big, BIG_LV)
big_ll <- function(Pm) {
  M <- cbind(Pm[, 1] + Pm[, 4], Pm[, 2] + Pm[, 3], Pm[, 5])
  -log(pmax(M[cbind(seq_len(nrow(M)), yb)], 1e-12))
}
joint_ll <- function(Pm) -log(pmax(Pm[cbind(seq_len(nrow(Pm)), y)], 1e-12))
HOR <- list(`-0.8 s` = X$off == -20L, `-0.4 s` = X$off == -10L, `before the tag (forecast)` = X$off < 0L,
            `tag to +1 s (recognition)` = X$off >= 0L)
out <- list()
bygame <- list()
for (s in names(SETS)[-1]) {
  for (mt in c("big", "joint")) {
    f <- if (mt == "big") big_ll else joint_ll
    ref <- f(PR[["baseline (refit)"]])
    var <- f(PR[[s]])
    for (h in names(HOR)) {
      d <- data.table(idx = X$idx, game_id = X$game_id, ref = ref, var = var)[HOR[[h]]][, .(ref = mean(ref), var = mean(var), game_id = game_id[1]), by = idx]
      ci <- boot_ci(d$var - d$ref, d$game_id)
      g <- d[, .(screens = .N, delta = mean(var - ref)), by = game_id]
      out[[length(out) + 1L]] <- data.table(model = s, metric = mt, horizon = h, loss_baseline = mean(d$ref),
                                            loss_with_helper = mean(d$var), delta = ci[1], lo = ci[2], hi = ci[3],
                                            screens = nrow(d), games_improved = sum(g$delta < 0))
      bygame[[length(bygame) + 1L]] <- g[, .(model = s, metric = mt, horizon = h, game_id, screens, delta)]
    }
  }
}
rnd <- function(D) D[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)]
out <- rbindlist(out)
fwrite(rnd(out), file.path(out_dir, "logistic_plus_gap.csv"))
fwrite(rnd(rbindlist(bygame)), file.path(out_dir, "logistic_plus_gap_by_game.csv"))
cat("\nLogistic baseline with the nearest helper added (delta below zero = the helper helps; 95% game bootstrap):\n")
print(rnd(out))
cat("\nWrote", out_dir, "\n")
