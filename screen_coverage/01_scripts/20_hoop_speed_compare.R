## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 20: does giving each player his speed toward or away from the hoop help the coverage read?
#   Rscript screen_coverage/01_scripts/20_hoop_speed_compare.R
#
# Prompted by the owner's play review (game 114243, #55 Perez sinking under a screen the live model read as over;
# 16_screen_timing_check.R): the live model sees each player's movement as up-court and sideways pieces and his
# level against the screener, which mixes the defender's and the screener's movement. Two versions trained under the
# same rules (03_train_transformer.R --timing=none, early stopping on the main time-weight curve, 4 random starts):
#   none          the current model's settings (the timing experiment's baseline)
#   hoop speed    plus one movement channel per player and frame: his speed away from (+) or toward (-) the hoop
#                 (--extra=hoop_speed)
# Scores: log loss of the full call and each defender under the three fixed time-weight curves, game-resampled 95%
# intervals and paired gains; the ball handler's defender's over-vs-under read by moment (switch screens left out), the
# moment and question the hoop speed targets; and the reviewed play.
#
# Writes screen_coverage/03_outputs/hoop_speed_compare/: scores.csv, paired_gain.csv, over_under_by_time.csv,
# by_time.csv, this_play.csv, validation_scores.csv.
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
exp_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "timing")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "hoop_speed_compare")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS AND PREDICTIONS -----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

VERSIONS <- c(none = "none", hoop_speed = "none+hoop_speed")
SEED_SETS <- c("tf_s1-2", "tf_s3-4")
N_BOOT <- 2000L
SEED <- 20261115L
PLAY <- list(game_id = 114243L, f0 = 69861L)
FPS <- 25

L <- load_logistic(root)
X <- L$X
calls <- L$calls
games <- sort(unique(X$game_id))

#' A version's held-out probabilities (the two seed sets averaged) and its validation-game probabilities per fold.
load_version <- function(dir) {
  test <- matrix(NA_real_, nrow(X), length(calls))
  val <- list()
  for (g in games) {
    parts <- lapply(SEED_SETS, function(s) readRDS(file.path(exp_dir, dir, s, sprintf("seqheads_%d.rds", g))))
    for (o in parts) if (!identical(o$rules, L$rules) || !identical(o$screen_ids, L$P$id)) stop("stale fold file: ", dir, " ", g)
    test[parts[[1]]$rows, ] <- Reduce(`+`, lapply(parts, `[[`, "prob")) / length(parts)
    val[[as.character(g)]] <- list(rows = parts[[1]]$val_rows, prob = Reduce(`+`, lapply(parts, `[[`, "val_prob")) / length(parts))
  }
  stopifnot(!anyNA(test))
  list(test = test, val = val)
}
V <- lapply(VERSIONS, load_version)
models <- c(lapply(V, `[[`, "test"), list(live = load_seqheads(root, do.call(file.path, c(list(root), SEQ_FLAT_DIR)))$prob))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - SCORES AND PAIRED GAINS ------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

long <- rbindlist(lapply(names(models), function(m) {
  loss <- frame_losses(models[[m]], X$call, calls)
  rbindlist(lapply(names(WINDOW_CURVES), function(cv) screen_scores(X, loss, cv)[, `:=`(model = m, curve = cv)]))
}))
long <- melt(long, id.vars = c("model", "curve", "idx", "game_id"), variable.name = "score", value.name = "loss")

set.seed(SEED)
draws <- replicate(N_BOOT, sample(games, replace = TRUE), simplify = FALSE)
boot_mean <- function(sum_g, n_g, game_g) {
  s <- setNames(sum_g, game_g)
  n <- setNames(n_g, game_g)
  v <- vapply(draws, function(g) sum(s[as.character(g)]) / sum(n[as.character(g)]), numeric(1))
  list(mean = sum(sum_g) / sum(n_g), lo = quantile(v, 0.025, names = FALSE), hi = quantile(v, 0.975, names = FALSE))
}
scores <- long[, .(sum = sum(loss), n = .N), by = .(model, curve, score, game_id)][, boot_mean(sum, n, game_id),
                                                                                   by = .(model, curve, score)]
fwrite(scores[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "scores.csv"))

# Paired gain of hoop speed (and of the live model) over "none": positive = better; games better of 10.
wide <- dcast(long, curve + score + idx + game_id ~ model, value.var = "loss")
paired <- rbindlist(lapply(c("hoop_speed", "live"), function(m) {
  g <- wide[, .(gain = none - get(m)), by = .(curve, score, game_id)][, .(sum = sum(gain), n = .N), by = .(curve, score, game_id)]
  g[, c(boot_mean(sum, n, game_id), .(games_better = sum(sum > 0))), by = .(curve, score)][, model := m]
}))
fwrite(paired[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "paired_gain.csv"))
print(dcast(scores, curve + score ~ model, value.var = "mean"), digits = 4)
print(paired[model == "hoop_speed"], digits = 3)

# What a per-fold selection on the validation game would have seen (main curve, full call).
val_scores <- rbindlist(lapply(names(VERSIONS), function(v) rbindlist(lapply(games, function(g) {
  e <- V[[v]]$val[[as.character(g)]]
  s <- screen_scores(X[e$rows], frame_losses(e$prob, X$call[e$rows], calls), "main")
  data.table(version = v, fold = g, joint = mean(s$joint), guard = mean(s$guard), big = mean(s$big))
}))))
fwrite(val_scores[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "validation_scores.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - BY MOMENT, OVER VS UNDER, AND THE REVIEWED PLAY ------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Every frame counted equally, by time from the pick frame.
by_time <- rbindlist(lapply(names(models), function(m) {
  data.table(model = m, t = X$off / FPS, frame_losses(models[[m]], X$call, calls))[,
    .(joint = mean(joint), guard = mean(guard), big = mean(big)), by = .(model, t)]
}))
fwrite(by_time[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "by_time.csv"))

# The ball handler's defender, over vs under only (switch screens left out; the two shares renormalised).
guard <- ifelse(grepl("^over", X$call), "over", ifelse(grepl("^under", X$call), "under", "switch"))
ou <- rbindlist(lapply(names(models), function(m) {
  p <- models[[m]]
  pu <- (p[, 3] + p[, 4]) / (p[, 1] + p[, 2] + p[, 3] + p[, 4])
  data.table(model = m, game_id = X$game_id, off = X$off, t = X$off / FPS, under = guard == "under", pu = pu)[under | guard == "over"]
}))
ou_t <- ou[off %in% seq(-25L, 25L, 5L), .(logloss = mean(-log(fifelse(under, pu, 1 - pu))),
                                               under_read_on_unders = mean(pu[under]), under_read_on_overs = mean(pu[!under])),
           by = .(model, t)]
fwrite(ou_t[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "over_under_by_time.csv"))
print(dcast(ou_t, t ~ model, value.var = "logloss"), digits = 4)

# The reviewed play: the ball handler's defender's over / under read around the pick frame.
k <- L$P[game_id == PLAY$game_id & f0 == PLAY$f0, which = TRUE]
r <- which(X$idx == k & X$off %in% seq(-25L, 10L, 5L))
this_play <- rbindlist(lapply(names(models), function(m) {
  p <- models[[m]][r, ]
  data.table(model = m, t = X$off[r] / FPS, over = p[, 1] + p[, 2], under = p[, 3] + p[, 4], switch = p[, 5])
}))
fwrite(this_play[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "this_play.csv"))
print(dcast(this_play, t ~ model, value.var = "under"), digits = 2)
cat("Wrote", out_dir, "\n")
