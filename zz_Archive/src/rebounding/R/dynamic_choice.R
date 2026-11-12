# Step 09 of the rebounding manual: the dynamic rebound model. For each ball particle k one softmax over the 12
# outcomes (ten players, two team awards) with the Step 04 static utilities plus each player's access to particle k;
# the episode's probabilities are the weighted average over particles, p_i = sum_k w_k softmax_i(U_ik). Fitted by
# penalised maximum likelihood of that mixture (BFGS, analytic gradient). Settings: config/experiment.yaml (step09).
# predict_rebound() is the replay interface. Requires static_geometry.R (PLAYER_FEATURES), conditional_choice.R
# (TEAM_COLS, UNPENALISED, fit_scaler), particle_integration.R (ACCESS_FEATURES).

#' Column maxima of a matrix with few rows (faster than apply over many columns).
col_max <- function(U) {
  m <- U[1, ]
  for (i in seq_len(nrow(U))[-1]) m <- pmax(m, U[i, ])
  m
}

#' Standardisation of the access features over the training player-particle rows.
fit_access_scaler <- function(acc, ids) {
  a <- acc[episode_id %in% ids]
  s <- vapply(ACCESS_FEATURES, function(f) sd(a[[f]]), 0)
  list(mean = vapply(ACCESS_FEATURES, function(f) mean(a[[f]]), 0), sd = ifelse(s > 1e-8, s, 1))
}

#' Design of the given episodes: for each episode and particle, 12 rows (its ten players in a fixed order, then team_off
#' and team_def). Episodes without particles get one particle with zero access (flagged upstream).
#' @param features which player features enter (PLAYER_FEATURES and/or ACCESS_FEATURES); team terms always do.
#' @return list(M, rows = data.table(episode_id, k, outcome_id), w = weight per (episode, particle) block, blocks).
dyn_design <- function(sf, acc, shot, ids, sc, asc, features = c(PLAYER_FEATURES, ACCESS_FEATURES)) {
  ids <- sort(unique(ids))
  p <- sf[episode_id %in% ids]
  a <- acc[episode_id %in% ids]
  miss <- setdiff(ids, unique(a$episode_id))
  if (length(miss)) a <- rbind(a, p[episode_id %in% miss, .(episode_id, pid, k = 1L, access_margin = 0, best_access = 0)])
  a[, nk := uniqueN(k), by = episode_id]
  pl <- merge(a, p, by = c("episode_id", "pid"))
  setorder(pl, episode_id, k, -off, pid)
  blocks <- unique(pl[, .(episode_id, k, nk)])
  nb <- nrow(blocks)
  cols <- c(intersect(features, c(PLAYER_FEATURES, ACCESS_FEATURES)), TEAM_COLS)
  M <- matrix(0, 12L * nb, length(cols), dimnames = list(NULL, cols))
  prow <- rep((0:(nb - 1L)) * 12L, each = 10L) + rep(1:10, nb)
  if (nrow(pl) != 10L * nb) stop("every episode and particle needs exactly ten players")
  for (f in intersect(features, PLAYER_FEATURES)) M[prow, f] <- (pl[[f]] - sc$mean[[f]]) / sc$sd[[f]]
  for (f in intersect(features, ACCESS_FEATURES)) M[prow, f] <- (pl[[f]] - asc$mean[[f]]) / asc$sd[[f]]
  z <- (shot$shot_dist[match(blocks$episode_id, shot$episode_id)] - sc$shot_mean) / sc$shot_sd
  orow <- (0:(nb - 1L)) * 12L + 11L
  drow <- orow + 1L
  M[orow, "team_off"] <- 1
  M[drow, "team_def"] <- 1
  M[orow, "team_off_x_shot_dist"] <- z
  M[drow, "team_def_x_shot_dist"] <- z
  rows <- data.table(episode_id = rep(blocks$episode_id, each = 12L), k = rep(blocks$k, each = 12L), outcome_id = "")
  rows[prow, outcome_id := as.character(pl$pid)]
  rows[orow, outcome_id := "team_off"]
  rows[drow, outcome_id := "team_def"]
  list(M = M, rows = rows, w = 1 / blocks$nk, blocks = blocks)
}

#' Fit the particle-mixture conditional logit. `y`: row (1..12) of the credited outcome in each block.
fit_dyn <- function(des, y, lambda, maxit = 1000L) {
  M <- des$M
  nb <- nrow(des$blocks)
  ep <- match(des$blocks$episode_id, unique(des$blocks$episode_id))
  pen <- as.numeric(!colnames(M) %in% UNPENALISED)
  Y <- matrix(0, 12L, nb)
  Y[cbind(y, seq_len(nb))] <- 1
  # Negative log likelihood and its gradient over the twelve outcomes, for the optimiser.
  vg <- function(b) {
    U <- matrix(M %*% b, 12L)
    mx <- col_max(U)
    E <- exp(sweep(U, 2, mx))
    s <- colSums(E)
    P <- sweep(E, 2, s, `/`)
    py <- P[cbind(y, seq_len(nb))]
    num <- des$w * py
    den <- as.vector(rowsum(num, ep))
    r <- num / den[ep]
    list(f = -sum(log(den)) + lambda / 2 * sum(pen * b^2),
         g = -as.vector(crossprod(M, as.vector(sweep(Y - P, 2, r, `*`)))) + lambda * pen * b)
  }
  cache <- new.env()
  fn <- function(b) {
    cache$v <- vg(b)
    cache$b <- b
    cache$v$f
  }
  gr <- function(b) if (identical(cache$b, b)) cache$v$g else vg(b)$g
  o <- optim(rep(0, ncol(M)), fn, gr, method = "BFGS", control = list(maxit = maxit, reltol = 1e-12))
  list(beta = setNames(o$par, colnames(M)), lambda = lambda, converged = o$convergence == 0L, objective = o$value)
}

#' Episode probabilities: the weighted average over particles of each particle's softmax.
predict_dyn <- function(fit, des) {
  U <- matrix(des$M %*% fit$beta[colnames(des$M)], 12L)
  P <- exp(sweep(U, 2, col_max(U)))
  P <- sweep(P, 2, colSums(P), `/`)
  P <- sweep(P, 2, des$w, `*`)
  d <- cbind(des$rows, probability = as.vector(P))
  d[, .(probability = sum(probability)), by = .(episode_id, outcome_id)]
}

#' Row of each block's credited outcome.
dyn_labels <- function(des, labels) {
  r <- des$rows[, .(episode_id, k, outcome_id, row = rowid(episode_id, k))]
  r <- merge(r, labels[, .(episode_id, outcome_id)], by = c("episode_id", "outcome_id"))
  r <- r[match(paste(des$blocks$episode_id, des$blocks$k), paste(r$episode_id, r$k))]
  if (anyNA(r$row)) stop("credited outcome missing from a block")
  r$row
}

#' Replay interface: the dynamic model's distribution at `frame_idx` for one episode, from inputs built with
#' observations up to that frame only. `inputs_at(episode_id, frame_idx)` (supplied by the caller, and the only
#' place tracking is read) returns list(kind = "release" or "rim+0.2", sf, acc, shot, flags); `models` holds the
#' fitted model, scalers and version for each kind.
predict_rebound <- function(episode_id, frame_idx, inputs_at, models, history_only = TRUE) {
  if (!isTRUE(history_only)) stop("only causal replay (history_only = TRUE) is supported")
  inp <- inputs_at(episode_id, frame_idx)
  m <- models[[inp$kind]]
  des <- dyn_design(inp$sf, inp$acc, inp$shot, episode_id, m$scaler, m$access_scaler)
  p <- predict_dyn(m$fit, des)
  side <- inp$sf[, .(outcome_id = as.character(pid), off)]
  pl <- merge(p[!outcome_id %in% c("team_off", "team_def")], side, by = "outcome_id")
  list(players = pl[, .(player_id = outcome_id, off, p_player = probability)],
       non_player = p[outcome_id %in% c("team_off", "team_def"), .(outcome = outcome_id, probability)],
       p_offense = sum(pl[off == TRUE]$probability) + p[outcome_id == "team_off"]$probability,
       flags = inp$flags, model_version = m$version, frame_idx = frame_idx, time_kind = inp$kind)
}

#' Predictions for many episodes in chunks, so designs with thousands of particles stay small in memory.
predict_dyn_ids <- function(fit, sf, acc, shot, ids, sc, asc, features, chunk = 10L) {
  ids <- sort(unique(ids))
  rbindlist(lapply(split(ids, ceiling(seq_along(ids) / chunk)), function(b)
    predict_dyn(fit, dyn_design(sf, acc[episode_id %in% b], shot, b, sc, asc, features))))
}
