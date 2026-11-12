# Step 04: static geometry features, the grouped conditional logit and the binary OREB model on synthetic data.

source(file.path(here, "R", "folds.R"))
source(file.path(here, "R", "metrics.R"))
source(file.path(here, "R", "reference_baselines.R"))
source(file.path(here, "R", "static_geometry.R"))
source(file.path(here, "R", "conditional_choice.R"))
source(file.path(here, "R", "team_rebound.R"))

# n_games x per_game synthetic episodes: ten players around the attacked hoop, a shooter, and credited outcomes drawn
# from a known conditional logit (nearer the hoop and on defence is likelier; team awards at fixed constants).
synthetic_static <- function(n_games = 4L, per_game = 60L, beta = c(dist_hoop = -1.2, is_offense = -0.6), seed = 5L) {
  set.seed(seed)
  n <- n_games * per_game
  ids <- sprintf("shot-%05d", seq_len(n))
  pl <- rbindlist(lapply(seq_len(n), function(e) data.table(episode_id = ids[e], pid = 1000L * e + 1:10, off = rep(c(TRUE, FALSE), each = 5),
                                                            x = RIM_X - runif(10, 1, 24), y = runif(10, -18, 18), source_frame = 1L)))
  shooter <- pl[off == TRUE, .SD[sample(.N, 1)], by = episode_id]
  shot <- shooter[, .(episode_id, shooter_id = pid, sx = x, sy = y)]
  shot[, shot_dist := sqrt((sx - RIM_X)^2 + sy^2)][, `:=`(rim = shot_dist < 5, three = shot_dist > 22)]
  sf <- static_features(pl, shot)
  sc <- fit_scaler(sf, shot, ids)
  des <- choice_design(sf, shot, ids, sc)
  b <- setNames(rep(0, ncol(des$M)), colnames(des$M))
  b[names(beta)] <- beta
  b[c("team_off", "team_def")] <- c(-2.2, -2.0)
  P <- matrix(predict_clogit(list(beta = b), des)$probability, 12L)
  pick <- apply(P, 2, function(p) sample.int(12L, 1L, prob = p))
  rows <- des$rows[(seq_len(n) - 1L) * 12L + pick]
  side <- c(rep("off", 5L), rep("def", 5L), "off", "def")[pick]
  labels <- data.table(episode_id = ids, game_id = rep(100L + seq_len(n_games), each = per_game),
                       outcome_id = rows$outcome_id, y_off = side == "off")
  fa <- data.table(episode_id = ids, game_id = labels$game_id, outer_fold = labels$game_id - 100L, game_date = "")
  choice <- rbindlist(lapply(ids, function(e) data.table(episode_id = e,
                                                         outcome_id = c(as.character(pl[episode_id == e]$pid), "team_off", "team_def"),
                                                         kind = c(rep("player", 10L), "team", "team"), side = c(rep("off", 5L), rep("def", 5L), "off", "def"))))
  list(pl = pl, shot = shot, sf = sf, labels = labels, fa = fa, choice = choice, beta = b)
}

test_that("player features match hand calculations", {
  pl <- data.table(episode_id = "e", pid = 1:10, off = rep(c(TRUE, FALSE), each = 5), source_frame = 1L,
                   x = RIM_X - c(3, 10, 20, 6, 15, 2, 9, 18, 8, 25), y = c(0, 5, 0, -6, 10, 0, 4, 1, -6, 0))
  shot <- data.table(episode_id = "e", shooter_id = 3L, sx = RIM_X - 20, sy = 0, shot_dist = 20, rim = FALSE, three = FALSE)
  f <- static_features(pl, shot)
  p1 <- f[pid == 1]
  expect_equal(p1$dist_hoop, 3)
  expect_equal(p1$opp_inside, 1)                 # defender 6 at 2 ft
  expect_equal(p1$mates_inside, 0)
  expect_equal(p1$nearest_opp_dist, 1)
  expect_equal(p1$inside_gap, -1)
  expect_equal(p1$abs_rel_bearing, 0)            # on the shooter's line
  expect_equal(f[pid == 3]$is_shooter, 1)
  expect_equal(sum(f$is_shooter), 1)
  expect_equal(f[pid == 2]$abs_rel_bearing, abs(atan2(5, -10) - pi))
  expect_equal(sum(f$closeness_share), 1)
  near <- sqrt((pl$x - pl$x[1])^2 + (pl$y - pl$y[1])^2)
  expect_equal(p1$n_within_6, sum(near < 6) - 1)
  expect_equal(p1$dist_minus_mean, 3 - mean(sqrt((pl$x - RIM_X)^2 + pl$y^2)))
  expect_equal(p1$dist_x_shot, 3 * 20 / 25)
})

test_that("features are unchanged by rotating or mirroring the court about the hoop, and scale with units", {
  s <- synthetic_static(1L, 20L)
  base <- static_features(s$pl, s$shot)
  turn <- function(d, th, mirror = 1) {
    d <- copy(d)
    for (pr in list(c("x", "y"), c("sx", "sy"))) if (all(pr %in% names(d))) {
      dx <- d[[pr[1]]] - RIM_X
      dy <- mirror * d[[pr[2]]]
      set(d, j = pr[1], value = RIM_X + cos(th) * dx - sin(th) * dy)
      set(d, j = pr[2], value = sin(th) * dx + cos(th) * dy)
    }
    d
  }
  for (th in c(0.7, pi)) for (mi in c(1, -1)) {
    r <- static_features(turn(s$pl, th, mi), turn(s$shot, th, mi))
    expect_equal(r, base, tolerance = 1e-9, info = sprintf("theta %.1f mirror %d", th, mi))
  }
  m <- 0.3048
  pm <- copy(s$pl)[, `:=`(x = x * m, y = y * m)]
  sm <- copy(s$shot)[, `:=`(sx = sx * m, sy = sy * m, shot_dist = shot_dist * m)]
  fm <- static_features(pm, sm, hoop = c(RIM_X * m, 0), ft = m)
  for (f in c("opp_inside", "mates_inside", "abs_rel_bearing", "is_offense", "is_shooter", "shooter_x_rim", "n_within_6", "closeness_share"))
    expect_equal(fm[[f]], base[[f]], tolerance = 1e-9, info = f)
  for (f in c("dist_hoop", "dist_minus_mean", "nearest_opp_dist", "inside_gap", "dist_x_shot"))
    expect_equal(fm[[f]], base[[f]] * m, tolerance = 1e-9, info = f)
})

test_that("the conditional logit gradient is exact, its probabilities sum to one, and it recovers a known model", {
  s <- synthetic_static(5L, 200L)
  ids <- s$labels$episode_id
  sc <- fit_scaler(s$sf, s$shot, ids)
  des <- choice_design(s$sf, s$shot, ids, sc)
  y <- design_labels(des, s$labels)
  fit <- fit_clogit(des$M, y, lambda = 0.01)
  expect_true(fit$converged)
  # numerical gradient of the objective at a random point
  b0 <- rnorm(ncol(des$M), 0, 0.3)
  obj <- function(b) {
    U <- matrix(des$M %*% b, 12L)
    n <- ncol(U)
    -sum(U[cbind(y, 1:n)] - apply(U, 2, function(u) max(u) + log(sum(exp(u - max(u)))))) + 0.5 / 2 * sum((!colnames(des$M) %in% UNPENALISED) * b^2)
  }
  num <- vapply(seq_along(b0), function(i) {
    h <- 1e-5
    e <- replace(numeric(length(b0)), i, h)
    (obj(b0 + e) - obj(b0 - e)) / (2 * h)
  }, 0)
  U <- matrix(des$M %*% b0, 12L)
  P <- apply(U, 2, function(u) exp(u - max(u)) / sum(exp(u - max(u))))
  Y <- matrix(0, 12L, ncol(U))
  Y[cbind(y, seq_len(ncol(U)))] <- 1
  ana <- as.vector(crossprod(des$M, as.vector(P - Y))) + 0.5 * (!colnames(des$M) %in% UNPENALISED) * b0
  expect_equal(ana, num, tolerance = 1e-5)
  pr <- predict_clogit(fit, des)
  expect_true(all(abs(pr[, sum(probability), by = episode_id]$V1 - 1) < 1e-12))
  # 1,000 synthetic episodes. dist_hoop and dist_minus_mean differ by a per-episode constant, so the softmax splits a
  # distance effect between them: check what is identified, the fitted probabilities and the per-foot effect along a
  # player's distance with the other nine fixed (both terms move together, dist_x_shot with it).
  truth <- predict_clogit(list(beta = s$beta), des)$probability
  expect_lt(mean(abs(pr$probability - truth)), 0.02)
  sh <- s$shot$shot_dist[match(unique(des$rows$episode_id), s$shot$episode_id)]
  per_ft <- fit$beta["dist_hoop"] / sc$sd["dist_hoop"] + fit$beta["dist_minus_mean"] * 0.9 / sc$sd["dist_minus_mean"] +
    fit$beta["dist_x_shot"] * mean(sh) / 25 / sc$sd["dist_x_shot"]
  expect_equal(unname(per_ft), unname(s$beta["dist_hoop"] / sc$sd["dist_hoop"]), tolerance = 0.3)
  expect_equal(unname(fit$beta["is_offense"]), unname(s$beta["is_offense"]), tolerance = 0.25)
  expect_equal(unname(fit$beta[c("team_off", "team_def")]), c(-2.2, -2.0), tolerance = 0.3)
})

test_that("reordering players changes no player's probability; scalers and fits use training games only", {
  s <- synthetic_static(3L, 40L)
  tr <- s$fa[outer_fold != 1]$episode_id
  te <- s$fa[outer_fold == 1]$episode_id
  a <- clogit_fit_predict(s$sf, s$shot, s$labels, tr, te, 3, 500L)
  b <- clogit_fit_predict(s$sf[sample(.N)], s$shot[sample(.N)], s$labels, tr, te, 3, 500L)
  key <- c("episode_id", "outcome_id")
  expect_equal(setkeyv(b$pred, key)$probability, setkeyv(a$pred, key)$probability, tolerance = 1e-7)   # optimiser path only
  expect_equal(a$scaler$n_episodes, length(tr))
  poisoned <- copy(s$sf)[episode_id %in% te, dist_hoop := dist_hoop + 100]
  expect_equal(fit_scaler(poisoned, s$shot, tr), a$scaler)
  fp <- function(f, lab, split) {
    r <- clogit_fit_predict(f, s$shot, lab, split$train, split$test, 3, 500L)$pred
    r[, model := "clogit"][]
  }
  expect_true(label_invariance(fp, s$sf, s$labels, s$choice, fold_split(s$fa, 1L)))
})

test_that("nested lambda selection uses only the training games and every fold predicts its own game", {
  s <- synthetic_static(3L, 30L)
  r <- clogit_fold_predictions(s$sf, s$shot, s$labels, s$fa, s$choice, c(1, 10), 500L, 1e-12)
  expect_equal(r$lambda[, sum(selected), by = outer_fold]$V1, rep(1L, 3))
  expect_true(all(r$pred[, uniqueN(test_game), by = outer_fold]$V1 == 1L))
  expect_true(all(merge(unique(r$pred[, .(episode_id, outer_fold)]), s$fa, by = "episode_id")[, outer_fold.x == outer_fold.y]))
  r$pred[, `:=`(model = "clogit", time_point = "release")]
  expect_true(all(check_predictions(r$pred, s$choice)$ok))
})

test_that("box-out matchups minimise total distance and the OREB model is fitted correctly", {
  ax <- c(0, 10, 20, 30, 40)
  ay <- rep(0, 5)
  dx <- c(41, 31, 1, 21, 11)
  dy <- rep(1, 5)
  expect_equal(matchup_assignment(ax, ay, dx, dy), c(3L, 5L, 4L, 2L, 1L))
  expect_equal(nrow(PERM5), 120L)
  expect_equal(nrow(unique(PERM5)), 120L)
  s <- synthetic_static(4L, 100L)
  ef <- episode_features(s$pl, s$shot)
  expect_equal(nrow(ef), 400L)
  expect_true(all(ef$n_off_inside_matchup >= 0 & ef$n_off_inside_matchup <= 5))
  ids <- ef$episode_id
  fit <- fit_oreb(ef, s$labels, ids, lambda = 0.01)
  expect_true(fit$converged)
  # the intercept-only score equation: mean prediction equals the observed rate at the optimum
  expect_equal(mean(predict_oreb(fit, ef, ids)$p_off), mean(s$labels$y_off), tolerance = 1e-5)
  c0 <- constant_oreb_predictions(s$labels, s$fa, ids)
  expect_equal(c0[outer_fold == 2]$p_off[1], mean(s$labels[game_id != 102]$y_off))
  r <- oreb_fold_predictions(ef, s$labels, s$fa, c(1, 30), 500L)
  expect_equal(nrow(r$pred), 400L)
  expect_true(all(r$pred$p_off > 0 & r$pred$p_off < 1))
  expect_equal(binary_log_loss(0.25, 1), -log(0.25))
})
