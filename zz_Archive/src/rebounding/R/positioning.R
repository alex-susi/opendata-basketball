# Step 10 of the rebounding manual: roles at release, role-level summaries, and player effects only where the data can
# identify them (empirical-Bayes shrinkage of role-adjusted values, split-by-game reliability, prior sensitivity).
# Settings: config/experiment.yaml (step10$roles, step10$effects). Requires geometry.R (RIM_X).

#' Role of each of the ten players at release: rim protector and shooter's defender on defence; shooter, offensive
#' player nearest the hoop and safeties (more than 30 ft from the hoop) on offence; everyone else "other".
assign_roles <- function(st, shooter_id) {
  d <- copy(st)[, dist_hoop := sqrt((x - RIM_X)^2 + y^2)]
  d[, role := fifelse(off, "offence: other", "defence: other")]
  dd <- d[off == FALSE]
  rp <- dd$pid[which.min(dd$dist_hoop)]
  d[pid == rp, role := "defence: rim protector"]
  sh <- d[pid == shooter_id]
  if (nrow(sh)) {
    dd <- d[off == FALSE & pid != rp]
    sd <- dd$pid[which.min(sqrt((dd$x - sh$x)^2 + (dd$y - sh$y)^2))]
    d[pid == sd, role := "defence: shooter's defender"]
    d[pid == shooter_id, role := "offence: shooter"]
  }
  oo <- d[off == TRUE & pid != shooter_id]
  d[pid == oo$pid[which.min(oo$dist_hoop)], role := "offence: nearest the hoop"]
  d[off == TRUE & role == "offence: other" & dist_hoop > 30, role := "offence: safety"]
  d[, .(pid, role)]
}

#' Mean of `value` by group with a game bootstrap interval (resampling games, pooling their rows).
group_means <- function(d, value, by, reps, seed, level = 0.95) {
  rbindlist(lapply(split(d, by = by), function(g) {
    pg <- g[, .(s = sum(get(value), na.rm = TRUE), n = sum(!is.na(get(value)))), by = game_id]
    set.seed(seed)
    b <- replicate(reps, {
      i <- sample.int(nrow(pg), replace = TRUE)
      sum(pg$s[i]) / sum(pg$n[i])
    })
    a <- (1 - level) / 2
    cbind(g[1, ..by], data.table(n = sum(pg$n), games = nrow(pg), mean = sum(pg$s) / sum(pg$n),
                                 lo = unname(quantile(b, a, na.rm = TRUE)), hi = unname(quantile(b, 1 - a, na.rm = TRUE))))
  }))
}

#' Empirical-Bayes shrinkage of player means of a role-adjusted value: tau^2 by the method of moments (between-player
#' variance of the means minus their average sampling variance), each mean shrunk by tau^2 / (tau^2 + s^2 / n).
eb_shrink <- function(p, tau_scale = 1) {
  s2 <- p$within_var / p$n
  tau2 <- max(0, var(p$mean) - mean(s2)) * tau_scale^2
  w <- if (tau2 > 0) tau2 / (tau2 + s2) else rep(0, nrow(p))
  cbind(p, tau2 = tau2, weight = w, shrunk = w * p$mean)
}
