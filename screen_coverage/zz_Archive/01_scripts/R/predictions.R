# Every held-out per-frame prediction of the screen-coverage models, logistic (02_per_frame.R) and transformer
# (04_train_transformer.R, 10_train_seq_transformer.R), in one place, all in the row order of logistic_per_frame.rds.
# Used by 05_compare.R, 06_classification.R, 07_export_live.R and 11_compare_seq.R.
#
# Since 2026-11-12 every fold file must have been built under the same rules (PAST_ONLY_RULES) and for the same
# screens as logistic_per_frame.rds; a stale file stops the load instead of being placed on the wrong rows.

suppressPackageStartupMessages(library(data.table))

COVERAGE_MODELS <- c("4 players + so far", "+ archetypes", "pooled, no timing", "pooled, no timing, + closeness")
TF_VARIANT <- setNames(c("timed", "arch", "pooled", "close"), COVERAGE_MODELS)
SEQ_MODEL <- "time-aware transformer, two heads"

#' The logistic step's screens, frame rows, predictions and baselines (02_per_frame.R).
load_logistic <- function(root) readRDS(file.path(root, "screen_coverage", "zz_Archive", "02_cache", "logistic_per_frame.rds"))

#' Read one transformer fold file, stopping if it was built under other rules or for other screens than `L`.
read_fold <- function(path, L) {
  if (!file.exists(path)) stop("Missing ", path)
  o <- readRDS(path)
  if (is.null(L$rules) || !identical(o$rules, L$rules) || !identical(o$screen_ids, L$P$id)) {
    stop(basename(path), " was built under other rules or for other screens than logistic_per_frame.rds: retrain it")
  }
  o
}

#' A transformer variant's attention, [rows x 10] in X's row order: the share of the four screen players' attention
#' (last layer, heads and seeds averaged) going to each token row (04_train_transformer.R).
load_tf_attention <- function(root, variant) {
  cache_dir <- file.path(root, "screen_coverage", "zz_Archive", "02_cache")
  L <- load_logistic(root)
  X <- L$X
  A <- matrix(NA_real_, nrow(X), 10L)
  for (g in sort(unique(X$game_id))) {
    o <- read_fold(file.path(cache_dir, "tf", sprintf("%s_%d.rds", variant, g)), L)
    if (is.null(o$att)) stop("No attention saved for ", variant, " fold ", g, ": rerun 04_train_transformer.R --force")
    A[o$rows, ] <- o$att
  }
  A
}

#' The time-aware, two-head transformer (10_train_seq_transformer.R), in X's row order: joint-call probabilities
#' [rows x 5], head probabilities [rows x 3] (switch, under | not switch, show | not switch) and attention [rows x 10]
#' over the fixed roster of 09_build_sequences.R (handler, screener, their defenders, three attackers, three defenders).
load_seqheads <- function(root) {
  cache_dir <- file.path(root, "screen_coverage", "zz_Archive", "02_cache")
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

#' list(P = screens, X = frame rows, calls, offs, lg_ll, sf_ll, prob = named list of [rows x calls] matrices named
#' "logistic: <model>" and "transformer: <model>").
load_coverage_predictions <- function(root) {
  cache_dir <- file.path(root, "screen_coverage", "zz_Archive", "02_cache")
  L <- load_logistic(root)
  X <- L$X
  # Each transformer variant's ten fold files, gathered into X's row order.
  tf <- lapply(TF_VARIANT, function(v) {
    Pm <- matrix(NA_real_, nrow(X), length(L$calls))
    for (g in sort(unique(X$game_id))) {
      o <- read_fold(file.path(cache_dir, "tf", sprintf("%s_%d.rds", v, g)), L)
      Pm[o$rows, ] <- o$prob
    }
    stopifnot(!anyNA(Pm))
    Pm
  })
  # Name every model by its family and variant.
  prob <- c(setNames(L$prob[COVERAGE_MODELS], paste("logistic:", COVERAGE_MODELS)),
            setNames(tf, paste("transformer:", COVERAGE_MODELS)))
  list(P = L$P, X = X, calls = L$calls, offs = L$offs, lg_ll = L$lg_ll, sf_ll = L$sf_ll, prob = prob)
}
