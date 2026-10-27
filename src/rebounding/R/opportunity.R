# Physical opportunity and collection (framework sections 7, 9 geometry, 10 and 13).
#
# A scene is one episode at one forecast checkpoint: the ten players as they are then, and P simulated
# no-touch ball paths (particle filter posterior, miss scenarios only) mapped to the player frame. From a
# scene the C++ code computes each player's access along every path and the competing-risks probabilities
# of every outcome: one of the ten players collects, a team award to either side, or unresolved by the
# horizon. Requires geometry.R, bundle.R, flight.R and cpp/opportunity.cpp.

STEP <- 0.08              # s between path steps
N_STEPS <- 40L            # horizon 3.2 s
P_SCENE <- 48L            # particles kept per scene
CONTROL_Z <- 9            # ft: the first point of a path at or below this height after its contact is a "target"
CORRIDOR <- 1.25          # ft: sd of the corridor around an opponent's route in which a body obstructs it
CLOSE <- 2.5              # ft: separation within which an obstruction is at full strength
OUTCOMES <- c(paste0("p", 1:10), "team_off", "team_def", "unresolved")
THETA <- c("b0", "b_def", "b_obs", "b_acc", "g_off", "g_def", "g_side")

load_opportunity_cpp <- function(here, cache) {
  Rcpp::sourceCpp(file.path(here, "cpp", "opportunity.cpp"), cacheDir = file.path(cache, "cpp"), env = globalenv())
}

#' Seconds after release of the two forecast checkpoints used for opportunity: release itself, and just
#' before the ball reaches the rim (the inferred contact, or the shot's end frame when no contact was found).
rim_time <- function(b) {
  tm <- bundle_times(b)
  if (!is.na(tm$contact)) tm$contact else tm$end
}

#' The ten players at a frame, offense first, each side in player-id order. NULL unless five a side.
players_at <- function(b, at) {
  pl <- b$players[frame == at]
  if (sum(pl$off) != 5L || sum(!pl$off) != 5L) return(NULL)
  pl[order(-off, pid)]
}

#' Obstruction of each player's route to the reachable ball by each opponent, averaged over target points:
#' O[b, o] is how much b stands in o's way (0 to 1). Same-team entries are zero.
obstruction_matrix <- function(px, py, off, tx, ty) {
  n <- length(px)
  O <- matrix(0, n, n)
  for (o in seq_len(n)) for (bb in seq_len(n)) {
    if (off[o] == off[bb]) next
    gap <- sqrt((px[bb] - px[o])^2 + (py[bb] - py[o])^2)
    if (gap > 8) next
    ux <- tx - px[o]; uy <- ty - py[o]
    L <- sqrt(ux^2 + uy^2)
    ok <- L > 1
    ux <- ux / pmax(L, 1e-9); uy <- uy / pmax(L, 1e-9)
    lam <- (px[bb] - px[o]) * ux + (py[bb] - py[o]) * uy
    perp <- abs(-(px[bb] - px[o]) * uy + (py[bb] - py[o]) * ux)
    inside <- ok & lam > 0 & lam < L
    O[bb, o] <- mean(inside * exp(-perp^2 / (2 * CORRIDOR^2))) * exp(-max(0, gap - CLOSE) / 1.5)
  }
  O
}

#' Build one scene. `fit` is a flight fit (run_flight.R) and `lib` its launch library.
#' @return list(id, game_id, t, pl (10 players), bx/by/bz (P x K), out_step, t_info, target, tx/ty (target
#'   points), y (recorded outcome index, 1-based), O (obstruction matrix)) or NULL with a reason attribute.
build_scene <- function(b, t_chk, fit, lib, seed, landing = FALSE) {
  s <- b$shot
  tm <- bundle_times(b)
  if (!is.na(tm$rebound) && tm$rebound <= t_chk + 1e-9) return(structure(list(), reason = "rebound before checkpoint"))
  frame <- s$f0 + round(t_chk * FPS)
  pl <- players_at(b, frame)
  if (is.null(pl)) return(structure(list(), reason = "not five players a side"))
  y <- if (s$grabbed %in% TRUE) match(s$rcanon, pl$canon) else if (s$defensive %in% TRUE) 12L else 11L
  if (is.na(y)) return(structure(list(), reason = "rebounder not on court"))
  st <- pf_at(b, t_chk, fit$phys, fit$sig, lib, seed = seed)
  fp <- forecast_paths(st$S, STEP * seq_len(N_STEPS), fit$phys, seed = seed + 17L)
  keep <- seq_len(P_SCENE)
  bx <- fp$x[keep, , drop = FALSE]; by <- fp$y[keep, , drop = FALSE]; bz <- fp$z[keep, , drop = FALSE]
  m <- to_player_frame(bx, by, bz, b$hoop)
  bx[] <- m$x; by[] <- m$y
  t_out <- fp$t_out[keep]
  out_step <- ifelse(is.na(t_out), -1L, pmin(N_STEPS, ceiling(t_out / STEP)) - 1L)
  tc <- fp$t_contact[keep]
  t_info <- ifelse(is.na(tc), 0, pmax(0, tc))
  # target: the first point at or below CONTROL_Z after the path's contact (or its last point)
  tk <- STEP * seq_len(N_STEPS)
  first <- vapply(seq_len(P_SCENE), function(p) {
    k <- which(bz[p, ] <= CONTROL_Z & tk >= t_info[p])
    if (length(k)) k[1] else N_STEPS
  }, 0L)
  tx <- bx[cbind(seq_len(P_SCENE), first)]
  ty <- by[cbind(seq_len(P_SCENE), first)]
  sc <- list(id = b$id, game_id = b$game_id, t = t_chk, frame = frame, pl = pl, bx = bx, by = by, bz = bz,
             out_step = as.integer(out_step), t_info = t_info, target = c(mean(tx), mean(ty)), tx = tx, ty = ty,
             y = as.integer(y), O = obstruction_cpp(pl$x, pl$y, pl$off, tx, ty, CORRIDOR, CLOSE), made_share = fp$made_share)
  if (landing) {
    # where the ball would first reach the floor if nobody touched it (miss scenarios only)
    L <- first_landing(fp$S, 5, fit$phys, seed + 29L)
    L <- L[!is.na(L[, 1]) & L[, 4] == 0, , drop = FALSE]
    m <- to_player_frame(L[, 2], L[, 3], fit$phys$z_floor, b$hoop)
    sc$land <- cbind(x = m$x, y = m$y, t = L[, 1])
  }
  sc
}

#' Scenes of every bundle at each named checkpoint (a function of the bundle giving seconds after release)
#' with one flight fit, cached at `path`.
build_scenes <- function(bundles, checkpoints, fit, lib, path, force = FALSE) {
  if (file.exists(path) && !force) return(readRDS(path))
  out <- lapply(checkpoints, function(at) lapply(seq_along(bundles), function(i) build_scene(bundles[[i]], at(bundles[[i]]), fit, lib, seed = i)))
  saveRDS(out, path)
  out
}

#' The two opportunity checkpoints: release, and just before the ball reaches the rim.
OPP_CHECKPOINTS <- list(release = function(b) 0, rim = function(b) rim_time(b) - 0.04)

#' Access array of a scene for one access-parameter set.
scene_access <- function(sc, acc, pl = sc$pl) {
  access_array(sc$bx, sc$by, sc$bz, as.matrix(pl[, .(x, y, vx, vy)]), sc$t_info, sc$target,
               c(acc$react, acc$vmax, acc$sigma, acc$z_reach, acc$z_scale, acc$info_lag), STEP, acc$policy)
}

#' Stack scenes into the arrays the C++ likelihood reads.
#' @param players Character vector of canonical ids with an effect slot (others get none).
stack_scenes <- function(scenes, acc, players, obstruction = TRUE) {
  E <- length(scenes)
  A <- unlist(lapply(scenes, scene_access, acc = acc), use.names = FALSE)
  out_step <- unlist(lapply(scenes, `[[`, "out_step"), use.names = FALSE)
  Z <- unlist(lapply(scenes, function(sc) {
    obs <- if (obstruction) apply(sc$O, 2, max) else rep(0, 10)
    as.vector(rbind(as.numeric(!sc$pl$off), obs))
  }), use.names = FALSE)
  pidx <- unlist(lapply(scenes, function(sc) match(as.character(sc$pl$canon), players) - 1L), use.names = FALSE)
  pidx[is.na(pidx)] <- -1L
  y <- vapply(scenes, function(sc) sc$y - 1L, 0L)
  list(A = A, out_step = as.integer(out_step), Z = Z, pidx = as.integer(pidx), y = as.integer(y),
       dims = as.integer(c(E, P_SCENE, N_STEPS, 10L, length(players))), players = players)
}

#' Fit the competing-risks model by penalised maximum likelihood (BFGS, analytic gradient).
#' @param free_theta Which of THETA are estimated (others stay at `start`).
#' @param sd_u Prior sd of player collection effects; 0 keeps them at zero.
fit_cr <- function(st, use = seq_len(st$dims[1]) - 1L, free_theta = rep(TRUE, 7), sd_u = 0, start = NULL, ridge = 1e-3) {
  M <- st$dims[5]
  par0 <- c(if (is.null(start)) c(-6, 0.5, 0, 1, -6, -6, 0.6) else start[1:7], rep(0, M))
  free <- c(free_theta, rep(sd_u > 0, M))
  f <- function(p) {
    p[!free] <- par0[!free]
    cr_objective(p, st$A, st$out_step, st$Z, st$pidx, st$y, st$dims, as.integer(use), free, sd_u, ridge)
  }
  cache <- new.env()
  val <- function(p) { r <- f(p); cache$g <- r$gradient; cache$p <- p; r$value }
  grd <- function(p) { if (!identical(cache$p, p)) f(p)$gradient else cache$g }
  o <- optim(par0, val, grd, method = "BFGS", control = list(maxit = 500, reltol = 1e-10))
  p <- o$par
  p[!free] <- par0[!free]
  list(theta = setNames(p[1:7], THETA), u = setNames(p[-(1:7)], st$players), value = o$value, convergence = o$convergence,
       sd_u = sd_u)
}

#' Outcome probabilities (episodes x 13: ten players, team awards, unresolved) under a fitted model.
predict_cr <- function(st, fit) {
  P <- cr_predict(c(fit$theta, fit$u), st$A, st$out_step, st$Z, st$pidx, st$y, st$dims)
  colnames(P) <- OUTCOMES
  P
}

#' Scores of outcome probabilities against recorded outcomes. Unresolved mass is reported and removed
#' (probabilities renormalised over the twelve outcomes) before scoring.
score_outcomes <- function(P, y, off_first = TRUE) {
  unres <- P[, 13]
  Q <- P[, 1:12, drop = FALSE] / pmax(1e-12, 1 - unres)
  py <- Q[cbind(seq_len(nrow(Q)), y)]
  p_off <- rowSums(Q[, c(1:5, 11), drop = FALSE])
  off <- y %in% c(1:5, 11)
  data.table(ll = -log(pmax(py, 1e-12)), p_off = p_off, off = off, ll_team = -(off * log(pmax(p_off, 1e-12)) + (!off) * log(pmax(1 - p_off, 1e-12))),
             brier_team = (p_off - off)^2, brier = rowSums((Q - outer(y, 1:12, `==`))^2), unresolved = unres,
             p_top = apply(Q[, 1:10, drop = FALSE], 1, max))
}

# ---- comparison models ------------------------------------------------------------------------------

#' Team prior: shares of offensive player, defensive player and the two team awards in training; each
#' side's player share split evenly over its five players.
prior_probs <- function(y_train, n) {
  r <- c(off = mean(y_train <= 5), def = mean(y_train >= 6 & y_train <= 10), to = mean(y_train == 11), td = mean(y_train == 12))
  matrix(c(rep(r["off"] / 5, 5), rep(r["def"] / 5, 5), r["to"], r["td"], 0), n, 13, byrow = TRUE)
}

#' Grouped softmax over the ten players on scene features, times the training share of player rebounds;
#' team awards at their training shares. `feats(sc)` returns a 10 x m matrix.
fit_softmax <- function(scenes, feats, y_train) {
  X <- lapply(scenes, feats)
  yy <- vapply(scenes, `[[`, 0L, "y")
  pl <- yy <= 10
  nll <- function(b) {
    -sum(vapply(which(pl), function(e) {
      s <- X[[e]] %*% b
      s[yy[e]] - (max(s) + log(sum(exp(s - max(s)))))
    }, 0)) + 1e-3 * sum(b^2)
  }
  o <- optim(rep(0, ncol(X[[1]])), nll, method = "BFGS")
  list(beta = o$par, feats = feats, team = c(mean(y_train == 11), mean(y_train == 12)))
}

predict_softmax <- function(fit, scenes) {
  t(vapply(scenes, function(sc) {
    s <- fit$feats(sc) %*% fit$beta
    p <- exp(s - max(s)); p <- p / sum(p)
    c(p * (1 - sum(fit$team)), fit$team, 0)
  }, numeric(13)))
}

#' Features of the "nearest to the forecast" benchmark: distance to the forecast target and side.
feats_nearest <- function(sc) {
  d <- sqrt((sc$pl$x - sc$target[1])^2 + (sc$pl$y - sc$target[2])^2)
  cbind(-d / 10, as.numeric(!sc$pl$off))
}

#' Features of the direct geometry classifier: distances to the hoop and to the forecast target, rank of
#' that distance among the ten, speed toward the target, side, and the obstruction received.
feats_geometry <- function(sc) {
  p <- sc$pl
  dh <- sqrt((p$x - RIM_X)^2 + p$y^2)
  dt <- sqrt((p$x - sc$target[1])^2 + (p$y - sc$target[2])^2)
  toward <- -((sc$target[1] - p$x) * p$vx + (sc$target[2] - p$y) * p$vy) / pmax(dt, 0.5)
  cbind(-dt / 10, -dh / 10, -(rank(dt) - 1) / 9, -toward / 10, as.numeric(!p$off), apply(sc$O, 2, max),
        pmin(dt, 6) / 6 * as.numeric(!p$off))
}

#' Empirical landing density with Voronoi cells (Maheswaran et al. 2014): where training rebounds were
#' secured, by shot range, as a kernel density on a 1 ft grid; each player gets the density of the cells
#' nearer to him than to anyone else.
fit_voronoi <- function(train_eps) {
  pts <- train_eps[grabbed == TRUE & !is.na(rx_pl)]
  grid <- CJ(x = seq(RIM_X - 34.5, COURT_HALF_L - 0.5, by = 1), y = seq(-COURT_HALF_W + 0.5, COURT_HALF_W - 0.5, by = 1))
  dens <- lapply(levels(train_eps$range), function(r) {
    p <- pts[range == r]
    d <- rowSums(outer(grid$x, p$rx_pl, function(a, b) dnorm(a, b, 2.5)) * outer(grid$y, p$ry_pl, function(a, b) dnorm(a, b, 2.5)))
    d / sum(d)
  })
  names(dens) <- levels(train_eps$range)
  list(grid = grid, dens = dens, team = c(mean(train_eps$outcome == "off team award"), mean(train_eps$outcome == "def team award")))
}

predict_voronoi <- function(fit, scenes, ranges) {
  t(vapply(seq_along(scenes), function(e) {
    sc <- scenes[[e]]
    d <- fit$dens[[as.character(ranges[e])]]
    near <- max.col(-outer(fit$grid$x, sc$pl$x, function(a, b) (a - b)^2) - outer(fit$grid$y, sc$pl$y, function(a, b) (a - b)^2))
    share <- vapply(1:10, function(i) sum(d[near == i]), 0)
    c(share * (1 - sum(fit$team)), fit$team, 0)
  }, numeric(13)))
}
