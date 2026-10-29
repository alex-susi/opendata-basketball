# Late forecasts: the collection model for the moments after the ball reaches the rim.
#
# The base model (opportunity.R) is fitted at release and just before the rim; the site used to reuse the rim fit
# at every later moment, where it is too flat (it learned how little access predicts while the bounce is still
# unknown). The late model is fitted on scenes taken at fixed times after the ball reaches the rim (LATE_TAU),
# pooled into one fit whose base score and access weight change linearly with tau (seconds since the rim), plus
# an arrival-margin term: how much later than the fastest other player each one could reach the ball. The
# reaction time and information policy are chosen again for these moments. Requires opportunity.R and
# cpp/opportunity.cpp (arrival_margin, crt_objective, crt_predict).

LATE_TAU <- c(0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.4)   # s after the ball reaches the rim
MARGIN_CAP <- 1                                  # s: arrival margins are capped to [-1, 1]
THETA_LATE <- c(THETA, "b0_t", "b_acc_t", "b_first", "b_first_t")
LATE_GRID <- CJ(policy = 0:2, react = c(0.05, 0.15, 0.25, 0.35, 0.5))   # policy 0: run at the ball once the bounce is seen
LATE_GRID_SCENES <- 700L                         # training scenes used to choose the access settings
LATE_HEIGHT <- CJ(z_reach = c(9.5, 10.5, 11.5), z_scale = c(0.2, 0.35, 0.7))   # ft: reach height and fall-off above it

#' When the ball reached the rim, as known at `t_now`: the first frame, below an earlier high point (the ball is
#' coming down), inside the audit's rim or backboard contact zones, or below 6 ft (an airball). Frames between
#' keyframes are the vendor's interpolation toward the next keyframe, so only frames up to the last keyframe seen
#' by t_now are used: the contact is known once the keyframe after it has arrived.
#' @return c(contact, seen): seconds after release of the contact and of the moment it became known, or NAs.
#'   A sequential rule, so a later t_now never changes an answer already given (no lookahead).
contact_seen <- function(b, t_now = Inf) {
  none <- c(contact = NA_real_, seen = NA_real_)
  w <- b$ball[t > -1e-9 & !is.na(x)]
  keys <- w$t[w$key & w$t <= t_now + 1e-9]
  if (length(keys) < 2L) return(none)
  w <- w[t > 1e-9 & t <= max(keys) + 1e-9]
  higher_before <- c(FALSE, w$z[-1] < cummax(w$z)[-nrow(w)] - 0.1)
  dh <- sqrt(w$x^2 + w$y^2)
  board <- w$x >= (BOARD_X - RIM_X) - BALL_R - CONTACT_PAD & abs(w$y) <= BOARD_HALF_W + CONTACT_PAD &
    w$z >= BOARD_Z0 - CONTACT_PAD & w$z <= BOARD_Z1 + CONTACT_PAD
  rim <- dh <= RIM_R + BALL_R + CONTACT_PAD + 0.6 & w$z >= RIM_Z - 1.2 & w$z <= RIM_Z + 1.5
  first <- which(higher_before & (rim | board | w$z < 6))[1]
  if (is.na(first)) return(none)
  c(contact = w$t[first], seen = keys[keys >= w$t[first] - 1e-9][1])
}

#' Scenes of every bundle at each LATE_TAU after its contact_seen() time, with one flight fit, cached at `path`.
#' A scene exists only once the contact is known (its keyframe has arrived) and while the ball is still loose
#' (build_scene() drops checkpoints at or after the rebound). Each scene carries tau and the contact time.
build_late_scenes <- function(bundles, fit, lib, path, force = FALSE) {
  if (file.exists(path) && !force) return(readRDS(path))
  out <- unlist(lapply(seq_along(bundles), function(i) {
    b <- bundles[[i]]
    cs <- contact_seen(b)
    if (is.na(cs[1])) return(list())
    a <- cs[[1]]
    lapply(seq_along(LATE_TAU), function(k) {
      if (a + LATE_TAU[k] < cs[[2]] - 1e-9) return(NULL)
      sc <- build_scene(b, a + LATE_TAU[k], fit, lib, seed = 10L * i + k)
      if (!length(sc)) return(NULL)
      sc$tau <- LATE_TAU[k]; sc$anchor <- a; sc$bundle <- i
      sc$bx <- unname(sc$bx); sc$by <- unname(sc$by); sc$bz <- unname(sc$bz)
      sc
    })
  }), recursive = FALSE)
  out <- Filter(Negate(is.null), out)
  saveRDS(out, path)
  out
}

acc_par <- function(acc) c(acc$react, acc$vmax, acc$sigma, acc$z_reach, acc$z_scale, acc$info_lag)

#' Arrival margins of a scene for one access-parameter set (same layout as scene_access()). With acc$gate the
#' margins count only while the ball is low enough to grab (scaled by the access height gate).
scene_margin <- function(sc, acc) {
  arrival_margin(sc$bx, sc$by, sc$bz, as.matrix(sc$pl[, .(x, y, vx, vy)]), sc$t_info, sc$target, acc_par(acc), acc$policy,
                 MARGIN_CAP, isTRUE(acc$gate))
}

#' Stack late scenes: stack_scenes() plus the arrival margins D, each scene's tau and its miss's weight (one over
#' the number of that miss's scenes in the stack, so every miss counts once when weights are used).
stack_late <- function(scenes, acc, players = character(0)) {
  st <- stack_scenes(scenes, acc, players, TRUE)
  st$D <- unlist(lapply(scenes, scene_margin, acc = acc), use.names = FALSE)
  st$tau <- vapply(scenes, `[[`, 0, "tau")
  ids <- vapply(scenes, `[[`, "", "id")
  st$w <- as.numeric(1 / table(ids)[ids])
  st$ids <- ids
  st
}

#' Fit the late model by penalised maximum likelihood (BFGS, analytic gradient); `free` says which of THETA_LATE
#' are estimated, the others stay at `start` (zero by default for the late terms). With sd_u > 0 the stack's
#' players get collection effects with that prior sd; `weighted` counts every miss once (see stack_late()).
fit_late <- function(st, free = rep(TRUE, 11), start = NULL, use = seq_len(st$dims[1]) - 1L, ridge = 1e-3,
                     sd_u = 0, weighted = FALSE) {
  M <- if (sd_u > 0) st$dims[5] else 0L
  par0 <- c(if (is.null(start)) c(-6, 0.5, 0, 1, -6, -6, 0.6, 0, 0, 0, 0) else unname(start), rep(0, M))
  free_all <- c(free, rep(TRUE, M))
  dims <- st$dims; dims[5] <- M
  pidx <- if (M) st$pidx else rep(-1L, length(st$pidx))
  w <- if (weighted) st$w else numeric(0)
  f <- function(p) {
    p[!free_all] <- par0[!free_all]
    crt_objective(p, st$A, st$D, st$tau, st$out_step, st$Z, pidx, st$y, dims, as.integer(use), free_all, sd_u, ridge, w)
  }
  cache <- new.env()
  val <- function(p) { r <- f(p); cache$g <- r$gradient; cache$p <- p; r$value }
  grd <- function(p) { if (!identical(cache$p, p)) f(p)$gradient else cache$g }
  o <- optim(par0, val, grd, method = "BFGS", control = list(maxit = 500, reltol = 1e-10))
  p <- o$par
  p[!free_all] <- par0[!free_all]
  list(theta = setNames(p[1:11], THETA_LATE), u = setNames(p[-(1:11)], if (M) st$players else character(0)),
       value = o$value, convergence = o$convergence, sd_u = sd_u)
}

#' Outcome probabilities (scenes x 13) under a late fit. Effects apply to the fit's players that are in the
#' stack's player list; everyone else gets none.
predict_late <- function(st, fit) {
  dims <- st$dims
  u <- if (length(fit$u)) unname(fit$u[st$players]) else numeric(0)
  if (length(u)) u[is.na(u)] <- 0
  dims[5] <- length(u)
  pidx <- if (length(u)) st$pidx else rep(-1L, length(st$pidx))
  P <- crt_predict(c(unname(fit$theta), u), st$A, st$D, st$tau, st$out_step, st$Z, pidx, st$y, dims)
  colnames(P) <- OUTCOMES
  P
}

#' A fixed subsample of the training scenes for choosing access settings.
grid_sample <- function(scenes, seed) {
  set.seed(seed)
  scenes[sort(sample(length(scenes), min(length(scenes), LATE_GRID_SCENES)))]
}

#' Choose the access settings for late scenes: every LATE_GRID setting, the full late model fitted on a fixed
#' subsample of the training scenes, the one with the best training likelihood kept.
choose_late_access <- function(scenes, base_acc, seed = 1L) {
  sub <- grid_sample(scenes, seed)
  grid <- copy(LATE_GRID)
  grid[, nll := mapply(function(pol, re) {
    acc <- modifyList(base_acc, list(policy = pol, react = re))
    fit_late(stack_late(sub, acc))$value
  }, policy, react)]
  # settings that fit equally well (a reaction time shorter than the time to see the bounce changes nothing) go to
  # the longest such reaction time, so the reported setting is the one that binds
  best <- grid[nll <= min(nll) + 1e-6][.N]
  list(acc = modifyList(base_acc, as.list(best[, .(policy, react)])), grid = grid)
}

#' Choose the reach height and how sharply access falls off above it (LATE_HEIGHT), with the arrival margin
#' counting only while the ball is low enough to grab; same subsample and rule as choose_late_access().
choose_late_height <- function(scenes, acc, seed = 1L) {
  sub <- grid_sample(scenes, seed)
  grid <- copy(LATE_HEIGHT)
  grid[, nll := mapply(function(zr, zs) {
    fit_late(stack_late(sub, modifyList(acc, list(z_reach = zr, z_scale = zs, gate = TRUE))))$value
  }, z_reach, z_scale)]
  best <- grid[which.min(nll)]
  list(acc = modifyList(acc, list(z_reach = best$z_reach, z_scale = best$z_scale, gate = TRUE)), grid = grid)
}

#' The ladder of late models on one training set: the base model refitted on late scenes, plus time-varying
#' weights, plus the arrival margin (the full model).
fit_late_ladder <- function(st) {
  m1 <- fit_late(st, free = c(rep(TRUE, 7), rep(FALSE, 4)))
  m2 <- fit_late(st, free = c(rep(TRUE, 9), FALSE, FALSE), start = m1$theta)
  m3 <- fit_late(st, start = m2$theta)
  list(late_refit = m1, late_time = m2, late_full = m3)
}

#' Collection effects on top of a fitted late model: its theta held fixed, one effect per player with prior sd
#' `sd_u`, every miss counted once (its scenes share one outcome, so they are not independent evidence).
fit_late_effects <- function(st, base, sd_u = 0.3) {
  fit_late(st, free = rep(FALSE, 11), start = base$theta, sd_u = sd_u, weighted = TRUE)
}

#' Parameter recovery for late collection effects: outcomes simulated from `base` plus known effects (one outcome
#' per miss, drawn from its earliest scene and shared by all its scenes), effects refitted, true and recovered
#' compared for players on court in at least `min_misses` misses.
late_recovery <- function(st, base, sd_true = 0.3, reps = 3, min_misses = 20) {
  players <- st$players
  first <- !duplicated(st$ids)
  misses_on <- table(unlist(lapply(which(first), function(e) players[st$pidx[(e - 1) * 10 + 1:10] + 1L])))
  n_on <- as.numeric(misses_on[players]); n_on[is.na(n_on)] <- 0
  rbindlist(lapply(seq_len(reps), function(r) {
    set.seed(200 + r)
    u_true <- setNames(rnorm(length(players), 0, sd_true), players)
    P <- predict_late(st, list(theta = base$theta, u = u_true))
    y_miss <- vapply(which(first), function(e) sample.int(12, 1, prob = P[e, 1:12] / sum(P[e, 1:12])), 0L)
    st2 <- st
    st2$y <- as.integer(y_miss[match(st$ids, st$ids[first])] - 1L)
    f <- fit_late_effects(st2, base, sd_true)
    keep <- n_on >= min_misses
    data.table(sd_true = sd_true, rep = r, cor_all = cor(u_true, f$u), cor_20plus = cor(u_true[keep], f$u[keep]),
               players_20plus = sum(keep), shrink_sd = sd(f$u))
  }))
}

#' Late forecast time of a scene or a site forecast: seconds since contact_seen(), capped at the last fitted tau.
late_tau <- function(t, anchor) pmin(max(LATE_TAU), pmax(0, t - anchor))
