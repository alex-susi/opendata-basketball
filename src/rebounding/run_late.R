# Late forecasts: the collection model for the moments after the ball reaches the rim, leave one game out.
#   Rscript src/rebounding/run_late.R [--game=<id>] [--refit]
# Needs run_flight.R and run_opportunity.R (the held-out rim model each fold is compared with). Late scenes are
# cached per flight fold (outputs/cache/rebounding/late_scenes_{gameId}.rds) and model folds in
# late_fold_{gameId}.rds; --game=<id> runs one fold (folds can run as parallel processes). Without --game it
# summarises the folds, fits the all-games model the site uses (late_final.rds) and writes outputs/rebounding/late/.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
load_opportunity_cpp(here, cache)
out_dir <- file.path(report, "late")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
refit <- "--refit" %in% args

#' Probabilities over the twelve outcomes with the unresolved share removed, as score_outcomes() scores them.
resolved <- function(P) P[, 1:12, drop = FALSE] / pmax(1e-12, 1 - P[, 13])

#' Every model on one held-out game: the current site model (that fold's rim fit), benchmarks, and the late ladder.
run_fold <- function(g) {
  fl <- readRDS(file.path(cache, sprintf("flight_fold_%s.rds", g)))$fit
  sc <- build_late_scenes(bundles, fl, launch_rows_all[game_id != g], file.path(cache, sprintf("late_scenes_%s.rds", g)), refit)
  gid <- vapply(sc, `[[`, 0L, "game_id")
  tr <- sc[gid != g]; te <- sc[gid == g]
  rim <- readRDS(file.path(cache, sprintf("opp_fold_%s.rds", g)))$rim
  ch <- choose_late_access(tr, rim$acc, seed = g %% 1000L)
  st_tr <- stack_late(tr, ch$acc)
  st_te <- stack_late(te, ch$acc)
  ladder <- fit_late_ladder(st_tr)
  rm(st_tr); gc()
  y_tr <- vapply(tr, `[[`, 0L, "y"); y_te <- vapply(te, `[[`, 0L, "y")
  near <- fit_softmax(tr, feats_nearest, y_tr)
  geo <- fit_softmax(tr, feats_geometry, y_tr)
  preds <- c(list(team_prior = prior_probs(y_tr, length(te)),
                  current_site = predict_cr(stack_scenes(te, rim$acc, character(0), TRUE), rim$fits$access_obstruction),
                  nearest_to_forecast = predict_softmax(near, te), geometry_classifier = predict_softmax(geo, te)),
             lapply(ladder, function(f) predict_late(st_te, f)))
  ids <- vapply(te, `[[`, "", "id"); tau <- vapply(te, `[[`, 0, "tau")
  scores <- rbindlist(lapply(names(preds), function(m) {
    colnames(preds[[m]]) <- OUTCOMES
    Q <- resolved(preds[[m]])
    score_outcomes(preds[[m]], y_te)[, `:=`(model = m, shot_id = ids, game_id = g, tau = tau, y = y_te,
                                            p_collector = ifelse(y_te <= 10, Q[cbind(seq_along(y_te), pmin(y_te, 12L))], NA_real_))]
  }))
  list(scores = scores, preds = preds, y = y_te, tau = tau, ids = ids, acc = ch$acc, grid = ch$grid[, game_id := g],
       fits = ladder, n_train = length(tr))
}

only <- sub("^--game=", "", grep("^--game=", args, value = TRUE))
for (g in if (length(only)) as.integer(only) else games) {
  path <- file.path(cache, sprintf("late_fold_%s.rds", g))
  if (file.exists(path) && !refit) next
  t0 <- Sys.time()
  saveRDS(run_fold(g), path)
  message(sprintf("Late fold %s: %.0f s", g, as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}
if (length(only)) quit(save = "no")

# ---- held-out summaries -----------------------------------------------------------------------------------

folds <- lapply(games, function(g) readRDS(file.path(cache, sprintf("late_fold_%s.rds", g))))
scores <- rbindlist(lapply(folds, `[[`, "scores"))
MODELS <- c("team_prior", "current_site", "nearest_to_forecast", "geometry_classifier", "late_refit", "late_time", "late_full")
fwrite(scores[model == "team_prior", .(scenes = .N, misses = uniqueN(shot_id)), by = tau][order(tau)], file.path(out_dir, "scenes_by_tau.csv"))

by_game <- scores[, .(n = .N, ll = mean(ll)), by = .(model, game_id)]
vs <- function(ref) {
  m <- merge(by_game, by_game[model == ref, .(game_id, ll0 = ll)], by = "game_id")
  m[, .(gain = mean(ll0 - ll), gain_se = sd(ll0 - ll) / sqrt(.N), games_better = sum(ll < ll0 - 1e-12)), by = model]
}
summ <- scores[, .(n = .N, log_loss = mean(ll), team_log_loss = mean(ll_team), brier = mean(brier),
                   collector_chance = mean(p_collector, na.rm = TRUE), top_median = median(p_top)), by = model]
summ <- merge(summ, setnames(vs("team_prior"), c("gain", "gain_se", "games_better"), c("gain_prior", "gain_prior_se", "better_than_prior")), by = "model")
summ <- merge(summ, setnames(vs("current_site"), c("gain", "gain_se", "games_better"), c("gain_current", "gain_current_se", "better_than_current")), by = "model")
setorder(summ, log_loss)
fwrite(summ, file.path(out_dir, "validation_summary.csv"))
fwrite(by_game, file.path(out_dir, "validation_by_game.csv"))

by_tau <- scores[, .(n = .N, log_loss = mean(ll), team_log_loss = mean(ll_team), collector_chance = mean(p_collector, na.rm = TRUE),
                     top_median = median(p_top), top_q90 = quantile(p_top, 0.9)), by = .(model, tau)]
setorder(by_tau, model, tau)
fwrite(by_tau, file.path(out_dir, "validation_by_tau.csv"))

# player-level calibration: every player's predicted chance against whether he collected
cal <- rbindlist(lapply(folds, function(f) rbindlist(lapply(c("current_site", "late_full"), function(m) {
  Q <- resolved(f$preds[[m]])
  data.table(model = m, p = as.vector(Q[, 1:10]), hit = as.vector(outer(f$y, 1:10, `==`)))
}))))
cal <- cal[, .(n = .N, predicted = mean(p), observed = mean(hit)),
           by = .(model, band = cut(p, c(0, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1), include.lowest = TRUE))]
setorder(cal, model, band)
fwrite(cal, file.path(out_dir, "calibration_players.csv"))

fwrite(rbindlist(lapply(seq_along(folds), function(k) {
  f <- folds[[k]]
  data.table(game_id = games[k], policy = f$acc$policy, react = f$acc$react, t(f$fits$late_full$theta))
})), file.path(out_dir, "fold_parameters.csv"))
fwrite(rbindlist(lapply(folds, `[[`, "grid")), file.path(out_dir, "access_grid.csv"))

full <- summ[model == "late_full"]
used <- full$gain_current > 0 && full$better_than_current >= 6L
fwrite(data.table(model = "late_full", gain_over_current = full$gain_current, se = full$gain_current_se,
                  games_better = full$better_than_current, used_on_site = used,
                  rule = "used when its held-out log loss beats the current site model on average and in at least 6 of 10 games"),
       file.path(out_dir, "decision.csv"))

# ---- the all-games fit the site uses ----------------------------------------------------------------------

final <- readRDS(file.path(cache, "final_fits.rds"))
flight_all <- readRDS(file.path(cache, "flight_params_all.rds"))
final_path <- file.path(cache, "late_final.rds")
if (!file.exists(final_path) || refit) {
  sc_all <- build_late_scenes(bundles, flight_all, launch_rows_all, file.path(cache, "late_scenes_all.rds"), refit)
  ch <- choose_late_access(sc_all, final$rim$acc, seed = 1L)
  ladder <- fit_late_ladder(stack_late(sc_all, ch$acc))
  saveRDS(list(acc = ch$acc, grid = ch$grid, fits = ladder, fit = ladder$late_full, used = used, scenes = length(sc_all)), final_path)
}
late_final <- readRDS(final_path)
late_final$used <- used
saveRDS(late_final, final_path)
fwrite(data.table(term = c("policy", "react", THETA_LATE), value = c(late_final$acc$policy, late_final$acc$react, late_final$fit$theta)),
       file.path(out_dir, "final_parameters.csv"))

# ---- one worked example: the Girona-Burgos miss Samuels rebounded (shot-114099-1-19) ----------------------

ex_id <- "shot-114099-1-19"
i <- which(vapply(bundles, `[[`, "", "id") == ex_id)
b <- bundles[[i]]
tm <- bundle_times(b)
cs <- contact_seen(b)
fold <- folds[[match(b$game_id, games)]]
rim_fold <- readRDS(file.path(cache, sprintf("opp_fold_%s.rds", b$game_id)))$rim
base_p <- function(sc, f) predict_cr(stack_scenes(list(sc), f$acc, character(0), TRUE), f$access_obstruction)[1, ]
example <- rbindlist(lapply(seq(0, tm$rebound - 0.04, by = 0.2), function(t) {
  sc <- build_scene(b, t, flight_all, launch_rows_all, seed = i)
  if (!length(sc)) return(NULL)
  who <- function(P) { k <- which.max(P[1:10]); list(p_rebounder = P[sc$y], top_pid = sc$pl$pid[k], top_p = P[k]) }
  late_now <- !is.na(cs[[1]]) && t >= cs[[2]] - 1e-9
  sc$tau <- late_tau(t, cs[[1]])
  # before: the release model, then the rim model from the recorded rim time on; now: the release model until the
  # contact is known, then the late model
  old <- base_p(sc, final[[if (t < rim_time(b) - 0.04 - 1e-9) "release" else "rim"]])
  new <- if (late_now) predict_late(stack_late(list(sc), late_final$acc), late_final$fit)[1, ] else base_p(sc, final$release)
  rows <- list(data.table(model = "before", source = "all games", t = t, as.data.table(who(old))),
               data.table(model = "now", source = "all games", t = t, as.data.table(who(new))))
  if (late_now) rows <- c(rows, list(
    data.table(model = "late_full", source = "held out", t = t, as.data.table(who(predict_late(stack_late(list(sc), fold$acc), fold$fits$late_full)[1, ]))),
    data.table(model = "current_site", source = "held out", t = t, as.data.table(who(base_p(sc, list(acc = rim_fold$acc, access_obstruction = rim_fold$fits$access_obstruction)))))))
  rbindlist(rows)
}))
example[, `:=`(shot_id = ex_id, contact = cs[[1]], rebound = tm$rebound, tau = pmax(0, t - cs[[1]]))]
fwrite(example, file.path(out_dir, "example.csv"))
print(summ)
print(by_tau[model %in% c("current_site", "late_full")])
print(example)
