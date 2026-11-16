## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 18: does telling the coverage model how long until the screen help?
#   Rscript screen_coverage/01_scripts/18_timing_compare.R
#
# Compares three versions of the coverage model trained under the same rules (03_train_transformer.R --timing,
# early stopping on the main time-weight curve, 4 random starts averaged, held-out games):
#   none      the current model's settings, no timing input (the fair baseline under the new rules)
#   physics   plus the two physics estimates of 17_time_to_screen.R (screener time to stop, handler-screener time to
#             meet, each with its "has an answer" flag)
#   learned   plus the learned step-1 estimate (median) and its 10-90% spread
# and the live model as trained today (flat stopping, 2 starts) for reference.
#
# Scores: log loss of the full call, the ball handler's defender and the screener's defender, under the three fixed
# time-weight curves (R/window_weights.R); 95% intervals and paired gains over "none" resample whole games. Then, for
# the learned version, how the coverage read fares when step 1 is badly wrong: test frames grouped by step 1's error,
# against the "none" model on the same frames.
#
# Writes screen_coverage/03_outputs/timing_compare/: scores.csv, paired_gain.csv, by_time.csv, by_step1_error.csv,
# validation_scores.csv, by_time.png.
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
exp_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "timing")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "timing_compare")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

VERSIONS <- c("none", "physics", "learned")
SEED_SETS <- c("tf_s1-2", "tf_s3-4")
N_BOOT <- 2000L
SEED <- 20261115L
STEP1_ERR_BANDS <- c(0, 0.1, 0.25, 0.5, 1, Inf)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PREDICTIONS ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- L$X
calls <- L$calls
games <- sort(unique(X$game_id))

#' A version's held-out test probabilities in X's rows (4 random starts: the two seed sets averaged), and its
#' validation-game probabilities per fold.
load_version <- function(v) {
  test <- matrix(0, nrow(X), length(calls))
  val <- list()
  for (g in games) {
    parts <- lapply(SEED_SETS, function(s) {
      o <- readRDS(file.path(exp_dir, v, s, sprintf("seqheads_%d.rds", g)))
      if (!identical(o$rules, L$rules) || !identical(o$screen_ids, L$P$id) || o$timing$version != v) stop("stale fold file")
      o
    })
    test[parts[[1]]$rows, ] <- Reduce(`+`, lapply(parts, `[[`, "prob")) / length(parts)
    val[[as.character(g)]] <- list(rows = parts[[1]]$val_rows,
                                   prob = Reduce(`+`, lapply(parts, `[[`, "val_prob")) / length(parts))
  }
  stopifnot(all(abs(rowSums(test) - 1) < 1e-4))
  list(test = test, val = val)
}
V <- setNames(lapply(VERSIONS, load_version), VERSIONS)
models <- c(lapply(V, `[[`, "test"), list(live = load_seqheads(root, do.call(file.path, c(list(root), SEQ_FLAT_DIR)))$prob))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SCORES AND PAIRED GAINS ------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

per_screen <- rbindlist(lapply(names(models), function(m) {
  loss <- frame_losses(models[[m]], X$call, calls)
  rbindlist(lapply(names(WINDOW_CURVES), function(cv) screen_scores(X, loss, cv)[, `:=`(model = m, curve = cv)]))
}))
long <- melt(per_screen, id.vars = c("model", "curve", "idx", "game_id"), variable.name = "score", value.name = "loss")

set.seed(SEED)
draws <- replicate(N_BOOT, sample(games, replace = TRUE), simplify = FALSE)
#' Mean over screens and its game-resampled 95% interval, from per-game sums and counts.
boot_mean <- function(sum_g, n_g, game_g) {
  s <- setNames(sum_g, game_g)
  n <- setNames(n_g, game_g)
  v <- vapply(draws, function(g) sum(s[as.character(g)]) / sum(n[as.character(g)]), numeric(1))
  list(mean = sum(sum_g) / sum(n_g), lo = quantile(v, 0.025, names = FALSE), hi = quantile(v, 0.975, names = FALSE))
}
bg <- long[, .(sum = sum(loss), n = .N), by = .(model, curve, score, game_id)]
scores <- bg[, boot_mean(sum, n, game_id), by = .(model, curve, score)]
fwrite(scores[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "scores.csv"))

# Paired gain over "none" (positive = the version is better), screen by screen, games resampled; games improved.
wide <- dcast(long, curve + score + idx + game_id ~ model, value.var = "loss")
paired <- rbindlist(lapply(setdiff(names(models), "none"), function(m) {
  d <- wide[, .(curve, score, game_id, gain = none - get(m))]
  g <- d[, .(sum = sum(gain), n = .N), by = .(curve, score, game_id)]
  g[, c(boot_mean(sum, n, game_id), .(games_better = sum(sum > 0))), by = .(curve, score)][, model := m]
}))
fwrite(paired[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "paired_gain.csv"))
print(dcast(scores[curve == "main"], score ~ model, value.var = "mean"), digits = 4)
print(paired[curve == "main"], digits = 3)

# Validation-game scores per fold (main curve, joint): what a per-fold selection would see.
val_scores <- rbindlist(lapply(VERSIONS, function(v) rbindlist(lapply(games, function(g) {
  e <- V[[v]]$val[[as.character(g)]]
  loss <- frame_losses(e$prob, X$call[e$rows], calls)
  s <- screen_scores(X[e$rows], loss, "main")
  data.table(version = v, fold = g, val_game = X$game_id[e$rows[1]], joint = mean(s$joint), guard = mean(s$guard),
             big = mean(s$big))
}))))
fwrite(val_scores[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "validation_scores.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - BY MOMENT --------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Unweighted per-frame log loss of the full call and each defender, by time from the pick frame.
by_time <- rbindlist(lapply(names(models), function(m) {
  loss <- frame_losses(models[[m]], X$call, calls)
  data.table(model = m, t = X$off / 25, loss)[, .(joint = mean(joint), guard = mean(guard), big = mean(big)), by = .(model, t)]
}))
fwrite(by_time[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "by_time.csv"))
bt <- melt(by_time, id.vars = c("model", "t"), variable.name = "score", value.name = "loss")
bt[, score := factor(score, c("joint", "guard", "big"), c("Full call", "Ball handler's defender", "Screener's defender"))]
p <- ggplot(bt, aes(t, loss, colour = model)) +
  geom_vline(xintercept = 0, colour = "grey80", linetype = "dashed") +
  geom_line(linewidth = 0.8) +
  facet_wrap(~score, nrow = 1, scales = "free_y") +
  scale_colour_manual(values = c(none = "grey45", physics = "#d1691f", learned = "#1f6fd1", live = "grey75")) +
  labs(x = "Seconds from the pick frame", y = "Log loss (lower is better)", colour = NULL,
       title = "Coverage read with and without a time-to-screen estimate", subtitle = "Held-out games, every frame counted equally") +
  theme_minimal(base_size = 10) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank())
ggsave(file.path(out_dir, "by_time.png"), p, width = 11, height = 4, dpi = 150, bg = "white")





## ═════════════════════════════════════════════════════════════════════════════
## 05 - WHEN STEP 1 IS WRONG ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Each test frame's step-1 error (its own fold's estimate minus the truth), banded; the learned and "none" models'
# full-call log loss on the same frames, weighted by the main curve.
S1 <- readRDS(file.path(exp_dir, "step1.rds"))
est <- numeric(nrow(X))
for (g in games) {
  r <- which(X$game_id == g)
  est[r] <- S1$folds[[as.character(g)]]$m[r, "t_q50"]
}
w <- window_weight(X$off, "main")
lj <- function(m) frame_losses(models[[m]], X$call, calls)$joint
E <- data.table(game_id = X$game_id, w = w, err = est - (-X$off / 25), learned = lj("learned"), physics = lj("physics"),
                none = lj("none"))[w > 0]
E[, band := cut(abs(err), STEP1_ERR_BANDS, include.lowest = TRUE)]
E[, direction := fifelse(err > 0, "thinks the screen is later", "thinks the screen is sooner")]
by_err <- E[, .(frames = .N, share = .N / nrow(E), none = sum(w * none) / sum(w), learned = sum(w * learned) / sum(w),
                physics = sum(w * physics) / sum(w)), by = .(band)][order(band)]
by_err[, learned_gain := none - learned]
by_dir <- E[abs(err) > 0.5, .(frames = .N, none = sum(w * none) / sum(w), learned = sum(w * learned) / sum(w)), by = direction]
fwrite(rbind(by_err[, .(group = paste("step-1 error", band), frames, share, none, physics, learned, learned_gain)],
             by_dir[, .(group = paste("error > 0.5 s,", direction), frames, share = NA_real_, none, physics = NA_real_,
                        learned, learned_gain = none - learned)])[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)],
       file.path(out_dir, "by_step1_error.csv"))
print(by_err, digits = 3)
print(by_dir, digits = 3)
cat("Wrote", out_dir, "\n")
