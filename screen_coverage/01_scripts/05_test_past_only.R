## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 5: "the future can't change the past" test.
#   Rscript screen_coverage/01_scripts/05_test_past_only.R
#
# Needs 01_logistic_baseline.R, 02_build_sequences.R and 03_train_transformer.R (all ten folds) under the current
# rules.
#
# For a sample of screens (three per game, chosen to include re-screens, where the old "so far" rule leaked) and
# prediction frames (-2, -1, -0.4, 0, +0.48 and +1 s around the tag), the inputs are rebuilt from the raw bundle
# twice: as delivered, and after scrambling everything that happens AFTER the prediction frame:
#   - every later tracking row is moved by a random 0-12 ft, and 30% of them are deleted
#   - every later frame's shot clock and game clock are replaced at random
#   - the call of every screen not yet readable at the prediction frame (tag + 1 s later) is replaced at random
# The test passes when, at every sampled row:
#   1. the rebuilt inputs match the cached ones the models were trained and scored on (the test runs the real code)
#   2. the inputs after scrambling are IDENTICAL to the inputs before (logistic and live transformer)
#   3. the predictions after scrambling are identical too: the logistic baseline ("no timing, + closeness") is refit
#      on its nine training games, and the live transformer's saved networks are rerun; both also match the cached
#      held-out predictions
# Negative controls show that the test can fail: scrambling the prediction frame itself must change the inputs, and
# the old rules (positions filled from up to two frames later; every earlier tag counted in "so far") must break
# the test on rows where they looked ahead.
#
# Writes screen_coverage/03_outputs/past_only_test/past_only_test.csv and stops with an error if any check fails.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "seq_transformer.R"))
torch_set_num_threads(1L)
cache_dir <- file.path(root, "screen_coverage", "02_cache")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "past_only_test")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS AND CACHED INPUTS ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# As in 01_logistic_baseline.R and 02_build_sequences.R; check 1 below fails if these drift from the pipeline.
VLAG <- 6L
DECAY <- 1
ROSTER_OFF <- -50L
TEST_OFFS <- c(-50L, -25L, -10L, 0L, 12L, 25L)
SCREENS_PER_GAME <- 3L
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
LSF <- paste0("lsf_", 1:5)
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
FEATS <- c(GEOM, LSF, "closeness", CLOSE)
BASELINE <- "no timing, + closeness"
TOL <- 1e-6

L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
stopifnot(identical(L$rules, PAST_ONLY_RULES), identical(SQ$rules, PAST_ONLY_RULES), identical(SQ$screen_ids, L$P$id))
P <- L$P
X <- L$X
CALLS <- L$calls
cached <- readRDS(file.path(cache_dir, "per_frame_features.rds"))
P5 <- cached$P[order(game_id, f0)][call %in% CALLS]           # every five-call screen, as counted by "so far"
NS <- nrow(P)
FLAT <- matrix(SQ$base, nrow = NS * dim(SQ$base)[2])
K_STEPS <- readRDS(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", P$game_id[1])))$k_steps

# Sample: per game, screens with an earlier same-defense screen tagged within 2 s first (the old leak), then random.
set.seed(20261112)
draw <- function(v, n) v[sample.int(length(v), min(n, length(v)))]     # sample() misreads a single number
P[, rescreen := vapply(seq_len(.N), function(i) {
  any(P5$game_id == game_id[i] & P5$def_team == def_team[i] & P5$f0 < f0[i] & P5$f0 > f0[i] - 50)
}, NA)]
pick <- P[, {
  r <- c(draw(which(rescreen), 2L), draw(which(!rescreen), SCREENS_PER_GAME))
  .(id = id[head(unique(r), SCREENS_PER_GAME)])
}, by = game_id]
cat("Sampled screens:", nrow(pick), "(re-screens among them:", P[id %in% pick$id, sum(rescreen)], ")\n")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - INPUT BUILDERS (THE PIPELINE'S OWN FUNCTIONS) --------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' The logistic baseline's inputs for screen p (one row of P) at frame `at`, from bundle B and five-call screens `scr`:
#' geometry, time to act, the defense so far, closeness and each measure times closeness (as 01_logistic_baseline.R).
logistic_inputs <- function(B, scr, p, at) {
  fp <- four_player_features(B, p, at, VLAG)
  sf <- so_far_shares(scr, data.table(game_id = p$game_id, def_team = p$def_team, f0 = p$f0, frame = at), CALLS)
  v <- c(unlist(fp[, GEOM[GEOM != "tta_now"], with = FALSE]), tta_now = min(fp$sc_now, fp$gc_now, 24, na.rm = TRUE),
         setNames(log(sf[1, ]), LSF))
  cl <- 1 / (1 + v[["d_hs"]] / 5)
  c(v, closeness = cl, setNames(v[sub("_close$", "", CLOSE)] * cl, CLOSE))
}

#' The live transformer's inputs for screen p at offset `off`: history [1, 10, k, features] and context.
seq_inputs <- function(B, scr, p, off) {
  ro <- c(p$H, p$S, p$BD, p$SD, other_six(B, p, p$f0 + ROSTER_OFF))
  pos <- ten_player_positions(B, p, matrix(ro, 1L))
  base <- sequence_base(pos$PX, pos$PY)
  hist <- seq_history(matrix(base, nrow = dim(base)[2]), 1L, 1L, off, K_STEPS)
  mem <- contact_memory(pos$PX, pos$PY, 1L, off)
  li <- logistic_inputs(B, scr, p, p$f0 + off)
  d_hs <- li[["d_hs"]]
  ctx <- c(li[c("tta_now", LSF)], closeness = 1 / (1 + d_hs / 5), hs_min = if (is.na(mem[1, 1])) d_hs else mem[1, 1],
           since_hs_min = if (is.na(mem[1, 2])) 0 else mem[1, 2])
  list(hist = hist, ctx = ctx, roster = ro)
}

#' A copy of the bundle and the screens with everything strictly after frame `at` scrambled (or, with
#' `at_frame_only`, the prediction frame itself, as a negative control).
scramble <- function(B, scr, at, seed, at_frame_only = FALSE) {
  set.seed(seed)
  B2 <- B
  B2$P <- copy(B$P)
  hit <- if (at_frame_only) which(B2$P$frame == at) else which(B2$P$frame > at)
  n <- length(hit)
  set(B2$P, hit, "x", B2$P$x[hit] + runif(n, -12, 12))
  set(B2$P, hit, "y", B2$P$y[hit] + runif(n, -12, 12))
  if (!at_frame_only) B2$P <- B2$P[-draw(hit, round(0.3 * n))]
  setkey(B2$P, frame, pid)
  B2$Fr <- copy(B$Fr)
  fh <- which(B2$Fr$frame > at)
  set(B2$Fr, fh, "sc", runif(length(fh), 0, 24))
  set(B2$Fr, fh, "gc", runif(length(fh), 0, 600))
  setkey(B2$Fr, frame)
  scr2 <- copy(scr)
  later <- which(scr2$f0 + KNOWN_AFTER > at)
  if (!at_frame_only) set(scr2, later, "call", sample(CALLS, length(later), replace = TRUE))
  list(B = B2, scr = scr2)
}

# The rules before 2026-11-12, for the negative controls: positions filled from up to two frames later, and every
# earlier tag of the same defense counted in "so far" whatever the prediction frame.
pos_old <- function(B, frames, ids) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_, poss = NA_character_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    q_frame <- frames[miss] + d
    q_id <- ids[miss]
    hit <- B$P[.(q_frame, q_id), .(x, y, poss), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y, poss = hit$poss)]
  }
  out
}
so_far_old_rule <- function(screens, rows, calls) so_far_shares(screens, rows, calls, known_after = -1e9)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - PREDICTION HELPERS -----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The logistic baseline for one held-out game, as in 01_logistic_baseline.R: every frame of the other nine games,
# each weighted 1/76, standardised with the training rows.
fit_fold <- function(g) {
  tr <- X[game_id != g]
  Xtr <- as.matrix(tr[, ..FEATS])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  fit <- multinom(y ~ ., data = data.frame(y = factor(tr$call, CALLS), scale(Xtr, mu, sdv)),
                  weights = rep(1 / length(L$offs), nrow(tr)), decay = DECAY, trace = FALSE, maxit = 2000)
  function(v) predict(fit, newdata = data.frame(scale(matrix(v[FEATS], 1, dimnames = list(NULL, FEATS)), mu, sdv)),
                      type = "probs")[CALLS]
}
# The live transformer's saved networks for one held-out game, averaged over random starts.
seq_predictor <- function(g) {
  o <- readRDS(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", g)))
  # The fold file records each network's full path when it was trained; look them up by name in this cache folder so
  # the check still works after the repository is moved or reorganised.
  nets <- lapply(file.path(cache_dir, "tf", basename(o$nets)), torch_load)
  for (n in nets) n$eval()
  nm <- o$norm
  function(inp) {
    xt <- (torch_tensor(inp$hist) - torch_tensor(nm$mu)) / torch_tensor(nm$sdv)
    ct <- torch_tensor(matrix((inp$ctx[colnames(SQ$ctx)] - nm$cmu) / nm$csd, 1))
    Reduce(`+`, lapply(nets, function(n) as_array(with_no_grad(joint_logp(n(xt, ct))$exp())))) / length(nets)
  }
}
seq_cached <- function(g) readRDS(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", g)))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - RUN THE CHECKS ---------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

res <- list()
add <- function(...) res[[length(res) + 1L]] <<- data.table(...)
same <- function(a, b) isTRUE(all.equal(unname(unlist(a)), unname(unlist(b)), tolerance = TOL))
for (g in unique(pick$game_id)) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  predict_seq <- seq_predictor(g)
  predict_log <- fit_fold(g)
  sc <- seq_cached(g)
  for (sid in pick[game_id == g]$id) {
    k <- match(sid, P$id)
    p <- P[k]
    for (o in TEST_OFFS) {
      at <- p$f0 + o
      r <- which(X$idx == k & X$off == o)
      seed <- k * 1000L + o + 100L
      # Inputs as delivered, and with everything after the prediction frame scrambled.
      li <- logistic_inputs(B, P5, p, at)
      si <- seq_inputs(B, P5, p, o)
      S2 <- scramble(B, P5, at, seed)
      li2 <- logistic_inputs(S2$B, S2$scr, p, at)
      si2 <- seq_inputs(S2$B, S2$scr, p, o)
      # Check 1: the rebuilt inputs are the cached ones.
      c1_log <- same(li[FEATS], X[r, FEATS, with = FALSE])
      c1_seq <- same(si$hist, seq_history(FLAT, NS, k, o, K_STEPS)) && same(si$ctx, SQ$ctx[r, names(si$ctx)]) &&
        identical(as.integer(si$roster), as.integer(SQ$roster[k, ]))
      # Check 2: scrambling the future leaves the inputs identical.
      c2_log <- identical(li, li2)
      c2_seq <- identical(si$hist, si2$hist) && identical(si$ctx, si2$ctx)
      # Check 3: predictions identical, and equal to the cached held-out ones.
      pr1 <- predict_log(li)
      pr2 <- predict_log(li2)
      ps1 <- predict_seq(si)
      ps2 <- predict_seq(si2)
      c3_log <- identical(pr1, pr2) && same(pr1, L$prob[[BASELINE]][r, ])
      c3_seq <- identical(ps1, ps2) && isTRUE(all.equal(as.vector(ps1), sc$prob[match(r, sc$rows), ], tolerance = 1e-4))
      # Negative controls: scrambling the prediction frame itself must change the inputs; the old rules must be
      # able to see the scrambled future on rows where they looked ahead.
      S3 <- scramble(B, P5, at, seed, at_frame_only = TRUE)
      nc_now <- !identical(li, logistic_inputs(S3$B, S3$scr, p, at))
      rows1 <- data.table(game_id = p$game_id, def_team = p$def_team, f0 = p$f0, frame = at)
      nc_old_so_far <- !identical(so_far_old_rule(P5, rows1, CALLS), so_far_old_rule(S2$scr, rows1, CALLS))
      Bgap <- B
      Bgap$P <- B$P[!(pid == p$H & frame %in% c(at, at - 1L))]
      Sgap <- scramble(Bgap, P5, at, seed)
      nc_old_pos <- !identical(pos_old(Bgap, at, p$H), pos_old(Sgap$B, at, p$H))
      nc_new_pos <- !identical(pos_past(Bgap, at, p$H), pos_past(Sgap$B, at, p$H))
      add(game_id = g, id = sid, off = o, rescreen = p$rescreen, matches_cache_logistic = c1_log,
          matches_cache_transformer = c1_seq, future_scrambled_inputs_same_logistic = c2_log,
          future_scrambled_inputs_same_transformer = c2_seq, future_scrambled_prediction_same_logistic = c3_log,
          future_scrambled_prediction_same_transformer = c3_seq, control_scrambling_now_changes_inputs = nc_now,
          control_old_so_far_rule_sees_future = nc_old_so_far, control_old_lookup_sees_future = nc_old_pos,
          new_lookup_sees_future = nc_new_pos)
    }
  }
  cat("Game", g, "done\n")
}
R <- rbindlist(res)
fwrite(R, file.path(out_dir, "past_only_test.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - VERDICT ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

must_all <- c("matches_cache_logistic", "matches_cache_transformer", "future_scrambled_inputs_same_logistic",
              "future_scrambled_inputs_same_transformer", "future_scrambled_prediction_same_logistic",
              "future_scrambled_prediction_same_transformer", "control_scrambling_now_changes_inputs")
summ <- R[, lapply(.SD, sum), .SDcols = c(must_all, "control_old_so_far_rule_sees_future", "control_old_lookup_sees_future",
                                         "new_lookup_sees_future")]
cat("\nRows checked:", nrow(R), "\nPassing rows per check:\n")
print(melt(summ, measure.vars = names(summ), variable.name = "check", value.name = "rows_true"))
cat("\nOld 'so far' rule saw the scrambled future on", R[, sum(control_old_so_far_rule_sees_future)], "rows (",
    R[rescreen == TRUE & off < 0, sum(control_old_so_far_rule_sees_future)], "of them before the tag of a re-screen)\n")
fail <- c(must_all[!vapply(must_all, function(m) all(R[[m]]), NA)],
          if (any(R$new_lookup_sees_future)) "new_lookup_sees_future",
          if (!any(R$control_old_lookup_sees_future)) "control_old_lookup_sees_future (never triggered)",
          if (!any(R$control_old_so_far_rule_sees_future)) "control_old_so_far_rule_sees_future (never triggered)")
if (length(fail)) stop("PAST-ONLY TEST FAILED: ", paste(fail, collapse = "; "))
cat("\nPAST-ONLY TEST PASSED: scrambling everything after the prediction frame changed no input and no prediction.\n")
