# The fixed time weights for scoring screen-coverage predictions (fixed by the owner on 2026-11-15, decision_log.md),
# and the per-frame losses they weight. Used by 14_weighted_scores.R and by every tuning run that follows; the curves
# are never changed from tuning results.
#
# Each curve weights a scored frame by its time from the pick frame (picks.frame, t = 0, the dashed Pick line in the
# viewer's trace panel). The anchor times are medians measured in 13_window_anchors.R from tracking and event timing
# only; the straight lines between them are a stated basketball judgment.
#   main    0 before -1.8 s (handler and screener start coming together), a straight line up to 1 at -0.9 s (within
#           15 ft and staying there: the screen is obvious), 1 through +0.24 s (the closest moment, the handler coming
#           off the screener's shoulder), a straight line down to 0 at +0.5 s (about a quarter-second of reaction time)
#   narrow  1 from -0.4 s (within 10 ft) to +0.24 s, 0 elsewhere
#   flat    1 over the whole scored window, -2 s to +1 s (the earlier, unweighted score)

suppressPackageStartupMessages(library(data.table))

WINDOW_FPS <- 25
WINDOW_CURVES <- list(main = list(t = c(-1.8, -0.9, 0.24, 0.5), w = c(0, 1, 1, 0)),
                      narrow = list(t = c(-0.4, 0.24), w = c(1, 1)),
                      flat = list(t = c(-2, 1), w = c(1, 1)))

# Which joint calls make up each defender's call. Guard = the ball handler's defender, big = the screener's defender.
GUARD_CALLS <- list(over = c("over + show", "over + drop"), under = c("under + drop", "under + show"), switch = "switch")
BIG_CALLS <- list(show = c("over + show", "under + show"), drop = c("over + drop", "under + drop"), switch = "switch")

#' Weight of each frame offset `off` (frames from the pick frame) under `curve`. Anchors are converted to frames and
#' rounded so the curve's end frames are counted exactly (-0.4 s is frame -10, not a float just past it).
window_weight <- function(off, curve) {
  k <- WINDOW_CURVES[[curve]]
  if (is.null(k)) stop("Unknown curve: ", curve)
  w <- approx(round(k$t * WINDOW_FPS, 6), k$w, xout = off, rule = 1, ties = "ordered")$y
  w[is.na(w)] <- 0
  w
}

#' Per-frame log loss of the true call: joint (five calls), guard (over / under / switch) and big (show / drop /
#' switch). `P` holds the five joint-call probabilities in the order `calls`, rows matching `call`.
frame_losses <- function(P, call, calls) {
  stopifnot(ncol(P) == length(calls), nrow(P) == length(call), !anyNA(P))
  y <- match(call, calls)
  # A defender's probability is the sum of the joint calls that share his part.
  one <- function(groups) {
    G <- sapply(groups, function(m) rowSums(P[, match(m, calls), drop = FALSE]))
    yy <- vapply(call, function(cc) which(vapply(groups, function(m) cc %in% m, logical(1))), integer(1))
    -log(G[cbind(seq_along(yy), yy)])
  }
  data.table(joint = -log(P[cbind(seq_along(y), y)]), guard = one(GUARD_CALLS), big = one(BIG_CALLS))
}

#' Weighted scores per screen: each screen's frames averaged with the curve's weights, for each loss. `X` needs `idx`
#' (screen), `off`, `game_id`; `loss` is frame_losses() in X's rows.
screen_scores <- function(X, loss, curve) {
  d <- data.table(idx = X$idx, game_id = X$game_id, w = window_weight(X$off, curve), loss)
  d[w > 0, .(game_id = game_id[1], joint = sum(w * joint) / sum(w), guard = sum(w * guard) / sum(w),
             big = sum(w * big) / sum(w)), by = idx]
}
