# Every held-out per-frame prediction of the screen-coverage models, logistic (02_per_frame.R) and transformer
# (04_train_transformer.R), in one place, all in the row order of logistic_per_frame.rds. Used by 05_compare.R,
# 06_classification.R and 07_export_live.R.

suppressPackageStartupMessages(library(data.table))

COVERAGE_MODELS <- c("4 players + so far", "+ archetypes", "pooled, no timing", "pooled, no timing, + closeness")
TF_VARIANT <- setNames(c("timed", "arch", "pooled", "close"), COVERAGE_MODELS)

#' A transformer variant's attention, [rows x 10] in X's row order: the share of the four screen players' attention
#' (last layer, heads and seeds averaged) going to each token row (04_train_transformer.R).
load_tf_attention <- function(root, variant) {
  cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
  X <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))$X
  A <- matrix(NA_real_, nrow(X), 10L)
  for (g in sort(unique(X$game_id))) {
    o <- readRDS(file.path(cache_dir, "tf", sprintf("%s_%d.rds", variant, g)))
    if (is.null(o$att)) stop("No attention saved for ", variant, " fold ", g, ": rerun 04_train_transformer.R --force")
    A[o$rows, ] <- o$att
  }
  A
}

SEQ_MODEL <- "time-aware transformer, two heads"

#' The time-aware, two-head transformer (10_train_seq_transformer.R), in X's row order: joint-call probabilities
#' [rows x 5], head probabilities [rows x 3] (switch, under | not switch, show | not switch) and attention [rows x 10]
#' over the fixed roster of 09_build_sequences.R (handler, screener, their defenders, three attackers, three defenders).
load_seqheads <- function(root) {
  cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
  X <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))$X
  out <- list(prob = matrix(NA_real_, nrow(X), 5), heads = matrix(NA_real_, nrow(X), 3), att = matrix(NA_real_, nrow(X), 10))
  for (g in sort(unique(X$game_id))) {
    f <- file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", g))
    if (!file.exists(f)) stop("Missing ", f, ": run 10_train_seq_transformer.R --fold=", g)
    o <- readRDS(f)
    out$prob[o$rows, ] <- o$prob; out$heads[o$rows, ] <- o$heads; out$att[o$rows, ] <- o$att
  }
  out
}

#' list(P = screens, X = frame rows, calls, offs, lg_ll, sf_ll, prob = named list of [rows x calls] matrices named
#' "logistic: <model>" and "transformer: <model>").
load_coverage_predictions <- function(root) {
  cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
  L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
  X <- L$X
  tf <- lapply(TF_VARIANT, function(v) {
    files <- file.path(cache_dir, "tf", sprintf("%s_%d.rds", v, sort(unique(X$game_id))))
    if (!all(file.exists(files))) stop("Missing transformer folds for ", v, ": run 04_train_transformer.R")
    Pm <- matrix(NA_real_, nrow(X), length(L$calls))
    for (f in files) { o <- readRDS(f); Pm[o$rows, ] <- o$prob }
    stopifnot(!anyNA(Pm))
    Pm
  })
  prob <- c(setNames(L$prob[COVERAGE_MODELS], paste("logistic:", COVERAGE_MODELS)),
            setNames(tf, paste("transformer:", COVERAGE_MODELS)))
  list(P = L$P, X = X, calls = L$calls, offs = L$offs, lg_ll = L$lg_ll, sf_ll = L$sf_ll, prob = prob)
}
