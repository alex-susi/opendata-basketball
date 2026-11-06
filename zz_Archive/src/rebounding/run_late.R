# Late forecasts: the collection model for the moments after the ball reaches the rim, leave one game out.
#   Rscript src/rebounding/run_late.R [--game=<id>] [--refit]
# Needs run_flight.R and run_opportunity.R (the held-out rim model each fold is compared with). Late scenes are
# cached per flight fold (outputs/cache/rebounding/late_scenes_{gameId}.rds) and model folds in
# late_fold_{gameId}.rds; --game=<id> runs one fold (folds can run as parallel processes). A fold made before a
# model was added keeps what it has and adds the rest; --refit redoes everything. Without --game it summarises the
# folds, fits the all-games model the site uses (late_final.rds) and writes outputs/rebounding/late/.

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

#' Every model on one held-out game: the current site model (that fold's rim fit), benchmarks, the late ladder,
#' the late model with a fitted reach height (with and without the height-gated arrival margin) and collection
#' effects on top of it. `prev` is an earlier run of this fold whose access choice and ladder are kept.
run_fold <- function(g, prev = NULL) {
  fl <- readRDS(file.path(cache, sprintf("flight_fold_%s.rds", g)))$fit
  sc <- build_late_scenes(bundles, fl, launch_rows_all[game_id != g], file.path(cache, sprintf("late_scenes_%s.rds", g)), refit)
  gid <- vapply(sc, `[[`, 0L, "game_id")
  tr <- sc[gid != g]; te <- sc[gid == g]
  rim <- readRDS(file.path(cache, sprintf("opp_fold_%s.rds", g)))$rim
  players <- sort(unique(unlist(lapply(tr, function(s) as.character(s$pl$canon)))))
  ch <- if (!is.null(prev$acc)) list(acc = prev$acc, grid = prev$grid) else choose_late_access(tr, rim$acc, seed = g %% 1000L)
  st_te <- stack_late(te, ch$acc)
  ladder <- if (!is.null(prev$fits$late_full)) prev$fits[c("late_refit", "late_time", "late_full")] else {
    st_tr <- stack_late(tr, ch$acc)

    fit_late_ladder(st_tr)
  }
  gc()
  # reach height and the gated margin, then collection effects on top of that model
  hc <- choose_late_height(tr, ch$acc, seed = g %% 1000L)
  acc_flat <- modifyList(hc$acc, list(gate = FALSE))
  st_tr <- stack_late(tr, acc_flat)
  height_flat <- fit_late(st_tr, start = ladder$late_full$theta)
  rm(st_tr); gc()
  st_tr <- stack_late(tr, hc$acc, players)
  height <- fit_late(st_tr, start = ladder$late_full$theta)
  effects <- fit_late_effects(st_tr, height)
  rm(st_tr); gc()
  st_te_h <- stack_late(te, hc$acc, players)
  y_tr <- vapply(tr, `[[`, 0L, "y"); y_te <- vapply(te, `[[`, 0L, "y")
  near <- fit_softmax(tr, feats_nearest, y_tr)
  geo <- fit_softmax(tr, feats_geometry, y_tr)
  preds <- c(list(team_prior = prior_probs(y_tr, length(te)),
                  current_site = predict_cr(stack_scenes(te, rim$acc, character(0), TRUE), rim$fits$access_obstruction),
                  nearest_to_forecast = predict_softmax(near, te), geometry_classifier = predict_softmax(geo, te)),
             lapply(ladder, function(f) predict_late(st_te, f)),
             list(late_height_flat = predict_late(stack_late(te, acc_flat), height_flat),
                  late_height = predict_late(st_te_h, height), late_effects = predict_late(st_te_h, effects)))
  ids <- vapply(te, `[[`, "", "id"); tau <- vapply(te, `[[`, 0, "tau")
  seen <- vapply(te, function(s) s$y <= 10 && as.character(s$pl$canon[s$y]) %in% players, NA)
  scores <- rbindlist(lapply(names(preds), function(m) {
    colnames(preds[[m]]) <- OUTCOMES
    Q <- resolved(preds[[m]])
    score_outcomes(preds[[m]], y_te)[, `:=`(model = m, shot_id = ids, game_id = g, tau = tau, y = y_te, rebounder_seen = seen,
                                            p_collector = ifelse(y_te <= 10, Q[cbind(seq_along(y_te), pmin(y_te, 12L))], NA_real_))]
  }))
  list(scores = scores, preds = preds, y = y_te, tau = tau, ids = ids, acc = ch$acc, grid = ch$grid[, game_id := g],
       height_grid = hc$grid[, game_id := g], accs = list(late_full = ch$acc, late_height_flat = acc_flat, late_height = hc$acc),
       fits = c(ladder, list(late_height_flat = height_flat, late_height = height, late_effects = effects)), n_train = length(tr))
}

only <- sub("^--game=", "", grep("^--game=", args, value = TRUE))
for (g in if (length(only)) as.integer(only) else games) {
  path <- file.path(cache, sprintf("late_fold_%s.rds", g))
  prev <- if (file.exists(path) && !refit) readRDS(path) else NULL
  if (!is.null(prev$fits$late_effects)) next
  t0 <- Sys.time()
  saveRDS(run_fold(g, prev), path)
  message(sprintf("Late fold %s: %.0f s", g, as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}
if (length(only)) quit(save = "no")

# ---- held-out summaries -----------------------------------------------------------------------------------

folds <- lapply(games, function(g) readRDS(file.path(cache, sprintf("late_fold_%s.rds", g))))
scores <- rbindlist(lapply(folds, `[[`, "scores"))
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
summ <- merge(summ, setnames(vs("late_full"), c("gain", "gain_se", "games_better"), c("gain_late", "gain_late_se", "better_than_late")), by = "model")
setorder(summ, log_loss)
fwrite(summ, file.path(out_dir, "validation_summary.csv"))
fwrite(by_game, file.path(out_dir, "validation_by_game.csv"))

# which late model the site uses: the fitted reach height (with the gated margin) only if it beats the late model
# with fixed height on held-out games; either way the late model must beat the reused rim model
passes_rule <- function(gain, better) isTRUE(gain > 0 && better >= 6L)
h <- summ[model == "late_height"]
site_model <- if (passes_rule(h$gain_late, h$better_than_late)) "late_height" else "late_full"
chosen <- summ[model == site_model]
used <- passes_rule(chosen$gain_current, chosen$better_than_current)
fwrite(data.table(
  comparison = c("late_full vs reused rim model", "late_height vs late_full", "site model vs reused rim model"),
  model = c("late_full", "late_height", site_model),
  gain = c(summ[model == "late_full", gain_current], h$gain_late, chosen$gain_current),
  se = c(summ[model == "late_full", gain_current_se], h$gain_late_se, chosen$gain_current_se),
  games_better = c(summ[model == "late_full", better_than_current], h$better_than_late, chosen$better_than_current),
  adopted = c(passes_rule(summ[model == "late_full", gain_current], summ[model == "late_full", better_than_current]),
              site_model == "late_height", used),
  rule = "adopted when its held-out log loss is better on average and in at least 6 of 10 games"),
  file.path(out_dir, "decision.csv"))

by_tau <- scores[, .(n = .N, log_loss = mean(ll), team_log_loss = mean(ll_team), collector_chance = mean(p_collector, na.rm = TRUE),
                     top_median = median(p_top), top_q90 = quantile(p_top, 0.9)), by = .(model, tau)]
setorder(by_tau, model, tau)
fwrite(by_tau, file.path(out_dir, "validation_by_tau.csv"))

# player-level calibration: every player's predicted chance against whether he collected, reused rim model and site model
cal <- rbindlist(lapply(folds, function(f) rbindlist(lapply(c("current_site", site_model), function(m) {
  Q <- resolved(f$preds[[m]])
  data.table(model = m, p = as.vector(Q[, 1:10]), hit = as.vector(outer(f$y, 1:10, `==`)))
}))))
cal <- cal[, .(n = .N, predicted = mean(p), observed = mean(hit)),
           by = .(model, band = cut(p, c(0, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1), include.lowest = TRUE))]
setorder(cal, model, band)
fwrite(cal, file.path(out_dir, "calibration_players.csv"))

fwrite(rbindlist(lapply(seq_along(folds), function(k) {
  f <- folds[[k]]
  data.table(game_id = games[k], policy = f$acc$policy, react = f$acc$react, z_reach = f$accs$late_height$z_reach,
             z_scale = f$accs$late_height$z_scale, t(f$fits[[site_model]]$theta))
})), file.path(out_dir, "fold_parameters.csv"))
fwrite(rbindlist(lapply(folds, `[[`, "grid")), file.path(out_dir, "access_grid.csv"))
fwrite(rbindlist(lapply(folds, `[[`, "height_grid")), file.path(out_dir, "height_grid.csv"))

# ---- the all-games fit the site uses, and the collection-effects test --------------------------------------

final <- readRDS(file.path(cache, "final_fits.rds"))
flight_all <- readRDS(file.path(cache, "flight_params_all.rds"))
final_path <- file.path(cache, "late_final.rds")
late_final <- if (file.exists(final_path) && !refit) readRDS(final_path) else list()
if (is.null(late_final$effects)) {
  sc_all <- build_late_scenes(bundles, flight_all, launch_rows_all, file.path(cache, "late_scenes_all.rds"), refit)
  if (is.null(late_final$fits$late_full)) {
    ch <- choose_late_access(sc_all, final$rim$acc, seed = 1L)
    late_final <- list(acc = ch$acc, grid = ch$grid, fits = fit_late_ladder(stack_late(sc_all, ch$acc)), scenes = length(sc_all))
  }
  hc <- choose_late_height(sc_all, late_final$acc, seed = 1L)
  players <- sort(unique(unlist(lapply(sc_all, function(s) as.character(s$pl$canon)))))
  st <- stack_late(sc_all, hc$acc, players)
  late_final$accs <- list(late_full = late_final$acc, late_height = hc$acc)
  late_final$height_grid <- hc$grid
  late_final$fits$late_height <- fit_late(st, start = late_final$fits$late_full$theta)
  late_final$effects <- fit_late_effects(st, late_final$fits$late_height)
  late_final$recovery <- late_recovery(st, late_final$fits$late_height)
  first <- !duplicated(st$ids)
  late_final$misses_on <- table(unlist(lapply(which(first), function(e) players[st$pidx[(e - 1) * 10 + 1:10] + 1L])))
  late_final$won <- table(unlist(lapply(sc_all[first], function(s) if (s$y <= 10) as.character(s$pl$canon[s$y]))))
  rm(st); gc()
}
late_final$site_model <- site_model
late_final$acc_site <- late_final$accs[[site_model]]
late_final$fit <- late_final$fits[[site_model]]
late_final$used <- used
fwrite(late_final$recovery, file.path(out_dir, "collection_recovery.csv"))

# identification of late collection effects, by the rule of the rim-checkpoint test (run_skills.R): better held-out
# forecasts where the rebounder was seen in training, and effects recoverable from simulated outcomes
seen <- scores[rebounder_seen == TRUE & model %in% c("late_height", "late_effects")]
gain_seen <- seen[model == "late_height", mean(ll)] - seen[model == "late_effects", mean(ll)]
seen_games <- dcast(seen[, .(ll = mean(ll)), by = .(game_id, model)], game_id ~ model, value.var = "ll")
rec_r <- late_final$recovery[, mean(cor_20plus)]
talent <- isTRUE(gain_seen > 0 && rec_r > 0.5)
late_final$talent <- talent
saveRDS(late_final, final_path)
fwrite(data.table(component = "Collection (late model)",
                  evidence = sprintf("%d held-out scenes with a rebounder seen in training; %d players", nrow(seen) / 2L, length(late_final$effects$u)),
                  player_sd = sd(late_final$effects$u), heldout_gain_seen = gain_seen,
                  games_better = seen_games[, sum(late_effects < late_height)], recovery_r = rec_r, passes = talent,
                  used_in_site = if (talent) "player effects" else "pooled (population) only"),
       file.path(out_dir, "identification.csv"))
eff <- data.table(canon = as.integer(names(late_final$effects$u)), effect = unname(late_final$effects$u),
                  misses = as.integer(late_final$misses_on[names(late_final$effects$u)]))
eff[, rebounds := as.integer(late_final$won[as.character(canon)])][is.na(rebounds), rebounds := 0L]
fwrite(eff[order(-effect)], file.path(out_dir, "collection_effects.csv"))

fit_acc <- late_final$acc_site
fwrite(data.table(term = c("policy", "react", "z_reach", "z_scale", "gated_margin", THETA_LATE),
                  value = c(fit_acc$policy, fit_acc$react, fit_acc$z_reach, fit_acc$z_scale, as.numeric(isTRUE(fit_acc$gate)),
                            late_final$fit$theta)),
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
  # contact is known, then the late model the site uses
  old <- base_p(sc, final[[if (t < rim_time(b) - 0.04 - 1e-9) "release" else "rim"]])
  new <- if (late_now) predict_late(stack_late(list(sc), late_final$acc_site), late_final$fit)[1, ] else base_p(sc, final$release)
  rows <- list(data.table(model = "before", source = "all games", t = t, as.data.table(who(old))),
               data.table(model = "now", source = "all games", t = t, as.data.table(who(new))))
  if (late_now) rows <- c(rows, list(
    data.table(model = "late_full", source = "held out", t = t,
               as.data.table(who(predict_late(stack_late(list(sc), fold$accs[[site_model]]), fold$fits[[site_model]])[1, ]))),
    data.table(model = "current_site", source = "held out", t = t, as.data.table(who(base_p(sc, list(acc = rim_fold$acc, access_obstruction = rim_fold$fits$access_obstruction)))))))
  rbindlist(rows)
}))
example[, `:=`(shot_id = ex_id, contact = cs[[1]], rebound = tm$rebound, tau = pmax(0, t - cs[[1]]))]
fwrite(example, file.path(out_dir, "example.csv"))
print(summ)
print(fread(file.path(out_dir, "decision.csv")))
print(fread(file.path(out_dir, "identification.csv")))
print(late_final$recovery)
print(example[source == "all games"])
