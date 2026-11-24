## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 38: availability sensitivities on the logistic baseline (coverage product plan, Phase 4,
# 2026-11-23).
#   Rscript screen_coverage/01_scripts/38_availability_sensitivity.R [--workers=8]
#
# Two assumptions behind every forecast, each varied over values fixed before any score was seen. Nothing here picks
# the best-scoring value. The live rules stay as they are unless the owner decides otherwise.
#   1. When an earlier screen's coverage counts in "the defense so far" · at its pick frame (0 s), 1 s after (live),
#      2 s, 3 s, at its episode stop (37_audit_timing.R), and a control with no earlier coverages at all
#   2. How exact the pick frame is · every pick frame moved by −0.24, −0.16, −0.08, +0.08, +0.16, +0.24 s. The window,
#      the time weights and the defense so far all follow the moved frame. Scored on the screens whose four players
#      are tracked over the widest shift (a common cohort), with the unshifted fit on the same screens as reference
#
# The model is the logistic baseline of 01_logistic_baseline.R (same inputs, fits held out by game, frames weighted
# 1/76), refitted for each variant. Scores are joint log loss per screen, averaged with the main curve, over the flat
# −2 s to +1 s window and over −1 s to just before the pick frame. Differences are against the live rule, paired by
# screen, with a 95% interval from resampling whole games.
#
# Writes screen_coverage/03_outputs/availability/: known_after.csv, tag_shift.csv.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(parallel)
})
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
targs <- commandArgs(TRUE)
hit <- grep("^--workers=", targs, value = TRUE)
WORKERS <- if (length(hit)) as.integer(sub("^--workers=", "", hit)) else 8L
out_dir <- file.path(root, "screen_coverage", "03_outputs", "availability")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS AND INPUTS ----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

KNOWN <- c(0L, 25L, 50L, 75L)
SHIFTS <- c(-6L, -4L, -2L, 0L, 2L, 4L, 6L)
OFFS <- -50:25
VLAG <- 6L
DECAY <- 1
CALLS <- c("over + show", "over + drop", "under + drop", "under + show", "switch")
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
LSF <- paste0("lsf_", seq_along(CALLS))
FEATS <- c(GEOM, LSF, "closeness", CLOSE)
FEATS_0 <- c(GEOM, "closeness", CLOSE)

L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
cached <- readRDS(file.path(root, "screen_coverage", "02_cache", "per_frame_features.rds"))
stopifnot(identical(cached$rules, PAST_ONLY_RULES))
Pall <- cached$P
P5 <- Pall[call %in% CALLS]
P <- L$P
stops <- fread(file.path(root, "screen_coverage", "03_outputs", "timing_audit", "per_screen.csv"))

# The four-player measures at the extra offsets a shift needs, for the scored screens (the cache holds −2 s to +1 s).
extra <- c(seq(min(OFFS) + min(SHIFTS), min(OFFS) - 1L), seq(max(OFFS) + 1L, max(OFFS) + max(SHIFTS)))
Fx <- rbindlist(lapply(sort(unique(P$game_id)), function(g) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  p <- Pall[game_id == g & id %in% P$id]
  rbindlist(lapply(extra, function(o) cbind(off = o, four_player_features(B, p, p$f0 + o, VLAG))))
}))
setcolorder(Fx, c("id", "off"))
Fe <- rbind(cached$Fe[id %in% P$id], Fx, use.names = TRUE)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - ROWS, FITS AND SCORES --------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Frame rows for screens `ids` with every pick frame moved by `shift` frames, and the defense so far counting an
#' earlier screen once its moved pick frame plus `known` frames has passed (`known` a scalar or one value per P5 row).
#' With `no_context` the so-far columns are left out.
make_rows <- function(ids, shift = 0L, known = 25L) {
  X <- Fe[id %in% ids & off >= min(OFFS) + shift & off <= max(OFFS) + shift]
  X[, off := off - shift]
  X <- merge(X, P[, .(id, game_id, call, def_team, f0)], by = "id")
  X[, f0 := f0 + shift]
  X[, tta_now := pmin(sc_now, gc_now, 24, na.rm = TRUE)]
  X[, closeness := 1 / (1 + d_hs / 5)]
  for (v in setdiff(GEOM, c("d_hs", "tta_now"))) set(X, j = paste0(v, "_close"), value = X[[v]] * X$closeness)
  scr <- copy(P5)[, f0 := f0 + shift]
  SF <- so_far_shares(scr, X, CALLS, known_after = known)
  for (k in seq_along(CALLS)) set(X, j = LSF[k], value = log(SF[, k]))
  X[, idx := match(id, ids)]
  setorder(X, off, idx)
  X[]
}

fit_predict <- function(train, test, feats) {
  Xtr <- as.matrix(train[, ..feats])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  dtr <- data.frame(y = factor(train$call, CALLS), scale(Xtr, mu, sdv))
  fit <- multinom(y ~ ., data = dtr, weights = rep(1 / 76, nrow(train)), decay = DECAY, trace = FALSE, maxit = 2000)
  predict(fit, newdata = data.frame(scale(as.matrix(test[, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
}

#' Held-out predictions for rows X with inputs `feats`, ten games in parallel. Returns per-screen scores.
score_variant <- function(X, feats, cl) {
  clusterExport(cl, c("X", "feats"), envir = environment())
  gs <- sort(unique(X$game_id))
  res <- parLapply(cl, gs, function(g) list(rows = which(X$game_id == g), P = fit_predict(X[game_id != g], X[game_id == g], feats)))
  Pm <- matrix(NA_real_, nrow(X), length(CALLS))
  for (r in res) Pm[r$rows, ] <- r$P
  ll <- -log(pmax(Pm[cbind(seq_len(nrow(X)), match(X$call, CALLS))], 1e-12))
  d <- data.table(idx = X$idx, game_id = X$game_id, off = X$off, ll = ll)
  d[, `:=`(w_main = window_weight(off, "main"), pre = off >= -25L & off < 0L)]
  d[, .(game_id = game_id[1], main = sum(w_main * ll) / sum(w_main), flat = mean(ll), before_marker = mean(ll[pre])), by = idx]
}

#' Paired difference of each score against the reference, with a 95% interval from resampling whole games.
paired <- function(a, ref, label) {
  rbindlist(lapply(c("main", "flat", "before_marker"), function(s) {
    d <- a[[s]] - ref[[s]]
    set.seed(1)
    gsum <- tapply(d, a$game_id, sum)
    gn <- tapply(d, a$game_id, length)
    b <- replicate(2000L, {
      k <- sample(names(gsum), length(gsum), TRUE)
      sum(gsum[k]) / sum(gn[k])
    })
    data.table(variant = label, score = s, value = round(mean(a[[s]]), 4), minus_live = round(mean(d), 4),
               lo = round(quantile(b, .025), 4), hi = round(quantile(b, .975), 4),
               games_worse = sum(tapply(d, a$game_id, mean) > 0))
  }))
}

cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})))
clusterExport(cl, c("fit_predict", "CALLS", "DECAY"))
t0 <- Sys.time()





## ═════════════════════════════════════════════════════════════════════════════
## 03 - WHEN EARLIER COVERAGES COUNT -------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Episode stop per P5 screen: its stop frame from the timing audit, else its chance end, else 3 s.
st <- stops[match(P5$id, id)]
ep_known <- round(fcoalesce(st$stop_t, st$chance_end_t, 3) * FPS)
kv <- list("0 s" = 0L, "1 s (live)" = 25L, "2 s" = 50L, "3 s" = 75L, "episode stop" = ep_known)
ka_scores <- lapply(kv, function(k) score_variant(make_rows(P$id, 0L, k), FEATS, cl))
ka_scores[["no earlier coverages"]] <- score_variant(make_rows(P$id, 0L, 25L), FEATS_0, cl)
ref <- ka_scores[["1 s (live)"]]
# Check · the live-rule refit reproduces 01_logistic_baseline.R's flat score.
cat(sprintf("Live rule flat score %.4f\n", mean(ref$flat)))
ka <- rbindlist(lapply(names(ka_scores), function(n) paired(ka_scores[[n]], ref, n)))
fwrite(ka, file.path(out_dir, "known_after.csv"))
cat("\nWhen an earlier coverage counts\n")
print(ka)





## ═════════════════════════════════════════════════════════════════════════════
## 04 - PICK-FRAME SHIFTS ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The common cohort: scored screens whose four players are tracked at every frame of the widest shift.
wide <- Fe[off >= min(OFFS) + min(SHIFTS) & off <= max(OFFS) + max(SHIFTS), .(ok = all(tracked)), by = id]
common <- P$id[P$id %in% wide[ok == TRUE]$id]
cat(sprintf("\nCommon cohort for shifts: %d of %d screens\n", length(common), nrow(P)))
sh_scores <- lapply(SHIFTS, function(s) score_variant(make_rows(common, s, 25L), FEATS, cl))
names(sh_scores) <- sprintf("%+.2f s", SHIFTS / FPS)
sref <- sh_scores[[match(0L, SHIFTS)]]
sh <- rbindlist(lapply(names(sh_scores), function(n) paired(sh_scores[[n]], sref, n)))
sh[, screens := length(common)]
fwrite(sh, file.path(out_dir, "tag_shift.csv"))
cat("\nPick frame moved\n")
print(sh)
stopCluster(cl)
cat(sprintf("\nDone in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
