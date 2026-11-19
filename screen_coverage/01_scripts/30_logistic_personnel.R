## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 30: the logistic baseline with the personnel experiment's inputs.
#   Rscript screen_coverage/01_scripts/30_logistic_personnel.R [--workers=6]
#
# Needs 01_logistic_baseline.R and 29_build_personnel.R. The same multinomial logistic model, rows, weights,
# standardisation and leave-one-game-out folds as 01_logistic_baseline.R ("no timing, + closeness"), fitted four ways:
#   baseline        its inputs unchanged (must reproduce the live baseline's predictions)
#   + positions     plus the four screen players' guard and big probabilities (wing is the reference) and "same
#                   size" (the chance both defenders are in the same group), from the held-out game's own fold
#                   (28_fold_positions.R: positions refitted without that game)
#   + memory        plus the possession's memory at the row's frame: earlier switch, earlier pick, cross-match
#   + both          both sets
#   defenders + memory   the two defenders' positions and same size only (no attackers), plus the memory
#   _hard versions       the same with each player's most likely group as 0/1 (owner, 2026-11-19)
#   [--only=a,b fits just those versions and merges them into the saved file]
# The training games of fold g use fold g's positions too, so one fit sees one set of positions.
#
# Writes screen_coverage/02_cache/experiments/personnel/logistic.rds (the four versions' probabilities in the row
# order of logistic_per_frame.rds).
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(parallel)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
hit <- grep("^--workers=", commandArgs(TRUE), value = TRUE)
WORKERS <- if (length(hit)) as.integer(sub("^--workers=", "", hit)) else 6L
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
cache_dir <- file.path(root, "screen_coverage", "02_cache")
exp_dir <- file.path(cache_dir, "experiments", "personnel")
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
PI <- readRDS(file.path(exp_dir, "inputs.rds"))
if (!identical(PI$rules, L$rules) || !identical(PI$screen_ids, L$P$id)) stop("inputs.rds is stale: rerun 29_build_personnel.R")
X <- copy(L$X)
CALLS <- L$calls
OFFS <- L$offs
DECAY <- 1





## ═════════════════════════════════════════════════════════════════════════════
## 01 - INPUTS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The live baseline's inputs (01_logistic_baseline.R, FEATS).
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
FEATS <- c(GEOM, paste0("lsf_", seq_along(CALLS)), "closeness", CLOSE)
# Positions of the four screen players (roster slots 1-4: handler, screener, handler's defender, screener's defender).
SLOTS <- c(h = 1L, s = 2L, bd = 3L, sd = 4L)
POS_F <- c(as.vector(outer(names(SLOTS), c("guard", "big"), paste, sep = "_")), "same_size")
MEM_F <- PI$mem_cols
for (k in MEM_F) set(X, j = k, value = PI$mem[, k])
DEF_F <- c("bd_guard", "bd_big", "sd_guard", "sd_big", "same_size")
# Hard groups (owner, 2026-11-19): the same columns from each player's most likely group as 0/1 (suffix _h).
POS_FH <- paste0(POS_F, "_h")
DEF_FH <- paste0(DEF_F, "_h")
VERSIONS <- list(baseline = FEATS, positions = c(FEATS, POS_F), memory = c(FEATS, MEM_F), both = c(FEATS, POS_F, MEM_F),
                 defenders_memory = c(FEATS, DEF_F, MEM_F), positions_hard = c(FEATS, POS_FH), both_hard = c(FEATS, POS_FH, MEM_F),
                 defenders_memory_hard = c(FEATS, DEF_FH, MEM_F), defenders_hard = c(FEATS, DEF_FH))
# --only=a,b fits just those versions and merges them into the saved file (the others are kept as they are).
hit <- grep("^--only=", commandArgs(TRUE), value = TRUE)
ONLY <- if (length(hit)) strsplit(sub("^--only=", "", hit), ",")[[1]] else names(VERSIONS)
if (!all(ONLY %in% names(VERSIONS))) stop("Unknown version in --only")

#' X with fold g's position columns, from the probabilities and (suffix _h) from the most likely group.
with_positions <- function(g) {
  Xg <- copy(X)
  for (form in c("", "_h")) {
    pa <- (if (form == "_h") PI$pos_hard else PI$pos)[[as.character(g)]]
    for (s in names(SLOTS)) {
      set(Xg, j = paste0(s, "_guard", form), value = pa[Xg$idx, SLOTS[[s]], "p_guard"])
      set(Xg, j = paste0(s, "_big", form), value = pa[Xg$idx, SLOTS[[s]], "p_big"])
    }
    set(Xg, j = paste0("same_size", form), value = rowSums(pa[Xg$idx, SLOTS[["bd"]], ] * pa[Xg$idx, SLOTS[["sd"]], ]))
  }
  Xg
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FITS -------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# As in 01_logistic_baseline.R: standardised with the training rows, every frame weighted 1/76.
fit_predict <- function(train, test, feats, w) {
  Xtr <- as.matrix(train[, ..feats])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  dtr <- data.frame(y = factor(train$call, CALLS), scale(Xtr, mu, sdv))
  fit <- multinom(y ~ ., data = dtr, weights = w, decay = DECAY, trace = FALSE, maxit = 2000)
  predict(fit, newdata = data.frame(scale(as.matrix(test[, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
}
fold <- function(g, feats) {
  Xg <- with_positions(g)
  tr <- Xg[game_id != g]
  list(rows = which(Xg$game_id == g), P = fit_predict(tr, Xg[game_id == g], feats, w = rep(1 / length(OFFS), nrow(tr))))
}
t0 <- Sys.time()
cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})))
gs <- sort(unique(X$game_id))
jobs <- CJ(v = ONLY, g = gs)
clusterExport(cl, c("X", "PI", "CALLS", "DECAY", "OFFS", "SLOTS", "VERSIONS", "jobs", "fit_predict", "fold", "with_positions"))
res <- parLapply(cl, seq_len(nrow(jobs)), function(i) fold(jobs$g[i], VERSIONS[[jobs$v[i]]]))
stopCluster(cl)
prob <- lapply(ONLY, function(v) {
  Pm <- matrix(NA_real_, nrow(X), length(CALLS))
  for (i in which(jobs$v == v)) Pm[res[[i]]$rows, ] <- res[[i]]$P
  Pm
})
names(prob) <- ONLY
out_path <- file.path(exp_dir, "logistic.rds")
if (!identical(ONLY, names(VERSIONS)) && file.exists(out_path)) prob <- modifyList(readRDS(out_path)$prob, prob)
cat(sprintf("Fits done in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
if ("baseline" %in% ONLY) cat("Baseline reproduces the live logistic predictions:", isTRUE(all.equal(prob$baseline, L$prob[["no timing, + closeness"]], tolerance = 1e-6)), "\n")
saveRDS(list(prob = prob, versions = VERSIONS, screen_ids = L$P$id, rules = L$rules), out_path)
