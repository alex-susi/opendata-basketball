# Step 04 of the rebounding manual: an L2-regularised grouped conditional logit over the 12 outcomes of a miss (the
# ten players and the two team awards), fitted per outer fold on the nine training games with lambda chosen by inner
# leave-one-game-out. Settings: config/experiment.yaml (step04$clogit). The grouped-softmax idea (no global
# intercept, shot-level values only through interactions) follows ReboundingPrediction models/conditional_logit.py,
# read for ideas only (no licence); written independently.
#
# Team awards are alternatives in the same softmax: each has a constant and a shot-distance slope, and zero player
# features. Requires static_geometry.R (PLAYER_FEATURES), metrics.R, folds.R.

TEAM_COLS <- c("team_off", "team_def", "team_off_x_shot_dist", "team_def_x_shot_dist")
UNPENALISED <- c("team_off", "team_def")

#' Standardisation learned from training rows only: player features over the training player rows, shot distance
#' over the training episodes. Constant columns keep a scale of 1.
fit_scaler <- function(sf, shot, ids, features = PLAYER_FEATURES) {
  tr <- sf[episode_id %in% ids]
  sh <- shot[episode_id %in% ids]
  sds <- vapply(features, function(f) sd(tr[[f]]), 0)
  list(mean = vapply(features, function(f) mean(tr[[f]]), 0), sd = ifelse(sds > 1e-8, sds, 1),
       shot_mean = mean(sh$shot_dist), shot_sd = max(sd(sh$shot_dist), 1e-8), n_player_rows = nrow(tr), n_episodes = nrow(sh))
}

#' Design of the given episodes: 12 rows each (ten players in their input order, then team_off, team_def), with
#' standardised player features, the team constants and the team shot-distance slopes.
#' @return list(M = matrix, rows = data.table(episode_id, outcome_id)).
choice_design <- function(sf, shot, ids, scaler) {
  ids <- sort(unique(ids))
  p <- sf[episode_id %in% ids][order(match(episode_id, ids))]
  if (nrow(p) != 10L * length(ids)) stop("every episode needs exactly ten player rows")
  pf <- names(scaler$mean)                       # the scaler's features (Step 04's PLAYER_FEATURES by default)
  Xp <- sweep(sweep(as.matrix(p[, ..pf]), 2, scaler$mean), 2, scaler$sd, `/`)
  z <- (shot$shot_dist[match(ids, shot$episode_id)] - scaler$shot_mean) / scaler$shot_sd
  n <- length(ids)
  M <- matrix(0, 12L * n, length(pf) + length(TEAM_COLS),
              dimnames = list(NULL, c(pf, TEAM_COLS)))
  player_row <- rep((0:(n - 1L)) * 12L, each = 10L) + rep(1:10, n)
  M[player_row, pf] <- Xp
  off_row <- (0:(n - 1L)) * 12L + 11L; def_row <- off_row + 1L
  M[off_row, "team_off"] <- 1; M[def_row, "team_def"] <- 1
  M[off_row, "team_off_x_shot_dist"] <- z; M[def_row, "team_def_x_shot_dist"] <- z
  rows <- data.table(episode_id = rep(ids, each = 12L), outcome_id = "")
  rows[player_row, outcome_id := as.character(p$pid)]
  rows[off_row, outcome_id := "team_off"][def_row, outcome_id := "team_def"]
  list(M = M, rows = rows)
}

#' Fit by penalised maximum likelihood. `y` is the row index (1..12) of each episode's credited outcome.
fit_clogit <- function(M, y, lambda, maxit = 1000L) {
  n <- nrow(M) / 12L
  pen <- as.numeric(!colnames(M) %in% UNPENALISED)
  Y <- matrix(0, 12L, n); Y[cbind(y, seq_len(n))] <- 1
  value_grad <- function(b) {
    U <- matrix(M %*% b, 12L)
    mx <- apply(U, 2, max)
    E <- exp(sweep(U, 2, mx)); s <- colSums(E)
    P <- sweep(E, 2, s, `/`)
    list(f = -sum(U[cbind(y, seq_len(n))] - mx - log(s)) + lambda / 2 * sum(pen * b^2),
         g = as.vector(crossprod(M, as.vector(P - Y))) + lambda * pen * b)
  }
  cache <- new.env()
  fn <- function(b) { cache$vg <- value_grad(b); cache$b <- b; cache$vg$f }
  gr <- function(b) { if (!identical(cache$b, b)) value_grad(b)$g else cache$vg$g }
  o <- optim(rep(0, ncol(M)), fn, gr, method = "BFGS", control = list(maxit = maxit, reltol = 1e-12))
  list(beta = setNames(o$par, colnames(M)), lambda = lambda, converged = o$convergence == 0L, iterations = o$counts[["gradient"]],
       objective = o$value)
}

#' Long predictions (episode_id, outcome_id, probability) of a fitted model on a design.
predict_clogit <- function(fit, design) {
  U <- matrix(design$M %*% fit$beta, 12L)
  P <- exp(sweep(U, 2, apply(U, 2, max)))
  P <- sweep(P, 2, colSums(P), `/`)
  cbind(design$rows, probability = as.vector(P))
}

#' Row index of each episode's credited outcome in a design.
design_labels <- function(design, labels) {
  r <- merge(design$rows[, .(episode_id, outcome_id, row = rowid(episode_id))], labels[, .(episode_id, outcome_id)],
             by = c("episode_id", "outcome_id"))
  ids <- unique(design$rows$episode_id)
  if (nrow(r) != length(ids)) stop("credited outcome missing from a design")
  r$row[match(ids, r$episode_id)]
}

#' Fit on training ids (scaler included) and predict test ids.
clogit_fit_predict <- function(sf, shot, labels, train, test, lambda, maxit, features = PLAYER_FEATURES) {
  sc <- fit_scaler(sf, shot, train, features)
  dtr <- choice_design(sf, shot, train, sc)
  fit <- fit_clogit(dtr$M, design_labels(dtr, labels), lambda, maxit)
  list(fit = fit, scaler = sc, pred = predict_clogit(fit, choice_design(sf, shot, test, sc)))
}

#' Outer-fold predictions with lambda chosen inside each fold's nine training games.
#' @return list(pred (long, with outer_fold), lambda (inner log loss per lambda and fold), coef (per fold), fits).
clogit_fold_predictions <- function(sf, shot, labels, fa, choice, grid, maxit, floor, features = PLAYER_FEATURES) {
  fa <- fa[episode_id %in% unique(sf$episode_id)]
  out <- list(); lam <- list(); coefs <- list()
  for (k in sort(unique(fa$outer_fold))) {
    s <- fold_split(fa, k)
    inner <- rbindlist(lapply(grid, function(l) {
      p <- rbindlist(lapply(s$inner, function(f) clogit_fit_predict(sf, shot, labels, f$train, f$test, l, maxit, features)$pred))
      p[, `:=`(model = "clogit", time_point = "inner")]
      data.table(lambda = l, inner_log_loss = mean(score_episodes(p, choice, labels, floor)$ll))
    }))
    best <- inner[inner_log_loss == min(inner_log_loss)][, max(lambda)]
    r <- clogit_fit_predict(sf, shot, labels, s$train, s$test, best, maxit, features)
    lam[[length(lam) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, inner, selected = inner$lambda == best)
    coefs[[length(coefs) + 1L]] <- data.table(outer_fold = k, test_game = s$test_game, term = names(r$fit$beta),
                                              estimate = unname(r$fit$beta), lambda = best, converged = r$fit$converged,
                                              iterations = r$fit$iterations, scaler_player_rows = r$scaler$n_player_rows,
                                              scaler_episodes = r$scaler$n_episodes)
    out[[length(out) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, n_train = length(s$train), r$pred)
  }
  list(pred = rbindlist(out), lambda = rbindlist(lam), coef = rbindlist(coefs))
}
