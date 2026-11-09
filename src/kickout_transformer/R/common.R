# Shared helpers for the kickout transformer learning exercise (src/kickout_transformer/).
# A learning exercise, not the competition entry: see src/kickout_transformer/EXPLAINER.md.

suppressPackageStartupMessages(library(data.table))

kt_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  here <- if (length(script)) dirname(normalizePath(script)) else file.path(getwd(), "src", "kickout_transformer")
  normalizePath(file.path(here, "..", ".."), winslash = "/")
}

# Three-class variant: pass --drop-other to steps 2-5 (or set KT_DROP_OTHER=1). Catches that ended in a foul,
# turnover, timeout or a held ball are removed and the models predict only shot / drive / pass. Its predictions and
# outputs go to separate *_3class folders, so the four-class results stay untouched.
DROP_OTHER <- "--drop-other" %in% commandArgs(TRUE) || identical(Sys.getenv("KT_DROP_OTHER"), "1")
CLASSES <- if (DROP_OTHER) c("shot", "drive", "pass") else c("shot", "drive", "pass", "other")
PROB_COLS <- paste0("p_", CLASSES)
CLASS_TAG <- paste0(length(CLASSES), " outcomes: ", paste(CLASSES, collapse = " / "))   # for figure titles

kt_paths <- function(root) {
  suffix <- if (DROP_OTHER) "_3class" else ""
  p <- list(base_cache = file.path(root, "outputs", "cache", "kickout_transformer"),
            cache = file.path(root, "outputs", "cache", paste0("kickout_transformer", suffix)),
            out = file.path(root, "outputs", paste0("kickout_transformer", suffix)))
  for (d in p) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  p
}

#' The catch table built by step 1. In the three-class variant the "other" catches are removed and `row` is
#' renumbered 1..n to match the token arrays (the four-class row number is kept as `row_all`).
kt_load_catches <- function(paths) {
  d <- readRDS(file.path(paths$base_cache, "catches.rds"))
  d$meta[, row_all := row]
  if (DROP_OTHER) {
    keep <- d$meta$label != "other"
    d$meta <- d$meta[keep][, row := .I]
    d$freeze <- d$freeze[keep, , , drop = FALSE]
    d$hist <- d$hist[keep, , , drop = FALSE]
    d$token_pid <- d$token_pid[keep, , drop = FALSE]
  }
  d
}

#' A prediction table: one row per catch, one probability column per class.
pred_table <- function(row, model, p) {
  out <- data.table(row = row, model = model)
  for (j in seq_along(CLASSES)) set(out, j = PROB_COLS[j], value = p[, j])
  out
}

#' Multiclass log loss of each row: -log(probability given to what actually happened).
row_logloss <- function(prob, y) {
  p <- prob[cbind(seq_along(y), match(y, CLASSES))]
  -log(pmax(p, 1e-12))
}

#' Multiclass Brier score of each row: squared distance between the probability vector and the one-hot answer.
row_brier <- function(prob, y) {
  onehot <- outer(match(y, CLASSES), seq_along(CLASSES), `==`) * 1
  rowSums((prob - onehot)^2)
}

#' Mean of a per-row score with a 95% interval from resampling whole games (catches in one game are not
#' independent, so the bootstrap draws games, not rows).
game_bootstrap <- function(score, game, reps = 2000L, seed = 1L) {
  set.seed(seed)
  games <- unique(game)
  by_game <- split(score, game)
  sums <- vapply(by_game, sum, 0)
  ns <- lengths(by_game)
  boot <- replicate(reps, {
    g <- sample(names(sums), length(sums), replace = TRUE)
    sum(sums[g]) / sum(ns[g])
  })
  c(mean = mean(score), lo = unname(quantile(boot, 0.025)), hi = unname(quantile(boot, 0.975)))
}
