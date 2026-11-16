## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage: which inputs the logistic baseline leans on (added 2026-11-15, for the reads page).
#   Rscript screen_coverage/01_scripts/12_baseline_importance.R [--workers=8] [--repeats=5]
#
# Needs 01_logistic_baseline.R. The baseline is "no timing, + closeness": a multinomial logistic model on the four
# screen players' measures, time to act, the defense's calls so far and closeness, each geometry measure also
# entered times closeness. Two views of importance:
#   1. Permutation, held out by game: refit on nine games (exactly as 01), then on the held-out game shuffle one
#      input group across that game's rows and measure how much the held-out log loss rises. A group is a measure
#      together with its "× closeness" twin (shuffled as a pair); the five "so far" shares are one group. Repeated
#      `--repeats` times and averaged; mean over the 10 games with a 95% interval from resampling games. Scored for
#      the five calls, the big's call and the guard's call, before the tag, at -0.4 s and from the tag on.
#   2. Coefficients of one fit on all ten games (standardised inputs): the change in the log-odds of each call
#      against over + show for one standard deviation more of the input, for reading direction, not size of effect
#      (correlated inputs share and trade their weight).
#
# Writes screen_coverage/03_outputs/logistic/importance/: permutation_importance.csv, coefficients.csv.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(parallel)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
targ <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), commandArgs(TRUE), value = TRUE)
  if (length(hit)) as.integer(sub(paste0("^--", name, "="), "", hit[1])) else default
}
WORKERS <- targ("workers", 8L)
REPEATS <- targ("repeats", 5L)
BOOT_SEED <- 20261115L
DECAY <- 1
out_dir <- file.path(root, "screen_coverage", "03_outputs", "logistic", "importance")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - ROWS, INPUTS AND GROUPS ------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
X <- L$X
CALLS <- L$calls
OFFS <- L$offs
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
LSF <- paste0("lsf_", 1:5)
FEATS <- c(GEOM, LSF, "closeness", CLOSE)
LABEL <- c(d_hs = "Handler to screener distance", d_bd = "Handler to his defender", d_sd = "Handler to the screener's defender",
           d_def = "Between the two defenders", bd_lvl = "Ball defender's level", sd_lvl = "Big's level",
           h_lvl = "Handler's level", s_hoop = "Screener's distance from the hoop", bd_lvl_v = "Ball defender's level changing",
           sd_lvl_v = "Big's level changing", tta_now = "Time to act", so_far = "Defense's calls so far (5 shares)",
           closeness = "Closeness (handler to screener, 0-1)")
GROUPS <- c(lapply(setNames(setdiff(GEOM, c("d_hs", "tta_now")), setdiff(GEOM, c("d_hs", "tta_now"))),
                   function(v) c(v, paste0(v, "_close"))),
            list(d_hs = "d_hs", tta_now = "tta_now", so_far = LSF, closeness = "closeness"))
stopifnot(setequal(unlist(GROUPS), FEATS))
BIG_OF <- c("show", "drop", "drop", "show", "switch")
BD_OF <- c("over", "over", "under", "under", "switch")
LV <- list(big = c("show", "drop", "switch"), guard = c("over", "under", "switch"))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PERMUTATION IMPORTANCE, HELD OUT BY GAME -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Row log losses (five calls, big, guard) of probabilities Pm against the rows' calls.
row_loss <- function(Pm, call) {
  y <- match(call, CALLS)
  out <- list(joint = -log(pmax(Pm[cbind(seq_len(nrow(Pm)), y)], 1e-12)))
  for (who in names(LV)) {
    of <- if (who == "big") BIG_OF else BD_OF
    M <- sapply(LV[[who]], function(l) rowSums(Pm[, of == l, drop = FALSE]))
    out[[who]] <- -log(pmax(M[cbind(seq_len(nrow(M)), match(of[y], LV[[who]]))], 1e-12))
  }
  out
}
#' One held-out game: fit as 01_logistic_baseline.R, then the loss rise from shuffling each group, averaged over
#' REPEATS shuffles, per screen and window.
fold_importance <- function(g) {
  tr <- X[game_id != g]
  te <- X[game_id == g]
  Xtr <- as.matrix(tr[, ..FEATS])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  fit <- multinom(y ~ ., data = data.frame(y = factor(tr$call, CALLS), scale(Xtr, mu, sdv)),
                  weights = rep(1 / length(OFFS), nrow(tr)), decay = DECAY, trace = FALSE, maxit = 2000)
  Xte <- as.matrix(te[, ..FEATS])
  pred <- function(M) predict(fit, newdata = data.frame(scale(M, mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
  base <- row_loss(pred(Xte), te$call)
  win <- list(`before the tag` = te$off < 0L, `at -0.4 s` = te$off == -10L, `tag to +1 s` = te$off >= 0L)
  set.seed(BOOT_SEED + g %% 1000L)
  rbindlist(lapply(names(GROUPS), function(gr) {
    rise <- lapply(base, function(b) numeric(length(b)))
    for (r in seq_len(REPEATS)) {
      M <- Xte
      perm <- sample.int(nrow(M))
      M[, GROUPS[[gr]]] <- Xte[perm, GROUPS[[gr]], drop = FALSE]
      lp <- row_loss(pred(M), te$call)
      for (m in names(rise)) rise[[m]] <- rise[[m]] + (lp[[m]] - base[[m]]) / REPEATS
    }
    # Per screen and window: frames averaged within the screen first.
    rbindlist(lapply(names(win), function(w) {
      k <- win[[w]]
      d <- data.table(idx = te$idx[k], joint = rise$joint[k], big = rise$big[k], guard = rise$guard[k])
      d <- d[, lapply(.SD, mean), by = idx]
      d[, `:=`(game_id = g, group = gr, window = w)]
    }))
  }))
}
t0 <- Sys.time()
cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})))
clusterExport(cl, c("X", "CALLS", "OFFS", "DECAY", "FEATS", "GROUPS", "REPEATS", "BOOT_SEED", "BIG_OF", "BD_OF", "LV",
                    "row_loss", "fold_importance"))
per_screen <- rbindlist(parLapply(cl, sort(unique(X$game_id)), fold_importance))
stopCluster(cl)
cat(sprintf("Permutations done in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))

# Mean rise with a 95% interval from resampling whole games (ratio of sums, as the other evaluators).
boot_ci <- function(d, game, reps = 2000L) {
  set.seed(BOOT_SEED)
  s <- split(d, game)
  sums <- vapply(s, sum, 0)
  ns <- lengths(s)
  b <- replicate(reps, {
    k <- sample(names(s), length(s), TRUE)
    sum(sums[k]) / sum(ns[k])
  })
  c(mean(d), quantile(b, c(0.025, 0.975)))
}
imp <- per_screen[, {
  j <- boot_ci(joint, game_id)
  .(rise_joint = j[1], lo_joint = j[2], hi_joint = j[3], rise_big = mean(big), rise_guard = mean(guard),
    games_hurt = sum(tapply(joint, game_id, mean) > 0), screens = .N)
}, by = .(group, window)]
imp[, label := LABEL[group]]
imp[, inputs := vapply(group, function(gr) paste(GROUPS[[gr]], collapse = " + "), "")]
setcolorder(imp, c("window", "group", "label", "inputs"))
imp <- imp[order(window, -rise_joint)]
fwrite(imp[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)],
       file.path(out_dir, "permutation_importance.csv"))
cat("\nHeld-out rise in log loss when each group is shuffled (five calls), before the tag:\n")
print(imp[window == "before the tag", .(label, rise_joint = round(rise_joint, 4), lo = round(lo_joint, 4), hi = round(hi_joint, 4),
                                        rise_big = round(rise_big, 4), rise_guard = round(rise_guard, 4), games_hurt)])





## ═════════════════════════════════════════════════════════════════════════════
## 03 - COEFFICIENTS OF ONE FIT ON ALL TEN GAMES -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

Xa <- as.matrix(X[, ..FEATS])
mu <- colMeans(Xa)
sdv <- apply(Xa, 2, sd)
sdv[sdv == 0] <- 1
fit <- multinom(y ~ ., data = data.frame(y = factor(X$call, CALLS), scale(Xa, mu, sdv)),
                weights = rep(1 / length(OFFS), nrow(X)), decay = DECAY, trace = FALSE, maxit = 2000)
co <- coef(fit)                                         # rows: the four calls against over + show
cf <- as.data.table(t(co), keep.rownames = "input")
cf <- cf[input != "(Intercept)"]
cf[, group := vapply(input, function(v) names(GROUPS)[vapply(GROUPS, function(g) v %in% g, NA)], "")]
cf[, label := LABEL[group]]
cf[, term := "plain"]
cf[grepl("_close$", input), term := "× closeness"]
cf[grepl("^lsf_", input), term := CALLS[as.integer(sub("lsf_", "", input))]]
setcolorder(cf, c("group", "label", "input", "term"))
fwrite(cf[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "coefficients.csv"))
cat("\nCoefficients (log-odds against over + show per standard deviation), all ten games:\n")
print(cf[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 2) else v)])
cat("\nWrote", out_dir, "\n")
