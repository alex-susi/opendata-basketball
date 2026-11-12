## ═════════════════════════════════════════════════════════════════════════════
# Step 4: score every model on the same held-out predictions.
#   Rscript kickout_transformer/01_scripts/04_evaluate.R
#
# Scores (all computed on the game each model never saw):
#   log loss   -log(probability given to what happened). Lower is better. Uniform guessing scores log(4) = 1.386 (log(3) = 1.099 with --drop-other).
#              It punishes confident mistakes hard, which is what we want from probabilities.
#   Brier      squared distance between the probability vector and the answer. Lower is better.
#   accuracy   share of catches where the most likely class happened. Shown for intuition only: "always pass"
#              already gets ~56% because passing is so common.
# Intervals come from resampling whole games (catches within one game are not independent).
# Differences are paired: the same catches scored by two models, so game-to-game difficulty cancels out.
#
# Writes kickout_transformer/03_outputs/4class/{metrics, paired_vs_logistic, per_game_logloss, calibration}.csv and figures.
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
suppressPackageStartupMessages({ library(ggplot2) })

MODEL_ORDER <- c("uniform", "league", "archetype", "player", "logistic", "transformer_freeze", "transformer_hist")
MODEL_LABEL <- c(uniform = sprintf("Uniform (%.0f%% each)", 100 / length(CLASSES)), league = "League average", archetype = "Archetype average",
                 player = "Player average", logistic = "Logistic, 10 hand features",
                 transformer_freeze = "Transformer: freeze frame", transformer_hist = "Transformer: + last 1 s")

# Baseline and transformer predictions; a model enters only once every one of its folds is done.
d <- kt_load_catches(paths)
m <- d$meta
tf_files <- list.files(paths$cache, "^tf_(freeze|hist)_[0-9]+\\.rds$", full.names = TRUE)
tf <- lapply(tf_files, readRDS)
pred <- rbind(readRDS(file.path(paths$cache, "pred_baselines.rds")), rbindlist(lapply(tf, `[[`, "pred")))
complete_models <- pred[, .N, by = model][N == nrow(m), model]
missing <- setdiff(MODEL_ORDER, complete_models)
if (length(missing)) message("Not every fold is done for: ", paste(missing, collapse = ", "), " (left out)")
pred <- pred[model %in% complete_models]
pred[m, on = "row", `:=`(label = i.label, game_id = i.game_id, kickout = i.kickout)]
# Per-catch log loss, Brier score, and whether the top class was right.
P <- as.matrix(pred[, ..PROB_COLS])
pred[, `:=`(logloss = row_logloss(P, label), brier = row_brier(P, label),
            correct = as.numeric(CLASSES[max.col(P, ties.method = "first")] == label))]
pred[, model := factor(model, levels = intersect(MODEL_ORDER, complete_models))]





## ═════════════════════════════════════════════════════════════════════════════
## 01 - OVERALL METRICS --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One model on one subset: mean log loss with a game-bootstrap interval, Brier, accuracy, mean probabilities.
summarise <- function(s, subset) {
  ci <- game_bootstrap(s$logloss, s$game_id)
  out <- data.table(subset = subset, n = nrow(s), logloss = ci[["mean"]], logloss_lo = ci[["lo"]],
                    logloss_hi = ci[["hi"]], brier = mean(s$brier), accuracy = mean(s$correct))
  for (cl in PROB_COLS) set(out, j = paste0("mean_", cl), value = mean(s[[cl]]))
  out
}
metrics <- rbind(pred[, summarise(.SD, "all perimeter catches"), by = model],
                 pred[kickout == TRUE, summarise(.SD, "strict kickouts"), by = model])
fwrite(metrics, file.path(paths$out, "metrics.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PAIRED DIFFERENCES -----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Paired log-loss difference of model a minus model b on the same catches, with a game-bootstrap interval.
paired <- function(a, b, subset_rows) {
  x <- pred[model == a]
  x <- x[subset_rows(x)]
  y <- pred[model == b]
  y <- y[subset_rows(y)]
  z <- x[y, on = "row", .(game_id, diff = logloss - i.logloss)]
  ci <- game_bootstrap(z$diff, z$game_id)
  data.table(model = a, versus = b, n = nrow(z), logloss_diff = ci[["mean"]], lo = ci[["lo"]], hi = ci[["hi"]])
}
pairs <- list(c("transformer_freeze", "logistic"), c("transformer_hist", "logistic"),
              c("transformer_hist", "transformer_freeze"), c("logistic", "league"), c("archetype", "league"),
              c("player", "archetype"), c("transformer_freeze", "league"))
pairs <- Filter(function(p) all(p %in% complete_models), pairs)
paired_tab <- rbind(rbindlist(lapply(pairs, function(p) paired(p[1], p[2], function(s) rep(TRUE, nrow(s)))))[, subset := "all perimeter catches"],
                    rbindlist(lapply(pairs, function(p) paired(p[1], p[2], function(s) s$kickout)))[, subset := "strict kickouts"])
fwrite(paired_tab, file.path(paths$out, "paired_logloss_differences.csv"))

per_game <- dcast(pred[, .(logloss = round(mean(logloss), 3)), by = .(game_id, model)], game_id ~ model,
                  value.var = "logloss")
fwrite(per_game, file.path(paths$out, "per_game_logloss.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - CALIBRATION ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# When a model says 30% shot, do ~30% of those catches end in a shot?

# Each model's probability for each class against how often that class happened, in probability bins.
long <- melt(pred[model %in% c("logistic", "transformer_freeze", "transformer_hist")],
             id.vars = c("row", "model", "label"), measure.vars = paste0("p_", CLASSES),
             variable.name = "class", value.name = "p")
long[, class := sub("^p_", "", class)]
long[, happened := as.numeric(label == class)]
long[, bin := cut(p, c(0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 1), include.lowest = TRUE)]
calib <- long[, .(n = .N, predicted = mean(p), observed = mean(happened)), by = .(model, class, bin)][order(model, class, bin)]
fwrite(calib, file.path(paths$out, "calibration.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - FIGURES ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

fig_dir <- file.path(paths$out, "figures")
dir.create(fig_dir, showWarnings = FALSE)
# Log loss with intervals for every model and subset; the dashed line is the uniform guess.
plot_m <- copy(metrics)
plot_m[, label := factor(MODEL_LABEL[as.character(model)], levels = rev(MODEL_LABEL[levels(pred$model)]))]
g1 <- ggplot(plot_m, aes(logloss, label)) +
  geom_vline(xintercept = log(length(CLASSES)), linetype = 2, colour = "grey60") +
  geom_errorbar(aes(xmin = logloss_lo, xmax = logloss_hi), width = 0.25, orientation = "y", colour = "grey40") +
  geom_point(size = 2.5, colour = "#2a6f97") +
  facet_wrap(~ sprintf("%s (n = %d)", subset, n), scales = "free_x") +
  labs(x = "Log loss on held-out games (lower is better; dashed = uniform guess)", y = NULL,
       title = sprintf("What does the receiver do after a perimeter catch? (%s)", CLASS_TAG),
       subtitle = "Leave-one-game-out predictions; bars are 95% intervals from resampling games") +
  theme_minimal(base_size = 11)
ggsave(file.path(fig_dir, "model_comparison.png"), g1, width = 9, height = 4, dpi = 150, bg = "white")

# Training curves of every random start for the first test game.
curves <- rbindlist(lapply(tf, function(o) o$curves[, `:=`(model = o$model, test_game = o$test_game)]))
if (nrow(curves)) {
  cv <- melt(curves[test_game == min(test_game)], id.vars = c("seed", "epoch", "model", "test_game"),
             variable.name = "data", value.name = "loss")
  g2 <- ggplot(cv, aes(epoch, loss, colour = data, group = interaction(data, seed))) +
    geom_line(alpha = 0.8) +
    facet_wrap(~ model) +
    scale_colour_manual(values = c(train = "#2a6f97", val = "#d1495b"),
                        labels = c(train = "training games", val = "validation game")) +
    labs(x = "Epoch (one pass through the training catches)", y = "Log loss", colour = NULL,
         title = sprintf("Training curves, test game %s (three seeds each; %s)", min(curves$test_game), CLASS_TAG),
         subtitle = "Training loss keeps falling; validation loss bottoms out early. The kept model is the validation minimum.") +
    theme_minimal(base_size = 11)
  ggsave(file.path(fig_dir, "training_curves.png"), g2, width = 9, height = 4, dpi = 150, bg = "white")
}

# Print the summary tables.
cat("\nMetrics:\n")
print(metrics[, .(model, subset, n, logloss = round(logloss, 3), lo = round(logloss_lo, 3), hi = round(logloss_hi, 3),
                  brier = round(brier, 3), accuracy = round(accuracy, 3))])
cat("\nPaired log-loss differences (negative = first model better):\n")
print(paired_tab[, .(subset, model, versus, diff = round(logloss_diff, 3), lo = round(lo, 3), hi = round(hi, 3))])
cat("\nPer-game log loss:\n")
print(per_game)
