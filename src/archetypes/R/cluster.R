# Fit playstyle clusters on the well-sampled players and give every player a probability of each cluster.
#
# Features are put on a common scale: (value - league mean) / between-player sd of true values. On that
# scale a shrunk value has variance equal to its reliability, so noisy features weigh less by construction.
# Reduce: principal components of the fit players' shrunk values. The number kept is the number of leading
#         components whose variance beats the same component of column-shuffled data (parallel analysis).
# Fit:    a Gaussian mixture on those components (mclust), model type and number of clusters by BIC unless given.
# Assign: the mixture is carried back to feature space (component covariance = loadings * cluster covariance
#         * loadings' + what the components leave unexplained). A player's raw values are then compared with
#         each cluster, adding his own sampling noise to the covariance and leaving out features he has no
#         data for. Thin samples and untracked players therefore get flatter probabilities, not confident ones.

suppressPackageStartupMessages(library(mclust))

# Spherical (EII, VII), diagonal (EEI, VEI, VVI) and full-covariance (VEV, VVV) mixtures.
MIXTURE_MODELS <- c("EII", "VII", "EEI", "VEI", "VVI", "VEV", "VVV")
PERMUTATIONS <- 500L
PERMUTATION_LEVEL <- 0.95

#' Player-by-feature matrices on the common scale.
#' @return list(shrunk, raw, noise): matrices with players in rows (named by pid); noise is a variance.
scaled_matrices <- function(values, dictionary, features, pids) {
  v <- values[feature %in% features & pid %in% pids]
  d <- dictionary[match(v$feature, feature)]
  v[, c("z_shrunk", "z_raw", "z_noise") := .((shrunk - d$league_mean) / d$between_sd, (raw - d$league_mean) / d$between_sd,
                                              (noise_sd / d$between_sd)^2)]
  wide <- function(col) {
    m <- dcast(v, pid ~ feature, value.var = col)
    out <- as.matrix(m[match(pids, pid), ..features])
    rownames(out) <- pids
    out
  }
  out <- list(shrunk = wide("z_shrunk"), raw = wide("z_raw"), noise = wide("z_noise"))
  out$raw[!is.finite(out$noise)] <- NA
  out
}

#' Principal components of Z with a parallel analysis: each component's variance against the 95th percentile
#' of the same component when every column is shuffled independently (which removes all correlation).
#' @return list(pca, table = variance, share and threshold per component, keep = number of components to keep).
principal_components <- function(Z) {
  pca <- stats::prcomp(Z, center = TRUE, scale. = FALSE)
  variance <- pca$sdev^2
  shuffled <- replicate(PERMUTATIONS, stats::prcomp(apply(Z, 2, sample), center = TRUE, scale. = FALSE)$sdev^2)
  threshold <- apply(shuffled, 1, stats::quantile, PERMUTATION_LEVEL)
  beats <- variance > threshold
  list(pca = pca, keep = if (all(beats)) length(beats) else which(!beats)[1] - 1L,
       table = data.table(component = seq_along(variance), variance = variance, share = variance / sum(variance),
                          cumulative = cumsum(variance) / sum(variance), shuffled_95 = threshold))
}

#' Fit the mixture on the first `q` principal components of the fit players' shrunk values.
#' @param G Candidate numbers of clusters. @param models Candidate mclust model types.
#' @return list(G, model, bic, centre, loadings, means, sigma, weights, residual, pcs, features, labels).
fit_clusters <- function(Z, G, q, models = MIXTURE_MODELS, pca = stats::prcomp(Z, center = TRUE, scale. = FALSE)) {
  scores <- pca$x[, seq_len(q), drop = FALSE]
  bic <- mclust::mclustBIC(scores, G = G, modelNames = models, verbose = FALSE)
  fit <- mclust::Mclust(scores, x = bic, verbose = FALSE)
  if (is.null(fit)) stop("No mixture could be fitted")
  W <- pca$rotation[, seq_len(q), drop = FALSE]
  list(G = fit$G, model = fit$modelName, bic = bic, centre = pca$center, loadings = W, means = t(fit$parameters$mean),
       sigma = array(fit$parameters$variance$sigma, c(q, q, fit$G)), weights = fit$parameters$pro,
       residual = pmax(colMeans((sweep(Z, 2, pca$center) - scores %*% t(W))^2), 1e-6), pcs = q, features = colnames(Z),
       labels = fit$classification)
}

#' Probability of each cluster for every row of `raw`, given each value's own noise variance.
assign_clusters <- function(fit, raw, noise) {
  mean_k <- lapply(seq_len(fit$G), function(k) fit$centre + drop(fit$loadings %*% fit$means[k, ]))
  cov_k <- lapply(seq_len(fit$G), function(k) fit$loadings %*% fit$sigma[, , k] %*% t(fit$loadings) + diag(fit$residual))
  logp <- t(vapply(seq_len(nrow(raw)), function(i) {
    obs <- which(!is.na(raw[i, ]))
    if (!length(obs)) return(log(fit$weights))
    vapply(seq_len(fit$G), function(k) {
      R <- chol(cov_k[[k]][obs, obs, drop = FALSE] + diag(noise[i, obs], length(obs)))
      resid <- backsolve(R, raw[i, obs] - mean_k[[k]][obs], transpose = TRUE)
      log(fit$weights[k]) - sum(log(diag(R))) - 0.5 * sum(resid^2)
    }, 0)
  }, numeric(fit$G)))
  p <- exp(logp - apply(logp, 1, max))
  p <- p / rowSums(p)
  dimnames(p) <- list(rownames(raw), paste0("p_", seq_len(fit$G)))
  p
}

#' How well a choice of model and cluster count survives resampling the fit players: refit on bootstrap
#' samples, reassign the original players, and compare with their original clusters.
#' @return c(median adjusted Rand index (1 = identical), share of resamples where the model could not be fitted).
cluster_stability <- function(M, G, q, model, reps = 40L) {
  base <- max.col(assign_clusters(fit_clusters(M$shrunk, G, q, model), M$raw, M$noise), ties.method = "first")
  ari <- vapply(seq_len(reps), function(b) {
    i <- sample(nrow(M$shrunk), replace = TRUE)
    f <- tryCatch(fit_clusters(M$shrunk[i, , drop = FALSE], G, q, model), error = function(e) NULL)
    if (is.null(f)) return(NA_real_)
    mclust::adjustedRandIndex(base, max.col(assign_clusters(f, M$raw, M$noise), ties.method = "first"))
  }, 0)
  c(stability = stats::median(ari, na.rm = TRUE), failed = mean(is.na(ari)))
}

#' What sets each cluster apart: probability-weighted mean of the fit players' shrunk values, per feature.
cluster_profiles <- function(P, Z, values, dictionary) {
  rbindlist(lapply(seq_len(ncol(P)), function(k) {
    w <- P[, k]
    data.table(cluster = k, feature = colnames(Z), z = colSums(w * Z) / sum(w),
               value = vapply(colnames(Z), function(f) {
                 v <- values[feature == f][match(rownames(Z), pid), shrunk]
                 sum(w * v) / sum(w)
               }, 0), league_mean = dictionary$league_mean[match(colnames(Z), dictionary$feature)])
  }))
}
