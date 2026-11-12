## ═════════════════════════════════════════════════════════════════════════════
# Refit the court control model's reaction time, timing spread and claim rate (REACT, SIGMA, LAMBDA in
# web/src/lib/control.ts) for its per-player motion limits.
#   Rscript web/scripts/fit_control.R
#
# Data, as in the archived fit (zz_Archive/src/court_control/build_control.R): every live pass in the ten games
# (not an inbound, caught within 2 s, taken by a teammate other than the passer or by the intercepting defender),
# with all ten players' positions and velocities at its release (velocity over 6 frames, capped at 30 ft/s, as
# control.ts measures it) and the spot it was taken (the taker's tracked position when he took it). Passes with
# fewer than five tracked players a side or no ball position are left out.
#
# For each pass, the offense's control of the spot it was taken is computed exactly as control.ts computes a cell,
# the ball arriving after BALL0 + BALL1 × distance. Passers choose safe passes (most are completed), so, as in the
# archived fit, a two-parameter logistic on logit(control) absorbs that selection, and each grid point is scored
# by the log loss of completed vs intercepted. Two motion models are fitted on the same grid:
#   archived  every player at VMAX from the moment he reacts (the archived model; its best point should be the
#             archived REACT 0.4, SIGMA 0.15, LAMBDA 100, which checks this rebuild)
#   limits    each player's sprint speed, acceleration and braking (sample.json; sample_stats.R)
# and compared leaving one game out at a time: the grid point and logistic are chosen on nine games and scored on
# the tenth. The players' limits come from all ten games' tracking (movement only, not pass outcomes).
# Writes web/outputs/court_control/fit_control.csv (the grid), fit_control_games.csv (held-out games) and prints the
# chosen constants.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "load_app.R"))
a <- load_shiny_app()
out_dir <- file.path(a$root, "web", "outputs", "court_control")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Constants of control.ts: top speed (ft/s), ball flight (s per ft), time step and cap (s), and default limits.
VMAX <- 18.1147264926486
BALL0 <- 0.0160704909212239
BALL1 <- 0.0201103502526555
DT <- 0.04
MAX_T <- 6
TOL <- 0.99
VEL_LAG <- 6L
MAX_SPEED <- 30
ACCEL <- 12.4
BRAKE <- 11.9
GRID <- CJ(react = c(0, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5), sigma = c(0.05, 0.1, 0.15, 0.2, 0.3, 0.45, 0.6, 0.8), lambda = c(20, 50, 100, 200))
# Motion models: the archived one, per-player sprint speeds at once, and per-player limits with acceleration and
# braking scaled by a factor (the measured percentiles may understate a first step).
MODELS <- list(archived = list(kind = "archived"), speeds = list(kind = "speeds"),
               limits_x1 = list(kind = "limits", k = 1), limits_x1.5 = list(kind = "limits", k = 1.5),
               limits_x2 = list(kind = "limits", k = 2), limits_x3 = list(kind = "limits", k = 3))

# Each player's limits from the site's sample.json, falling back to the defaults.
sample <- fromJSON(file.path(a$root, "web", "public", "data", "sample.json"), simplifyVector = FALSE)
limits_of <- function(key) {
  t <- sample$players[[key]]$trk
  if (is.null(t$vmax)) c(VMAX, ACCEL, BRAKE) else c(t$vmax, t$amax %||% ACCEL, t$dmax %||% BRAKE)
}
`%||%` <- function(x, y) if (is.null(x)) y else x





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PASSES WITH THE TEN PLAYERS AT RELEASE ---------------------------------
## ═════════════════════════════════════════════════════════════════════════════

games <- as.integer(fromJSON(file.path(a$root, "data", "matches.json"))$id)
rows <- list()
# One game at a time: the live passes, then the ten players' positions and velocities at each release.
for (g in games) {
  ev <- a$read_json_file(a$match_file(a$root, g, "_dynamic_events.json"))
  pa <- data.table(frame = a$int_field(ev$passes, "startFrame"), end = a$int_field(ev$passes, "endFrame"),
                   passer = a$int_field(ev$passes, "passerId"), receiver = a$int_field(ev$passes, "receiverId"),
                   thief = a$int_field(ev$passes, "toReceiverId"), turnover = a$lgl_field(ev$passes, "turnover"),
                   inbounds = a$lgl_field(ev$passes, "inbounds"))
  # Live passes caught within 2 s by a teammate or by the intercepting defender.
  pa <- pa[!inbounds & end > frame & end - frame <= 50L &
             ((turnover & !is.na(thief)) | (!turnover & !is.na(receiver) & receiver != passer))]
  pa[, taker := fifelse(turnover, thief, receiver)]
  roster <- a$app_data$roster[game_id == g]
  trk <- a$get_tracking(a$app_data, g)
  pl <- trk$players[, .(frame, pid, x, y)]
  fr <- trk$frames[, .(frame, bx, by)]
  setkey(pl, frame, pid)
  # Skip passes without a ball position, a tracked taker, or five tracked players a side.
  for (i in seq_len(nrow(pa))) {
    p <- pa[i]
    now <- pl[.(p$frame)]
    back <- pl[.(p$frame - VEL_LAG)]
    ball <- fr[frame == p$frame]
    tk <- pl[.(p$end, p$taker)]
    if (!nrow(ball) || is.na(ball$bx) || !nrow(tk) || is.na(tk$x)) next
    now[, team := roster$team_id[match(pid, roster$pid)]]
    off_team <- roster$team_id[match(p$passer, roster$pid)]
    now <- now[!is.na(x) & !is.na(team)]
    now[, off := team == off_team]
    if (sum(now$off) != 5L || sum(!now$off) != 5L) next
    b <- back[match(now$pid, back$pid)]
    now[, `:=`(vx = fifelse(is.na(b$x), 0, (x - b$x) * 25 / VEL_LAG), vy = fifelse(is.na(b$y), 0, (y - b$y) * 25 / VEL_LAG))]
    sp <- sqrt(now$vx^2 + now$vy^2)
    slow <- pmin(1, MAX_SPEED / pmax(sp, 1e-6))
    now[, `:=`(vx = vx * slow, vy = vy * slow)]
    setorder(now, -off)
    lim <- t(vapply(paste0(roster$canon[match(now$pid, roster$pid)], ":", now$team), limits_of, numeric(3)))
    rows[[length(rows) + 1L]] <- list(game = g, y = !p$turnover, bx = ball$bx, by = ball$by, tx = tk$x, ty = tk$y,
                                      x = now$x, yy = now$y, vx = now$vx, vy = now$vy, lim = lim)
  }
  message(sprintf("game %d: %d passes kept so far", g, length(rows)))
}
# Stack the passes into matrices: one row per pass, one column per player (offense first).
n <- length(rows)
M <- function(f) t(vapply(rows, f, numeric(10)))
X <- M(function(r) r$x)
Y <- M(function(r) r$yy)
VX <- M(function(r) r$vx)
VY <- M(function(r) r$vy)
LV <- M(function(r) r$lim[, 1])
LA <- M(function(r) r$lim[, 2])
LD <- M(function(r) r$lim[, 3])
pass <- data.table(game = vapply(rows, `[[`, 0L, "game"), y = vapply(rows, `[[`, NA, "y"),
                   bx = vapply(rows, `[[`, 0, "bx"), by = vapply(rows, `[[`, 0, "by"),
                   tx = vapply(rows, `[[`, 0, "tx"), ty = vapply(rows, `[[`, 0, "ty"))
message(sprintf("%d live passes, %d intercepted", n, sum(!pass$y)))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - CONTROL AT EACH PASS'S SPOT --------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# As control.ts computes a cell.

# Time to cover a distance from speed u: brake if moving away, accelerate to the top speed v, then run at it.
run_time <- function(dist, u, v, a, d) {
  t <- ifelse(u < 0, -u / d, 0)
  dist <- dist + ifelse(u < 0, u^2 / (2 * d), 0)
  u <- pmin(pmax(u, 0), v)
  ramp <- (v^2 - u^2) / (2 * a)
  t + ifelse(ramp >= dist, (sqrt(u^2 + 2 * a * dist) - u) / a, (v - u) / a + (dist - ramp) / v)
}

# Arrival time of every player at each pass's spot, under one motion model.
arrival <- function(react, m) {
  rx <- X + VX * react
  ry <- Y + VY * react
  dx <- pass$tx - rx
  dy <- pass$ty - ry          # recycled down columns: one target per row
  dist <- sqrt(dx^2 + dy^2)
  if (m$kind == "archived") return(react + dist / VMAX)
  if (m$kind == "speeds") return(react + dist / LV)
  u <- ifelse(dist > 1e-9, (VX * dx + VY * dy) / dist, 0)
  react + matrix(run_time(dist, u, LV, LA * m$k, LD * m$k), nrow = n)
}

# Offense's share of control at the spot: players claim it at rate lambda once the ball arrives, each in a logistic
# ramp around his own arrival time.
control <- function(tau, sigma, lambda) {
  t_ball <- BALL0 + BALL1 * sqrt((pass$tx - pass$bx)^2 + (pass$ty - pass$by)^2)
  scale <- pi / sqrt(3) / sigma
  rate <- lambda * DT
  P <- matrix(0, n, 10)
  tot <- numeric(n)
  live <- rep(TRUE, n)
  for (s in seq_len(ceiling(MAX_T / DT))) {
    if (!any(live)) break
    t <- t_ball + s * DT
    free <- 1 - tot
    add <- (free * rate) / (1 + exp(-(t - tau) * scale))
    P[live, ] <- P[live, ] + add[live, ]
    tot[live] <- rowSums(P[live, , drop = FALSE])
    live <- live & tot < TOL
  }
  rowSums(P[, 1:5]) / pmax(tot, 1e-9)
}

# Every model and grid point: logit of control for each pass.
log_loss <- function(y, p) {
  p <- pmin(pmax(p, 1e-6), 1 - 1e-6)
  -mean(ifelse(y, log(p), log(1 - p)))
}
scores <- list()
Z <- list()
for (model in names(MODELS)) {
  for (react in unique(GRID$react)) {
    tau <- arrival(react, MODELS[[model]])
    for (k in which(GRID$react == react)) {
      pc <- control(tau, GRID$sigma[k], GRID$lambda[k])
      Z[[paste(model, k)]] <- qlogis(pmin(pmax(pc, 1e-4), 1 - 1e-4))
    }
  }
  message("fitted grid for ", model)
}
# Calibrate a logistic on logit(control), then score log loss on the test rows.
calib <- function(z, rows) coef(glm(pass$y[rows] ~ z[rows], family = binomial()))
score <- function(z, fit_rows, test_rows) {
  b <- calib(z, fit_rows)
  log_loss(pass$y[test_rows], plogis(b[1] + b[2] * z[test_rows]))
}

# Every grid point scored on all ten games.
all_rows <- seq_len(n)
grid_out <- rbindlist(lapply(names(MODELS), function(model) {
  cbind(model = model, GRID, log_loss = vapply(seq_len(nrow(GRID)), function(k) score(Z[[paste(model, k)]], all_rows, all_rows), 0))
}))
fwrite(grid_out, file.path(out_dir, "fit_control.csv"))

# Leave one game out: choose the grid point on nine games and score it on the tenth.
held <- rbindlist(lapply(games, function(g) {
  tr <- which(pass$game != g)
  te <- which(pass$game == g)
  base <- log_loss(pass$y[te], rep(mean(pass$y[tr]), length(te)))
  rbindlist(lapply(names(MODELS), function(model) {
    ll <- vapply(seq_len(nrow(GRID)), function(k) score(Z[[paste(model, k)]], tr, tr), 0)
    k <- which.min(ll)
    data.table(game = g, model = model, n = length(te), base = base, log_loss = score(Z[[paste(model, k)]], tr, te), GRID[k])
  }))
}))
fwrite(held, file.path(out_dir, "fit_control_games.csv"))

# Report the best points and the held-out comparison.
best <- grid_out[, .SD[which.min(log_loss)], by = model]
cat("\nBest grid point on all ten games:\n")
print(best)
paired <- dcast(held, game + n + base ~ model, value.var = "log_loss")
cat("\nHeld-out games (log loss; lower is better):\n")
print(paired)
summary_out <- rbindlist(lapply(names(MODELS), function(m) {
  gain <- paired$archived - paired[[m]]
  data.table(model = m, held_out_log_loss = weighted.mean(paired[[m]], paired$n), games_better_than_archived = sum(gain > 0),
             mean_gain_vs_archived = mean(gain), se = sd(gain) / sqrt(nrow(paired)))
}))
cat(sprintf("\nBase rate held-out log loss %.4f\n", weighted.mean(paired$base, paired$n)))
print(summary_out)
fwrite(summary_out, file.path(out_dir, "fit_control_summary.csv"))
cat("\nGrid points chosen in the held-out folds:\n")
print(held[, .N, by = .(model, react, sigma, lambda)][order(model, -N)])
