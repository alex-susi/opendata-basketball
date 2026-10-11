# Turn counts into features: raw ratios, their sampling noise, and values shrunk toward the league mean.
#
# Each feature is modelled as raw_i = true_i + noise_i with Var(noise_i) = sigma2 / den_i, where den_i is the
# feature's own denominator (touches, chances, frames, attempts...). sigma2 is the variance one unit of the
# denominator contributes: for season features it is binomial, mu * (1 - mu); for tracked features it is
# measured from the difference between a player's odd and even chances. tau2 is the spread of true values
# between players, by the method of moments. A player's reliability is den / (den + sigma2 / tau2) and his
# shrunk value moves the raw ratio toward the league mean by one minus that.

MIN_PRIOR <- 1e-8

#' Wide count table (one row per player) from long counts.
wide_counts <- function(long) dcast(long[, .(value = sum(value)), by = .(pid, stat)], pid ~ stat, value.var = "value", fill = 0)

#' Numerator and denominator of every feature in `spec` for each row of a wide count table.
#' Counts a table does not have are zero.
feature_values <- function(spec, wide) {
  need <- unique(unlist(lapply(c(spec$num, spec$den), function(e) all.vars(parse(text = e)))))
  for (col in setdiff(need, names(wide))) set(wide, j = col, value = 0)
  rbindlist(lapply(seq_len(nrow(spec)), function(i) {
    data.table(pid = wide$pid, feature = spec$feature[i], num = as.numeric(eval(parse(text = spec$num[i]), wide)),
               den = as.numeric(eval(parse(text = spec$den[i]), wide)))
  }))
}

#' Per-unit noise variance from two halves of the same players.
#' E[(r0 - r1)^2] = sigma2 * (1 / n0 + 1 / n1), so each player's h * (r0 - r1)^2 estimates sigma2.
split_sigma2 <- function(n0, r0, n1, r1) {
  ok <- n0 > 0 & n1 > 0
  if (sum(ok) < 10L) return(NA_real_)
  mean((n0 * n1 / (n0 + n1) * (r0 - r1)^2)[ok])
}

#' League mean, spread of true values and prior strength m = sigma2 / tau2 (in denominator units).
prior_fit <- function(raw, den, sigma2) {
  ok <- den > 0 & !is.na(raw)
  raw <- raw[ok]
  den <- den[ok]
  m <- stats::median(den)
  for (iter in 1:50) {
    w <- den / (den + m)
    mu <- sum(w * raw) / sum(w)
    tau2 <- sum(w * ((raw - mu)^2 - sigma2 / den)) / sum(w)
    if (!is.finite(tau2) || tau2 <= MIN_PRIOR * max(sigma2, MIN_PRIOR)) return(list(mu = mu, tau2 = 0, m = Inf))
    m <- sigma2 / tau2
  }
  list(mu = mu, tau2 = tau2, m = m)
}

#' Estimate every feature in `spec` for the players in `total`.
#' @param total,half0,half1 Long (pid, feature, num, den); the halves are NULL for season features.
#' @return list(values = one row per player and feature, priors = one row per feature).
estimate_features <- function(spec, total, half0 = NULL, half1 = NULL) {
  out <- lapply(seq_len(nrow(spec)), function(i) {
    f <- spec$feature[i]
    v <- total[feature == f]
    v[, raw := fifelse(den > 0, num / den, NA_real_)]
    if (is.null(half0)) {
      mu0 <- sum(v$num) / sum(v$den)
      sigma2 <- mu0 * (1 - mu0)
    } else {
      a <- half0[feature == f][match(v$pid, pid)]
      b <- half1[feature == f][match(v$pid, pid)]
      v[, c("den0", "raw0", "den1", "raw1") := .(fcoalesce(a$den, 0), a$num / a$den, fcoalesce(b$den, 0), b$num / b$den)]
      sigma2 <- split_sigma2(v$den0, v$raw0, v$den1, v$raw1)
    }
    p <- prior_fit(v$raw, v$den, sigma2)
    v[, reliability := fifelse(den > 0, den / (den + p$m), 0)]
    v[, shrunk := p$mu + reliability * (fcoalesce(raw, p$mu) - p$mu)]
    v[, noise_sd := sqrt(sigma2 / den)]
    s <- spec$scale[i]
    for (col in intersect(c("raw", "shrunk", "noise_sd", "raw0", "raw1"), names(v))) set(v, j = col, value = v[[col]] * s)
    list(values = v, prior = data.table(feature = f, league_mean = p$mu * s, unit_sd = sqrt(sigma2) * s, between_sd = sqrt(p$tau2) * s,
                                        prior_strength = p$m))
  })
  list(values = rbindlist(lapply(out, `[[`, "values"), fill = TRUE), priors = rbindlist(lapply(out, `[[`, "prior")))
}

#' Correlation between two measurements of a feature, and its Spearman-Brown step-up to both combined.
pair_cor <- function(x, y) {
  ok <- !is.na(x) & !is.na(y)
  if (sum(ok) < 8L || stats::sd(x[ok]) == 0 || stats::sd(y[ok]) == 0) return(c(n = sum(ok), r = NA_real_, stepped = NA_real_))
  r <- stats::cor(x[ok], y[ok])
  c(n = sum(ok), r = r, stepped = 2 * r / (1 + r))
}

#' Assignment-time-weighted profile of the men each defender guards, as counts for spec.R's d_guard_* features.
#' @param pairs Long (def, off, half, game_id, frames) with canonical ids.
#' @param profile data.table(pid, touch, three, screener, handler): the offensive players' own (shrunk) values.
guard_counts <- function(pairs, profile) {
  p <- merge(pairs, profile, by.x = "off", by.y = "pid")
  long <- melt(p[, .(pid = def, half, game_id, g_frames = as.numeric(frames), g_touch = frames * touch, g_three = frames * three,
                     g_screener = frames * screener, g_handler = frames * handler)],
               id.vars = c("pid", "half", "game_id"), variable.name = "stat", variable.factor = FALSE)
  long[, .(value = sum(value)), by = .(pid, half, game_id, stat)]
}
