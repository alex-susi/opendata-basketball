## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 17: step 1 of the two-step model, how long until the screen (from past frames only).
#   Rscript screen_coverage/01_scripts/17_time_to_screen.R [--report-only]
#
# For every coverage fold (one test game) this writes the step-1 inputs the coverage model of that fold will see at
# every prediction frame of every game, so that no game's estimate ever comes from a model that saw that game:
#   test game        estimated by a step-1 model fit on the other nine games
#   any other game   estimated by a step-1 model fit on the eight games that are neither the test game nor it
# Two versions (R/time_to_screen.R):
#   physics   the screener's time to stop (speed / deceleration) and the handler-screener time to meet (gap, closing
#             speed and closing acceleration), each with a flag for "the equation has an answer"; the contact gap in
#             the meet equation is the median handler-screener gap at the pick frame in the fold's training games
#   learned   a gradient-boosted model (xgboost, quantiles 10/50/90%) on the physics estimates and the raw motion:
#             its median estimate and its 10-90% spread
# Target: seconds until the pick frame (picks.frame); negative after it. Rows are the scored frames, -2 s to +1 s.
#
# Writes screen_coverage/02_cache/experiments/timing/step1.rds, and the step-1 accuracy on each test game to
# screen_coverage/03_outputs/time_to_screen/: accuracy_by_time.csv, accuracy.csv, estimates.png.
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
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "time_to_screen.R"))
exp_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "timing")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "time_to_screen")
dir.create(exp_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Training frames are thinned to every other frame (neighbouring frames are near copies); estimates cover every frame.
TRAIN_EVERY <- 2L
SEED <- 20261115L





## ═════════════════════════════════════════════════════════════════════════════
## 02 - INPUTS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
SQ <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
stopifnot(identical(L$rules, PAST_ONLY_RULES), identical(SQ$rules, PAST_ONLY_RULES), identical(SQ$screen_ids, L$P$id))
X <- L$X
D <- tts_inputs(SQ, X$idx, X$off)
y <- -X$off / FPS
games <- sort(unique(X$game_id))
# The handler-screener gap at each screen's pick frame, for the meet equation's contact gap.
gap0 <- tts_inputs(SQ, seq_len(nrow(L$P)), rep(0L, nrow(L$P)))$gap
contact_gap <- function(gs) median(gap0[L$P$game_id %in% gs], na.rm = TRUE)
cat("Median handler-screener gap at the pick frame, all games:", round(contact_gap(games), 2), "ft\n")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - CROSS-FITTED ESTIMATES -------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Step-1 inputs for the rows of `est_games`, from step-1 models fit on `fit_games` only.
estimate <- function(fit_games, est_games) {
  rows <- which(X$game_id %in% est_games)
  tr <- which(X$game_id %in% fit_games & X$off %% TRAIN_EVERY == 0L)
  cg <- contact_gap(fit_games)
  ph <- tts_physics(D, cg)
  F <- cbind(D, ph)
  set.seed(SEED)
  pred <- tts_fit(F, y, tr)(rows)
  list(rows = rows, m = cbind(as.matrix(ph[rows]), pred), contact_gap = cg)
}

# For each coverage fold: the test game from the other nine; every other game from the other eight. With
# --report-only the saved estimates are reread and only the accuracy report below is redone (fitting takes ~10 min).
cols <- c(TTS_PHYSICS, TTS_LEARNED, "t_q10", "t_q90")
step1 <- list()
t0 <- Sys.time()
REPORT_ONLY <- "--report-only" %in% commandArgs(TRUE)
if (REPORT_ONLY) {
  saved <- readRDS(file.path(exp_dir, "step1.rds"))
  stopifnot(identical(saved$screen_ids, L$P$id), identical(saved$rules, PAST_ONLY_RULES))
  step1 <- saved$folds
}
for (G in if (REPORT_ONLY) integer(0) else games) {
  M <- matrix(NA_real_, nrow(X), length(cols), dimnames = list(NULL, cols))
  rest <- setdiff(games, G)
  e <- estimate(rest, G)
  M[e$rows, ] <- e$m[, cols]
  for (H in rest) {
    e2 <- estimate(setdiff(rest, H), H)
    M[e2$rows, ] <- e2$m[, cols]
  }
  stopifnot(!anyNA(M))
  step1[[as.character(G)]] <- list(m = M, contact_gap = e$contact_gap)
  cat(sprintf("fold %d done, %.0f s\n", G, as.numeric(Sys.time() - t0, units = "secs")))
}
if (!REPORT_ONLY) {
  saveRDS(list(folds = step1, cols = cols, screen_ids = L$P$id, rules = PAST_ONLY_RULES, train_every = TRAIN_EVERY,
               settings = list(cap = TTS_CAP, still = TTS_STILL, slowing = TTS_SLOWING, quantiles = TTS_QUANTILES)),
          file.path(exp_dir, "step1.rds"))
}





## ═════════════════════════════════════════════════════════════════════════════
## 04 - ACCURACY ON THE TEST GAMES ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Each game's rows as estimated in its own fold (by models that never saw it).
held <- rbindlist(lapply(games, function(G) {
  r <- which(X$game_id == G)
  m <- step1[[as.character(G)]]$m[r, ]
  data.table(game_id = G, idx = X$idx[r], t = -y[r], truth = y[r], as.data.table(m))
}))
# Errors in seconds. Physics estimates are scored only where their equation has an answer. "No information" always
# guesses the middle of the window (0.5 s to go), the best constant for this target.
held[, `:=`(err_learned = t_q50 - truth, err_stop = fifelse(stop_ok == 1, t_stop - truth, NA_real_),
            err_meet = fifelse(meet_ok == 1, t_meet - truth, NA_real_), err_none = 0.5 - truth,
            inside = truth >= t_q10 & truth <= t_q90)]
held[, band := cut(t, c(-2, -1.5, -1, -0.5, 0, 0.5, 1), include.lowest = TRUE)]
acc_t <- held[, .(frames = .N, learned_mae = mean(abs(err_learned)), no_info_mae = mean(abs(err_none)),
                  stop_answers = mean(stop_ok == 1), stop_mae = mean(abs(err_stop), na.rm = TRUE),
                  meet_answers = mean(meet_ok == 1), meet_mae = mean(abs(err_meet), na.rm = TRUE),
                  learned_10_90_covers = mean(inside), learned_spread = mean(t_spread)), by = band]
setorder(acc_t, band)
acc <- held[, .(learned_mae = mean(abs(err_learned)), no_info_mae = mean(abs(err_none)),
                stop_mae = mean(abs(err_stop), na.rm = TRUE), meet_mae = mean(abs(err_meet), na.rm = TRUE),
                learned_10_90_covers = mean(inside), corr_spread_abs_error = cor(t_spread, abs(err_learned)))]
fwrite(acc_t[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "accuracy_by_time.csv"))
fwrite(acc[, lapply(.SD, round, 3)], file.path(out_dir, "accuracy.csv"))
print(acc_t, digits = 3)
print(acc, digits = 3)

# Estimated against true time to the pick frame: median and middle 80% of the learned estimates at each frame.
fig <- held[, .(med = median(t_q50), lo = quantile(t_q50, 0.1), hi = quantile(t_q50, 0.9),
                stop_med = median(t_stop[stop_ok == 1]), meet_med = median(t_meet[meet_ok == 1])), by = truth]
perfect <- data.table(truth = range(fig$truth))
p <- ggplot(fig, aes(truth)) +
  geom_line(data = perfect, aes(truth, truth), colour = "grey60", linetype = "dashed") +
  geom_ribbon(aes(ymin = lo, ymax = hi), fill = "#1f6fd1", alpha = 0.15) +
  geom_line(aes(y = med, colour = "learned (median, middle 80%)"), linewidth = 1) +
  geom_line(aes(y = stop_med, colour = "physics: screener stops (median)"), linewidth = 0.7) +
  geom_line(aes(y = meet_med, colour = "physics: handler and screener meet (median)"), linewidth = 0.7) +
  scale_colour_manual(values = c("learned (median, middle 80%)" = "#1f6fd1", "physics: screener stops (median)" = "#d1691f",
                                 "physics: handler and screener meet (median)" = "#2a9d55")) +
  scale_x_reverse() +
  labs(x = "True seconds until the pick frame (right = after it)", y = "Estimated seconds until the pick frame",
       colour = NULL, title = "Step 1: estimated time until the screen, held-out games",
       subtitle = "Dashed line = perfect. Physics lines only where the equation has an answer") +
  theme_minimal(base_size = 10) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank())
ggsave(file.path(out_dir, "estimates.png"), p, width = 8, height = 5, dpi = 150, bg = "white")
cat("Wrote", out_dir, "\n")
