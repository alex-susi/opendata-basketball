# Screen coverage, step 5: the four logistic models against their four transformer versions, frame by frame.
#   Rscript src/screen_coverage/05_compare.R
#
# Needs 02_per_frame.R (logistic predictions, outputs/cache/screen_coverage/logistic_per_frame.rds) and
# 04_train_transformer.R for all four variants and ten held-out games (outputs/cache/screen_coverage/tf/).
# Every model is scored on the same 1,464 screens and the same frames, each game's screens predicted by models that
# never saw that game. What differs between a logistic model and its transformer twin:
#   logistic      the four players of the screen, as ten hand-made measures (distances, levels, level speeds)
#   transformer   all ten players as tokens (position, position relative to the screener, hoop distance, level,
#                 velocity), mixed by attention; the same context numbers as its logistic twin
# The logistic "4 players + so far" and "+ archetypes" are one model per frame; their transformer twins are one
# network each that is given the seconds to the screen as an input.
#
# Writes outputs/screen_coverage/per_frame/: scores_by_frame_all_models.csv, window_summary_all_models.csv,
# transformer_vs_logistic.csv, figures/scores_by_frame_all_models.png, strips_transformer_close.csv and
# figures/strips_transformer_close/<nn>_<pick>.png (strips from the "pooled, no timing, + closeness" transformer).

suppressPackageStartupMessages({ library(data.table); library(ggplot2); library(patchwork) })
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
out_dir <- file.path(root, "outputs", "screen_coverage", "per_frame")
source(file.path(root, "src", "screen_coverage", "R", "strips.R"))
FPS <- 25

source(file.path(root, "src", "screen_coverage", "R", "predictions.R"))
L <- load_coverage_predictions(root)
P <- L$P; X <- L$X; CALLS <- L$calls; OFFS <- L$offs
MODELS <- COVERAGE_MODELS
ll_of <- function(Pm) -log(pmax(Pm[cbind(seq_len(nrow(X)), match(X$call, CALLS))], 1e-12))
LL <- lapply(L$prob, ll_of)
for (k in names(LL)) set(X, j = k, value = LL[[k]])

boot_ci <- function(score, game, reps = 2000L) {
  set.seed(1); s <- split(score, game); sums <- vapply(s, sum, 0); ns <- lengths(s)
  b <- replicate(reps, { k <- sample(names(s), length(s), TRUE); sum(sums[k]) / sum(ns[k]) })
  c(mean(score), quantile(b, c(0.025, 0.975)))
}

# ---- scores by frame -------------------------------------------------------------------------------------

sc <- X[, lapply(.SD, mean), by = off, .SDcols = names(LL)][, t := off / FPS]
fwrite(sc[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "scores_by_frame_all_models.csv"))

# paired: transformer minus its logistic twin, per frame
pair <- rbindlist(lapply(MODELS, function(m) X[, {
  ci <- boot_ci(get(paste("transformer:", m)) - get(paste("logistic:", m)), game_id)
  .(t = off[1] / FPS, model = m, change = ci[1], lo = ci[2], hi = ci[3])
}, by = off]))
fwrite(pair[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "transformer_vs_logistic.csv"))

# windows: each screen's frames averaged first, so a screen counts once
X[, window := fifelse(off < 0, "before the screen (-2.0 to -0.04 s)", "at and after the screen (0 to +1.0 s)")]
ws <- X[, c(lapply(.SD, mean), list(game_id = game_id[1])), by = .(window, idx), .SDcols = names(LL)]
win <- rbindlist(lapply(MODELS, function(m) ws[, {
  a <- get(paste("logistic:", m)); b <- get(paste("transformer:", m)); ci <- boot_ci(b - a, game_id)
  .(model = m, logistic = round(mean(a), 4), transformer = round(mean(b), 4), transformer_minus_logistic = round(ci[1], 4),
    lo = round(ci[2], 4), hi = round(ci[3], 4), games_transformer_better = sum(tapply(b - a, game_id, mean) < 0))
}, by = window]))
fwrite(win, file.path(out_dir, "window_summary_all_models.csv"))
cat("Average log loss by window (each screen counted once); transformer minus logistic, 95% game bootstrap:\n"); print(win)
cat("\nAt selected frames:\n")
print(sc[off %in% c(-50, -25, -20, -15, -10, -5, 0, 10, 25), c("t", names(LL)), with = FALSE][, lapply(.SD, round, 3)])

# ---- figure ------------------------------------------------------------------------------------------------

long <- melt(sc, id.vars = c("off", "t"), variable.name = "series", value.name = "logloss")
long[, `:=`(family = sub(":.*", "", series), model = factor(sub("^[a-z]+: ", "", series), levels = MODELS))]
MCOL <- setNames(c("#2a78d6", "#eb6834", "#1baf7a", "#6250d6"), MODELS)
base <- data.table(label = c("league", "defense so far"), logloss = c(mean(L$lg_ll), mean(L$sf_ll)))
p1 <- ggplot(long, aes(t, logloss, colour = model, linetype = family)) +
  geom_hline(data = base, aes(yintercept = logloss), linetype = "dotted", colour = c("#9a9a96", "#c98500"), inherit.aes = FALSE) +
  annotate("text", x = 0.98, y = base$logloss, label = base$label, hjust = 1, vjust = c(-0.5, 1.5), size = 3.2,
           colour = c("#9a9a96", "#c98500")) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_line(linewidth = 0.8) +
  scale_colour_manual(values = MCOL, name = NULL) +
  scale_linetype_manual(values = c(logistic = "solid", transformer = "22"), name = NULL,
                        labels = c(logistic = "logistic (4 players, hand-made measures)", transformer = "transformer (all 10 players)")) +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  guides(colour = guide_legend(order = 1, nrow = 2), linetype = guide_legend(order = 2, nrow = 2, override.aes = list(colour = "grey25"))) +
  labs(title = "Screen coverage at every frame: the four logistic models and their transformer versions",
       subtitle = sprintf("Held-out log loss (lower is better), %s screens, every model scored on the same frames of games it never saw. Dotted: baselines that ignore positions.",
                          format(nrow(P), big.mark = ",")),
       x = NULL, y = "Held-out log loss") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(size = 9), legend.key.width = unit(26, "pt"))
pair[, model := factor(model, levels = MODELS)]
p2 <- ggplot(pair, aes(t, change, colour = model, fill = model)) +
  geom_hline(yintercept = 0, colour = "grey40") + geom_vline(xintercept = 0, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.13, colour = NA) + geom_line(linewidth = 0.8) +
  scale_colour_manual(values = MCOL, guide = "none") + scale_fill_manual(values = MCOL, guide = "none") +
  scale_x_continuous(breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v)) +
  labs(subtitle = "Transformer minus its logistic twin (below zero = the transformer is better; band: 95% interval from resampling whole games)",
       x = "Seconds relative to the screen tag", y = "Change") +
  theme_minimal(base_size = 11) + theme(panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9))
ggsave(file.path(out_dir, "figures", "scores_by_frame_all_models.png"), p1 / p2 + plot_layout(heights = c(1.5, 1)),
       width = 12, height = 9, dpi = 150, bg = "white")

# ---- strips from the "pooled, no timing, + closeness" transformer -------------------------------------------

film <- fread(file.path(root, "outputs", "screen_coverage", "film_check_4players.csv"))
ids <- unique(c("pick-188630-1-12", film$id))
ids <- ids[ids %in% P$id]
draw_strips(X, L$prob[["transformer: pooled, no timing, + closeness"]], P, ids, film,
            "transformer, pooled, no timing, + closeness (all 10 players, never told when the screen comes)",
            file.path(out_dir, "strips_transformer_close.csv"), file.path(out_dir, "figures", "strips_transformer_close"),
            OFFS, FPS)
cat("\nStrips drawn for", length(ids), "screens\n")
