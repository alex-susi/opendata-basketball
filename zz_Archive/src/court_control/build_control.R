# Fit and check the court control model, then save what the play viewer needs to draw it.
#   Rscript src/court_control/build_control.R [--force]
#
# 1. Tables for all ten games (cached in outputs/cache/court_control/tables.rds; --force rebuilds them):
#    missed shots sampled from release to the rim, and live frames for the relevance model.
# 2. Leave-one-game-out: fit every piece on nine games and score the tenth against base rates
#    (outputs/court_control/validation_*.csv). Each fold's rebound parameters are kept in
#    outputs/cache/court_control/params_{gameId}.rds for src/court_control/price_rebounds.R.
# 3. Refit on all ten games and save the parameters, the court-value grid and reference cases for the
#    site's own implementation (outputs/court_control/params.json, reference.json).
#    web/scripts/export_data.R copies them into the site.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/court_control"
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "..", "epv", "R", "features.R"))
source(file.path(here, "..", "epv", "R", "models.R"))
source(file.path(here, "R", "data.R"))
source(file.path(here, "R", "control.R"))

set.seed(20261016)
app <- load_app_data()
games <- app$matches$game_id
cache <- file.path(app$root, "outputs", "cache", "court_control")
report <- file.path(app$root, "outputs", "court_control")
dir.create(cache, recursive = TRUE, showWarnings = FALSE)
dir.create(report, recursive = TRUE, showWarnings = FALSE)

RELEVANCE_PER_GAME <- 500L   # relevance samples kept per game (each needs a whole control grid)

# ---- tables --------------------------------------------------------------------------------------

tables_path <- file.path(cache, "tables.rds")
if (file.exists(tables_path) && !"--force" %in% args) {
  tabs <- readRDS(tables_path)
} else {
  tabs <- lapply(games, function(g) {
    message("Tables for game ", g)
    rt <- rebound_table(app, g)
    rl <- relevance_table(app, g)
    keep <- sort(sample(nrow(rl$rows), min(RELEVANCE_PER_GAME, nrow(rl$rows))))
    ev <- game_events(app$root, g)
    rl$rows[, pts := points_from(poss_id, frame, ev$points)]
    pa <- ev$passes[!inbounds & !turnover & !is.na(receiver) & passer != receiver & end_frame > frame &
                      end_frame - frame <= 50L & len_ev > 3]
    list(rebound = rt, relevance = list(rows = rl$rows[keep], P = lapply(rl$P, function(m) m[keep, , drop = FALSE])),
         passes = pa[, .(game_id = g, flight = (end_frame - frame) / 25, len = len_ev)])
  })
  saveRDS(tabs, tables_path)
}

stack_P <- function(parts) setNames(lapply(names(parts[[1]]), function(k) do.call(rbind, lapply(parts, `[[`, k))), names(parts[[1]]))
shots <- rbindlist(lapply(tabs, function(t) t$rebound$shots))
samples <- rbindlist(lapply(tabs, function(t) t$rebound$samples))
SP <- stack_P(lapply(tabs, function(t) t$rebound$P))
samples <- merge(cbind(samples, idx = seq_len(nrow(samples))), shots, by = c("game_id", "shot_id"), sort = FALSE)
samples[, last := frame == max(frame), by = .(game_id, shot_id)]
rel <- rbindlist(lapply(tabs, function(t) t$relevance$rows))
RP <- stack_P(lapply(tabs, function(t) t$relevance$P))
passes <- rbindlist(lapply(tabs, `[[`, "passes"))
message(sprintf("%d missed shots (%d rebounded by a player), %d in-flight samples, %d relevance samples",
                nrow(shots), sum(shots$grabbed), nrow(samples), nrow(rel)))

# Top speed: the 99th percentile of tracked player speed on live frames (backward difference, clipped).
VMAX <- unname(quantile(sqrt(RP$vx^2 + RP$vy^2), 0.99))
BALL <- unname(coef(lm(flight ~ len, data = passes)))
message(sprintf("Top speed %.1f ft/s; pass flight %.3f s + %.4f s per foot", VMAX, BALL[1], BALL[2]))

rebound_grid <- court_grid(REBOUND_CELL, half = TRUE, reach = REBOUND_REACH)
general_grid <- court_grid(GENERAL_CELL)

# Live passes, for the live-ball control parameters (cached beside the tables; --force rebuilds them).
passes_path <- file.path(cache, "passes.rds")
if (file.exists(passes_path) && !"--force" %in% args) {
  ptabs <- readRDS(passes_path)
} else {
  ptabs <- lapply(games, function(g) {
    message("Passes for game ", g)
    pass_table(app, g)
  })
  saveRDS(ptabs, passes_path)
}
live_passes <- rbindlist(lapply(ptabs, `[[`, "rows"))
PP <- stack_P(lapply(ptabs, `[[`, "P"))
message(sprintf("%d live passes, %d intercepted", nrow(live_passes), sum(live_passes$intercepted)))

# ---- fitting -------------------------------------------------------------------------------------

#' Timing constants from training shots: flight to the rim, bounce out, and team rebounds.
fit_timing <- function(sh) {
  fl <- coef(lm(I((f1 - f0) / 25) ~ pmin(dist, 40), data = sh))
  b <- sh[grabbed == TRUE & !is.na(rx)][, .(bounce = (rf - f1) / 25, rr = sqrt((HOOP_X - rx)^2 + ry^2))][bounce > -0.5 & bounce < 4]
  bo <- coef(lm(bounce ~ rr, data = b))
  list(flight0 = unname(fl[1]), flight1 = unname(fl[2]), bounce0 = unname(bo[1]), bounce1 = unname(bo[2]),
       team_share = mean(!sh$grabbed), team_oreb = sh[grabbed == FALSE, mean(oreb)])
}

#' Landing model by maximum likelihood on where training rebounds were taken.
fit_landing <- function(sh) {
  obs <- sh[grabbed == TRUE & !is.na(rx) & sqrt((rx - HOOP_X)^2 + ry^2) <= REBOUND_REACH]
  unpack <- function(th) list(land0 = exp(th[1]), land1 = exp(th[2]), shape = 1 + exp(th[3]), focus = exp(th[4]),
                              floor = exp(th[5]))
  # landing_weight() over the grid for every shot at once: the same terms, laid out as shots x cells.
  r <- matrix(rep(pmax(sqrt((rebound_grid$x - HOOP_X)^2 + rebound_grid$y^2), 0.25), each = nrow(obs)), nrow(obs))
  side <- cos(outer(atan2(obs$sy, obs$sx - HOOP_X), atan2(rebound_grid$y, rebound_grid$x - HOOP_X), function(a, b) b - a))
  log_r <- log(r)
  dist <- pmin(sqrt((obs$sx - HOOP_X)^2 + obs$sy^2), 30)
  nll <- function(th) {
    par <- unpack(th)
    mu <- par$land0 + par$land1 * dist
    tot <- rowSums(exp((par$shape - 2) * log_r - par$shape * r / mu) * (exp(par$focus * (side - 1)) + par$floor))
    -sum(log(landing_weight(obs$rx, obs$ry, obs$sx, obs$sy, par)) - log(tot * REBOUND_CELL^2))
  }
  opt <- optim(c(log(4), log(0.1), log(1), log(1), log(0.3)), nll, control = list(maxit = 600))
  c(unpack(opt$par), list(land_nll = opt$value / nrow(obs)))
}

#' Control parameters by maximum likelihood on which team took each training rebound, at the spot it was
#' taken, from every in-flight sample of the shot (release to rim).
fit_control <- function(smp, timing) {
  s <- smp[grabbed == TRUE & !is.na(rx)]
  P <- lapply(SP, function(m) m[s$idx, , drop = FALSE])
  unpack <- function(th) c(list(react = exp(th[1]), sigma = exp(th[2]), lambda = exp(th[3]), kappa = exp(th[4]), vmax = VMAX), timing)
  nll <- function(th) {
    par <- unpack(th)
    tau <- arrival_times(P$x, P$y, P$vx, P$vy, s$rx, s$ry, par)
    pc <- offense_control(tau, rebound_time(s$rx, s$ry, s$dist, s$elapsed, par), par, par$kappa)
    pc <- pmin(pmax(pc, 1e-4), 1 - 1e-4)
    -mean(ifelse(s$oreb, log(pc), log(1 - pc)))
  }
  opt <- optim(c(log(0.3), log(0.4), log(4), log(1)), nll, control = list(maxit = 400))
  c(unpack(opt$par)[c("react", "sigma", "lambda", "kappa", "vmax")], list(control_nll = opt$value))
}

#' Every piece of the rebound model on a set of training games.
fit_rebound <- function(train_games) {
  sh <- shots[game_id %in% train_games]
  timing <- fit_timing(sh)
  t0 <- Sys.time()
  landing <- fit_landing(sh)
  t1 <- Sys.time()
  control <- fit_control(samples[game_id %in% train_games], timing)
  message(sprintf("  landing %.0f s, control %.0f s", difftime(t1, t0, units = "secs"), difftime(Sys.time(), t1, units = "secs")))
  c(timing, landing, control)
}

#' Rebound chance for given samples (rows of `samples`) under a fitted model.
predict_rebound <- function(smp, par) {
  vapply(seq_len(nrow(smp)), function(i) {
    j <- smp$idx[i]
    pl <- lapply(SP[c("x", "y", "vx", "vy")], function(m) m[j, ])
    rebound_chance(pl, rebound_grid, smp$sx[i], smp$sy[i], smp$elapsed[i], par)$p
  }, 0)
}

#' Offense control at the spot each rebound was taken (location known): the control model's own check.
predict_at_spot <- function(smp, par) {
  P <- lapply(SP, function(m) m[smp$idx, , drop = FALSE])
  tau <- arrival_times(P$x, P$y, P$vx, P$vy, smp$rx, smp$ry, par)
  offense_control(tau, rebound_time(smp$rx, smp$ry, smp$dist, smp$elapsed, par), par, par$kappa)
}

# ---- scoring -------------------------------------------------------------------------------------

log_loss <- function(y, p) {
  p <- pmin(pmax(p, 1e-6), 1 - 1e-6)
  -mean(ifelse(y, log(p), log(1 - p)))
}
auc <- function(y, p) {
  r <- rank(p)
  n1 <- sum(y)
  n0 <- sum(!y)
  if (!n1 || !n0) return(NA_real_)
  (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

#' Per-game log loss of a prediction against the training base rate, summarised as mean gain +/- SE.
summarise_gain <- function(dt, label) {
  by_game <- dt[, .(n = .N, events = sum(y), base = log_loss(y, base), model = log_loss(y, p)), by = game_id]
  by_game[, gain := base - model]
  data.table(check = label, n = nrow(dt), events = sum(dt$y), base = log_loss(dt$y, dt$base), model = log_loss(dt$y, dt$p),
             auc = auc(dt$y, dt$p), gain = mean(by_game$gain), se = sd(by_game$gain) / sqrt(nrow(by_game)),
             games_better = sum(by_game$gain > 0))
}

# ---- rebound model: leave one game out -----------------------------------------------------------

fold_path <- function(g) file.path(cache, paste0("fold_", g, ".rds"))

#' The rebound model fitted without game g. Saved: src/epv/build_epv.R prices game g's rebounds with it.
fold_params <- function(g) {
  path <- file.path(cache, paste0("params_", g, ".rds"))
  if (file.exists(path) && !"--force" %in% args) return(readRDS(path))
  message("Rebound parameters without game ", g)
  par <- fit_rebound(setdiff(games, g))
  saveRDS(par, path)
  par
}

held <- rbindlist(lapply(games, function(g) {
  par <- fold_params(g)
  if (file.exists(fold_path(g)) && !"--force" %in% args) return(readRDS(fold_path(g)))
  message("Rebound fold, game ", g)
  test <- samples[game_id == g]
  base <- shots[game_id != g, mean(oreb)]
  base_spot <- shots[game_id != g & grabbed == TRUE, mean(oreb)]
  pick_rows <- test[, .(release = idx[elapsed == 0][1], rim = idx[last][1],
                        mid = idx[which.min(abs(elapsed - max(elapsed) / 2))]), by = shot_id]
  at <- function(col) {
    rows <- test[match(pick_rows[[col]], idx)]
    data.table(game_id = g, shot_id = rows$shot_id, moment = col, y = rows$oreb, base = base, p = predict_rebound(rows, par))
  }
  spot <- test[grabbed == TRUE & !is.na(rx)]
  out <- rbind(at("release"), at("mid"), at("rim"),
               data.table(game_id = g, shot_id = spot$shot_id, moment = "at_spot", y = spot$oreb, base = base_spot,
                          p = predict_at_spot(spot, par)))
  out <- out[!is.na(y) & !is.na(p)]
  saveRDS(out, fold_path(g))
  out
}))

rebound_validation <- rbind(summarise_gain(held[moment == "release"], "P(OREB) at release"),
                            summarise_gain(held[moment == "mid"], "P(OREB) halfway to the rim"),
                            summarise_gain(held[moment == "rim"], "P(OREB) as the ball reaches the rim"),
                            summarise_gain(held[moment == "at_spot", .SD[1], by = .(game_id, shot_id)],
                                           "Team at the spot the rebound was taken (from release)"))
print(rebound_validation)
fwrite(rebound_validation, file.path(report, "validation_rebound.csv"))
fwrite(held[, .(n = .N, events = sum(y), base = log_loss(y, base), model = log_loss(y, p),
                mean_p = mean(p), rate = mean(y)), by = .(moment, game_id)],
       file.path(report, "validation_rebound_by_game.csv"))
cal <- held[moment != "at_spot", .(n = .N, predicted = mean(p), observed = mean(y)), by = .(moment, bin = cut(p, c(0, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 1)))]
setorder(cal, moment, bin)
print(cal)
fwrite(cal, file.path(report, "calibration_rebound.csv"))

# ---- final rebound and control fit on all ten games ----------------------------------------------

message("Final fit on all games")
final <- fit_rebound(games)
str(final)

# ---- live-ball control: fitted on which team took each pass, at the spot it was taken -------------

#' Offense control at each pass's destination from the players at its release, the ball arriving after
#' the flight time a pass of that length takes.
pass_control <- function(rows, par) {
  P <- lapply(PP, function(m) m[rows, , drop = FALSE])
  pa <- live_passes[rows]
  tau <- arrival_times(P$x, P$y, P$vx, P$vy, pa$tx, pa$ty, par)
  offense_control(tau, ball_time(pa$bx, pa$by, pa$tx, pa$ty, par), par)
}
# Passers pick safe passes (98% are completed), so raw control at a pass's destination is not its chance of
# completion. The physics is instead chosen by how well control separates completed from intercepted passes
# once a two-parameter logistic on logit(control) absorbs that selection: the grid point with the lowest
# log loss on the training games. The court shows raw control; the logistic is only used for scoring.
GENERAL_GRID <- CJ(react = c(0.2, 0.4, 0.7), sigma = c(0.15, 0.2, 0.3, 0.45), lambda = c(8, 20, 50, 100))
general_par <- function(k) c(as.list(GENERAL_GRID[k]), list(vmax = VMAX, ball0 = BALL[1], ball1 = BALL[2]))
pass_y <- !live_passes$intercepted
pass_z <- sapply(seq_len(nrow(GENERAL_GRID)), function(k) {
  qlogis(pmin(pmax(pass_control(seq_len(nrow(live_passes)), general_par(k)), 1e-4), 1 - 1e-4))
})
calibrate <- function(rows, k) coef(glm(pass_y[rows] ~ pass_z[rows, k], family = binomial()))
pick_general <- function(rows) {
  which.min(vapply(seq_len(nrow(GENERAL_GRID)), function(k) {
    b <- calibrate(rows, k)
    log_loss(pass_y[rows], plogis(b[1] + b[2] * pass_z[rows, k]))
  }, 0))
}
pass_held <- rbindlist(lapply(games, function(g) {
  tr <- which(live_passes$game_id != g)
  te <- which(live_passes$game_id == g)
  k <- pick_general(tr)
  b <- calibrate(tr, k)
  data.table(game_id = g, y = pass_y[te], base = mean(pass_y[tr]), p = plogis(b[1] + b[2] * pass_z[te, k]),
             raw = plogis(pass_z[te, k]), GENERAL_GRID[k])
}))
pass_validation <- summarise_gain(pass_held, "Pass completed: control at the spot the ball was taken (recalibrated)")
print(pass_validation)
print(pass_held[, .N, by = .(react, sigma, lambda)])
fwrite(rbind(rebound_validation, pass_validation), file.path(report, "validation_rebound.csv"))
general <- general_par(pick_general(seq_len(nrow(live_passes))))
str(general)
message(sprintf("Raw control at completed passes' destinations: median %.2f; at intercepted: %.2f",
                median(pass_held[y == TRUE, raw]), median(pass_held[y == FALSE, raw])))

# The offense should control the ball handler's own spot.
holder_pc <- vapply(seq_len(nrow(rel)), function(i) {
  pl <- lapply(RP[c("x", "y", "vx", "vy")], function(m) m[i, ])
  grid_control(pl, data.table(x = rel$bx[i], y = rel$by[i]), 0, general)
}, 0)
message(sprintf("Offense control at the ball: median %.2f, share above 0.5: %.2f", median(holder_pc), mean(holder_pc > 0.5)))

# ---- relevance: where the ball is 1.44 s later --------------------------------------------------

message("Control grids for relevance samples")
pc_grids <- t(vapply(seq_len(nrow(rel)), function(i) {
  pl <- lapply(RP[c("x", "y", "vx", "vy")], function(m) m[i, ])
  grid_control(pl, general_grid, ball_time(rel$bx[i], rel$by[i], general_grid$x, general_grid$y, general), general)
}, numeric(nrow(general_grid))))
nearest_cell <- function(x, y) {
  nx <- ceiling(2 * HALF_L / GENERAL_CELL)
  ny <- ceiling(2 * HALF_W / GENERAL_CELL)
  ix <- pmin(pmax(floor((x + HALF_L) / GENERAL_CELL), 0), nx - 1)
  iy <- pmin(pmax(floor((HALF_W - y) / GENERAL_CELL), 0), ny - 1)
  iy * nx + ix + 1L
}
rel[, cell := nearest_cell(tx, ty)]
hoop_d <- sqrt((general_grid$x - HOOP_X)^2 + general_grid$y^2)

D2 <- outer(rel$bx, general_grid$x, "-")^2 + outer(rel$by, general_grid$y, "-")^2
LPC <- log(pmax(pc_grids, 1e-4))
HOOP_PULL <- matrix(rep(hoop_d / 10, each = nrow(rel)), nrow(rel))

#' Mean log density of the observed targets, per square foot. The same sum as relevance(), over all
#' samples at once.
relevance_score <- function(rows, th, full = TRUE) {
  lw <- -D2[rows, , drop = FALSE] / (2 * exp(th[1])^2)
  if (full) lw <- lw + th[2] * LPC[rows, , drop = FALSE] - th[3] * HOOP_PULL[rows, , drop = FALSE]
  top <- row_max(lw)
  lse <- top + log(rowSums(exp(lw - top)))
  mean(lw[cbind(seq_along(rows), rel$cell[rows])] - lse - log(GENERAL_CELL^2))
}
fit_relevance <- function(rows, full = TRUE) {
  if (full) {
    opt <- optim(c(log(10), 1, 0), function(th) -relevance_score(rows, th), control = list(maxit = 300))
    list(spread = exp(opt$par[1]), tilt = opt$par[2], pull = opt$par[3], th = opt$par)
  } else {
    opt <- optimize(function(ls) -relevance_score(rows, c(ls, 0, 0), FALSE), c(log(2), log(40)))
    list(spread = exp(opt$minimum), tilt = 0, pull = 0, th = c(opt$minimum, 0, 0))
  }
}
rel_held <- rbindlist(lapply(games, function(g) {
  message("Relevance fold, game ", g)
  tr <- which(rel$game_id != g)
  te <- which(rel$game_id == g)
  full <- fit_relevance(tr)
  dist_only <- fit_relevance(tr, FALSE)
  data.table(game_id = g, n = length(te), distance_only = relevance_score(te, dist_only$th, FALSE),
             full = relevance_score(te, full$th), spread = full$spread, tilt = full$tilt, pull = full$pull)
}))
rel_held[, gain := full - distance_only]
print(rel_held)
fwrite(rel_held, file.path(report, "validation_relevance.csv"))
rel_final <- fit_relevance(seq_len(nrow(rel)))
message(sprintf("Relevance: gain in log density %.3f +/- %.3f per sample, better in %d of 10 games",
                mean(rel_held$gain), sd(rel_held$gain) / sqrt(10), sum(rel_held$gain > 0)))

# ---- court value: expected points of a shot from each spot ---------------------------------------

epv_tabs <- readRDS(file.path(app$root, "outputs", "cache", "epv", "tables.rds"))
epv_shots <- rbindlist(lapply(epv_tabs, `[[`, "shots"), fill = TRUE)[fouled == FALSE]
loc <- mgcv::gam(update(XFG_LOCATION, made ~ .), family = binomial(), data = epv_shots[, .(made = as.integer(made), x, y)])
vg <- copy(general_grid)
vg[, xfg := as.numeric(predict(loc, data.frame(x = pmax(x, 0), y = y), type = "response"))]
vg[, dist := sqrt((HOOP_X - x)^2 + y^2)]
vg[, pts := 2 + as.integer(dist > THREE_R - ARC_MARGIN | abs(y) > THREE_Y - ARC_MARGIN)]
vg[, value := fifelse(dist > SHOT_RANGE, 0, xfg * pts)]

#' Scoring opportunity at a frame: control x relevance x value, summed over the court.
obso <- t(vapply(seq_len(nrow(rel)), function(i) {
  cells <- pc_grids[i, ] * relevance(general_grid, rel$bx[i], rel$by[i], pc_grids[i, ], rel_final) * vg$value
  c(sum(cells), max(cells))
}, numeric(2)))
rel[, obso := obso[, 1]]
OBSO_REF <- unname(quantile(obso[, 2], 0.95))   # the site's colour scale: a cell this valuable is drawn at full strength
obso_check <- rel[, .(n = .N, obso = mean(obso), points_rest_of_possession = mean(pts)), by = .(quintile = cut(obso, quantile(obso, 0:5 / 5), include.lowest = TRUE))]
setorder(obso_check, quintile)
print(obso_check)
fwrite(obso_check, file.path(report, "check_scoring_opportunity.csv"))

# ---- save for the site -------------------------------------------------------------------------

#' A reference case for the site's tests: one frame's players and what this implementation gives.
reference_case <- function(i) {
  j <- samples$idx[i]
  pl <- lapply(SP[c("x", "y", "vx", "vy")], function(m) unname(m[j, ]))
  rb <- rebound_chance(pl, rebound_grid, samples$sx[i], samples$sy[i], samples$elapsed[i], final)
  probe <- c(1L, 50L, 200L, 400L)
  pc <- grid_control(pl, general_grid, ball_time(pl$x[1], pl$y[1], general_grid$x, general_grid$y, general), general)
  w <- relevance(general_grid, pl$x[1], pl$y[1], pc, rel_final)
  list(players = pl, sx = samples$sx[i], sy = samples$sy[i], elapsed = samples$elapsed[i], poreb = rb$p,
       rebound_cells = I(probe), rebound_pc = I(rb$pc[probe]), rebound_dens = I(rb$dens[probe]),
       general_cells = I(probe), general_pc = I(pc[probe]), relevance = I(w[probe]),
       obso = sum(pc * w * vg$value))
}
pick_cases <- c(which(samples$elapsed == 0)[c(3, 40)], which(samples$elapsed > 0.5)[7])

params <- list(
  built = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  court = list(halfL = HALF_L, halfW = HALF_W, hoopX = HOOP_X),
  integration = list(dt = CONTROL_DT, maxT = CONTROL_MAX_T, tol = CONTROL_TOL),
  general = c(general, list(cell = GENERAL_CELL)),
  rebound = c(final[c("react", "sigma", "lambda", "kappa", "vmax", "flight0", "flight1", "bounce0", "bounce1",
                      "team_share", "team_oreb", "land0", "land1", "shape", "focus", "floor")],
              list(cell = REBOUND_CELL, reach = REBOUND_REACH)),
  relevance = list(spread = rel_final$spread, tilt = rel_final$tilt, pull = rel_final$pull,
                   aheadSeconds = RELEVANCE_AHEAD / 25, obsoRef = OBSO_REF),
  value = list(cell = GENERAL_CELL, nx = ceiling(2 * HALF_L / GENERAL_CELL), ny = ceiling(2 * HALF_W / GENERAL_CELL),
               v = I(round(vg$value, 4)))
)
jsonlite::write_json(params, file.path(report, "params.json"), auto_unbox = TRUE, digits = NA, pretty = FALSE)
jsonlite::write_json(lapply(pick_cases, reference_case), file.path(report, "reference.json"), auto_unbox = TRUE, digits = NA)
message("Wrote ", file.path(report, "params.json"))
