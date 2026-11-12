# Step 04 of the rebounding manual: the binary offensive-rebound model (offence secures the miss: an offensive player
# or an offensive team award), an L2-regularised logistic regression on the episode features of static_geometry.R,
# fitted per outer fold with lambda chosen by inner leave-one-game-out, and the constant training rate it is compared
# with (C2). Settings: config/experiment.yaml (step04$oreb). Requires static_geometry.R (EPISODE_FEATURES), folds.R.

#' Fit: standardise on the training episodes, unpenalised intercept, objective = binary log loss summed over episodes
#' + lambda / 2 x sum of squared slopes. BFGS with the analytic gradient.
fit_oreb <- function(ef, labels, ids, lambda, maxit = 1000L) {
  tr <- merge(ef[episode_id %in% ids], labels[, .(episode_id, y_off)], by = "episode_id")
  mu <- vapply(EPISODE_FEATURES, function(f) mean(tr[[f]]), 0)
  s <- vapply(EPISODE_FEATURES, function(f) sd(tr[[f]]), 0)
  s <- ifelse(s > 1e-8, s, 1)
  X <- cbind(1, sweep(sweep(as.matrix(tr[, ..EPISODE_FEATURES]), 2, mu), 2, s, `/`))
  y <- as.numeric(tr$y_off)
  pen <- c(0, rep(1, length(EPISODE_FEATURES)))
  fn <- function(b) {
    eta <- X %*% b
    sum(log1p(exp(-abs(eta))) + pmax(eta, 0) - y * eta) + lambda / 2 * sum(pen * b^2)
  }
  gr <- function(b) as.vector(crossprod(X, plogis(X %*% b) - y)) + lambda * pen * b
  o <- optim(rep(0, ncol(X)), fn, gr, method = "BFGS", control = list(maxit = maxit, reltol = 1e-12))
  list(beta = setNames(o$par, c("intercept", EPISODE_FEATURES)), mean = mu, sd = s, lambda = lambda,
       converged = o$convergence == 0L, n_train = nrow(tr))
}

predict_oreb <- function(fit, ef, ids) {
  te <- ef[episode_id %in% ids]
  X <- cbind(1, sweep(sweep(as.matrix(te[, ..EPISODE_FEATURES]), 2, fit$mean), 2, fit$sd, `/`))
  data.table(episode_id = te$episode_id, p_off = as.vector(plogis(X %*% fit$beta)))
}

binary_log_loss <- function(p, y, floor = 1e-12) {
  p <- pmin(pmax(p, floor), 1 - floor)
  -(y * log(p) + (1 - y) * log(1 - p))
}

#' Outer-fold P(OREB) with lambda chosen inside each fold's nine training games.
oreb_fold_predictions <- function(ef, labels, fa, grid, maxit) {
  fa <- fa[episode_id %in% ef$episode_id]
  y_of <- function(ids) as.numeric(labels$y_off[match(ids, labels$episode_id)])
  out <- list()
  lam <- list()
  coefs <- list()
  # Per outer fold: choose the ridge penalty on the inner folds, then fit and predict the test game.
  for (k in sort(unique(fa$outer_fold))) {
    s <- fold_split(fa, k)
    inner <- rbindlist(lapply(grid, function(l) {
      p <- rbindlist(lapply(s$inner, function(f) predict_oreb(fit_oreb(ef, labels, f$train, l, maxit), ef, f$test)))
      data.table(lambda = l, inner_log_loss = mean(binary_log_loss(p$p_off, y_of(p$episode_id))))
    }))
    best <- inner[inner_log_loss == min(inner_log_loss)][, max(lambda)]
    fit <- fit_oreb(ef, labels, s$train, best, maxit)
    lam[[length(lam) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, inner, selected = inner$lambda == best)
    coefs[[length(coefs) + 1L]] <- data.table(outer_fold = k, test_game = s$test_game, term = names(fit$beta),
                                              estimate = unname(fit$beta), lambda = best, converged = fit$converged,
                                              n_train = fit$n_train)
    out[[length(out) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, n_train = fit$n_train, predict_oreb(fit, ef, s$test))
  }
  list(pred = rbindlist(out), lambda = rbindlist(lam), coef = rbindlist(coefs))
}

#' The C2 reference: each outer fold's training share of offensive outcomes (the Step 03 constant_oreb).
constant_oreb_predictions <- function(labels, fa, ids) {
  fa <- fa[episode_id %in% ids]
  rbindlist(lapply(sort(unique(fa$outer_fold)), function(k) {
    s <- fold_split(fa, k)
    data.table(outer_fold = k, episode_id = s$test, p_off = mean(labels$y_off[match(s$train, labels$episode_id)]))
  }))
}
