# Step 09: particles, access features and the particle-mixture conditional logit on synthetic data.

for (f in c("bundle.R", "folds.R", "metrics.R", "static_geometry.R", "conditional_choice.R", "spatial_prior.R", "physics.R",
            "particle_filter.R", "reach.R", "particle_integration.R", "dynamic_choice.R")) source(file.path(here, "R", f))
rp <- list(reaction_s = 0.2, catch_radius_ft = 2, standing_reach_ft = 8.5, jump_reach_ft = 11, takeoff_s = 0.25, v_max = 15)

# n synthetic episodes with ten players and K particles near the hoop; outcomes drawn from a known mixture model
synthetic_dyn <- function(n = 300L, K = 6L, b_acc = 1.5, seed = 4L) {
  set.seed(seed)
  ids <- sprintf("e%04d", seq_len(n))
  pl <- rbindlist(lapply(seq_len(n), function(e) data.table(episode_id = ids[e], pid = 100L * e + 1:10, off = rep(c(TRUE, FALSE), each = 5),
    x = RIM_X - runif(10, 1, 22), y = runif(10, -15, 15), vx = rnorm(10, 0, 4), vy = rnorm(10, 0, 4), source_frame = 1L)))
  shot <- pl[off == TRUE, .SD[1], by = episode_id][, .(episode_id, shooter_id = pid, sx = x, sy = y)]
  shot[, `:=`(shot_dist = sqrt((sx - RIM_X)^2 + sy^2), rim = FALSE, three = FALSE)]
  sf <- static_features(pl[, .(episode_id, pid, off, x, y, source_frame)], shot)
  acc <- rbindlist(lapply(ids, function(e) {
    parts <- data.table(k = seq_len(K), bx = RIM_X - runif(K, 0, 10), by = runif(K, -8, 8), z = runif(K, 5, 10))
    cbind(episode_id = e, access_features(pl[episode_id == e], parts, 1.0, rp))
  }))
  sc <- fit_scaler(sf, shot, ids); asc <- fit_access_scaler(acc, ids)
  des <- dyn_design(sf, acc, shot, ids, sc, asc)
  b <- setNames(rep(0, ncol(des$M)), colnames(des$M)); b["access_margin"] <- b_acc; b[c("team_off", "team_def")] <- -2.5
  p <- predict_dyn(list(beta = b), des)
  lab <- p[, .(outcome_id = sample(outcome_id, 1, prob = probability)), by = episode_id]
  off_ids <- as.character(pl[off == TRUE]$pid)
  lab[, `:=`(y_off = outcome_id %in% c(off_ids, "team_off"), game_id = 1L)]
  list(pl = pl, shot = shot, sf = sf, acc = acc, labels = lab, ids = ids, sc = sc, asc = asc, beta = b)
}

test_that("one particle and no access terms reduce the mixture to the Step 04 conditional logit", {
  s <- synthetic_dyn(150L, 1L)
  des <- dyn_design(s$sf, s$acc, s$shot, s$ids, s$sc, s$asc, features = PLAYER_FEATURES)
  f1 <- fit_dyn(des, dyn_labels(des, s$labels), 3)
  d4 <- choice_design(s$sf, s$shot, s$ids, s$sc)
  f4 <- fit_clogit(d4$M, design_labels(d4, s$labels), 3)
  expect_equal(unname(f1$beta[names(f4$beta)]), unname(f4$beta), tolerance = 1e-5)
})

test_that("the mixture gradient is exact and probabilities are a distribution that ignores row order", {
  s <- synthetic_dyn(80L, 4L)
  des <- dyn_design(s$sf, s$acc, s$shot, s$ids, s$sc, s$asc)
  y <- dyn_labels(des, s$labels)
  b0 <- rnorm(ncol(des$M), 0, 0.3); lam <- 0.7
  obj <- function(b) {
    p <- predict_dyn(list(beta = setNames(b, colnames(des$M))), des)
    py <- merge(p, s$labels[, .(episode_id, outcome_id)], by = c("episode_id", "outcome_id"))$probability
    -sum(log(py)) + lam / 2 * sum((!colnames(des$M) %in% UNPENALISED) * b^2)
  }
  num <- vapply(seq_along(b0), function(i) { e <- replace(numeric(length(b0)), i, 1e-5); (obj(b0 + e) - obj(b0 - e)) / 2e-5 }, 0)
  env_g <- local({ M <- des$M; nb <- nrow(des$blocks); ep <- match(des$blocks$episode_id, unique(des$blocks$episode_id))
    U <- matrix(M %*% b0, 12L); P <- apply(U, 2, function(u) exp(u - max(u)) / sum(exp(u - max(u))))
    Y <- matrix(0, 12L, nb); Y[cbind(y, seq_len(nb))] <- 1; py <- P[cbind(y, seq_len(nb))]; num_ <- des$w * py
    r <- num_ / as.vector(rowsum(num_, ep))[ep]
    -as.vector(crossprod(M, as.vector(sweep(Y - P, 2, r, `*`)))) + lam * (!colnames(M) %in% UNPENALISED) * b0 })
  expect_equal(env_g, num, tolerance = 1e-5)
  fit <- fit_dyn(des, y, lam)
  p <- predict_dyn(fit, des)
  expect_true(all(abs(p[, sum(probability), by = episode_id]$V1 - 1) < 1e-12))
  shuf <- dyn_design(s$sf[sample(.N)], s$acc[sample(.N)], s$shot, s$ids, s$sc, s$asc)
  p2 <- predict_dyn(fit, shuf)
  key <- c("episode_id", "outcome_id")
  expect_equal(setkeyv(p2, key)$probability, setkeyv(copy(p), key)$probability, tolerance = 1e-12)
})

test_that("a known access effect is recovered and helps", {
  s <- synthetic_dyn(400L, 6L, b_acc = 1.5)
  des <- dyn_design(s$sf, s$acc, s$shot, s$ids, s$sc, s$asc)
  fit <- fit_dyn(des, dyn_labels(des, s$labels), 1)
  expect_equal(unname(fit$beta["access_margin"]), 1.5, tolerance = 0.35)
  st <- dyn_design(s$sf, s$acc, s$shot, s$ids, s$sc, s$asc, features = PLAYER_FEATURES)
  f0 <- fit_dyn(st, dyn_labels(st, s$labels), 1)
  expect_lt(fit$objective, f0$objective)
})

test_that("access: margins, the best player per particle, and nobody best when the ball is out of reach", {
  st <- data.table(pid = 1:3, x = c(40, 30, 20), y = 0, vx = 0, vy = 0)
  parts <- data.table(k = 1:2, bx = c(40, 40), by = 0, z = c(7, 13))
  a <- access_features(st, parts, 1.0, rp)
  expect_equal(a[k == 1 & pid == 1]$access_margin, 1.0 - rp$reaction_s)
  expect_equal(a[k == 1, sum(best_access)], 1); expect_equal(a[k == 1 & best_access == 1]$pid, 1L)
  expect_equal(a[k == 2, sum(best_access)], 0); expect_true(all(a[k == 2]$access_margin == -1.5))
  grid <- spatial_grid(list(x_ft = c(0, 46), y_ft = c(-25, 25), cell_ft = 1))
  M <- matrix(0, grid$nx, grid$ny); M[cell_index(grid, 40.3, 2.6)] <- 1
  set.seed(1); pm <- particles_from_map(M, grid, 20L)
  expect_true(all(pm$bx >= 40 & pm$bx <= 41 & pm$by >= 2 & pm$by <= 3))
})

test_that("predict_rebound returns a coherent distribution and reads inputs only through the caller's function", {
  s <- synthetic_dyn(120L, 4L)
  des <- dyn_design(s$sf, s$acc, s$shot, s$ids, s$sc, s$asc)
  fit <- fit_dyn(des, dyn_labels(des, s$labels), 3)
  models <- list(release = list(fit = fit, scaler = s$sc, access_scaler = s$asc, version = "test"))
  calls <- 0L
  inputs_at <- function(id, t) { calls <<- calls + 1L
    list(kind = "release", sf = s$sf[episode_id == id], acc = s$acc[episode_id == id], shot = s$shot, flags = character()) }
  r <- predict_rebound(s$ids[3], 500L, inputs_at, models)
  expect_equal(calls, 1L)
  expect_equal(sum(r$players$p_player) + sum(r$non_player$probability), 1, tolerance = 1e-12)
  expect_equal(r$p_offense, sum(r$players[off == TRUE]$p_player) + r$non_player[outcome == "team_off"]$probability)
  expect_equal(nrow(r$players), 10L)
  expect_error(predict_rebound(s$ids[3], 500L, inputs_at, models, history_only = FALSE))
})
