## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 31: does the personnel experiment help? Scores against the live models.
#   Rscript screen_coverage/01_scripts/31_personnel_compare.R
#
# "Transformer, live" is the model live from 2026-11-15 to 2026-11-19 (SEQ_MAIN_DIR), which every version here was
# compared against. The switch-part version became the live model on 2026-11-19 (33_promote_switch_positions.R).
#
# Needs the live folds (03_train_transformer.R), the personnel folds (03_train_transformer.R --personnel, seeds 1-2
# and 3-4, averaged into the same four starts as live) and 30_logistic_personnel.R. Every number is held out by game.
#   Scores       log loss of the joint coverage and of each defender (guard = the ball handler's defender, big = the
#                screener's defender) on the main time-weight curve, plus before the pick frame (-2 s to -0.04 s) and
#                at and after it (0 to +1 s), each screen's frames averaged first. 95% intervals resample whole games
#   Paired gain  old minus new per screen (above 0 = the new inputs helped), its interval and games improved. The
#                transformer's two seed halves are also scored alone: how much of a gain is training noise
#   Switches     switch log loss (switch or not, main curve), screen-level AUC of the main-curve switch
#                probability, and every coverage's recall and precision of the top coverage on main-curve frames
#   Groups       switches and the switch read by the screener's defender's position and the memory flags
#
# Writes screen_coverage/03_outputs/experiments/personnel/: scores.csv, paired_gain.csv, per_call.csv,
# switch_groups.csv, by_game.csv.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
exp_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "personnel")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "experiments", "personnel")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
N_BOOT <- 2000L
SEED <- 20261119L





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PREDICTIONS ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- L$X
CALLS <- L$calls
LG <- readRDS(file.path(exp_dir, "logistic.rds"))
PI <- readRDS(file.path(exp_dir, "inputs.rds"))
half <- function(s, d = exp_dir) load_seqheads(root, file.path(d, s))$prob
H12 <- half("tf_s1-2")
H34 <- half("tf_s3-4")
# Hard groups (owner, 2026-11-19): each player's most likely group as 0/1 (03_train_transformer.R --positions=hard).
hard_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "personnel_hard")
K12 <- half("tf_s1-2", hard_dir)
K34 <- half("tf_s3-4", hard_dir)
# Memory only (owner, 2026-11-19): no position channels (03_train_transformer.R --positions=none).
mem_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "personnel_memory")
M12 <- half("tf_s1-2", mem_dir)
M34 <- half("tf_s3-4", mem_dir)
# Positions only, no memory (owner, 2026-11-19): hard groups for all ten players, and for the two screen defenders only.
avg_dir <- function(v) {
  d <- file.path(root, "screen_coverage", "02_cache", "experiments", v)
  (half("tf_s1-2", d) + half("tf_s3-4", d)) / 2
}
MODELS <- list("Transformer, split head control" = avg_dir("split_head_control"),
               "Transformer + positions in the switch part" = avg_dir("personnel_hard_swhead_nomem"),
               "Transformer + hard positions only" = avg_dir("personnel_hard_nomem"),
               "Transformer + defenders' hard positions only" = avg_dir("personnel_hard_def_nomem"),
               "Transformer + memory only" = (M12 + M34) / 2, "Transformer + memory only (seeds 1-2 only)" = M12,
               "Transformer + memory only (seeds 3-4 only)" = M34,"Transformer, live" = load_seqheads(root, do.call(file.path, c(list(root), SEQ_MAIN_DIR)))$prob, "Transformer + personnel" = (H12 + H34) / 2,
               "Transformer + personnel (seeds 1-2 only)" = H12, "Transformer + personnel (seeds 3-4 only)" = H34,
               "Transformer + personnel, hard groups" = (K12 + K34) / 2, "Transformer + personnel, hard groups (seeds 1-2 only)" = K12,
               "Transformer + personnel, hard groups (seeds 3-4 only)" = K34,
               "Logistic, live" = L$prob[["no timing, + closeness"]], "Logistic + positions" = LG$prob$positions,
               "Logistic + memory" = LG$prob$memory, "Logistic + positions + memory" = LG$prob$both,
               "Logistic + defenders' positions + memory" = LG$prob$defenders_memory,
               "Logistic + hard positions" = LG$prob$positions_hard, "Logistic + hard positions + memory" = LG$prob$both_hard,
               "Logistic + defenders' hard positions + memory" = LG$prob$defenders_memory_hard,
               "Logistic + defenders' hard positions" = LG$prob$defenders_hard)
PAIRS <- list(c("Transformer, live", "Transformer, split head control"),
              c("Transformer, split head control", "Transformer + positions in the switch part"),
              c("Transformer, live", "Transformer + positions in the switch part"), c("Transformer, live", "Transformer + hard positions only"), c("Transformer, live", "Transformer + defenders' hard positions only"),
              c("Transformer, live", "Transformer + memory only"), c("Transformer, live", "Transformer + memory only (seeds 1-2 only)"),
              c("Transformer, live", "Transformer + memory only (seeds 3-4 only)"), c("Transformer, live", "Transformer + personnel"), c("Transformer, live", "Transformer + personnel (seeds 1-2 only)"),
              c("Transformer, live", "Transformer + personnel (seeds 3-4 only)"),
              c("Transformer, live", "Transformer + personnel, hard groups"), c("Transformer, live", "Transformer + personnel, hard groups (seeds 1-2 only)"),
              c("Transformer, live", "Transformer + personnel, hard groups (seeds 3-4 only)"),
              c("Transformer + personnel", "Transformer + personnel, hard groups"), c("Logistic, live", "Logistic + positions"),
              c("Logistic, live", "Logistic + memory"), c("Logistic, live", "Logistic + positions + memory"),
              c("Logistic, live", "Logistic + defenders' positions + memory"), c("Logistic, live", "Logistic + hard positions"),
              c("Logistic, live", "Logistic + hard positions + memory"), c("Logistic, live", "Logistic + defenders' hard positions + memory"),
              c("Logistic, live", "Logistic + defenders' hard positions"))
# Screen-level context: the screener's defender's position (his own held-out fold) and the memory at the pick frame.
pos_sd <- vapply(seq_len(nrow(L$P)), function(i) {
  pa <- PI$pos[[as.character(L$P$game_id[i])]]
  c("guard", "wing", "big")[which.max(pa[i, 4, ])]
}, "")
mem0 <- PI$mem[X$off == 0, ][order(X$idx[X$off == 0]), , drop = FALSE]





## ═════════════════════════════════════════════════════════════════════════════
## 02 - SCORES PER SCREEN ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

k_sw <- match("switch", CALLS)
y_sw <- X$call == "switch"
w_main <- window_weight(X$off, "main")
#' One model's per-screen scores: main-curve joint / guard / big, before and after the pick frame (joint), main-curve
#' switch log loss and switch probability.
per_screen <- function(Pm) {
  fl <- frame_losses(Pm, X$call, CALLS)
  s <- screen_scores(X, fl, "main")
  ba <- data.table(idx = X$idx, pre = X$off < 0, joint = fl$joint)[, .(before = mean(joint[pre]), after = mean(joint[!pre])), by = idx]
  sw <- data.table(idx = X$idx, w = w_main, p = Pm[, k_sw], y = y_sw)[w > 0, .(sw_ll = -sum(w * fifelse(y, log(p), log(1 - p))) / sum(w),
                                                                              p_sw = sum(w * p) / sum(w)), by = idx]
  Reduce(function(a, b) merge(a, b, by = "idx"), list(s, ba, sw))
}
S <- lapply(MODELS, per_screen)
games <- sort(unique(X$game_id))
#' Mean and 95% interval resampling whole games, for a per-screen value v with games g.
boot <- function(v, g) {
  set.seed(SEED)
  s <- tapply(v, g, sum)
  n <- tapply(v, g, length)
  b <- replicate(N_BOOT, {
    k <- sample(names(s), length(s), TRUE)
    sum(s[k]) / sum(n[k])
  })
  c(mean = mean(v), lo = unname(quantile(b, 0.025)), hi = unname(quantile(b, 0.975)))
}
SCORES <- c(joint = "main curve, joint", guard = "main curve, ball handler's defender", big = "main curve, screener's defender",
            before = "before the pick frame, joint", after = "at and after the pick frame, joint", sw_ll = "main curve, switch or not")
y_scr <- L$P$call == "switch"
#' How often a random switch gets a higher score than a random other screen.
auc <- function(p, yy) {
  r <- rank(p)
  (sum(r[yy]) - sum(yy) * (sum(yy) + 1) / 2) / (sum(yy) * sum(!yy))
}
scores <- rbindlist(lapply(names(MODELS), function(m) {
  d <- S[[m]]
  rbind(rbindlist(lapply(names(SCORES), function(k) as.data.table(as.list(boot(d[[k]], d$game_id)))[, `:=`(model = m, score = SCORES[[k]])])),
        data.table(mean = auc(d$p_sw, y_scr[d$idx]), lo = NA_real_, hi = NA_real_, model = m, score = "switch AUC (screen-level, main curve)"))
}))
setcolorder(scores, c("model", "score"))
fwrite(scores[, .(model, score, mean = round(mean, 4), lo = round(lo, 4), hi = round(hi, 4))], file.path(out_dir, "scores.csv"))
cat("\nScores (log loss, lower is better; AUC higher is better):\n")
print(dcast(scores, model ~ score, value.var = "mean")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)])

# Paired gains: old minus new per screen.
gain <- rbindlist(lapply(PAIRS, function(pr) {
  a <- S[[pr[1]]]
  b <- S[[pr[2]]][match(a$idx, idx)]
  rbindlist(lapply(names(SCORES), function(k) {
    d <- a[[k]] - b[[k]]
    bt <- boot(d, a$game_id)
    data.table(old = pr[1], new = pr[2], score = SCORES[[k]], gain = bt[["mean"]], lo = bt[["lo"]], hi = bt[["hi"]],
               games_better = sum(tapply(d, a$game_id, mean) > 0))
  }))
}))
fwrite(gain[, .(old, new, score, gain = round(gain, 4), lo = round(lo, 4), hi = round(hi, 4), games_better)], file.path(out_dir, "paired_gain.csv"))
cat("\nPaired gain (old minus new, above 0 = helped), 95% game interval, games improved of 10:\n")
print(gain[, .(new, score, gain = round(gain, 4), lo = round(lo, 4), hi = round(hi, 4), games_better)], nrows = 100)

# By game, main-curve joint.
by_game <- rbindlist(lapply(names(MODELS), function(m) S[[m]][, .(model = m, joint = mean(joint), sw_ll = mean(sw_ll)), by = game_id]))
fwrite(by_game[, .(model, game_id, joint = round(joint, 4), sw_ll = round(sw_ll, 4))], file.path(out_dir, "by_game.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - EACH COVERAGE AND THE SWITCH GROUPS ------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Top-coverage recall and precision on main-curve frames (each screen's frames weighted by the curve, summing to 1).
wn <- w_main / ave(w_main, X$idx, FUN = sum)
y <- match(X$call, CALLS)
per_call <- rbindlist(lapply(names(MODELS), function(m) {
  top <- max.col(MODELS[[m]], ties.method = "first")
  rbindlist(lapply(seq_along(CALLS), function(k) data.table(model = m, coverage = CALLS[k], screens = sum(wn[y == k]),
                                                            recall = sum(wn[y == k & top == k]) / sum(wn[y == k]),
                                                            precision = sum(wn[y == k & top == k]) / sum(wn[top == k]))))
}))
fwrite(per_call[, .(model, coverage, screens = round(screens), recall = round(recall, 3), precision = round(precision, 3))], file.path(out_dir, "per_call.csv"))
cat("\nRecall of each coverage (top coverage, main curve):\n")
print(dcast(per_call, model ~ coverage, value.var = "recall")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])

# Switch read by group: actual switch rate, the model's average switch probability and switch recall.
groups <- list("All screens" = rep(TRUE, nrow(L$P)), "Screener's defender a guard" = pos_sd == "guard",
               "Screener's defender a wing" = pos_sd == "wing", "Screener's defender a big" = pos_sd == "big",
               "Earlier switch in the possession" = mem0[, "sw_before"] == 1, "Cross-matched" = mem0[, "cross"] == 1,
               "Earlier pick in the possession" = mem0[, "re_pick"] == 1)
sg <- rbindlist(lapply(c("Transformer, live", "Transformer, split head control", "Transformer + positions in the switch part", "Transformer + hard positions only", "Transformer + defenders' hard positions only", "Transformer + memory only", "Transformer + personnel","Transformer + personnel, hard groups", "Logistic, live", "Logistic + positions + memory"), function(m) {
  top <- max.col(MODELS[[m]], ties.method = "first") == k_sw
  d <- S[[m]]
  rbindlist(lapply(names(groups), function(gname) {
    s <- which(groups[[gname]])
    rr <- X$idx %in% s & y_sw
    data.table(model = m, group = gname, screens = length(s), switched = mean(y_scr[s]), p_switch = mean(d$p_sw[match(s, d$idx)]),
               switch_recall = sum(wn[rr & top]) / sum(wn[rr]))
  }))
}))
fwrite(sg[, .(model, group, screens, switched = round(switched, 3), p_switch = round(p_switch, 3), switch_recall = round(switch_recall, 3))],
       file.path(out_dir, "switch_groups.csv"))
cat("\nSwitch read by group:\n")
print(sg[, .(model, group, screens, switched = round(switched, 3), p_switch = round(p_switch, 3), switch_recall = round(switch_recall, 3))], nrows = 100)
