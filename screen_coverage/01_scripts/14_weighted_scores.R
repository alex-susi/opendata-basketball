## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 14: the live models' scores under the fixed time-weight curves.
#   Rscript screen_coverage/01_scripts/14_weighted_scores.R
#
# Scores the live time-aware transformer, the logistic baseline and the league mix of calls under the three curves of
# R/window_weights.R (main, narrow, flat), for the joint call and for each defender: guard (the ball handler's
# defender: over / under / switch) and big (the screener's defender: show / drop / switch). These are the reference
# numbers every tuning run is compared with. Each screen's frames are averaged with the curve's weights, then screens
# are averaged; 95% intervals resample whole games.
#
# Writes screen_coverage/03_outputs/weighted_scores/: scores.csv, scores_by_game.csv, paired_gain.csv, curves.png.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "weighted_scores")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Game resamples for the intervals, and the logistic baseline used (the one with closeness, as in 04_evaluate.R).
N_BOOT <- 2000L
SEED <- 20261115L
LOGISTIC <- "no timing, + closeness"





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PREDICTIONS ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Every frame row's five joint-call probabilities for each model. The league mix is each held-out game's call shares
# from the other nine games, the same for every frame.
L <- load_logistic(root)
X <- L$X
calls <- L$calls
TF <- load_seqheads(root)
mix <- matrix(NA_real_, nrow(X), length(calls))
for (g in unique(X$game_id)) {
  train <- L$P[game_id != g]
  share <- as.numeric(table(factor(train$call, levels = calls))) / nrow(train)
  rows <- which(X$game_id == g)
  mix[rows, ] <- matrix(share, length(rows), length(calls), byrow = TRUE)
}
models <- list(transformer = TF$prob, logistic = L$prob[[LOGISTIC]], league_mix = mix)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SCORES -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Per-screen weighted scores for every model and curve.
per_screen <- rbindlist(lapply(names(models), function(m) {
  loss <- frame_losses(models[[m]], X$call, calls)
  rbindlist(lapply(names(WINDOW_CURVES), function(cv) screen_scores(X, loss, cv)[, `:=`(model = m, curve = cv)]))
}))
stopifnot(per_screen[, .N, by = .(model, curve)][, all(N == nrow(L$P))])
long <- melt(per_screen, id.vars = c("model", "curve", "idx", "game_id"), variable.name = "score",
             value.name = "loss")

# Game-resampled 95% intervals: draw ten games with replacement, average their screens.
set.seed(SEED)
games <- sort(unique(long$game_id))
draws <- replicate(N_BOOT, sample(games, replace = TRUE), simplify = FALSE)
by_game <- long[, .(sum = sum(loss), n = .N), by = .(model, curve, score, game_id)]
boot_ci <- function(d) {
  s <- setNames(d$sum, d$game_id)
  n <- setNames(d$n, d$game_id)
  v <- vapply(draws, function(g) sum(s[as.character(g)]) / sum(n[as.character(g)]), numeric(1))
  as.list(quantile(v, c(0.025, 0.975), names = FALSE))
}
scores <- by_game[, c(.(mean = sum(sum) / sum(n)), setNames(boot_ci(.SD), c("lo", "hi"))),
                  by = .(model, curve, score)]
scores[, curve := factor(curve, names(WINDOW_CURVES))]
scores[, score := factor(score, c("joint", "guard", "big"))]
setorder(scores, curve, score, model)
fwrite(scores[, .(curve, score, model, mean = round(mean, 4), lo = round(lo, 4), hi = round(hi, 4))],
       file.path(out_dir, "scores.csv"))
fwrite(by_game[, .(model, curve, score, game_id, loss = round(sum / n, 4), screens = n)],
       file.path(out_dir, "scores_by_game.csv"))
print(dcast(scores, curve + score ~ model, value.var = "mean"), digits = 4)

# Paired gain of the transformer over the logistic baseline (positive = transformer better), screen by screen, with
# the same game resamples: the form every tuning comparison takes.
gain <- dcast(long[model %in% c("transformer", "logistic")], curve + score + idx + game_id ~ model, value.var = "loss")
gain <- gain[, .(sum = sum(logistic - transformer), n = .N), by = .(curve, score, game_id)]
paired <- gain[, c(.(gain = sum(sum) / sum(n)), setNames(boot_ci(.SD), c("lo", "hi"))), by = .(curve, score)]
fwrite(paired[, .(curve, score, gain = round(gain, 4), lo = round(lo, 4), hi = round(hi, 4))],
       file.path(out_dir, "paired_gain.csv"))
print(paired, digits = 3)





## ═════════════════════════════════════════════════════════════════════════════
## 04 - FIGURE -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The three curves over the scored frames, with the anchor times marked.
offs <- sort(unique(X$off))
cv <- rbindlist(lapply(names(WINDOW_CURVES), function(k) data.table(curve = k, t = offs / WINDOW_FPS,
                                                                       w = window_weight(offs, k))))
cv[, curve := factor(curve, names(WINDOW_CURVES))]
marks <- data.table(t = c(-1.8, -0.9, -0.4, 0, 0.24, 0.5),
                    lab = c("start coming\ntogether", "within 15 ft", "within 10 ft", "pick frame",
                            "closest\nmoment", "+ reaction"))
p <- ggplot(cv, aes(t, w, colour = curve)) +
  geom_vline(data = marks, aes(xintercept = t), colour = "grey75", linetype = "dashed") +
  geom_text(data = marks, aes(t, 1.16, label = lab), inherit.aes = FALSE, size = 2.8, lineheight = 0.85) +
  geom_line(linewidth = 1) +
  scale_colour_manual(values = c(main = "#1f6fd1", narrow = "#d1691f", flat = "grey55")) +
  scale_x_continuous(breaks = seq(-2, 1, 0.5)) +
  scale_y_continuous(breaks = c(0, 0.5, 1), limits = c(0, 1.25)) +
  labs(x = "Seconds from the pick frame", y = "Weight", colour = NULL,
       title = "Fixed time weights for scoring coverage reads") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank())
ggsave(file.path(out_dir, "curves.png"), p, width = 9, height = 4.2, dpi = 150, bg = "white")
cat("Wrote", out_dir, "\n")
