# Step 05: the release-time spatial prior on synthetic rebound locations.

source(file.path(here, "R", "folds.R"))
source(file.path(here, "R", "spatial_prior.R"))
if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a)) b else a
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$step05
grid <- spatial_grid(cfg$domain)

# Synthetic misses in 4 games: rim shots rebound near the hoop; threes rebound long and on the far side from the shot.
synthetic_spatial <- function(n_games = 4L, per_game = 60L, seed = 9L) {
  set.seed(seed)
  n <- n_games * per_game
  d <- data.table(episode_id = sprintf("s%04d", seq_len(n)), game_id = rep(100L + seq_len(n_games), each = per_game),
                  shot_range = sample(c("rim", "three"), n, TRUE), side = sample(c(-1L, 1L), n, TRUE))
  d[, `:=`(tx = fifelse(shot_range == "rim", RIM_X - 3 + rnorm(.N, 0, 2), RIM_X - 14 + rnorm(.N, 0, 3)),
           ty = fifelse(shot_range == "rim", rnorm(.N, 0, 2), -side * 9 + rnorm(.N, 0, 3)))]
  d[, `:=`(tx = pmin(pmax(tx, 0.1), 45.9), ty = pmin(pmax(ty, -24.9), 24.9))]
  d[, cell := cell_index(grid, tx, ty)]
  fa <- data.table(episode_id = d$episode_id, game_id = d$game_id, outer_fold = d$game_id - 100L, game_date = "")
  list(d = d, fa = fa)
}

test_that("the grid covers the domain and cells are indexed like the map matrix", {
  expect_equal(c(grid$nx, grid$ny), c(46L, 50L))
  expect_equal(grid$area, 1)
  expect_equal(cell_index(grid, 0.5, -24.5), 1L)
  expect_equal(cell_index(grid, 45.5, 24.5), 46L * 50L)
  expect_true(is.na(cell_index(grid, -0.5, 0)))
  i <- cell_index(grid, 40.2, 3.7)
  expect_equal(c(grid$px[i], grid$py[i]), c(40.5, 3.5))
})

test_that("every map is a probability distribution over the domain", {
  s <- synthetic_spatial()
  fit <- fit_spatial(grid, s$d, 2, 0.5, 0.5, cfg)
  for (m in SPATIAL_MODELS) for (r in c("rim", "three")) for (sd in c(-1L, 1L)) {
    M <- predict_spatial(fit, m, r, sd)
    expect_equal(dim(M), c(grid$nx, grid$ny))
    expect_equal(sum(M), 1, tolerance = 1e-12, info = paste(m, r, sd))
    expect_true(all(M > 0), info = m)
  }
  k <- kde_mass(grid, RIM_X, 0, 1)
  expect_gt(k$inside, 0.99)                             # one point mid-court: almost all its mass inside
  expect_lt(kde_mass(grid, 45.9, 24.9, 2)$inside, 0.4)  # one point in the corner: most mass falls outside, renormalised
})

test_that("mirroring sends a shot from the other side to the mirrored map", {
  s <- synthetic_spatial()
  fit <- fit_spatial(grid, s$d, 2, 0, 1, cfg)
  a <- predict_spatial(fit, "side_range_kde", "three", 1L); b <- predict_spatial(fit, "side_range_kde", "three", -1L)
  expect_equal(b, mirror_map(a))
  # threes from y >= 0 rebound at negative y in the synthetic data: the map puts most mass there
  expect_gt(sum(a[, grid$cy < 0]), 0.7)
  expect_equal(shot_side(c(-0.1, 0, 3)), c(-1L, 1L, 1L))
})

test_that("scores: negative log density, highest-density coverage and area", {
  M <- matrix(0, grid$nx, grid$ny); M[1:4] <- c(0.4, 0.3, 0.2, 0.1)
  sc <- score_map(M, grid, 2L, c(0.5, 0.8))
  expect_equal(unname(sc["nll"]), -log(0.3)); expect_equal(unname(sc["u"]), 0.7)
  expect_equal(unname(sc[c("area_0.5", "area_0.8")]), c(2, 3))
  w <- wilson(8, 10); expect_true(w["lo"] < 0.8 && w["hi"] > 0.8)
})

test_that("zone bins put each zone's smoothed share on its cells", {
  s <- synthetic_spatial()
  Z <- zone_map(grid, s$d$tx, s$d$ty, unlist(cfg$zone_rings_ft), cfg$zone_sectors, cfg$zone_smoothing)
  expect_equal(sum(Z), 1, tolerance = 1e-12)
  expect_gt(Z[cell_index(grid, RIM_X - 2, 0)], Z[cell_index(grid, 5, 20)])
})

test_that("settings are chosen inside the training games and maps never read the held-out locations", {
  s <- synthetic_spatial(3L, 50L)
  r <- spatial_fold_predictions(grid, s$d[, .(episode_id, shot_range, side)], s$d, s$fa, cfg)
  expect_equal(r$selection[chosen == TRUE, .N, by = .(outer_fold, setting)][, unique(N)], 1L)
  expect_equal(uniqueN(r$scores$episode_id), nrow(s$d))
  # moving every held-out location of fold 1 changes none of fold 1's maps
  moved <- copy(s$d)[game_id == 101L, `:=`(tx = 5, ty = 20)][, cell := cell_index(grid, tx, ty)]
  r2 <- spatial_fold_predictions(grid, moved[, .(episode_id, shot_range, side)], moved, s$fa, cfg)
  ids <- s$d[game_id == 101L]$episode_id
  for (m in SPATIAL_MODELS) expect_equal(r2$maps[[m]][ids], r$maps[[m]][ids], info = m)
  # with conditional structure in the data, the side-aware map beats the pooled one on held-out locations
  agg <- r$scores[, .(nll = mean(nll)), by = model]
  expect_lt(agg[model == "side_range_kde"]$nll, agg[model == "pooled_kde"]$nll)
  expect_lt(agg[model == "pooled_kde"]$nll, agg[model == "uniform"]$nll)
})
