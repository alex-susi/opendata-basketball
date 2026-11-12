## ═════════════════════════════════════════════════════════════════════════════
# Step 2: baselines. Every model is fitted on nine games and predicts the tenth (leave-one-game-out), so no
# prediction ever uses the game it is scored on.
#   Rscript src/kickout_transformer/02_baselines.R
#
#   uniform    an equal share for each class (25% each; 33% each with --drop-other)
#   league     the class shares in the nine training games
#   archetype  the class shares of catches by receivers of the same offensive archetype (outputs/archetypes/),
#              shrunk toward the league shares as if we had seen ARCH_PRIOR extra catches at the league shares
#   player     the receiver's own class shares, shrunk toward his archetype's shares with PLAYER_PRIOR extra catches
#   logistic   multinomial logistic regression on ten hand-built features at the catch (no tracking history
#              apart from the 0.24 s velocity in the defender's closing speed)
#
# Note: the archetypes were clustered partly from counts in these same ten games, so the archetype baseline has a
# little information from the held-out game. It is a learning benchmark, not a clean estimate.
#
# Writes outputs/cache/kickout_transformer/pred_baselines.rds.
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
suppressPackageStartupMessages(library(nnet))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Shrinkage priors (in catches) and the logistic model's inputs.
ARCH_PRIOR <- 20
PLAYER_PRIOR <- 10
LOGIT_FEATS <- c("recv_hoop_dist", "recv_corner", "recv_speed", "def1_dist", "def1_closing", "def2_dist",
                 "defs_in_paint", "time_to_act", "kickout", "from_paint")
LOGIT_DECAY <- 1       # weight decay (ridge penalty) for multinom





## ═════════════════════════════════════════════════════════════════════════════
## 02 - BASELINE PREDICTIONS BY FOLD -------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

d <- kt_load_catches(paths)
m <- d$meta
m[, y := factor(label, levels = CLASSES)]
games <- sort(unique(m$game_id))

# Class counts, and shares shrunk toward a prior as if k extra catches had the prior's shares.
counts <- function(lbl) as.numeric(table(factor(lbl, levels = CLASSES)))
shrink <- function(n_vec, prior_p, k) (n_vec + k * prior_p) / (sum(n_vec) + k)

# One held-out game: fit every baseline on the other nine games and predict this game's catches.
fold_preds <- function(g) {
  tr <- m[game_id != g]
  te <- m[game_id == g]
  league <- counts(tr$label) / nrow(tr)
  arch_p <- lapply(split(tr$label, tr$archetype), function(l) shrink(counts(l), league, ARCH_PRIOR))
  arch_of <- function(a) if (is.null(arch_p[[a]])) league else arch_p[[a]]
  player_p <- lapply(split(tr, tr$canon), function(s) shrink(counts(s$label), arch_of(s$archetype[1]), PLAYER_PRIOR))

  # Probabilities for the test catches: uniform, league, archetype, and player (falling back to the archetype).
  p_uniform <- matrix(1 / length(CLASSES), nrow(te), length(CLASSES))
  p_league <- matrix(league, nrow(te), length(CLASSES), byrow = TRUE)
  p_arch <- do.call(rbind, lapply(te$archetype, arch_of))
  p_player <- do.call(rbind, lapply(seq_len(nrow(te)), function(i) {
    pp <- player_p[[as.character(te$canon[i])]]
    if (is.null(pp)) arch_of(te$archetype[i]) else pp
  }))

  # logistic: standardise with the training games' means and sds
  X <- as.matrix(tr[, ..LOGIT_FEATS]) * 1
  mu <- colMeans(X)
  sdv <- apply(X, 2, sd)
  sdv[sdv == 0] <- 1
  Xtr <- scale(X, mu, sdv)
  Xte <- scale(as.matrix(te[, ..LOGIT_FEATS]) * 1, mu, sdv)
  dtr <- data.frame(y = tr$y, Xtr)
  dte <- data.frame(Xte)
  fit <- multinom(y ~ ., data = dtr, decay = LOGIT_DECAY, trace = FALSE, maxit = 500)
  p_logit <- predict(fit, newdata = dte, type = "probs")[, CLASSES, drop = FALSE]
  colnames(p_logit) <- NULL

  # Stack the five models' predictions and keep this fold's logistic coefficients.
  mk <- function(p, model) pred_table(te$row, model, p)
  list(pred = rbind(mk(p_uniform, "uniform"), mk(p_league, "league"), mk(p_arch, "archetype"),
                    mk(p_player, "player"), mk(p_logit, "logistic")),
       coef = data.table(game_id = g, class = rownames(coef(fit)), coef(fit)))
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - RUN AND SAVE -----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

res <- lapply(games, fold_preds)
pred <- rbindlist(lapply(res, `[[`, "pred"))
coefs <- rbindlist(lapply(res, `[[`, "coef"))
setnames(coefs, c("game_id", "class", "intercept", LOGIT_FEATS))
saveRDS(pred, file.path(paths$cache, "pred_baselines.rds"))
fwrite(coefs, file.path(paths$out, "logistic_coefficients_by_fold.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - QUICK LOOK -------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

pred[m, on = "row", `:=`(label = i.label, game_id = i.game_id, kickout = i.kickout)]
P <- as.matrix(pred[, ..PROB_COLS])
pred[, logloss := row_logloss(P, label)]
cat("Mean log loss (lower is better), all catches and strict kickouts:\n")
print(pred[, .(all = round(mean(logloss), 4), kickouts = round(mean(logloss[kickout]), 4)), by = model])
cat("\nLogistic coefficients averaged over folds (standardised features, relative to 'shot'):\n")
print(coefs[, lapply(.SD, function(v) round(mean(v), 2)), by = class, .SDcols = c("intercept", LOGIT_FEATS)])
