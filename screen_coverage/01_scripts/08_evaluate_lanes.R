## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, lane experiment: matched comparison of the roll-lane variants against the live model.
#   Rscript screen_coverage/01_scripts/08_evaluate_lanes.R [--boot-seed=20261115]
#
# Needs 01_logistic_baseline.R, the live folds (03_train_transformer.R) and the experiment's folds
# (03_train_transformer.R --variant=... --seeds=...). Variants without all ten folds are skipped and listed.
#
# Models, all held out by game, on the same 1,463 screens x 76 frames (keys checked: one row per game, screen and
# frame offset, identical across models):
#   A          the live v2 transformer (seeds 1-2), read from screen_coverage/02_cache/tf/
#   A seeds 3-4  the same inputs and settings with two other random starts: how far a score moves by chance alone
#   B          A plus roll distance, closing speed and validity for the three off-ball defenders
#   C          A plus roll distance and validity (only if trained)
#
# Scores (lower is better), each from the averaged five-call probabilities in their stored order:
#   big      the screener's defender: show = over + show + under + show, drop = over + drop + under + drop,
#            switch = switch. PRIMARY: at -0.4 s (offset -10); repeated at -0.8 s (offset -20)
#   guard    the handler's defender: over = both over calls, under = both under calls, switch
#   joint    the five calls
# Loss -log(max(p, 1e-12)) of the tagged call. Windows: before the tag (forecast; frames averaged within a screen
# first) and from the tag on (recognition). Paired differences delta = variant - reference on the same rows; a 95%
# interval from 2,000 draws of whole games (all of a game's screens together), the number of games that improve, and
# the largest single game's share of the summed change.
#
# Writes screen_coverage/03_outputs/experiments/lanes/: pooled_results.csv, by_game.csv, secondary_metrics.csv,
# reliability_big.csv, confusion_big.csv, validity_by_game_lead.csv, availability_subsets.csv, manifest.json.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "lane_variants.R"))
hit <- grep("^--boot-seed=", commandArgs(TRUE), value = TRUE)
BOOT_SEED <- if (length(hit)) as.integer(sub("^--boot-seed=", "", hit)) else 20261115L
BOOT_REPS <- 2000L
out_dir <- lane_out_dir(root)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
t_start <- Sys.time()





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PREDICTIONS ON THE SAME ROWS -------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- copy(L$X)
P <- L$P
CALLS <- L$calls
stopifnot(identical(CALLS, c("over + show", "over + drop", "under + drop", "under + show", "switch")))
stopifnot(X[, .N, by = .(game_id, id, off)][, all(N == 1L)])
games <- sort(unique(X$game_id))

#' Five-call probabilities [rows x 5] in X's row order from a folder of fold files, or NULL if any fold is missing.
gather <- function(dir) {
  paths <- file.path(dir, sprintf("seqheads_%d.rds", games))
  if (!all(file.exists(paths))) return(NULL)
  Pm <- matrix(NA_real_, nrow(X), 5)
  for (p in paths) {
    o <- read_fold(p, L)
    Pm[o$rows, ] <- o$prob
  }
  stopifnot(!anyNA(Pm), max(abs(rowSums(Pm) - 1)) < 1e-4)
  Pm
}
SOURCES <- c(`A` = file.path(root, "screen_coverage", "02_cache", "tf"),
             `A seeds 3-4` = lane_tf_dir(root, "A", 3:4),
             `B` = lane_tf_dir(root, "B", 1:2),
             `C` = lane_tf_dir(root, "C", 1:2))
PROB <- lapply(SOURCES, gather)
missing <- names(PROB)[vapply(PROB, is.null, NA)]
PROB <- PROB[!vapply(PROB, is.null, NA)]
if (length(missing)) cat("Skipped (not all ten folds fitted):", paste(missing, collapse = ", "), "\n")
stopifnot("A" %in% names(PROB))
MODELS <- names(PROB)

# The two defenders' marginal calls and the tagged outcome of each.
y <- match(X$call, CALLS)
BIG_OF <- c("show", "drop", "drop", "show", "switch")
BD_OF <- c("over", "over", "under", "under", "switch")
BIG_LV <- c("show", "drop", "switch")
BD_LV <- c("over", "under", "switch")
marg <- function(Pm, of, lv) sapply(lv, function(l) rowSums(Pm[, of == l, drop = FALSE]))
ll <- function(Pm, k) -log(pmax(Pm[cbind(seq_len(nrow(Pm)), k)], 1e-12))
LOSS <- list()
for (m in MODELS) {
  Pm <- PROB[[m]]
  LOSS[[m]] <- data.table(joint = ll(Pm, y), big = ll(marg(Pm, BIG_OF, BIG_LV), match(BIG_OF[y], BIG_LV)),
                          guard = ll(marg(Pm, BD_OF, BD_LV), match(BD_OF[y], BD_LV)))
}
METRICS <- c("big", "guard", "joint")
HORIZONS <- list(`-0.8 s` = quote(off == -20L), `-0.4 s` = quote(off == -10L),
                 `before the tag (forecast)` = quote(off < 0L), `tag to +1 s (recognition)` = quote(off >= 0L))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PAIRED COMPARISONS WITH A GAME BOOTSTRAP -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Ratio-of-sums bootstrap over whole games, as in the v2 evaluator: per-screen scores `d` and their games.
boot_ci <- function(d, game, reps = BOOT_REPS, seed = BOOT_SEED) {
  set.seed(seed)
  s <- split(d, game)
  sums <- vapply(s, sum, 0)
  ns <- lengths(s)
  b <- replicate(reps, {
    k <- sample(names(s), length(s), TRUE)
    sum(sums[k]) / sum(ns[k])
  })
  c(mean(d), quantile(b, c(0.025, 0.975)))
}
#' Per-screen scores for one horizon: one row per screen (frames averaged within the screen for a window).
per_screen <- function(v, h) {
  keep <- X[, eval(HORIZONS[[h]])]
  data.table(idx = X$idx[keep], game_id = X$game_id[keep], v = v[keep])[, .(v = mean(v), game_id = game_id[1]), by = idx]
}
COMPARISONS <- list(c("B", "A", "roll lanes: B minus A"),
                    c("A seeds 3-4", "A", "seed noise: A (seeds 3-4) minus A (seeds 1-2)"),
                    c("C", "A", "roll distance only: C minus A"),
                    c("B", "C", "closing speed: B minus C"))
COMPARISONS <- Filter(function(cc) all(cc[1:2] %in% MODELS), COMPARISONS)
pooled <- list()
bygame <- list()
for (cc in COMPARISONS) {
  for (mt in METRICS) {
    for (h in names(HORIZONS)) {
      ref <- per_screen(LOSS[[cc[2]]][[mt]], h)
      var <- per_screen(LOSS[[cc[1]]][[mt]], h)
      stopifnot(identical(ref$idx, var$idx))
      d <- var$v - ref$v
      ci <- boot_ci(d, ref$game_id)
      g <- data.table(game_id = ref$game_id, d = d)[, .(screens = .N, delta = mean(d), delta_sum = sum(d)), by = game_id]
      # The largest single game's share of the summed change (in the direction of the pooled change).
      tot <- sum(d)
      top <- if (tot != 0) max(g$delta_sum * sign(tot)) / abs(tot) else NA_real_
      pooled[[length(pooled) + 1L]] <- data.table(comparison = cc[3], variant = cc[1], reference = cc[2], metric = mt,
                                                  horizon = h, loss_reference = mean(ref$v), loss_variant = mean(var$v),
                                                  delta = ci[1], lo = ci[2], hi = ci[3], screens = nrow(ref),
                                                  games_improved = sum(g$delta < 0), games = nrow(g),
                                                  top_game_share = top, primary = mt == "big" && h == "-0.4 s")
      bygame[[length(bygame) + 1L]] <- g[, .(comparison = cc[3], metric = mt, horizon = h, game_id, screens, delta)]
    }
  }
}
pooled <- rbindlist(pooled)
bygame <- rbindlist(bygame)
rnd <- function(D) D[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)]
fwrite(rnd(pooled), file.path(out_dir, "pooled_results.csv"))
fwrite(rnd(bygame), file.path(out_dir, "by_game.csv"))
cat("\nPaired changes (delta = variant - reference; below zero favours the variant; 95% game bootstrap):\n")
print(rnd(pooled)[horizon %in% c("-0.8 s", "-0.4 s", "before the tag (forecast)"),
                  .(comparison, metric, horizon, loss_reference, loss_variant, delta, lo, hi, games_improved, top_game_share)])





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SECONDARY METRICS, RELIABILITY AND CONFUSION ---------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Top-call accuracy (joint, big, guard) and switch precision / recall from the top joint call, at each horizon.
sec <- list()
for (m in MODELS) {
  Pm <- PROB[[m]]
  top <- max.col(Pm, ties.method = "first")
  big_top <- BIG_LV[max.col(marg(Pm, BIG_OF, BIG_LV), ties.method = "first")]
  bd_top <- BD_LV[max.col(marg(Pm, BD_OF, BD_LV), ties.method = "first")]
  for (h in names(HORIZONS)) {
    k <- X[, eval(HORIZONS[[h]])]
    sw_pred <- top[k] == 5L
    sw_true <- y[k] == 5L
    sec[[length(sec) + 1L]] <- data.table(model = m, horizon = h, rows = sum(k),
                                          joint_accuracy = mean(top[k] == y[k]),
                                          big_accuracy = mean(big_top[k] == BIG_OF[y[k]]),
                                          guard_accuracy = mean(bd_top[k] == BD_OF[y[k]]),
                                          switch_precision = if (any(sw_pred)) mean(sw_true[sw_pred]) else NA_real_,
                                          switch_recall = mean(sw_pred[sw_true]),
                                          joint_logloss = mean(LOSS[[m]]$joint[k]), big_logloss = mean(LOSS[[m]]$big[k]),
                                          guard_logloss = mean(LOSS[[m]]$guard[k]))
  }
}
fwrite(rnd(rbindlist(sec)), file.path(out_dir, "secondary_metrics.csv"))

# Reliability of the big's three outcomes at -0.8 s and -0.4 s: predicted probability in tenths against how often.
rel <- list()
conf <- list()
for (m in MODELS) {
  Mb <- marg(PROB[[m]], BIG_OF, BIG_LV)
  for (o in c(-20L, -10L)) {
    k <- X$off == o
    for (l in BIG_LV) {
      p <- Mb[k, l]
      bin <- pmin(floor(p * 10), 9L)
      rel[[length(rel) + 1L]] <- data.table(model = m, t = o / FPS, outcome = l, bin = bin, p = p,
                                            hit = BIG_OF[y[k]] == l)[, .(n = .N, mean_predicted = mean(p),
                                                                         observed = mean(hit)), by = .(model, t, outcome, bin)]
    }
    pred <- BIG_LV[max.col(Mb[k, ], ties.method = "first")]
    conf[[length(conf) + 1L]] <- data.table(model = m, t = o / FPS, actual = BIG_OF[y[k]], predicted = pred)[, .N, by = .(model, t, actual, predicted)]
  }
}
fwrite(rnd(rbindlist(rel)[order(model, t, outcome, bin)]), file.path(out_dir, "reliability_big.csv"))
fwrite(rbindlist(conf)[order(model, t, actual, predicted)], file.path(out_dir, "confusion_big.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - FEATURE AVAILABILITY ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Valid off-ball roll-lane values (0-3 defenders) at each prediction row's own frame, from B's audit.
SB <- readRDS(file.path(lane_dir(root, "B"), "sequences.rds"))
nb_valid <- apply(SB$roll_audit$valid, c(1, 2), sum)                       # [screens, stored frames]
X[, roll_valid_n := nb_valid[cbind(idx, match(off, SB$base_offs))]]
rm(SB)
val <- X[, .(rows = .N, mean_valid_defenders = mean(roll_valid_n), all_three = mean(roll_valid_n == 3L),
             none = mean(roll_valid_n == 0L)), by = .(game_id, t = off / FPS)][order(game_id, t)]
fwrite(rnd(val), file.path(out_dir, "validity_by_game_lead.csv"))
cat("\nRoll-lane availability: all three off-ball defenders valid on", sprintf("%.1f%%", 100 * X[, mean(roll_valid_n == 3L)]),
    "of rows; at -0.4 s", sprintf("%.1f%%", 100 * X[off == -10L, mean(roll_valid_n == 3L)]), "\n")

# Diagnostic subsets of the primary score: rows with all three defenders valid against the rest.
avail <- list()
for (cc in COMPARISONS) {
  for (o in c(-20L, -10L)) {
    k <- X$off == o
    d <- LOSS[[cc[1]]]$big[k] - LOSS[[cc[2]]]$big[k]
    full <- X$roll_valid_n[k] == 3L
    avail[[length(avail) + 1L]] <- data.table(comparison = cc[3], t = o / FPS,
                                              subset = c("all three valid", "fewer than three"),
                                              screens = c(sum(full), sum(!full)),
                                              delta_big = c(mean(d[full]), if (any(!full)) mean(d[!full]) else NA_real_))
  }
}
fwrite(rnd(rbindlist(avail)), file.path(out_dir, "availability_subsets.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - MANIFEST ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Identity of code, data and settings, and each model's fold mapping, seeds, epochs and run time.
git <- function(...) tryCatch(system2("git", c("-C", shQuote(root), ...), stdout = TRUE, stderr = FALSE), error = function(e) NA)
fold_info <- rbindlist(lapply(names(PROB), function(m) rbindlist(lapply(games, function(g) {
  o <- readRDS(file.path(SOURCES[[m]], sprintf("seqheads_%d.rds", g)))
  data.table(model = m, test_game = g, val_game = o$val_game, seeds = paste(o$best$seed, collapse = ","),
             best_epochs = paste(o$best$epoch, collapse = ","), val_logloss = paste(round(o$best$val_logloss, 4), collapse = ","),
             seconds = round(o$seconds), feats = paste(o$lane$feats %||% SEQ_FEATS, collapse = ","))
}))))
fwrite(fold_info, file.path(out_dir, "fold_info.csv"))
lfs <- git("lfs", "ls-files", "--long")
manifest <- list(
  created = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  commit = git("rev-parse", "HEAD"), working_tree = git("status", "--porcelain"),
  r_version = R.version.string, torch_version = as.character(packageVersion("torch")),
  data = list(tracking_lfs_objects = lfs, rules = PAST_ONLY_RULES),
  rows = list(screens = nrow(P), frames_per_screen = length(L$offs), offsets = range(L$offs)),
  variants = lapply(LANE_VARIANTS, function(e) c(SEQ_FEATS, e)),
  eligibility = paste("roll_lane_valid = off-ball defender (roster rows 8-10) present (tracked at the frame and 0.2 s",
                      "and 0.4 s before), screener tracked at the frame, both gaps finite (segment longer than 1e-6 ft)"),
  models = as.list(SOURCES[names(PROB)]), skipped = missing,
  bootstrap = list(seed = BOOT_SEED, reps = BOOT_REPS, unit = "game"),
  commands = c("Rscript screen_coverage/01_scripts/02_build_sequences.R --variant=A|B|C",
               "Rscript screen_coverage/01_scripts/07_test_lane_geometry.R",
               "Rscript screen_coverage/01_scripts/03_train_transformer.R --fold=<gameId> --variant=B --seeds=1,2",
               "Rscript screen_coverage/01_scripts/03_train_transformer.R --fold=<gameId> --variant=A --seeds=3,4",
               "Rscript screen_coverage/01_scripts/05_test_past_only.R --variant=B",
               "Rscript screen_coverage/01_scripts/08_evaluate_lanes.R"),
  evaluation_seconds = round(as.numeric(Sys.time() - t_start, units = "secs")))
write_json(manifest, file.path(out_dir, "manifest.json"), auto_unbox = TRUE, pretty = TRUE)
cat("\nWrote", out_dir, "\n")
