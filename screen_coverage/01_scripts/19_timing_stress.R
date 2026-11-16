## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 19: what happens to the coverage read when the time-to-screen estimate is wrong?
#   Rscript screen_coverage/01_scripts/19_timing_stress.R
#
# Stress test of the "learned" timing version (03_train_transformer.R --timing=learned, 4 random starts). Each held-out
# game is predicted again by its own fold's saved networks with the step-1 estimate deliberately changed, everything
# else as trained:
#   as trained         the estimate the model was built with (reproduces the saved predictions: a check)
#   0.5 s / 1 s later  every estimate pushed later (the model is told the screen is further away than step 1 thinks)
#   0.5 s / 1 s sooner every estimate pulled sooner
#   shuffled           the estimate and its spread swapped at random among the game's frames (a useless estimate
#                      that still looks like a real one)
#   true time          the true time to the pick frame with the narrowest spread step 1 ever gives (a perfect step 1:
#                      the ceiling of the idea)
# Compared with the "none" version (no timing input) on the same screens, main time-weight curve, games resampled.
#
# Writes screen_coverage/03_outputs/timing_compare/stress.csv.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "seq_transformer.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
torch_set_num_threads(4L)
exp_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "timing")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "timing_compare")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS AND DATA ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

SEED_SETS <- c("tf_s1-2", "tf_s3-4")
N_BOOT <- 2000L
SEED <- 20261115L
L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
SQ <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
S1 <- readRDS(file.path(exp_dir, "step1.rds"))
X <- L$X
calls <- L$calls
games <- sort(unique(X$game_id))
NS <- dim(SQ$base)[1]
flat <- matrix(SQ$base, nrow = NS * dim(SQ$base)[2])
truth <- -X$off / FPS
# Narrowest spread step 1 gives anywhere (its 1st percentile), used with the true time.
min_spread <- quantile(unlist(lapply(S1$folds, function(f) f$m[, "t_spread"])), 0.01, names = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PREDICT WITH CHANGED ESTIMATES -----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' The scenarios: each a function of the game's step-1 matrix rows `m` and their true times `tt`, returning the
#' (median, spread) columns to feed.
SCENARIOS <- list(
  "as trained" = function(m, tt) m[, c("t_q50", "t_spread")],
  "0.5 s later" = function(m, tt) cbind(m[, "t_q50"] + 0.5, m[, "t_spread"]),
  "1 s later" = function(m, tt) cbind(m[, "t_q50"] + 1, m[, "t_spread"]),
  "0.5 s sooner" = function(m, tt) cbind(m[, "t_q50"] - 0.5, m[, "t_spread"]),
  "1 s sooner" = function(m, tt) cbind(m[, "t_q50"] - 1, m[, "t_spread"]),
  "shuffled" = function(m, tt) m[sample.int(nrow(m)), c("t_q50", "t_spread")],
  "true time" = function(m, tt) cbind(tt, min_spread)
)

set.seed(SEED)
probs <- setNames(lapply(SCENARIOS, function(s) matrix(NA_real_, nrow(X), length(calls))), names(SCENARIOS))
for (g in games) {
  r <- which(X$game_id == g)
  folds <- lapply(SEED_SETS, function(s) readRDS(file.path(exp_dir, "learned", s, sprintf("seqheads_%d.rds", g))))
  nets <- unlist(lapply(seq_along(SEED_SETS), function(k) {
    lapply(file.path(exp_dir, "learned", SEED_SETS[k], basename(folds[[k]]$nets)), torch_load)
  }))
  for (n in nets) n$eval()
  norms <- rep(lapply(folds, `[[`, "norm"), each = 2)
  m <- S1$folds[[as.character(g)]]$m[r, ]
  hist <- seq_history(flat, NS, X$idx[r], X$off[r], folds[[1]]$k_steps, SQ$base_offs, SQ$step, SQ$feats, SQ$flip)
  for (sc in names(SCENARIOS)) {
    ctx <- cbind(SQ$ctx[r, ], SCENARIOS[[sc]](m, truth[r]))
    # Each network with its own fold's standardisation; the four averaged.
    p <- Reduce(`+`, lapply(seq_along(nets), function(k) {
      nm <- norms[[k]]
      xt <- standardise_history(hist, nm)
      ct <- torch_tensor(scale(ctx, nm$cmu, nm$csd))
      as_array(with_no_grad(joint_logp(nets[[k]](xt, ct))$exp()))
    })) / length(nets)
    probs[[sc]][r, ] <- p
  }
  # Check: "as trained" reproduces the saved predictions.
  saved <- Reduce(`+`, lapply(folds, `[[`, "prob")) / length(folds)
  stopifnot(max(abs(probs[["as trained"]][r, ] - saved)) < 1e-4)
  cat("game", g, "done\n")
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SCORES -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The "none" version's held-out predictions, 4 random starts.
none <- matrix(NA_real_, nrow(X), length(calls))
for (g in games) {
  f <- lapply(SEED_SETS, function(s) readRDS(file.path(exp_dir, "none", s, sprintf("seqheads_%d.rds", g))))
  none[f[[1]]$rows, ] <- Reduce(`+`, lapply(f, `[[`, "prob")) / length(f)
}
set.seed(SEED)
draws <- replicate(N_BOOT, sample(games, replace = TRUE), simplify = FALSE)
base_s <- screen_scores(X, frame_losses(none, X$call, calls), "main")
stress <- rbindlist(lapply(names(probs), function(sc) {
  s <- screen_scores(X, frame_losses(probs[[sc]], X$call, calls), "main")
  d <- merge(s, base_s, by = c("idx", "game_id"), suffixes = c("", "_none"))
  # Gain over "none" per game, then resampled (positive = better than having no timing input).
  g <- d[, .(gain = sum(joint_none - joint), n = .N, guard = sum(guard_none - guard), big = sum(big_none - big)), by = game_id]
  v <- vapply(draws, function(dd) {
    k <- match(dd, g$game_id)
    sum(g$gain[k]) / sum(g$n[k])
  }, numeric(1))
  data.table(scenario = sc, joint = mean(d$joint), guard = mean(d$guard), big = mean(d$big),
             gain_vs_none = sum(g$gain) / sum(g$n), lo = quantile(v, 0.025, names = FALSE), hi = quantile(v, 0.975, names = FALSE),
             guard_gain = sum(g$guard) / sum(g$n), big_gain = sum(g$big) / sum(g$n), games_better = sum(g$gain > 0))
}))
stress <- rbind(data.table(scenario = "none (no timing input)", joint = mean(base_s$joint), guard = mean(base_s$guard),
                           big = mean(base_s$big), gain_vs_none = 0, lo = NA_real_, hi = NA_real_, guard_gain = 0, big_gain = 0,
                           games_better = NA_integer_), stress)
fwrite(stress[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "stress.csv"))
print(stress, digits = 3)
