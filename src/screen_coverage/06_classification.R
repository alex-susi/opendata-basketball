## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 6: if each model simply "called" its most likely coverage, how often would it be right?
#   Rscript src/screen_coverage/06_classification.R
#
# Log loss scores the whole probability (75% vs 80% matters to it). A coach or player may only want one answer:
# "expect over + show". Here every model's call at a frame is the coverage it gave the highest probability, and we
# count how those calls turn out. Same screens, frames and held-out predictions as 05_compare.R.
#
#   accuracy            share of calls that were right
#   precision (a call)  when the model called it, how often it happened
#   recall (a call)     when it happened, how often the model called it
#   F1                  the balance of the two: 2 x precision x recall / (precision + recall)
#   macro recall        recall averaged over the five calls with equal weight ("balanced accuracy"): a model that
#                       always says over + show gets 20% here however common over + show is
#   macro precision/F1  the same averaging; a call the model never makes counts as precision 0
#   ball defender       the same accuracy for the handler's defender alone: over, under or switch (the model's call
#                       is the one with the highest summed probability, e.g. over + show plus over + soft)
#   big                 the same for the screener's defender: show, soft or switch
# Baselines: always calling the most common coverage (over + show), and calling this defense's most frequent call so
# far in the game (league mix before its first screen).
#
# Writes outputs/screen_coverage/per_frame/classification/: metrics_by_frame.csv, metrics_by_window.csv,
# per_call_live.csv, confusion_live.csv, figures/accuracy_by_frame.png, figures/confusion_live.png.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
source(file.path(root, "src", "screen_coverage", "R", "predictions.R"))
suppressPackageStartupMessages({
  library(ggplot2)
  library(patchwork)
})
out_dir <- file.path(root, "outputs", "screen_coverage", "per_frame", "classification")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

FPS <- 25
LIVE <- "transformer: pooled, no timing, + closeness"
LIVE_CUTS <- c(-1.0, -0.6, -0.4, -0.2, 0, 0.4)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - TOP CALLS --------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Predictions in X's row order; y is the true call's position among the five.
L <- load_coverage_predictions(root)
P <- L$P
X <- L$X
CALLS <- L$calls
y <- match(X$call, CALLS)
BD_OF <- c("over", "over", "under", "under", "switch")      # ball defender's part of each joint call
BIG_OF <- c("show", "soft", "soft", "show", "switch")       # the big's part

# calls from each model, plus the two baselines
sofar <- as.matrix(P[X$idx, paste0("so_far_", seq_along(CALLS)), with = FALSE])
probs <- c(L$prob, list(`baseline: always over + show` = matrix(rep(c(1, 0, 0, 0, 0), each = nrow(X)), nrow(X)),
                        `baseline: defense's most frequent call so far` = sofar))
# A part call (ball defender or big): the part with the highest summed probability over the joint calls.
part_call <- function(Pm, of) {
  lv <- unique(of)
  m <- sapply(lv, function(l) rowSums(Pm[, of == l, drop = FALSE]))
  lv[max.col(m, ties.method = "first")]
}
calls <- lapply(probs, function(Pm) max.col(Pm, ties.method = "first"))
bd_call <- lapply(probs, part_call, of = BD_OF)
big_call <- lapply(probs, part_call, of = BIG_OF)
bd_true <- BD_OF[y]
big_true <- BIG_OF[y]





## ═════════════════════════════════════════════════════════════════════════════
## 03 - METRICS ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Precision, recall and F1 for each call; a call never made has NA precision.
per_call <- function(pred, truth) {
  rbindlist(lapply(seq_along(CALLS), function(k) {
    tp <- sum(pred == k & truth == k)
    np <- sum(pred == k)
    na <- sum(truth == k)
    prec <- if (np) tp / np else NA_real_
    rec <- if (na) tp / na else NA_real_
    data.table(call = CALLS[k], happened = na, called = np, right = tp, precision = prec, recall = rec,
               f1 = if (is.na(prec) || is.na(rec) || prec + rec == 0) 0 else 2 * prec * rec / (prec + rec))
  }))
}
# Accuracy, macro scores and part accuracies over a set of rows for one model.
summarise <- function(rows, m) {
  pc <- per_call(calls[[m]][rows], y[rows])
  data.table(accuracy = mean(calls[[m]][rows] == y[rows]),
             macro_precision = mean(fifelse(is.na(pc$precision), 0, pc$precision)), macro_recall = mean(pc$recall),
             macro_f1 = mean(pc$f1), ball_defender_accuracy = mean(bd_call[[m]][rows] == bd_true[rows]),
             big_accuracy = mean(big_call[[m]][rows] == big_true[rows]), calls_made = sum(table(calls[[m]][rows]) > 0))
}

# Metrics at every frame and over the two windows, for every model and baseline.
by_frame <- rbindlist(lapply(names(probs), function(m) rbindlist(lapply(sort(unique(X$off)), function(o)
  cbind(data.table(model = m, off = o, t = o / FPS), summarise(which(X$off == o), m))))))
fwrite(by_frame[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "metrics_by_frame.csv"))

X[, window := fifelse(off < 0, "before the screen (-2.0 to -0.04 s)", "at and after the screen (0 to +1.0 s)")]
by_win <- rbindlist(lapply(names(probs), function(m) rbindlist(lapply(unique(X$window), function(w)
  cbind(data.table(model = m, window = w), summarise(which(X$window == w), m))))))
fwrite(by_win[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "metrics_by_window.csv"))
cat("Top-call metrics by window (every frame of every screen in the window counts once):\n")
print(by_win[, .(model, window, accuracy = round(accuracy, 3), macro_recall = round(macro_recall, 3),
                 macro_f1 = round(macro_f1, 3), ball_def = round(ball_defender_accuracy, 3), big = round(big_accuracy, 3))])
cat("\nAccuracy at selected moments:\n")
print(dcast(by_frame[round(t, 2) %in% LIVE_CUTS], model ~ t, value.var = "accuracy")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])

# the live model, call by call, at a few moments
pcl <- rbindlist(lapply(LIVE_CUTS, function(tc) cbind(data.table(t = tc), per_call(calls[[LIVE]][X$off == round(tc * FPS)], y[X$off == round(tc * FPS)]))))
fwrite(pcl[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "per_call_live.csv"))
cat("\nLive model, call by call:\n")
print(pcl[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 2) else v)])
# Confusion tables of the live model at -0.4 s and at the tag: counts and each row's shares.
conf <- rbindlist(lapply(c(-0.4, 0), function(tc) {
  r <- X$off == round(tc * FPS)
  d <- data.table(actual = factor(CALLS[y[r]], CALLS), called = factor(CALLS[calls[[LIVE]][r]], CALLS))[, .N, by = .(actual, called)]
  d <- CJ(actual = factor(CALLS, CALLS), called = factor(CALLS, CALLS))[d, on = .(actual, called), N := i.N][is.na(N), N := 0L]
  d[, share := N / sum(N), by = actual][, t := tc]
}))
fwrite(conf, file.path(out_dir, "confusion_live.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - FIGURES ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

MODELS <- COVERAGE_MODELS
bf <- by_frame[!startsWith(model, "baseline")]
bf[, `:=`(family = sub(":.*", "", model), variant = factor(sub("^[a-z]+: ", "", model), levels = MODELS))]
bl <- by_frame[startsWith(model, "baseline")]
MCOL <- setNames(c("#2a78d6", "#eb6834", "#1baf7a", "#6250d6"), MODELS)
# One metric by frame: colour by variant, solid logistic, dashed transformer, baselines dotted grey.
panel <- function(col, ttl, ylab) {
  lab <- bl[off == max(off)]
  lab[, vj := fifelse(get(col) == max(get(col)), -0.5, 1.5)]          # the higher baseline labelled above its line
  ggplot(bf, aes(t, .data[[col]], colour = variant, linetype = family)) +
    geom_line(data = bl, aes(t, .data[[col]], group = model), inherit.aes = FALSE, colour = "grey55", linetype = "dotted") +
    geom_text(data = lab, aes(t, .data[[col]], label = sub("baseline: ", "", model), vjust = vj), inherit.aes = FALSE,
              hjust = 1, size = 3, colour = "grey40") +
    geom_vline(xintercept = 0, colour = "grey60") +
    geom_line(linewidth = 0.8) +
    scale_colour_manual(values = MCOL, name = NULL) +
    scale_linetype_manual(values = c(logistic = "solid", transformer = "22"), name = NULL,
                          labels = c(logistic = "logistic (4 players)", transformer = "transformer (all 10 players)")) +
    scale_y_continuous(labels = function(v) paste0(round(100 * v), "%")) +
    scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
    labs(subtitle = ttl, x = NULL, y = ylab) +
    theme_minimal(base_size = 11) +
    theme(legend.position = "top", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9.5),
          legend.key.width = unit(26, "pt"))
}
p1 <- panel("accuracy", "Accuracy: share of top calls that were right (out of five calls)", "Accuracy") +
  guides(colour = guide_legend(nrow = 2, order = 1), linetype = guide_legend(nrow = 2, order = 2, override.aes = list(colour = "grey25")))
p2 <- panel("macro_recall", "Balanced accuracy: recall averaged over the five calls (always calling over + show scores 20%)", "Balanced acc.") +
  theme(legend.position = "none")
p3 <- panel("ball_defender_accuracy", "Ball defender only: over, under or switch (always 'over' is right 67% of the time)", "Accuracy") +
  theme(legend.position = "none") +
  labs(x = "Seconds relative to the screen tag")
g <- p1 / p2 / p3 + plot_layout(heights = c(1.3, 1, 1)) +
  plot_annotation(title = "If each model just called its most likely coverage: how often it was right, frame by frame",
                  subtitle = sprintf("%s screens, held-out games. Dotted grey: baselines.", format(nrow(P), big.mark = ",")),
                  theme = theme(plot.title = element_text(face = "bold", size = 13)))
ggsave(file.path(out_dir, "figures", "accuracy_by_frame.png"), g, width = 12, height = 11, dpi = 150, bg = "white")

# Confusion heat maps for the live model.
conf[, lab := sprintf("%d\n%.0f%%", N, 100 * share)]
conf[, panel := factor(sprintf("%+.1f s", t), levels = sprintf("%+.1f s", c(-0.4, 0)))]
pc <- ggplot(conf, aes(called, actual, fill = share)) +
  geom_tile(colour = "white", linewidth = 1) +
  geom_text(aes(label = lab, colour = share > 0.5), size = 3.2, lineheight = 0.9) +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = "grey15"), guide = "none") +
  scale_fill_gradient(low = "#f1f6fd", high = "#1d5fae", labels = function(v) paste0(100 * v, "%"), name = "Share of\nthe row") +
  scale_y_discrete(limits = rev) +
  facet_wrap(~ panel) +
  coord_equal() +
  labs(title = "The live model's calls against what happened",
       subtitle = "Transformer, pooled, no timing, + closeness. Rows: the coverage that happened; each row sums to 100% (the diagonal is recall).",
       x = "The model's top call", y = "What happened") +
  theme_minimal(base_size = 11) +
  theme(panel.grid = element_blank(), axis.text.x = element_text(angle = 30, hjust = 1),
        plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9.5))
ggsave(file.path(out_dir, "figures", "confusion_live.png"), pc, width = 12, height = 6.2, dpi = 150, bg = "white")
