# Step 02, labeler v2: EM for a Gaussian hidden Markov model with structural zeros and fixed self-transitions.
# depmixS4 fits fixed parameters only through a general optimizer (Rsolnp), impractical with ~250 parameters; this EM
# keeps both constraints exactly. Emissions: independent normals per state and feature. A row with any missing feature
# is unobserved (emission density 1), as in depmixS4. Rows must be sorted by episode, then frame. Episodes are processed
# together, one time step at a time. The likelihood is checked against depmixS4 in tests/unit/test_hmm_em.R.

#' Row indices by time step: rows[[t]] holds the t-th row of every episode that long; rows[[t]] - 1 are their
#' predecessors (same episode, same order).
hmm_index <- function(ep) {
  pos <- ave(seq_along(ep), ep, FUN = seq_along)
  split(seq_along(ep), pos)
}

#' Log emission densities (rows x states); unobserved rows are 0. mask (rows x states, optional): FALSE makes a state
#' impossible on that row.
hmm_log_emis <- function(X, mu, sd, mask = NULL) {
  obs <- stats::complete.cases(X)
  L <- matrix(0, nrow(X), nrow(mu))
  Xo <- X[obs, , drop = FALSE]
  for (k in seq_len(nrow(mu)))
    L[obs, k] <- rowSums(stats::dnorm(Xo, rep(mu[k, ], each = nrow(Xo)), rep(sd[k, ], each = nrow(Xo)), log = TRUE))
  if (!is.null(mask)) {
    if (any(rowSums(mask) == 0)) stop("a row with every state masked")
    L[!mask] <- -Inf
  }
  L
}

#' Scaled forward-backward. Returns the log-likelihood, state posteriors (rows x states) and expected transition counts.
hmm_fb <- function(L, A, init, idx) {
  off <- apply(L, 1, max)
  B <- exp(L - off)
  n <- nrow(B)
  K <- ncol(B)
  al <- matrix(0, n, K)
  sc <- numeric(n)
  r <- idx[[1]]
  a <- B[r, , drop = FALSE] * rep(init, each = length(r))
  sc[r] <- rowSums(a)
  al[r, ] <- a / sc[r]
  for (t in seq_along(idx)[-1]) {
    r <- idx[[t]]
    a <- (al[r - 1L, , drop = FALSE] %*% A) * B[r, , drop = FALSE]
    sc[r] <- rowSums(a)
    al[r, ] <- a / sc[r]
  }
  be <- matrix(1, n, K)
  Xi <- matrix(0, K, K)
  for (t in rev(seq_along(idx)[-1])) {
    r <- idx[[t]]
    w <- B[r, , drop = FALSE] * be[r, , drop = FALSE] / sc[r]
    Xi <- Xi + crossprod(al[r - 1L, , drop = FALSE], w)
    be[r - 1L, ] <- w %*% t(A)
  }
  g <- al * be
  list(loglik = sum(log(sc)) + sum(off), gamma = g / rowSums(g), xi = Xi * A)
}

#' Transition M-step: rows proportional to expected counts over the allowed cells; a state with a fixed stay keeps it
#' and shares the rest in proportion to its counts.
hmm_m_trans <- function(xi, allowed, fixed_stay) {
  K <- nrow(xi)
  A <- matrix(0, K, K)
  # Each state's transition row from expected counts, holding a fixed stay probability where one is given.
  for (k in seq_len(K)) {
    ok <- allowed[k, ]
    if (!is.na(fixed_stay[k])) {
      ok[k] <- FALSE
      cnt <- xi[k, ] * ok
      A[k, ] <- if (sum(cnt) > 0) (1 - fixed_stay[k]) * cnt / sum(cnt) else (1 - fixed_stay[k]) * ok / sum(ok)
      A[k, k] <- fixed_stay[k]
    } else {
      cnt <- xi[k, ] * ok
      A[k, ] <- if (sum(cnt) > 0) cnt / sum(cnt) else ok / sum(ok)
    }
  }
  A
}

#' EM fit. X: numeric matrix (rows sorted by episode, frame); ep: episode of each row; A0 starting transitions (zeros
#' stay zero); fixed_stay: per-state fixed self-transition or NA; init: fixed initial distribution.
hmm_em <- function(X, ep, A0, mu0, sd0, init, fixed_stay, maxit = 500, rel_tol = 1e-8, min_sd = 0.05,
                   mask = NULL, verbose = FALSE) {
  idx <- hmm_index(ep)
  allowed <- A0 > 0
  obs <- stats::complete.cases(X)
  Xo <- X[obs, , drop = FALSE]
  A <- A0
  mu <- mu0
  sd <- sd0
  ll_old <- -Inf
  trace <- numeric(0)
  # EM: forward-backward, then update transitions and emissions, until the log likelihood stops improving.
  for (it in seq_len(maxit)) {
    fb <- hmm_fb(hmm_log_emis(X, mu, sd, mask), A, init, idx)
    trace <- c(trace, fb$loglik)
    if (verbose && it %% 10 == 0) cat(sprintf("  iteration %d: logLik %.1f\n", it, fb$loglik))
    if (is.finite(ll_old) && (fb$loglik - ll_old) / abs(ll_old) < rel_tol) break
    ll_old <- fb$loglik
    A <- hmm_m_trans(fb$xi, allowed, fixed_stay)
    w <- fb$gamma[obs, , drop = FALSE]
    ws <- pmax(colSums(w), 1e-12)
    mu <- crossprod(w, Xo) / ws
    for (k in seq_len(nrow(mu)))
      sd[k, ] <- pmax(min_sd, sqrt(colSums(w[, k] * (Xo - rep(mu[k, ], each = nrow(Xo)))^2) / ws[k]))
  }
  list(A = A, mu = mu, sd = sd, init = init, loglik = fb$loglik, iterations = it, trace = trace,
       converged = it < maxit, n_par = sum(allowed) - nrow(A) - sum(!is.na(fixed_stay)) + 2 * length(mu))
}

#' Viterbi path (state index per row), vectorized over episodes.
hmm_viterbi <- function(L, A, init, idx) {
  n <- nrow(L)
  K <- ncol(L)
  lA <- log(A)
  dl <- matrix(-Inf, n, K)
  bp <- matrix(0L, n, K)
  r <- idx[[1]]
  dl[r, ] <- L[r, , drop = FALSE] + rep(log(init), each = length(r))
  for (t in seq_along(idx)[-1]) {
    r <- idx[[t]]
    p <- dl[r - 1L, , drop = FALSE]
    for (k in seq_len(K)) {
      cand <- p + rep(lA[, k], each = length(r))
      j <- max.col(cand, ties.method = "first")
      bp[r, k] <- j
      dl[r, k] <- cand[cbind(seq_along(r), j)] + L[r, k]
    }
  }
  path <- integer(n)
  T <- length(idx)
  # last row of each episode: its best final state
  last <- unlist(lapply(seq_len(T), function(t) {
    r <- idx[[t]]
    if (t < T) setdiff(r, idx[[t + 1]] - 1L) else r
  }))
  path[last] <- max.col(dl[last, , drop = FALSE], ties.method = "first")
  for (t in rev(seq_len(T)[-1])) {
    r <- idx[[t]]
    path[r - 1L] <- bp[cbind(r, path[r])]
  }
  path
}
