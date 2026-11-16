## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 22: precision and recall matrices for the live transformer (and its logistic baseline).
#   Rscript screen_coverage/01_scripts/22_confusion_matrices.R
#
# The five calls are not balanced (over + show 497 screens, switch 211, under + show 109), so overall accuracy hides
# how each call is read. Each frame's read is the model's top call (the largest of the five probabilities, what the
# card's Combined row shows). Counted three ways, all held out by game on the same 1,463 screens:
#   main curve   every scored frame weighted by the fixed main time-weight curve (R/window_weights.R), each screen's
#                weights summing to 1, so the counts are in screens
#   -0.4 s       the frame 10 frames before the pick frame (the moment of per_call_at_minus_0.4s.csv)
#   0.0 s        the pick frame itself
# Two matrices from each count table:
#   recall       rows = actual call, each row sums to 1: of the screens that were X, the share read as each call
#   precision    columns = top call, each column sums to 1: of the screens read as X, the share that really were each
# Also for each defender's part (guard: over / under / switch, big: show / drop / switch) and, for switch alone,
# measures that do not depend on the top call: mean switch probability on true switches and on the rest, and the
# chance a random true switch gets a higher switch probability than a random other screen (AUC).
#
# Writes screen_coverage/03_outputs/confusion/: counts.csv, recall.csv, precision.csv, per_call.csv, switch_ranking.csv,
# matrices.png.
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
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "confusion")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PREDICTIONS AND FRAME WEIGHTS ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- copy(L$X)
CALLS <- L$calls
SQ <- load_seqheads(root)
TF <- "live transformer"
LB <- "logistic baseline"
prob <- list(SQ$prob, L$prob[["no timing, + closeness"]])
names(prob) <- c(TF, LB)
stopifnot(!anyNA(unlist(prob)))

# Frame weights for each way of counting; the main curve is scaled so each screen sums to 1.
X[, w_main := window_weight(off, "main")]
X[, w_main := w_main / sum(w_main), by = id]
X[, w_m04 := as.numeric(off == -10L)]
X[, w_0 := as.numeric(off == 0L)]
MOMENTS <- c(`main curve` = "w_main", `-0.4 s` = "w_m04", `0.0 s` = "w_0")
stopifnot(all(X[, .(s = sum(w_m04)), by = id]$s == 1))

# The joint calls that make up each defender's part (R/window_weights.R).
PARTS <- list(joint = setNames(as.list(CALLS), CALLS), guard = GUARD_CALLS, big = BIG_CALLS)

#' Probabilities of each level of `part`, summed from the five joint calls.
part_prob <- function(Pm, part) {
  G <- sapply(PARTS[[part]], function(m) rowSums(Pm[, match(m, CALLS), drop = FALSE]))
  colnames(G) <- names(PARTS[[part]])
  G
}

#' The level of `part` that each joint call belongs to.
part_of <- function(call, part) {
  lv <- names(PARTS[[part]])
  lv[vapply(call, function(cc) which(vapply(PARTS[[part]], function(m) cc %in% m, logical(1))), integer(1))]
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - COUNTS, RECALL AND PRECISION -------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Weighted count of (actual, top call) for each model, moment and part.
counts <- rbindlist(lapply(names(prob), function(m) rbindlist(lapply(names(PARTS), function(part) {
  G <- part_prob(prob[[m]], part)
  lv <- colnames(G)
  d <- data.table(actual = factor(part_of(X$call, part), lv), read = factor(lv[max.col(G, ties.method = "first")], lv))
  rbindlist(lapply(names(MOMENTS), function(mo) {
    d[, w := X[[MOMENTS[[mo]]]]]
    cc <- d[w > 0, .(screens = sum(w)), by = .(actual, read)]
    full <- CJ(actual = factor(lv, lv), read = factor(lv, lv))
    cc <- merge(full, cc, by = c("actual", "read"), all.x = TRUE)
    cc[is.na(screens), screens := 0]
    cc[, `:=`(model = m, part = part, moment = mo)]
  }))
}))))
counts[, recall := screens / sum(screens), by = .(model, part, moment, actual)]
counts[, precision := screens / sum(screens), by = .(model, part, moment, read)]
setcolorder(counts, c("model", "part", "moment", "actual", "read"))

fwrite(counts[, .(model, part, moment, actual, read, screens = round(screens, 2))], file.path(out_dir, "counts.csv"))
fwrite(counts[, .(model, part, moment, actual, read, recall = round(recall, 4))], file.path(out_dir, "recall.csv"))
fwrite(counts[, .(model, part, moment, actual, read, precision = round(precision, 4))], file.path(out_dir, "precision.csv"))

# Diagonals side by side: each call's recall, precision, F1 and how often it is the top call against how often it
# happens.
pc <- counts[, .(actual_screens = sum(screens[actual == read]) / recall[actual == read][1]), by = .(model, part, moment, call = actual)]
pc <- merge(pc, counts[actual == read, .(model, part, moment, call = actual, recall, precision)], by = c("model", "part", "moment", "call"))
pc <- merge(pc, counts[, .(read_screens = sum(screens)), by = .(model, part, moment, call = read)], by = c("model", "part", "moment", "call"))
pc[is.nan(precision), precision := NA_real_]
pc[, f1 := 2 * precision * recall / (precision + recall)]
pc <- pc[, .(model, part, moment, call, actual_screens = round(actual_screens, 1), read_screens = round(read_screens, 1),
             recall = round(recall, 4), precision = round(precision, 4), f1 = round(f1, 4))]
fwrite(pc, file.path(out_dir, "per_call.csv"))
cat("\nPer call, main curve:\n")
print(pc[moment == "main curve"])
# Macro averages (each call counts the same) against plain accuracy.
macro <- pc[, .(macro_recall = round(mean(recall), 3), macro_precision = round(mean(precision, na.rm = TRUE), 3),
                macro_f1 = round(mean(f1, na.rm = TRUE), 3)), by = .(model, part, moment)]
acc <- counts[, .(accuracy = round(sum(screens[actual == read]) / sum(screens), 3)), by = .(model, part, moment)]
cat("\nAccuracy against macro averages:\n")
print(merge(acc, macro, by = c("model", "part", "moment")))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SWITCH WITHOUT THE TOP CALL --------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Does the model rank switches above other screens even when switch is not the top call? Per screen, the switch
# probability averaged with the main-curve weights (and at the two single frames).
is_sw <- X$call == "switch"
auc <- function(p, pos) {
  r <- rank(p)
  (sum(r[pos]) - sum(pos) * (sum(pos) + 1) / 2) / (sum(pos) * sum(!pos))
}
sr <- rbindlist(lapply(names(prob), function(m) rbindlist(lapply(names(MOMENTS), function(mo) {
  d <- X[, .(id, call, w = get(MOMENTS[[mo]]), p = prob[[m]][, 5])][w > 0, .(p = sum(w * p) / sum(w), sw = call[1] == "switch"), by = id]
  data.table(model = m, moment = mo, switches = sum(d$sw), others = sum(!d$sw),
             mean_p_switch_on_switches = round(mean(d$p[d$sw]), 4), mean_p_switch_on_others = round(mean(d$p[!d$sw]), 4),
             share_of_switches = round(mean(d$sw), 4), auc = round(auc(d$p, d$sw), 4),
             switches_above_0.30 = round(mean(d$p[d$sw] > 0.30), 4), others_above_0.30 = round(mean(d$p[!d$sw] > 0.30), 4))
}))))
fwrite(sr, file.path(out_dir, "switch_ranking.csv"))
cat("\nSwitch probability, per screen:\n")
print(sr)





## ═════════════════════════════════════════════════════════════════════════════
## 04 - FIGURE -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Recall and precision heat maps for the live transformer on the main curve, one row each for the joint call, the ball
# handler's defender and the screener's defender. Each cell shows its share and, in brackets, its screens
# (main-curve weighted, so rounded to whole screens).
draw <- function(d, value, title) {
  d <- copy(d)
  d[, v := get(value)]
  lv <- names(PARTS[[d$part[1]]])
  d[, read := factor(read, lv)]
  d[, actual := factor(actual, rev(lv))]
  ggplot(d, aes(read, actual, fill = v)) +
    geom_tile(colour = "white") +
    geom_text(aes(label = ifelse(is.na(v), "", sprintf("%.0f%%\n(%.0f)", 100 * v, screens))), size = 3.2, lineheight = 0.9) +
    scale_fill_gradient(low = "#f4f1ea", high = "#2f6db3", limits = c(0, 1), na.value = "grey90", guide = "none") +
    labs(title = title, x = "Model's top call", y = "Actual call") +
    theme_minimal(base_size = 11) +
    theme(panel.grid = element_blank(),
          axis.text.x = element_text(angle = 30, hjust = 1),
          plot.title = element_text(hjust = 0.5))
}
ROWS <- c(joint = "Full call", guard = "Ball handler's defender", big = "Screener's defender")
panels <- unlist(lapply(names(ROWS), function(pt) {
  fig_d <- counts[model == TF & part == pt & moment == "main curve"]
  list(draw(fig_d, "recall", paste0(ROWS[[pt]], "\nRecall (rows sum to 100%)")),
       draw(fig_d, "precision", paste0(ROWS[[pt]], "\nPrecision (columns sum to 100%)")))
}), recursive = FALSE)
p <- wrap_plots(panels, ncol = 2, heights = c(5, 3, 3)) +
  plot_annotation(title = "Live transformer, held out by game, main time-weight curve (1,463 screens)",
                  caption = "Cell = share (screens). Screens are main-curve weighted, each screen counting 1, rounded to whole screens.",
                  theme = theme(plot.title = element_text(hjust = 0.5)))
ggsave(file.path(out_dir, "matrices.png"), p, width = 11, height = 13, dpi = 150, bg = "white")
cat("\nWrote", out_dir, "\n")
