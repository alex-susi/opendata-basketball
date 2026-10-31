# Step 05 of the rebounding manual: a release-time probability map of where the rebound will be credited, over the
# attacked half court in 1 ft cells. Inputs at release are the shot range and the side the shot comes from; the
# realised location is only ever a training target or a score. Settings: config/experiment.yaml (step05).
#
# The target is the credited rebounder's position, not the ball's free landing point (Step 02 BLOCKED). Kernel
# heatmaps of rebound locations and player Voronoi cells follow TrueImpactShotCharts (MIT, code/util/VisUtil.py and
# StatsUtil.py; ideas only, written independently). Requires geometry.R (RIM_X), folds.R.

#' The cell grid of the domain: edges, centres and the hoop-relative geometry of every cell.
spatial_grid <- function(dom) {
  xe <- seq(dom$x_ft[1], dom$x_ft[2], by = dom$cell_ft)
  ye <- seq(dom$y_ft[1], dom$y_ft[2], by = dom$cell_ft)
  cx <- (xe[-1] + xe[-length(xe)]) / 2
  cy <- (ye[-1] + ye[-length(ye)]) / 2
  list(xe = xe, ye = ye, cx = cx, cy = cy, nx = length(cx), ny = length(cy), area = dom$cell_ft^2,
       px = rep(cx, times = length(cy)), py = rep(cy, each = length(cx)))   # cell centres, column-major like a nx x ny matrix
}

#' Linear (column-major) index of the cell holding each point; NA outside the domain.
cell_index <- function(grid, x, y) {
  ix <- findInterval(x, grid$xe, rightmost.closed = TRUE)
  iy <- findInterval(y, grid$ye, rightmost.closed = TRUE)
  ok <- ix >= 1 & ix <= grid$nx & iy >= 1 & iy <= grid$ny
  ifelse(ok, ix + (iy - 1L) * grid$nx, NA_integer_)
}

#' Gaussian kernel density with each point's mass integrated exactly over every cell (separable in x and y).
#' @return list(M = nx x ny matrix summing to 1 over the domain, inside = share of the mass that fell in the domain).
kde_mass <- function(grid, x, y, h) {
  if (!length(x)) return(list(M = matrix(1 / (grid$nx * grid$ny), grid$nx, grid$ny), inside = 1))
  A <- pnorm(outer(grid$xe[-1], x, `-`) / h) - pnorm(outer(grid$xe[-length(grid$xe)], x, `-`) / h)
  B <- pnorm(outer(grid$ye[-1], y, `-`) / h) - pnorm(outer(grid$ye[-length(grid$ye)], y, `-`) / h)
  M <- A %*% t(B) / length(x)
  inside <- sum(M)
  list(M = M / inside, inside = inside)
}

uniform_map <- function(grid) matrix(1 / (grid$nx * grid$ny), grid$nx, grid$ny)

#' Hoop-relative zones: distance rings x equal angle sectors; each zone gets its smoothed share of the training
#' locations, spread evenly over its cells. Zones with no cell in the domain get nothing.
zone_map <- function(grid, x, y, rings, sectors, a) {
  zone_of <- function(px, py) {
    r <- findInterval(sqrt((px - RIM_X)^2 + py^2), rings, rightmost.closed = TRUE)
    s <- findInterval((atan2(py, px - RIM_X) + pi) / (2 * pi) * sectors, 0:sectors, rightmost.closed = TRUE)
    (r - 1L) * sectors + pmin(s, sectors)
  }
  zc <- zone_of(grid$px, grid$py)
  zones <- sort(unique(zc))
  cnt <- tabulate(match(zone_of(x, y), zones), length(zones))
  share <- (cnt + a) / (sum(cnt) + length(zones) * a)
  ncell <- tabulate(match(zc, zones), length(zones))
  matrix(share[match(zc, zones)] / ncell[match(zc, zones)], grid$nx, grid$ny)
}

#' The shot side used for mirroring: +1 when the shooter's y at release is >= 0, else -1.
shot_side <- function(sy) ifelse(sy >= 0, 1L, -1L)

#' Mirror a map left to right (y to -y); the grid's y edges are symmetric about 0.
mirror_map <- function(M) M[, ncol(M):1, drop = FALSE]

#' Fit every spatial model on training targets (tx, ty, shot_range, side) with bandwidth h and weights.
fit_spatial <- function(grid, tr, h, w_range, w_side, cfg) {
  ranges <- sort(unique(tr$shot_range))
  pooled <- kde_mass(grid, tr$tx, tr$ty, h)
  by_range <- setNames(lapply(ranges, function(r) kde_mass(grid, tr[shot_range == r]$tx, tr[shot_range == r]$ty, h)$M), ranges)
  by_side <- setNames(lapply(ranges, function(r) {
    d <- tr[shot_range == r]
    kde_mass(grid, d$tx, d$ty * d$side, h)$M                              # every shot seen from the y >= 0 side
  }), ranges)
  list(h = h, w_range = w_range, w_side = w_side, eps = cfg$epsilon_uniform, uniform = uniform_map(grid),
       pooled = pooled$M, pooled_inside = pooled$inside, by_range = by_range, by_side = by_side,
       zone = zone_map(grid, tr$tx, tr$ty, unlist(cfg$zone_rings_ft), cfg$zone_sectors, cfg$zone_smoothing),
       n_train = nrow(tr))
}

SPATIAL_MODELS <- c("uniform", "zone_bins", "pooled_kde", "range_kde", "side_range_kde")

#' The map of one model for a shot of the given range and side (a range missing from training uses the pooled map).
predict_spatial <- function(fit, model, shot_range, side) {
  mix <- function(M) (1 - fit$eps) * M + fit$eps * fit$uniform
  switch(model,
    uniform = fit$uniform,
    zone_bins = fit$zone,
    pooled_kde = mix(fit$pooled),
    range_kde = mix((1 - fit$w_range) * fit$pooled + fit$w_range * (fit$by_range[[shot_range]] %||% fit$pooled)),
    side_range_kde = {
      S <- fit$by_side[[shot_range]] %||% fit$pooled
      if (side < 0 && !is.null(fit$by_side[[shot_range]])) S <- mirror_map(S)
      mix((1 - fit$w_side) * fit$pooled + fit$w_side * S)
    },
    stop("unknown spatial model ", model))
}

#' Scores of one map at one location: negative log density per square foot; u = probability of the cells at least
#' as dense as the target's (the location is inside the level-L highest-density region when u <= L); and the area of
#' each highest-density region.
score_map <- function(M, grid, cell, levels) {
  p <- M[cell]
  srt <- sort(as.vector(M), decreasing = TRUE)
  cs <- cumsum(srt)
  c(nll = -log(p / grid$area), u = sum(M[M >= p]),
    setNames(vapply(levels, function(L) which(cs >= L - 1e-12)[1] * grid$area, 0), paste0("area_", levels)))
}

#' Wilson interval for a proportion.
wilson <- function(k, n, z = 1.96) {
  p <- k / n; d <- 1 + z^2 / n
  c <- (p + z^2 / (2 * n)) / d; h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  c(lo = max(0, min(p, c - h)), hi = min(1, max(p, c + h)))   # clamped: rounding can leave 0 or 1 just outside
}

#' Mean negative log density of held-out targets for a list of (train, test) splits under one setting.
inner_nll <- function(grid, targets, splits, h, w_range, w_side, cfg, model) {
  mean(unlist(lapply(splits, function(f) {
    tr <- targets[episode_id %in% f$train]; te <- targets[episode_id %in% f$test]
    if (!nrow(te)) return(NULL)
    fit <- fit_spatial(grid, tr, h, w_range, w_side, cfg)
    vapply(seq_len(nrow(te)), function(i)
      -log(predict_spatial(fit, model, te$shot_range[i], te$side[i])[te$cell[i]] / grid$area), 0)
  })))
}

#' Settings chosen inside the training games: bandwidth for pooled_kde, then the weights of range_kde and
#' side_range_kde with that bandwidth; ties go to the smoother setting.
select_spatial <- function(grid, targets, splits, cfg) {
  hs <- unlist(cfg$bandwidth_grid_ft); ws <- unlist(cfg$weight_grid)
  hh <- data.table(h = hs, nll = vapply(hs, function(h) inner_nll(grid, targets, splits, h, 0, 0, cfg, "pooled_kde"), 0))
  h <- hh[nll == min(nll)][, max(h)]
  wr <- data.table(w = ws, nll = vapply(ws, function(w) inner_nll(grid, targets, splits, h, w, 0, cfg, "range_kde"), 0))
  wsd <- data.table(w = ws, nll = vapply(ws, function(w) inner_nll(grid, targets, splits, h, 0, w, cfg, "side_range_kde"), 0))
  list(h = h, w_range = wr[nll == min(nll)][, min(w)], w_side = wsd[nll == min(nll)][, min(w)],
       log = rbind(hh[, .(setting = "bandwidth", value = h, inner_nll = nll)],
                   wr[, .(setting = "w_range", value = w, inner_nll = nll)],
                   wsd[, .(setting = "w_side", value = w, inner_nll = nll)]))
}

#' Outer-fold maps and scores. `episodes`: every eligible episode (episode_id, shot_range, side); `targets`: those with a
#' credited location (episode_id, tx, ty, cell, shot_range, side). Maps exist for every episode, scores for targets.
spatial_fold_predictions <- function(grid, episodes, targets, fa, cfg) {
  levels <- unlist(cfg$scores$coverage_levels)
  scores <- list(); maps <- list(); sel <- list()
  for (k in sort(unique(fa$outer_fold))) {
    s <- fold_split(fa, k)
    inner <- lapply(s$inner, function(f) list(train = intersect(f$train, targets$episode_id), test = f$test))
    ch <- select_spatial(grid, targets, inner, cfg)
    fit <- fit_spatial(grid, targets[episode_id %in% s$train], ch$h, ch$w_range, ch$w_side, cfg)
    sel[[length(sel) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, ch$log,
                                     chosen = c(ch$log$setting == "bandwidth" & ch$log$value == ch$h) |
                                       (ch$log$setting == "w_range" & ch$log$value == ch$w_range) |
                                       (ch$log$setting == "w_side" & ch$log$value == ch$w_side),
                                     pooled_inside = fit$pooled_inside, n_train = fit$n_train)
    te <- episodes[episode_id %in% s$test]
    for (m in SPATIAL_MODELS) {
      mp <- lapply(seq_len(nrow(te)), function(i) predict_spatial(fit, m, te$shot_range[i], te$side[i]))
      names(mp) <- te$episode_id
      maps[[m]] <- c(maps[[m]], mp)
      tt <- targets[episode_id %in% te$episode_id]
      if (nrow(tt)) scores[[length(scores) + 1L]] <- cbind(
        data.table(model = m, outer_fold = k, test_game = s$test_game, episode_id = tt$episode_id),
        as.data.table(t(vapply(seq_len(nrow(tt)), function(i) score_map(mp[[tt$episode_id[i]]], grid, tt$cell[i], levels),
                               numeric(2L + length(levels))))))
    }
  }
  list(scores = rbindlist(scores), maps = maps, selection = rbindlist(sel))
}

#' Half-court lines in the attack frame (FIBA, feet): baseline, sidelines, key, free-throw circle, three-point line,
#' restricted area, backboard and ring.
draw_half_court <- function(col = "grey35") {
  base <- COURT_HALF_L; side <- COURT_HALF_W
  key_w <- 4.9 * FT_PER_M / 2; key_x <- base - 5.8 * FT_PER_M
  rect(0, -side, base, side, border = col)
  rect(key_x, -key_w, base, key_w, border = col)
  th <- seq(-pi / 2, pi / 2, length.out = 60); r_ft <- 1.8 * FT_PER_M
  lines(key_x - r_ft * cos(th), r_ft * sin(th), col = col)
  r3 <- 6.75 * FT_PER_M; y3 <- side - 0.9 * FT_PER_M
  a <- asin(y3 / r3); th3 <- seq(-a, a, length.out = 80)
  lines(RIM_X - r3 * cos(th3), r3 * sin(th3), col = col)
  segments(RIM_X - r3 * cos(a), c(-y3, y3), base, c(-y3, y3), col = col)
  thr <- seq(-pi / 2, pi / 2, length.out = 40); rr <- 1.25 * FT_PER_M
  lines(RIM_X - rr * cos(thr), rr * sin(thr), col = col)
  segments(BOARD_X, -BOARD_HALF_W, BOARD_X, BOARD_HALF_W, col = col, lwd = 2)
  symbols(RIM_X, 0, circles = RIM_R, inches = FALSE, add = TRUE, fg = col)
}

#' One map on the half court, with the cells of the given highest-density regions outlined.
draw_map <- function(M, grid, main = "", levels = c(0.5, 0.8, 0.95), zmax = NULL) {
  zmax <- zmax %||% max(M)
  image(grid$cx, grid$cy, pmin(M, zmax), col = hcl.colors(40, "Blues 3", rev = TRUE), zlim = c(0, zmax), asp = 1,
        xlab = "", ylab = "", axes = FALSE, main = main, cex.main = 0.85)
  srt <- sort(as.vector(M), decreasing = TRUE); cs <- cumsum(srt)
  thr <- vapply(levels, function(L) srt[which(cs >= L - 1e-12)[1]], 0)
  contour(grid$cx, grid$cy, M, levels = thr, labels = paste0(levels * 100, "%"), add = TRUE, col = "grey20", lwd = 0.8,
          labcex = 0.55, drawlabels = TRUE)
  draw_half_court()
}
