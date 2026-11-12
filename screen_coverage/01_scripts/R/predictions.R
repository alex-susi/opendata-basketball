# Loaders for the screen-coverage predictions, all in the row order of logistic_per_frame.rds: the logistic baseline
# (01_logistic_baseline.R) and the live time-aware transformer (03_train_transformer.R). Used by 04_evaluate.R,
# 05_test_past_only.R and 06_export_live.R.
#
# Every fold file must have been built under the same rules (PAST_ONLY_RULES) and for the same screens as
# logistic_per_frame.rds; a stale file stops the load instead of being placed on the wrong rows. (The loaders for the
# archived token transformers are in zz_Archive/R/predictions.R.)

suppressPackageStartupMessages(library(data.table))

SEQ_MODEL <- "time-aware transformer, two heads"

#' The baseline step's screens, frame rows, logistic predictions and baselines (01_logistic_baseline.R).
load_logistic <- function(root) readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))

#' Read one transformer fold file, stopping if it was built under other rules or for other screens than `L`.
read_fold <- function(path, L) {
  if (!file.exists(path)) stop("Missing ", path)
  o <- readRDS(path)
  if (is.null(L$rules) || !identical(o$rules, L$rules) || !identical(o$screen_ids, L$P$id)) {
    stop(basename(path), " was built under other rules or for other screens than logistic_per_frame.rds: retrain it")
  }
  o
}

#' The live transformer (03_train_transformer.R), in X's row order: joint-call probabilities [rows x 5], head
#' probabilities [rows x 3] (switch, under | not switch, show | not switch) and attention [rows x 10] over the fixed
#' roster of 02_build_sequences.R (handler, screener, their defenders, three attackers, three defenders).
load_seqheads <- function(root) {
  cache_dir <- file.path(root, "screen_coverage", "02_cache")
  L <- load_logistic(root)
  X <- L$X
  # Gather the ten fold files into X's row order.
  out <- list(prob = matrix(NA_real_, nrow(X), 5), heads = matrix(NA_real_, nrow(X), 3), att = matrix(NA_real_, nrow(X), 10))
  for (g in sort(unique(X$game_id))) {
    o <- read_fold(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", g)), L)
    out$prob[o$rows, ] <- o$prob
    out$heads[o$rows, ] <- o$heads
    out$att[o$rows, ] <- o$att
  }
  out
}
