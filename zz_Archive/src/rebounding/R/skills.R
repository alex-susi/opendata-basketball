# Anticipation, boxing out and collection effects (framework sections 8, 9, 10 and 11).
#
# Each skill is estimated from its own kind of evidence: anticipation from movement in the first half
# second after release, judged against a role-matched reference policy with the ball forecast frozen at
# release; boxing out from opponent pairs whose routes to the reachable ball are blocked (a spatial
# obstruction proxy: no video, no body orientation); collection from who secures the ball given access
# (player effects in the competing-risks model). Requires opportunity.R and cpp/opportunity.cpp.

ANT_STEPS <- 6L           # decision interval: 6 path steps = 0.48 s after release
ANT_FRAMES <- 12L         # the same interval in tracking frames
ANT_REF <- 16L            # reference moves drawn per player
EXPOSURE_MIN <- 0.005     # least spread of reference values for a player-episode to carry anticipation weight
BOX_ON <- 0.35            # obstruction at which a box-out counts as established
BOX_HOLD <- 0.25          # obstruction that counts as still holding it
BOX_LOST <- 0.10          # obstruction below which it is lost
BOX_STEP <- 5L            # frames between box-out samples (0.2 s)

# ---- movement and anticipation ------------------------------------------------------------------------

#' Role at release: side, and the shooter or a distance band from the hoop.
player_roles <- function(pl, shooter) {
  d <- sqrt((pl$x - RIM_X)^2 + pl$y^2)
  band <- as.character(cut(d, c(-Inf, 10, 18, 24, Inf), labels = c("near", "mid", "perimeter", "deep")))
  paste(ifelse(pl$off, "off", "def"), ifelse(pl$canon == shooter, "shooter", band))
}

#' Hoop-polar unit vectors at each position: radial toward the hoop and its left-hand tangent.
polar_axes <- function(x, y) {
  dx <- RIM_X - x; dy <- -y
  d <- pmax(sqrt(dx^2 + dy^2), 0.5)
  list(rx = dx / d, ry = dy / d, tx = -dy / d, ty = dx / d)
}

#' Start and end states of the ten players over the decision interval, with displacement and end velocity in
#' each player's hoop-polar frame. NULL if the same ten are not all tracked at both ends.
movement_rows <- function(b, sc) {
  p0 <- sc$pl
  p1 <- b$players[frame == sc$frame + ANT_FRAMES]
  p1 <- p1[match(p0$pid, p1$pid)]
  if (anyNA(p1$x)) return(NULL)
  ax <- polar_axes(p0$x, p0$y)
  dx <- p1$x - p0$x; dy <- p1$y - p0$y
  data.table(shot_id = b$id, game_id = b$game_id, pid = p0$pid, canon = p0$canon, off = p0$off,
             role = player_roles(p0, b$shot$canon), x0 = p0$x, y0 = p0$y, vx0 = p0$vx, vy0 = p0$vy,
             x1 = p1$x, y1 = p1$y, vx1 = p1$vx, vy1 = p1$vy,
             dr = dx * ax$rx + dy * ax$ry, dt = dx * ax$tx + dy * ax$ty,
             vr = p1$vx * ax$rx + p1$vy * ax$ry, vt = p1$vx * ax$tx + p1$vy * ax$ty)
}

#' Damped-velocity factors for position and end velocity, fitted by least squares on movement rows.
fit_damping <- function(lib) {
  h <- ANT_FRAMES / FPS
  list(pos = sum((lib$x1 - lib$x0) * lib$vx0 * h + (lib$y1 - lib$y0) * lib$vy0 * h) / sum((lib$vx0^2 + lib$vy0^2) * h^2),
       vel = sum(lib$vx1 * lib$vx0 + lib$vy1 * lib$vy0) / sum(lib$vx0^2 + lib$vy0^2))
}

#' Role-matched residual moves for one player, in his own hoop-polar frame: what players of his role did beyond
#' carrying on with damped momentum. Columns x, y (end position) and vx, vy (end velocity).
residual_cloud <- function(row, lib, damp) {
  pool <- lib[role == row$role]
  if (nrow(pool) < 20L) pool <- lib[off == row$off]
  h <- ANT_FRAMES / FPS
  ex <- pool$x1 - pool$x0 - damp$pos * pool$vx0 * h; ey <- pool$y1 - pool$y0 - damp$pos * pool$vy0 * h
  evx <- pool$vx1 - damp$vel * pool$vx0; evy <- pool$vy1 - damp$vel * pool$vy0
  a <- polar_axes(pool$x0, pool$y0)
  dr <- ex * a$rx + ey * a$ry; dt <- ex * a$tx + ey * a$ty
  vr <- evx * a$rx + evy * a$ry; vt <- evx * a$tx + evy * a$ty
  ax <- polar_axes(row$x0, row$y0)
  data.table(x = row$x0 + damp$pos * row$vx0 * h + dr * ax$rx + dt * ax$tx,
             y = row$y0 + damp$pos * row$vy0 * h + dr * ax$ry + dt * ax$ty,
             vx = damp$vel * row$vx0 + vr * ax$rx + vt * ax$tx, vy = damp$vel * row$vy0 + vr * ax$ry + vt * ax$ty)
}

#' Reference end states for one player: n draws from the pooled behaviour model (damped momentum plus a
#' role-matched residual move), the model validated in score_movement().
reference_moves <- function(row, lib, n, seed, damp) {
  set.seed(seed)
  cloud <- residual_cloud(row, lib, damp)
  cloud[sample(.N, n, replace = TRUE)]
}

#' Collection probabilities of the scene's players after the decision interval, for many variants of where
#' one player is: the ball forecast stays the release forecast (paths from step ANT_STEPS + 1 on), every other
#' player is where he actually was. Returns a variants x 13 matrix.
variant_probs <- function(sc, base_pl, i, ends, acc, fit) {
  K <- N_STEPS - ANT_STEPS
  cols <- ANT_STEPS + seq_len(K)
  bx <- sc$bx[, cols, drop = FALSE]; by <- sc$by[, cols, drop = FALSE]; bz <- sc$bz[, cols, drop = FALSE]
  out_step <- ifelse(sc$out_step < 0L, -1L, pmax(0L, sc$out_step - ANT_STEPS))
  t_info <- pmax(0, sc$t_info - ANT_STEPS * STEP)
  V <- nrow(ends)
  A <- numeric(0); Z <- numeric(0)
  for (v in seq_len(V)) {
    pl <- copy(base_pl)
    pl[i, c("x", "y", "vx", "vy") := ends[v]]
    A <- c(A, access_array(bx, by, bz, as.matrix(pl[, .(x, y, vx, vy)]), t_info, sc$target,
                           c(acc$react, acc$vmax, acc$sigma, acc$z_reach, acc$z_scale, acc$info_lag), STEP, acc$policy))
    O <- obstruction_cpp(pl$x, pl$y, pl$off, sc$tx, sc$ty, CORRIDOR, CLOSE)
    Z <- c(Z, as.vector(rbind(as.numeric(!pl$off), apply(O, 2, max))))
  }
  dims <- as.integer(c(V, P_SCENE, K, 10L, 0L))
  P <- cr_predict(fit$theta, A, rep(as.integer(out_step), V), Z, rep(-1L, 10L * V), rep(0L, V), dims)
  colnames(P) <- OUTCOMES
  P
}

#' Anticipation evidence for one episode: for every player, the collection chance (own and team's) after
#' the decision interval at his observed end state and at ANT_REF role-matched reference end states.
anticipation_episode <- function(b, sc, lib, acc, fit, seed, damp) {
  mv <- movement_rows(b, sc)
  if (is.null(mv)) return(NULL)
  base_pl <- data.table(x = mv$x1, y = mv$y1, vx = mv$vx1, vy = mv$vy1, off = mv$off)
  rbindlist(lapply(seq_len(10L), function(i) {
    ref <- reference_moves(mv[i], lib, ANT_REF, seed + i, damp)
    ends <- rbind(base_pl[i, .(x, y, vx, vy)], ref)
    P <- variant_probs(sc, base_pl, i, ends, acc, fit)
    own <- P[, i]
    team <- if (mv$off[i]) rowSums(P[, c(1:5, 11)]) else rowSums(P[, c(6:10, 12)])
    data.table(shot_id = b$id, game_id = b$game_id, pid = mv$pid[i], canon = mv$canon[i], off = mv$off[i],
               role = mv$role[i], v_obs = own[1], v_ref = mean(own[-1]), v_ref_sd = sd(own[-1]),
               v_ref_best = max(own[-1]), team_obs = team[1], team_ref = mean(team[-1]),
               moved_ft = sqrt((mv$x1[i] - mv$x0[i])^2 + (mv$y1[i] - mv$y0[i])^2), dr = mv$dr[i])
  }))
}

#' Movement forecasts for held-out players, scored at the decision interval's end: stationary, damped velocity,
#' role-matched moves ignoring momentum, and damped momentum plus role-matched residuals (the reference policy).
#' @param lib Training games' movement rows; `damp` the damped-velocity factors fitted on them.
score_movement <- function(test, lib, damp, sd_stat, sd_damp) {
  h <- ANT_FRAMES / FPS
  cloud_score <- function(r, ex, ey) {
    kde <- function(x, y) log(mean(dnorm(x, ex, 1) * dnorm(y, ey, 1)) + 1e-300)
    ly <- kde(r$x1, r$y1)
    ld <- vapply(seq_len(min(200L, length(ex))), function(j) kde(ex[j] + rnorm(1), ey[j] + rnorm(1)), 0)
    c(err = sqrt((r$x1 - mean(ex))^2 + (r$y1 - mean(ey))^2), ls = ly, cover80 = ly >= unname(quantile(ld, 0.2)))
  }
  rbindlist(lapply(seq_len(nrow(test)), function(k) {
    r <- test[k]
    pool <- lib[role == r$role]
    if (nrow(pool) < 20L) pool <- lib[off == r$off]
    ax <- polar_axes(r$x0, r$y0)
    res <- residual_cloud(r, lib, damp)
    dx <- r$x0 + damp$pos * r$vx0 * h
    dy <- r$y0 + damp$pos * r$vy0 * h
    g <- function(mx, my, s) c(err = sqrt((r$x1 - mx)^2 + (r$y1 - my)^2),
                               ls = sum(dnorm(c(r$x1, r$y1), c(mx, my), s, log = TRUE)),
                               cover80 = ((r$x1 - mx)^2 + (r$y1 - my)^2) / s^2 <= qchisq(0.8, 2))
    rbind(data.table(model = "stationary", t(g(r$x0, r$y0, sd_stat))),
          data.table(model = "damped_velocity", t(g(dx, dy, sd_damp))),
          data.table(model = "role_reference", t(cloud_score(r, r$x0 + pool$dr * ax$rx + pool$dt * ax$tx, r$y0 + pool$dr * ax$ry + pool$dt * ax$ty))),
          data.table(model = "damped_role", t(cloud_score(r, res$x, res$y))))[, `:=`(game_id = r$game_id, role = r$role)]
  }))
}

# ---- boxing out ---------------------------------------------------------------------------------------

#' Candidate box-out pairs of one episode and their obstruction over time. Pairs are opponents within 6 ft
#' of each other at release, both within 22 ft of the hoop, neither the shooter; obstruction is measured
#' against the release forecast's reachable target points every BOX_STEP frames until the rebound (or
#' 0.6 s after the rim, if earlier).
boxout_pairs <- function(b, sc) {
  p0 <- sc$pl
  dh <- sqrt((p0$x - RIM_X)^2 + p0$y^2)
  tm <- bundle_times(b)
  t_end <- min(c(tm$rebound, rim_time(b) + 0.6), na.rm = TRUE)
  frames <- seq(sc$frame, b$shot$f0 + round(t_end * FPS), by = BOX_STEP)
  series <- lapply(frames, function(f) {
    pl <- b$players[frame == f][match(p0$pid, pid)]
    if (anyNA(pl$x)) return(NULL)
    list(frame = f, O = obstruction_cpp(pl$x, pl$y, p0$off, sc$tx, sc$ty, CORRIDOR, CLOSE), pl = pl)
  })
  series <- Filter(Negate(is.null), series)
  if (length(series) < 2L) return(NULL)
  cand <- CJ(bb = 1:10, o = 1:10)[p0$off[bb] != p0$off[o] & dh[bb] <= 22 & dh[o] <= 22 &
                                    p0$canon[bb] != b$shot$canon & p0$canon[o] != b$shot$canon]
  cand <- cand[sqrt((p0$x[bb] - p0$x[o])^2 + (p0$y[bb] - p0$y[o])^2) <= 6]
  if (!nrow(cand)) return(NULL)
  t_rim <- rim_time(b)
  rbindlist(lapply(seq_len(nrow(cand)), function(k) {
    bb <- cand$bb[k]; o <- cand$o[k]
    s <- vapply(series, function(x) x$O[bb, o], 0)
    tt <- (vapply(series, function(x) as.numeric(x$frame), 0) - b$shot$f0) / FPS
    est <- which(s >= BOX_ON)[1]
    at <- if (is.na(est)) 1L else est
    pb <- series[[at]]$pl[bb]; po <- series[[at]]$pl[o]
    gap <- sqrt((pb$x - po$x)^2 + (pb$y - po$y)^2)
    after <- if (is.na(est)) integer(0) else seq(est, length(s))
    upto <- after[tt[after] <= t_rim + 0.2]
    hold <- if (length(upto)) mean(s[upto] >= BOX_HOLD) else NA_real_
    tgt <- c(mean(sc$tx), mean(sc$ty))
    last <- series[[length(series)]]$pl
    closer <- sqrt((last$x[o] - tgt[1])^2 + (last$y[o] - tgt[2])^2) < sqrt((last$x[bb] - tgt[1])^2 + (last$y[bb] - tgt[2])^2)
    lost <- !is.na(est) && any(s[after] < BOX_LOST)
    label <- if (is.na(est)) (if (max(s) >= 0.15) "attempted" else "none") else
      if (gap < (pb$err + po$err) / 2) "ambiguous" else
      if (!is.na(hold) && hold >= 0.8 && s[length(s)] >= BOX_HOLD) "maintained" else
      if (lost && closer) "escaped" else "attempted"
    rel <- function(p, v) ((tgt[1] - p$x) * v[1] + (tgt[2] - p$y) * v[2]) / max(0.5, sqrt((tgt[1] - p$x)^2 + (tgt[2] - p$y)^2))
    data.table(shot_id = b$id, game_id = b$game_id, blocker = p0$pid[bb], blocker_canon = p0$canon[bb],
               opponent = p0$pid[o], opponent_canon = p0$canon[o], blocker_def = !p0$off[bb],
               max_obs = max(s), obs_release = s[1], established = !is.na(est), t_establish = if (is.na(est)) NA_real_ else tt[est],
               hold_share = hold, label = label, gap = gap, obs_at_est = s[at],
               blocker_hoop = sqrt((pb$x - RIM_X)^2 + pb$y^2), opponent_hoop = sqrt((po$x - RIM_X)^2 + po$y^2),
               opp_toward = rel(po, c(po$vx, po$vy)), blk_toward = rel(pb, c(pb$vx, pb$vy)),
               frames = list(vapply(series, function(x) as.numeric(x$frame), 0)), strength = list(round(s, 3)))
  }))
}

#' Team value of each player's obstruction at a scene: the change in his team's chance of the ball, and in
#' his own collection chance, if his obstruction of every opponent were removed.
boxout_value <- function(sc, acc, fit) {
  A <- scene_access(sc, acc)
  base_Z <- function(O) as.vector(rbind(as.numeric(!sc$pl$off), apply(O, 2, max)))
  Zs <- list(base_Z(sc$O))
  for (bb in 1:10) { O <- sc$O; O[bb, ] <- 0; Zs[[bb + 1]] <- base_Z(O) }
  V <- length(Zs)
  dims <- as.integer(c(V, P_SCENE, N_STEPS, 10L, 0L))
  P <- cr_predict(fit$theta, rep(A, V), rep(sc$out_step, V), unlist(Zs), rep(-1L, 10L * V), rep(0L, V), dims)
  team <- function(r, off) if (off) sum(P[r, c(1:5, 11)]) else sum(P[r, c(6:10, 12)])
  data.table(shot_id = sc$id, pid = sc$pl$pid, canon = sc$pl$canon, off = sc$pl$off, obstruction_given = apply(sc$O, 1, max),
             team_value = vapply(1:10, function(bb) team(1, sc$pl$off[bb]) - team(bb + 1, sc$pl$off[bb]), 0),
             own_value = vapply(1:10, function(bb) P[1, bb] - P[bb + 1, bb], 0), p_collect = P[1, 1:10])
}
