# Steps 2 and 4 of the rebounding framework: physical opportunity and collection, leave one game out.
#   Rscript src/rebounding/run_opportunity.R [--refit]
# Needs run_flight.R's folds. Scenes are cached per flight fold (outputs/cache/rebounding/scenes_{gameId}.rds,
# built with flight parameters fitted without that game) and model folds in opp_fold_{gameId}.rds, so an
# interrupted run resumes. Writes outputs/rebounding/collection/*.csv.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
load_opportunity_cpp(here, cache)
out_dir <- file.path(report, "collection")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

ACC_BASE <- list(react = 0.5, vmax = 18.1, sigma = 0.25, z_reach = 10.5, z_scale = 0.35, info_lag = 0.25, policy = 1L)
ACC_GRID <- CJ(policy = 0:2, react = c(0.5, 1.0))
SD_U <- c(0.15, 0.3, 0.6)
CHECKPOINTS <- names(OPP_CHECKPOINTS)

# Recorded rebound spots in the player frame, for the empirical-density benchmark.
reb_xy <- rbindlist(lapply(bundles, function(b) {
  s <- b$shot
  p <- if (s$grabbed %in% TRUE) b$players[frame == s$rf & canon == s$rcanon] else b$players[0]
  data.table(shot_id = b$id, rx_pl = if (nrow(p)) p$x[1] else NA_real_, ry_pl = if (nrow(p)) p$y[1] else NA_real_)
}))
eps <- merge(episodes[status == "eligible"], reb_xy, by = "shot_id")

#' Scenes of every bundle at both checkpoints, with the flight fit of one fold (or of all games).
scenes_for <- function(tag, fit, lib) {
  build_scenes(bundles, OPP_CHECKPOINTS, fit, lib, file.path(cache, sprintf("scenes_%s.rds", tag)), "--refit" %in% args)
}

valid <- function(sc) length(sc) > 0L

#' Every model of the ladder on one fold and checkpoint.
run_fold <- function(sc_all, g, cp) {
  ok <- vapply(sc_all, valid, NA)
  tr <- which(ok & bundle_game != g)
  te <- which(ok & bundle_game == g)
  s_tr <- sc_all[tr]; s_te <- sc_all[te]
  y_tr <- vapply(s_tr, `[[`, 0L, "y"); y_te <- vapply(s_te, `[[`, 0L, "y")
  players <- sort(unique(unlist(lapply(s_tr, function(sc) as.character(sc$pl$canon)))))
  # access physics: information policy and reaction time by training likelihood (no obstruction, no effects)
  grid <- copy(ACC_GRID)
  grid[, nll := mapply(function(pol, re) {
    acc <- modifyList(ACC_BASE, list(policy = pol, react = re))
    fit_cr(stack_scenes(s_tr, acc, players, FALSE), free_theta = c(TRUE, TRUE, FALSE, TRUE, TRUE, TRUE, TRUE))$value
  }, policy, react)]
  acc <- modifyList(ACC_BASE, as.list(grid[which.min(nll), .(policy, react)]))
  st_tr0 <- stack_scenes(s_tr, acc, players, FALSE); st_te0 <- stack_scenes(s_te, acc, players, FALSE)
  st_tr <- stack_scenes(s_tr, acc, players, TRUE); st_te <- stack_scenes(s_te, acc, players, TRUE)
  f3 <- fit_cr(st_tr0, free_theta = c(TRUE, TRUE, FALSE, TRUE, TRUE, TRUE, TRUE))
  f4 <- fit_cr(st_tr, start = f3$theta)
  f5 <- lapply(SD_U, function(sd) fit_cr(st_tr, sd_u = sd, start = f4$theta))
  names(f5) <- paste0("effects_sd", SD_U)
  tr_eps <- eps[shot_id %in% vapply(s_tr, `[[`, "", "id")]
  te_ids <- vapply(s_te, `[[`, "", "id")
  ranges <- eps$range[match(te_ids, eps$shot_id)]
  vor <- fit_voronoi(tr_eps)
  near <- fit_softmax(s_tr, feats_nearest, y_tr)
  geo <- fit_softmax(s_tr, feats_geometry, y_tr)
  preds <- c(list(team_prior = prior_probs(y_tr, length(te)), empirical_voronoi = predict_voronoi(vor, s_te, ranges),
                  nearest_to_forecast = predict_softmax(near, s_te), geometry_classifier = predict_softmax(geo, s_te),
                  access = predict_cr(st_te0, f3), access_obstruction = predict_cr(st_te, f4)),
             lapply(f5, function(f) predict_cr(st_te, f)))
  repeat_ep <- vapply(s_te, function(sc) any(as.character(sc$pl$canon) %in% players), NA)
  rebounder_seen <- vapply(s_te, function(sc) sc$y <= 10 && as.character(sc$pl$canon[sc$y]) %in% players, NA)
  scores <- rbindlist(lapply(names(preds), function(m) {
    colnames(preds[[m]]) <- OUTCOMES
    score_outcomes(preds[[m]], y_te)[, `:=`(model = m, shot_id = te_ids, game_id = g, checkpoint = cp,
                                           repeat_player = repeat_ep, rebounder_seen = rebounder_seen)]
  }))
  list(scores = scores, grid = grid[, game_id := g], acc = acc,
       fits = list(access = f3, access_obstruction = f4, effects = f5), preds = preds, te_ids = te_ids)
}

only <- sub("^--game=", "", grep("^--game=", args, value = TRUE))
for (g in if (length(only)) as.integer(only) else games) {
  path <- file.path(cache, sprintf("opp_fold_%s.rds", g))
  if (file.exists(path) && !"--refit" %in% args) next
  fl <- readRDS(file.path(cache, sprintf("flight_fold_%s.rds", g)))$fit
  sc <- scenes_for(g, fl, launch_rows_all[game_id != g])
  t0 <- Sys.time()
  res <- lapply(CHECKPOINTS, function(cp) run_fold(sc[[cp]], g, cp))
  names(res) <- CHECKPOINTS
  saveRDS(res, path)
  message(sprintf("Opportunity fold %s: %.0f s", g, as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

# ---- summaries -----------------------------------------------------------------------------------------

if (length(only)) quit(save = "no")
folds <- lapply(games, function(g) readRDS(file.path(cache, sprintf("opp_fold_%s.rds", g))))
scores <- rbindlist(lapply(folds, function(f) rbindlist(lapply(f, `[[`, "scores"))))
auc <- function(p, y) {
  r <- rank(p); n1 <- sum(y); n0 <- sum(!y)
  if (!n1 || !n0) return(NA_real_)
  (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
by_game <- scores[, .(n = .N, ll = mean(ll), ll_team = mean(ll_team)), by = .(checkpoint, model, game_id)]
base <- by_game[model == "team_prior", .(checkpoint, game_id, ll0 = ll, llt0 = ll_team)]
by_game <- merge(by_game, base, by = c("checkpoint", "game_id"))
summ <- scores[, .(n = .N, log_loss = mean(ll), team_log_loss = mean(ll_team), team_brier = mean(brier_team),
                   team_auc = auc(p_off, off), brier = mean(brier), unresolved = mean(unresolved)), by = .(checkpoint, model)]
gain <- by_game[, .(gain = mean(ll0 - ll), gain_se = sd(ll0 - ll) / sqrt(.N), team_gain = mean(llt0 - ll_team),
                    team_gain_se = sd(llt0 - ll_team) / sqrt(.N), games_better = sum(ll < ll0)), by = .(checkpoint, model)]
summ <- merge(summ, gain, by = c("checkpoint", "model"))
setorder(summ, checkpoint, log_loss)
fwrite(summ, file.path(out_dir, "validation_summary.csv"))
fwrite(by_game, file.path(out_dir, "validation_by_game.csv"))
# effects against the population model, for episodes with and without a player seen in training
eff <- scores[model %in% c("access_obstruction", "effects_sd0.3"),
              .(n = .N, log_loss = mean(ll)), by = .(checkpoint, model, rebounder_seen)]
fwrite(dcast(eff, checkpoint + rebounder_seen ~ model, value.var = c("log_loss", "n")), file.path(out_dir, "effects_new_vs_repeat.csv"))
cal <- scores[model == "access_obstruction", .(n = .N, predicted = mean(p_off), observed = mean(off)),
              by = .(checkpoint, band = cut(p_off, c(0, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 1), include.lowest = TRUE))]
setorder(cal, checkpoint, band)
fwrite(cal, file.path(out_dir, "calibration_team.csv"))
fwrite(rbindlist(lapply(seq_along(folds), function(k) rbindlist(lapply(CHECKPOINTS, function(cp) {
  f <- folds[[k]][[cp]]
  data.table(game_id = games[k], checkpoint = cp, policy = f$acc$policy, react = f$acc$react,
             t(f$fits$access_obstruction$theta))
})))), file.path(out_dir, "fold_parameters.csv"))
fwrite(rbindlist(lapply(folds, function(f) rbindlist(lapply(CHECKPOINTS, function(cp) f[[cp]]$grid[, checkpoint := cp])))),
       file.path(out_dir, "access_grid.csv"))
contested <- scores[model %in% c("team_prior", "access_obstruction", "geometry_classifier")]
top <- scores[model == "access_obstruction", .(shot_id, contested = p_top < median(p_top)), by = checkpoint]
contested <- merge(contested, top, by = c("shot_id", "checkpoint"))
fwrite(contested[, .(n = .N, log_loss = mean(ll), team_log_loss = mean(ll_team)), by = .(checkpoint, contested, model)][order(checkpoint, contested, log_loss)],
       file.path(out_dir, "contested_subsets.csv"))
print(summ)
