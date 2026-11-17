## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 26: the live model's recall and precision counts at every frame, for the docs' sliders.
#   Rscript screen_coverage/01_scripts/26_matrices_by_frame.R
#
# Same counts as 22_confusion_matrices.R (real coverage against the model's top coverage, for the full coverage and
# for each defender's part), but at each of the 76 frames from -2 s to +1 s around the pick frame instead of only
# the main curve, -0.4 s and the pick frame. Every screen has one row per frame, so each frame's counts are screens.
# The main-curve counts (each screen's weights summing to 1) are included so a page can show them as its default.
#
# Writes screen_coverage/03_outputs/confusion/by_frame.json. The model pages embed a copy of it.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "confusion")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - TOP COVERAGE AT EVERY FRAME ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- copy(L$X)
CALLS <- L$calls
P <- load_seqheads(root)$prob
stopifnot(!anyNA(P))
X[, w_main := window_weight(off, "main")]
X[, w_main := w_main / sum(w_main), by = id]
PARTS <- list(joint = setNames(as.list(CALLS), CALLS), guard = GUARD_CALLS, big = BIG_CALLS)

# Each part's levels, the real level of every row and the model's top level (largest summed probability).
part_rows <- function(part) {
  lv <- names(PARTS[[part]])
  G <- sapply(PARTS[[part]], function(m) rowSums(P[, match(m, CALLS), drop = FALSE]))
  real <- lv[vapply(X$call, function(cc) which(vapply(PARTS[[part]], function(m) cc %in% m, logical(1))), integer(1))]
  data.table(off = X$off, w = X$w_main, real = factor(real, lv), read = factor(lv[max.col(G, ties.method = "first")], lv))
}

#' Count matrix (rows real, columns top coverage) of `d`, weighted by `weight` (one per row of `d`).
count_matrix <- function(d, lv, weight = rep(1, nrow(d))) {
  m <- matrix(0, length(lv), length(lv))
  agg <- data.table(real = d$real, read = d$read, ww = weight)[, .(n = sum(ww)), by = .(real, read)]
  m[cbind(as.integer(agg$real), as.integer(agg$read))] <- agg$n
  m
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - EXPORT ------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

offs <- sort(unique(X$off))
out <- list(offs = offs, generated = format(Sys.Date()))
for (part in names(PARTS)) {
  d <- part_rows(part)
  lv <- levels(d$real)
  frames <- lapply(offs, function(o) count_matrix(d[off == o], lv))
  main <- round(count_matrix(d, lv, d$w), 2)
  stopifnot(all(vapply(frames, sum, numeric(1)) == length(unique(X$id))))
  out[[part]] <- list(levels = lv, frames = frames, main = main)
}
# Check against 22_confusion_matrices.R's main-curve counts.
chk <- fread(file.path(out_dir, "counts.csv"))[model == "live transformer" & moment == "main curve" & part == "joint"]
stopifnot(abs(sum(diag(out$joint$main)) - sum(chk[actual == read]$screens)) < 0.1)
write_json(out, file.path(out_dir, "by_frame.json"), auto_unbox = TRUE, digits = NA)
cat("Frames:", length(offs), "| joint recall at the pick frame:",
    round(diag(out$joint$frames[[match(0L, offs)]]) / rowSums(out$joint$frames[[match(0L, offs)]]), 2), "\n")
