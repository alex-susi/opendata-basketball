# Every held-out per-frame prediction of the screen-coverage models, logistic (02_per_frame.R) and transformer
# (04_train_transformer.R), in one place, all in the row order of logistic_per_frame.rds. Used by 05_compare.R,
# 06_classification.R and 07_export_live.R.

suppressPackageStartupMessages(library(data.table))

COVERAGE_MODELS <- c("4 players + so far", "+ archetypes", "pooled, no timing", "pooled, no timing, + closeness")
TF_VARIANT <- setNames(c("timed", "arch", "pooled", "close"), COVERAGE_MODELS)

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
