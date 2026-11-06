# Court control: who would get to the ball if it went to a spot, where a missed shot is rebounded, and where
# the ball goes next. Adapted from soccer's pitch control (Spearman 2016, 2017, 2018; Fernandez and Bornn
# 2018) to the basketball court.
#
# Coordinates are feet, the offense attacking the hoop at (HOOP_X, 0). Every function here has a twin in
# web/src/lib/control.ts that the site runs live; web/tests/control.test.ts checks the two agree.
# Requires src/epv/R/features.R for the court constants.

CONTROL_DT <- 0.04       # s, integration step (one tracking frame)
CONTROL_MAX_T <- 6       # s of integration after the ball arrives
CONTROL_TOL <- 0.99      # stop integrating a spot once this much of it is controlled
GENERAL_CELL <- 2        # ft, grid for control, relevance and scoring opportunity
REBOUND_CELL <- 1.5      # ft, grid for the rebound surface
REBOUND_REACH <- 35      # ft from the hoop beyond which no rebound is counted

# ---- grids ---------------------------------------------------------------------------------------

#' Cell centres covering the court, offense attacking +x.
#' @param cell Cell size in feet.
#' @param half Only the offensive half (x >= 0).
#' @param reach If set, only cells within this many feet of the hoop.
#' @return data.table(x, y) in row-major order: y from top (+) to bottom, x from left to right.
court_grid <- function(cell, half = FALSE, reach = NULL) {
  nx <- ceiling(2 * HALF_L / cell)
  ny <- ceiling(2 * HALF_W / cell)
  xs <- -HALF_L + cell * (seq_len(nx) - 0.5)
  ys <- HALF_W - cell * (seq_len(ny) - 0.5)
  g <- CJ(y = ys, x = xs, sorted = FALSE)[, .(x, y)]
  if (half) g <- g[x >= 0]
  if (!is.null(reach)) g <- g[sqrt((x - HOOP_X)^2 + y^2) <= reach]
  g
}

# ---- physics: time to arrive and control ---------------------------------------------------------

#' Seconds each player needs to reach each spot: he keeps his velocity for the reaction time, then runs
#' straight there at top speed (Spearman's time to intercept).
#' @param px,py,vx,vy n x k matrices, one row per spot (a frame's players repeated, or each sample's own).
#' @param qx,qy Spots, length n.
#' @param par list(react, vmax).
#' @return n x k matrix of arrival times.
arrival_times <- function(px, py, vx, vy, qx, qy, par) {
  rx <- px + vx * par$react
  ry <- py + vy * par$react
  par$react + sqrt((qx - rx)^2 + (qy - ry)^2) / par$vmax
}

#' Share of each spot the offense controls when the ball reaches it at t_ball. Each player's chance of
#' having arrived by time t is logistic in t - tau with spread sigma; while the spot is uncontrolled, an
#' arrived player takes control at rate lambda (defenders at kappa * lambda). Integrated from t_ball on.
#' @param tau n x k arrival times, offense in the first n_off columns.
#' @param t_ball Ball arrival time at each spot, length n.
#' @param par list(sigma, lambda).
#' @return Offense share of control, length n (offense / (offense + defense)).
offense_control <- function(tau, t_ball, par, kappa = 1, n_off = 5L) {
  n <- nrow(tau)
  k <- ncol(tau)
  lam <- matrix(rep(par$lambda * c(rep(1, n_off), rep(kappa, k - n_off)) * CONTROL_DT, each = n), n)
  scale <- pi / sqrt(3) / par$sigma
  P <- matrix(0, n, k)
  tot <- numeric(n)
  live <- seq_len(n)
  for (s in seq_len(ceiling(CONTROL_MAX_T / CONTROL_DT))) {
    t <- t_ball[live] + s * CONTROL_DT
    f <- plogis((t - tau[live, , drop = FALSE]) * scale)
    P[live, ] <- P[live, , drop = FALSE] + (1 - tot[live]) * f * lam[live, , drop = FALSE]
    tot[live] <- rowSums(P[live, , drop = FALSE])
    live <- live[tot[live] < CONTROL_TOL]
    if (!length(live)) break
  }
  off <- rowSums(P[, seq_len(n_off), drop = FALSE])
  off / pmax(tot, 1e-9)
}

#' Repeat one frame's players (vectors of length k) down n rows.
spread_players <- function(v, n) matrix(rep(v, each = n), n)

#' Offense control over a grid for one frame.
#' @param pl list(x, y, vx, vy) vectors of length 10, offense first.
#' @param t_ball Ball arrival time at each grid spot.
grid_control <- function(pl, grid, t_ball, par, kappa = 1) {
  n <- nrow(grid)
  tau <- arrival_times(spread_players(pl$x, n), spread_players(pl$y, n), spread_players(pl$vx, n),
                       spread_players(pl$vy, n), grid$x, grid$y, par)
  offense_control(tau, t_ball, par, kappa)
}

#' Ball travel time from (bx, by) to each spot: a pass's flight time is linear in its length.
ball_time <- function(bx, by, qx, qy, par) par$ball0 + par$ball1 * sqrt((qx - bx)^2 + (qy - by)^2)

# ---- rebounds ------------------------------------------------------------------------------------

#' Seconds from release until a shot reaches the rim, linear in shot distance.
flight_time <- function(dist, par) par$flight0 + par$flight1 * pmin(dist, 40)

#' Seconds from release until the ball reaches each spot after a miss: the rest of the shot's flight,
#' then the bounce out to the spot, linear in its distance from the hoop.
#' @param elapsed Seconds since release.
rebound_time <- function(qx, qy, dist, elapsed, par) {
  pmax(flight_time(dist, par) - elapsed, 0) + par$bounce0 + par$bounce1 * sqrt((qx - HOOP_X)^2 + qy^2)
}

#' Unnormalised density of where a miss from (sx, sy) is rebounded, per square foot. Distance from the
#' hoop is gamma with shape `shape` and a mean that grows with shot distance; direction from the hoop is
#' a von Mises bump toward the shooter's side plus a uniform floor `floor`.
#' Normalise over a grid with landing_density().
landing_weight <- function(qx, qy, sx, sy, par) {
  r <- pmax(sqrt((qx - HOOP_X)^2 + qy^2), 0.25)
  dist <- sqrt((sx - HOOP_X)^2 + sy^2)
  mu <- par$land0 + par$land1 * pmin(dist, 30)
  side <- cos(atan2(qy, qx - HOOP_X) - atan2(sy, sx - HOOP_X))
  r^(par$shape - 2) * exp(-par$shape * r / mu) * (exp(par$focus * (side - 1)) + par$floor)
}

#' Landing density over a rebound grid for one shot, summing to one over the grid's cells.
landing_density <- function(grid, sx, sy, par) {
  w <- landing_weight(grid$x, grid$y, sx, sy, par)
  w / sum(w)
}

#' Chance of an offensive rebound if the shot misses: the landing density times offense control at each
#' spot, mixed with the rate for team rebounds (ball out of bounds or not secured by a player).
#' @param pl One frame's ten players, offense first.
#' @param elapsed Seconds since release.
#' @return list(p = chance, pc = control on the grid, dens = landing density on the grid).
rebound_chance <- function(pl, grid, sx, sy, elapsed, par) {
  dist <- sqrt((sx - HOOP_X)^2 + sy^2)
  pc <- grid_control(pl, grid, rebound_time(grid$x, grid$y, dist, elapsed, par), par, par$kappa)
  dens <- landing_density(grid, sx, sy, par)
  list(p = (1 - par$team_share) * sum(dens * pc) + par$team_share * par$team_oreb, pc = pc, dens = dens)
}

#' rebound_chance() at release for many (frame, shooter) pairs at once, in chunks of `chunk` pairs.
#' @param P list(x, y, vx, vy) of n x 10 matrices, one row per pair, offense first.
#' @param sx,sy The shooter's spot for each pair.
#' @return Chance of an offensive rebound if the shot misses, length n.
rebound_chance_many <- function(P, sx, sy, grid, par, chunk = 40L) {
  n <- length(sx)
  nc <- nrow(grid)
  out <- numeric(n)
  for (start in seq(1L, n, by = chunk)) {
    idx <- start:min(n, start + chunk - 1L)
    rows <- rep(idx, each = nc)
    qx <- rep(grid$x, length(idx))
    qy <- rep(grid$y, length(idx))
    px <- rep(sx[idx], each = nc)
    py <- rep(sy[idx], each = nc)
    tau <- arrival_times(P$x[rows, , drop = FALSE], P$y[rows, , drop = FALSE], P$vx[rows, , drop = FALSE],
                         P$vy[rows, , drop = FALSE], qx, qy, par)
    pc <- offense_control(tau, rebound_time(qx, qy, sqrt((px - HOOP_X)^2 + py^2), 0, par), par, par$kappa)
    w <- matrix(landing_weight(qx, qy, px, py, par), nc)
    out[idx] <- (1 - par$team_share) * colSums(w * matrix(pc, nc)) / colSums(w) + par$team_share * par$team_oreb
  }
  out
}

# ---- relevance and scoring opportunity -----------------------------------------------------------

#' Where the ball is likely to be RELEVANCE_AHEAD frames from now, as a distribution over the grid:
#' a Gaussian around the ball, tilted toward spots the offense controls and toward the hoop.
#' @param pc Offense control on the grid.
relevance <- function(grid, bx, by, pc, par) {
  d2 <- (grid$x - bx)^2 + (grid$y - by)^2
  hoop <- sqrt((grid$x - HOOP_X)^2 + grid$y^2)
  lw <- -d2 / (2 * par$spread^2) + par$tilt * log(pmax(pc, 1e-4)) - par$pull * hoop / 10
  w <- exp(lw - max(lw))
  w / sum(w)
}
