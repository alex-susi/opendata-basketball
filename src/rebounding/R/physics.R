# Step 07 of the rebounding manual: ball physics for the particle forecasts. Free flight by fourth-order Runge-Kutta
# under gravity, with optional quadratic drag and a Magnus term (off by default: the track's own curvature, about
# 28.2 ft/s^2, already absorbs what the data can tell); collisions with the rim (a torus), the backboard face and the
# floor, each particle carrying its own restitution and friction because spin and contact are unknown.
# Settings: config/experiment.yaml (step07$physics). basketball-shot (djlee9812) has no licence, so nothing is
# ported from it: these are the textbook rigid-sphere contact rules, written independently.
#
# Coordinates: positions are relative to the hoop centre (to_hoop / from_hoop), feet and seconds, offence attacking
# +x, so the board face is at x = BOARD_X - RIM_X and the rim ring at radius RIM_R in the plane z = 0.
# Requires geometry.R.

to_hoop <- function(P, hoop) sweep(P, 2, hoop)
from_hoop <- function(P, hoop) sweep(P, 2, hoop, `+`)

#' Acceleration of N balls (velocities V, N x 3): gravity, plus drag k |v| v and Magnus km (omega x v) when given.
accel <- function(V, g, drag = 0, omega = NULL, km = 0) {
  A <- matrix(0, nrow(V), 3); A[, 3] <- -g
  if (drag > 0) A <- A - drag * sqrt(rowSums(V^2)) * V
  if (!is.null(omega) && km != 0)
    A <- A + km * cbind(omega[, 2] * V[, 3] - omega[, 3] * V[, 2], omega[, 3] * V[, 1] - omega[, 1] * V[, 3],
                        omega[, 1] * V[, 2] - omega[, 2] * V[, 1])
  A
}

#' One RK4 step of positions X and velocities V (N x 3 each) over dt.
rk4_step <- function(X, V, dt, g, drag = 0, omega = NULL, km = 0) {
  a1 <- accel(V, g, drag, omega, km); v1 <- V
  a2 <- accel(V + a1 * dt / 2, g, drag, omega, km); v2 <- V + a1 * dt / 2
  a3 <- accel(V + a2 * dt / 2, g, drag, omega, km); v3 <- V + a2 * dt / 2
  a4 <- accel(V + a3 * dt, g, drag, omega, km); v4 <- V + a3 * dt
  list(X = X + dt / 6 * (v1 + 2 * v2 + 2 * v3 + v4), V = V + dt / 6 * (a1 + 2 * a2 + 2 * a3 + a4))
}

#' Resolve contacts of N balls (hoop-relative X, V) with the rim, the board face and the floor. Each ball that
#' penetrates a surface while moving into it is put back on the surface; its normal velocity is reversed and scaled
#' by its restitution and its tangential velocity scaled by (1 - friction). Never adds speed when restitution <= 1.
#' @param C per-ball contact parameters: e_rim, mu_rim, e_board, mu_board (vectors of length N).
#' @return list(X, V, hit = character contact kind per ball this step, "" when none).
collide <- function(X, V, C, ph) {
  hit <- character(nrow(X))
  # rim: nearest point of the ring circle
  rho <- pmax(sqrt(X[, 1]^2 + X[, 2]^2), 1e-9)
  cx <- RIM_R * X[, 1] / rho; cy <- RIM_R * X[, 2] / rho
  D <- cbind(X[, 1] - cx, X[, 2] - cy, X[, 3])
  dist <- sqrt(rowSums(D^2)); rr <- BALL_R + RIM_TUBE
  N <- D / pmax(dist, 1e-9)
  vn <- rowSums(V * N)
  i <- which(dist < rr & vn < 0)
  if (length(i)) {
    Vn <- vn[i] * N[i, , drop = FALSE]; Vt <- V[i, , drop = FALSE] - Vn
    V[i, ] <- Vt * (1 - C$mu_rim[i]) - C$e_rim[i] * Vn
    X[i, ] <- cbind(cx[i], cy[i], 0) + N[i, , drop = FALSE] * rr
    hit[i] <- "RIM"
  }
  # backboard face
  bx <- BOARD_X - RIM_X
  j <- which(X[, 1] + BALL_R > bx & X[, 1] < bx + 0.5 & abs(X[, 2]) <= BOARD_HALF_W & X[, 3] >= BOARD_Z0 - RIM_Z &
               X[, 3] <= BOARD_Z1 - RIM_Z & V[, 1] > 0)
  if (length(j)) {
    V[j, 1] <- -C$e_board[j] * V[j, 1]; V[j, 2:3] <- V[j, 2:3] * (1 - C$mu_board[j])
    X[j, 1] <- bx - BALL_R
    hit[j] <- "BACKBOARD"
  }
  # floor (the track's ball centre at a floor contact)
  fz <- ph$floor_z_ft - RIM_Z
  k <- which(X[, 3] < fz & V[, 3] < 0)
  if (length(k)) {
    V[k, 3] <- -ph$floor_restitution * V[k, 3]; V[k, 1:2] <- V[k, 1:2] * (1 - ph$floor_friction)
    X[k, 3] <- fz
    hit[k] <- "FLOOR"
  }
  list(X = X, V = V, hit = hit)
}

#' Simulate N balls for `t` seconds in substeps of at most `dt` (RK4 then contacts each substep).
#' @return list(X, V, contacts = N x 3 counts of RIM, BACKBOARD, FLOOR contacts during the run).
simulate_balls <- function(X, V, C, t, g, ph, dt = ph$substep_s) {
  cnt <- matrix(0L, nrow(X), 3, dimnames = list(NULL, c("RIM", "BACKBOARD", "FLOOR")))
  if (t <= 0) return(list(X = X, V = V, contacts = cnt))
  n <- ceiling(t / dt - 1e-9); h <- t / n
  for (s in seq_len(n)) {
    st <- rk4_step(X, V, h, g)
    co <- collide(st$X, st$V, C, ph)
    X <- co$X; V <- co$V
    for (kind in colnames(cnt)) cnt[co$hit == kind, kind] <- cnt[co$hit == kind, kind] + 1L
  }
  list(X = X, V = V, contacts = cnt)
}

#' Contact parameters for N particles, uniform over the configured ranges.
draw_contact_params <- function(n, ph) {
  u <- function(r) runif(n, r[[1]], r[[2]])
  list(e_rim = u(ph$rim_restitution), mu_rim = u(ph$rim_friction), e_board = u(ph$board_restitution),
       mu_board = u(ph$board_friction))
}

#' The ball state at origin t from the last two usable measured frames (Step 03 rule: frame f usable from f + 1):
#' last position, its frame, and the velocity at that frame (difference quotient corrected for gravity on z).
two_point_state <- function(obs, t, g) {
  u <- obs[usable_from <= t][order(frame)]
  if (nrow(u) < 2L) return(NULL)
  a <- u[.N - 1L]; b <- u[.N]
  dt <- (b$frame - a$frame) / FPS
  v <- c(b$x - a$x, b$y - a$y, b$z - a$z) / dt
  v[3] <- v[3] - g * dt / 2
  list(p = c(b$x, b$y, b$z), v = v, frame = b$frame)
}
