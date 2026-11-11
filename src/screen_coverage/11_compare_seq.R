# Screen coverage, step 11: the time-aware, two-head transformer against the earlier models, and every figure redrawn
# with it.
#   Rscript src/screen_coverage/11_compare_seq.R
#
# Needs 02-07 (earlier models) and 10_train_seq_transformer.R for all ten games. Every model is scored on the same
# 1,464 screens and frames of games it never saw. The comparison of interest is against the current live model
# ("transformer: pooled, no timing, + closeness", which also never knows when the screen comes) and against the best
# timing-aware logistic model ("4 players + so far").
#
# Writes outputs/screen_coverage/per_frame/seq_heads/:
#   window_summary.csv, scores_by_frame.csv, head_metrics.csv, metrics_by_frame.csv, per_call.csv, confusion.csv,
#   attention_by_role.csv, strips.csv
#   figures/scores_by_frame.png, accuracy_by_frame.png, confusion.png, heads_by_frame.png, strips/<nn>_<pick>.png

suppressPackageStartupMessages({ library(data.table); library(ggplot2); library(patchwork) })
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "src", "screen_coverage", "R", "predictions.R"))
source(file.path(root, "src", "screen_coverage", "R", "strips.R"))
out_dir <- file.path(root, "outputs", "screen_coverage", "per_frame", "seq_heads")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)
FPS <- 25

L <- load_coverage_predictions(root)
P <- L$P; X <- L$X; CALLS <- L$calls
NEW <- "time-aware transformer, two heads"
LIVE <- "transformer: pooled, no timing, + closeness"
BEST_LOG <- "logistic: 4 players + so far"
files <- file.path(root, "outputs", "cache", "screen_coverage", "tf", sprintf("seqheads_%d.rds", sort(unique(X$game_id))))
stopifnot(all(file.exists(files)))
PN <- matrix(NA_real_, nrow(X), 5); HN <- matrix(NA_real_, nrow(X), 3); AN <- matrix(NA_real_, nrow(X), 10)
for (f in files) { o <- readRDS(f); PN[o$rows, ] <- o$prob; HN[o$rows, ] <- o$heads; AN[o$rows, ] <- o$att }
stopifnot(!anyNA(PN))
probs <- c(list(PN), L$prob); names(probs)[1] <- NEW
y <- match(X$call, CALLS)
ll_of <- function(Pm) -log(pmax(Pm[cbind(seq_len(nrow(X)), y)], 1e-12))
LL <- lapply(probs, ll_of)
for (k in names(LL)) set(X, j = k, value = LL[[k]])

boot_ci <- function(score, game, reps = 2000L) {
  set.seed(1); s <- split(score, game); sums <- vapply(s, sum, 0); ns <- lengths(s)
  b <- replicate(reps, { k <- sample(names(s), length(s), TRUE); sum(sums[k]) / sum(ns[k]) })
  c(mean(score), quantile(b, c(0.025, 0.975)))
}

# ---- log loss by window and by frame --------------------------------------------------------------------------

X[, window := fifelse(off < 0, "before the screen (-2.0 to -0.04 s)", "at and after the screen (0 to +1.0 s)")]
ws <- X[, c(lapply(.SD, mean), list(game_id = game_id[1])), by = .(window, idx), .SDcols = names(LL)]
win <- rbindlist(lapply(c(LIVE, BEST_LOG), function(ref) ws[, {
  a <- get(NEW); b <- get(ref); ci <- boot_ci(a - b, game_id)
  .(compared_with = ref, new = round(mean(a), 4), other = round(mean(b), 4), new_minus_other = round(ci[1], 4),
    lo = round(ci[2], 4), hi = round(ci[3], 4), games_new_better = sum(tapply(a - b, game_id, mean) < 0))
}, by = window]))
fwrite(win, file.path(out_dir, "window_summary.csv"))
cat("Log loss by window (each screen counted once); new minus the other model, 95% game bootstrap:\n"); print(win)
allwin <- ws[, lapply(.SD, function(v) round(mean(v), 4)), by = window, .SDcols = names(LL)]
cat("\nAll models by window:\n"); print(melt(allwin, id.vars = "window", variable.name = "model")[order(window, value)])

sc <- X[, lapply(.SD, mean), by = off, .SDcols = names(LL)][, t := off / FPS]
fwrite(sc[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "scores_by_frame.csv"))
pair <- rbindlist(lapply(c(LIVE, BEST_LOG), function(ref) X[, {
  ci <- boot_ci(get(NEW) - get(ref), game_id); .(t = off[1] / FPS, ref = ref, change = ci[1], lo = ci[2], hi = ci[3])
}, by = off]))
cat("\nLog loss at selected moments:\n")
print(sc[off %in% c(-50, -25, -15, -10, -5, 0, 10, 25), .(t, new = round(get(NEW), 3), live = round(get(LIVE), 3), logistic = round(get(BEST_LOG), 3))])

long <- melt(sc, id.vars = c("off", "t"), variable.name = "series", value.name = "logloss")
long[, series := as.character(series)]
long[, grp := fcase(series == NEW, "new", series == LIVE, "live", series == BEST_LOG, "logistic", default = "other")]
base <- data.table(label = c("league", "defense so far"), logloss = c(mean(L$lg_ll), mean(L$sf_ll)))
SCOL <- c(new = "#d1495b", live = "#6250d6", logistic = "#2a78d6", other = "#c4c7cc")
SLAB <- c(new = "time-aware transformer, two heads (new)", live = "live: transformer, no timing, + closeness",
          logistic = "logistic, 4 players + so far (knows the timing)", other = "the other five earlier models")
p1 <- ggplot(long, aes(t, logloss, group = series, colour = grp)) +
  geom_hline(data = base, aes(yintercept = logloss), linetype = "dotted", colour = c("#9a9a96", "#c98500"), inherit.aes = FALSE) +
  annotate("text", x = 0.98, y = base$logloss, label = base$label, hjust = 1, vjust = c(-0.5, 1.5), size = 3.2, colour = c("#9a9a96", "#c98500")) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_line(data = long[grp == "other"], linewidth = 0.5) + geom_line(data = long[grp != "other"], linewidth = 1) +
  scale_colour_manual(values = SCOL, labels = SLAB, breaks = c("new", "live", "logistic", "other"), name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  guides(colour = guide_legend(nrow = 2)) +
  labs(title = "Screen coverage at every frame: the time-aware, two-head transformer against the earlier models",
       subtitle = sprintf("Held-out log loss (lower is better), %s screens, every model scored on the same frames of games it never saw.", format(nrow(P), big.mark = ",")),
       x = NULL, y = "Held-out log loss") +
  theme_minimal(base_size = 11) + theme(legend.position = "top", panel.grid.minor = element_blank(),
                                        plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9))
pair[, ref := factor(ref, levels = c(LIVE, BEST_LOG), labels = c("new minus the live transformer", "new minus the timing-aware logistic"))]
p2 <- ggplot(pair, aes(t, change, colour = ref, fill = ref)) +
  geom_hline(yintercept = 0, colour = "grey40") + geom_vline(xintercept = 0, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.15, colour = NA) + geom_line(linewidth = 0.9) +
  scale_colour_manual(values = c("#6250d6", "#2a78d6"), name = NULL) + scale_fill_manual(values = c("#6250d6", "#2a78d6"), name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  labs(subtitle = "Paired change in log loss (below zero = the new model is better; band: 95% interval from resampling whole games)",
       x = "Seconds relative to the screen tag", y = "Change") +
  theme_minimal(base_size = 11) + theme(legend.position = "top", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9))
ggsave(file.path(out_dir, "figures", "scores_by_frame.png"), p1 / p2 + plot_layout(heights = c(1.5, 1)), width = 12, height = 9, dpi = 150, bg = "white")

# ---- top call, and each defender on his own ---------------------------------------------------------------------

BD_OF <- c("over", "over", "under", "under", "switch"); BIG_OF <- c("show", "soft", "soft", "show", "switch")
sofar <- as.matrix(P[X$idx, paste0("so_far_", seq_along(CALLS)), with = FALSE])
cls <- c(probs[c(NEW, LIVE, BEST_LOG)], list(`baseline: always over + show` = matrix(rep(c(1, 0, 0, 0, 0), each = nrow(X)), nrow(X)),
                                             `baseline: defense's most frequent call so far` = sofar))
part <- function(Pm, of) { lv <- unique(of); m <- sapply(lv, function(l) rowSums(Pm[, of == l, drop = FALSE])); list(lv = lv, m = m) }
calls_of <- lapply(cls, function(Pm) max.col(Pm, ties.method = "first"))
per_call <- function(pred, truth) rbindlist(lapply(seq_along(CALLS), function(k) {
  tp <- sum(pred == k & truth == k); np <- sum(pred == k); na <- sum(truth == k)
  prec <- if (np) tp / np else NA_real_; rec <- if (na) tp / na else NA_real_
  data.table(call = CALLS[k], happened = na, called = np, right = tp, precision = prec, recall = rec,
             f1 = if (is.na(prec) || is.na(rec) || prec + rec == 0) 0 else 2 * prec * rec / (prec + rec))
}))
pc_bd <- lapply(cls, part, of = BD_OF); pc_big <- lapply(cls, part, of = BIG_OF)
bd_true <- BD_OF[y]; big_true <- BIG_OF[y]
metrics <- function(rows, m) {
  pc <- per_call(calls_of[[m]][rows], y[rows])
  bd <- pc_bd[[m]]; bg <- pc_big[[m]]
  bd_call <- bd$lv[max.col(bd$m[rows, , drop = FALSE], ties.method = "first")]
  big_call <- bg$lv[max.col(bg$m[rows, , drop = FALSE], ties.method = "first")]
  bd_p <- bd$m[cbind(rows, match(bd_true[rows], bd$lv))]; big_p <- bg$m[cbind(rows, match(big_true[rows], bg$lv))]
  data.table(accuracy = mean(calls_of[[m]][rows] == y[rows]), macro_recall = mean(pc$recall),
             macro_f1 = mean(pc$f1), ball_defender_accuracy = mean(bd_call == bd_true[rows]), big_accuracy = mean(big_call == big_true[rows]),
             ball_defender_logloss = -mean(log(pmax(bd_p, 1e-12))), big_logloss = -mean(log(pmax(big_p, 1e-12))))
}
by_frame <- rbindlist(lapply(names(cls), function(m) rbindlist(lapply(sort(unique(X$off)), function(o)
  cbind(data.table(model = m, off = o, t = o / FPS), metrics(which(X$off == o), m))))))
fwrite(by_frame[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "metrics_by_frame.csv"))
hm <- rbindlist(lapply(names(cls), function(m) rbindlist(lapply(unique(X$window), function(w)
  cbind(data.table(model = m, window = w), metrics(which(X$window == w), m))))))
fwrite(hm[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "head_metrics.csv"))
cat("\nTop-call and per-defender metrics by window:\n")
print(hm[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])
cat("\nAccuracy at selected moments:\n")
print(dcast(by_frame[round(t, 2) %in% c(-1, -0.6, -0.4, -0.2, 0, 0.4)], model ~ t, value.var = "accuracy")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])

pcl <- rbindlist(lapply(c(-1.0, -0.6, -0.4, -0.2, 0, 0.4), function(tc) {
  r <- X$off == round(tc * FPS); cbind(data.table(t = tc), per_call(calls_of[[NEW]][r], y[r]))
}))
fwrite(pcl[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "per_call.csv"))
cat("\nNew model, call by call:\n"); print(pcl[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 2) else v)])

bfm <- by_frame[model %in% c(NEW, LIVE, BEST_LOG)]
bfm[, grp := fcase(model == NEW, "new", model == LIVE, "live", default = "logistic")]
blm <- by_frame[startsWith(model, "baseline")]
apanel <- function(col, ttl, ylab, legend = FALSE) {
  lab <- blm[off == max(off)]; lab[, vj := fifelse(get(col) == max(get(col)), -0.5, 1.5)]
  ggplot(bfm, aes(t, .data[[col]], colour = grp)) +
    geom_line(data = blm, aes(t, .data[[col]], group = model), inherit.aes = FALSE, colour = "grey55", linetype = "dotted") +
    geom_text(data = lab, aes(t, .data[[col]], label = sub("baseline: ", "", model), vjust = vj), inherit.aes = FALSE, hjust = 1, size = 3, colour = "grey40") +
    geom_vline(xintercept = 0, colour = "grey60") + geom_line(linewidth = 0.9) +
    scale_colour_manual(values = SCOL[c("new", "live", "logistic")], labels = SLAB[c("new", "live", "logistic")], breaks = c("new", "live", "logistic"), name = NULL) +
    scale_y_continuous(labels = function(v) paste0(round(100 * v), "%")) +
    scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
    labs(subtitle = ttl, x = NULL, y = ylab) + theme_minimal(base_size = 11) +
    theme(legend.position = if (legend) "top" else "none", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9.5))
}
ga <- apanel("accuracy", "Accuracy: share of top calls that were right (out of five calls)", "Accuracy", TRUE) /
  apanel("macro_recall", "Balanced accuracy: recall averaged over the five calls", "Balanced acc.") /
  apanel("ball_defender_accuracy", "Ball defender only: over, under or switch", "Accuracy") /
  (apanel("big_accuracy", "Big only: show, soft or switch", "Accuracy") + labs(x = "Seconds relative to the screen tag")) +
  plot_annotation(title = "If each model just called its most likely coverage: how often it was right, frame by frame",
                  subtitle = sprintf("%s screens, held-out games. Dotted grey: baselines.", format(nrow(P), big.mark = ",")),
                  theme = theme(plot.title = element_text(face = "bold", size = 13)))
ggsave(file.path(out_dir, "figures", "accuracy_by_frame.png"), ga, width = 12, height = 13, dpi = 150, bg = "white")

# each head on its own: log loss of the ball defender's and the big's calls
hl <- melt(bfm[, .(t, grp, `Ball defender (over / under / switch)` = ball_defender_logloss, `Big (show / soft / switch)` = big_logloss)],
           id.vars = c("t", "grp"), variable.name = "head", value.name = "logloss")
gh <- ggplot(hl, aes(t, logloss, colour = grp)) + geom_vline(xintercept = 0, colour = "grey60") + geom_line(linewidth = 0.9) +
  facet_wrap(~ head, nrow = 1) +
  scale_colour_manual(values = SCOL[c("new", "live", "logistic")], labels = SLAB[c("new", "live", "logistic")], breaks = c("new", "live", "logistic"), name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f", v)) +
  labs(title = "Each defender's call on its own: held-out log loss (lower is better)",
       subtitle = "Three outcomes per defender; the earlier models' joint probabilities are summed to the same three for a fair comparison.",
       x = "Seconds relative to the screen tag", y = "Log loss") +
  theme_minimal(base_size = 11) + theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
                                        plot.subtitle = element_text(size = 9.5), strip.text = element_text(face = "bold"))
ggsave(file.path(out_dir, "figures", "heads_by_frame.png"), gh, width = 12, height = 5.5, dpi = 150, bg = "white")

conf <- rbindlist(lapply(c(-0.4, 0), function(tc) {
  r <- X$off == round(tc * FPS)
  d <- data.table(actual = factor(CALLS[y[r]], CALLS), called = factor(CALLS[calls_of[[NEW]][r]], CALLS))[, .N, by = .(actual, called)]
  d <- CJ(actual = factor(CALLS, CALLS), called = factor(CALLS, CALLS))[d, on = .(actual, called), N := i.N][is.na(N), N := 0L]
  d[, share := N / sum(N), by = actual][, t := tc]
}))
fwrite(conf, file.path(out_dir, "confusion.csv"))
conf[, `:=`(lab = sprintf("%d\n%.0f%%", N, 100 * share), panel = factor(sprintf("%+.1f s", t), levels = sprintf("%+.1f s", c(-0.4, 0))))]
pcf <- ggplot(conf, aes(called, actual, fill = share)) + geom_tile(colour = "white", linewidth = 1) +
  geom_text(aes(label = lab, colour = share > 0.5), size = 3.2, lineheight = 0.9) +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = "grey15"), guide = "none") +
  scale_fill_gradient(low = "#f1f6fd", high = "#1d5fae", labels = function(v) paste0(100 * v, "%"), name = "Share of\nthe row") +
  scale_y_discrete(limits = rev) + facet_wrap(~ panel) + coord_equal() +
  labs(title = "The time-aware, two-head transformer's calls against what happened",
       subtitle = "Rows: the coverage that happened; each row sums to 100% (the diagonal is recall).", x = "The model's top call", y = "What happened") +
  theme_minimal(base_size = 11) + theme(panel.grid = element_blank(), axis.text.x = element_text(angle = 30, hjust = 1),
                                        plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9.5))
ggsave(file.path(out_dir, "figures", "confusion.png"), pcf, width = 12, height = 6.2, dpi = 150, bg = "white")

# ---- attention, strips ----------------------------------------------------------------------------------------

roles <- c("ball handler", "screener", "handler's defender", "screener's defender", rep("other attacker", 3), rep("other defender", 3))
att <- data.table(role = roles, share = colMeans(AN))[, .(share_per_player = round(mean(share), 3)), by = role]
fwrite(att, file.path(out_dir, "attention_by_role.csv"))
cat("\nAttention per player by role (even split = 0.10):\n"); print(att)

film <- fread(file.path(root, "outputs", "screen_coverage", "film_check_4players.csv"))
ids <- unique(c("pick-188630-1-12", film$id)); ids <- ids[ids %in% P$id]
draw_strips(X, PN, P, ids, film, "time-aware transformer, two linked heads (last 1.6 s of all ten players; never told when the screen comes)",
            file.path(out_dir, "strips.csv"), file.path(out_dir, "figures", "strips"), L$offs, FPS)
cat("\nStrips drawn for", length(ids), "screens\n")
