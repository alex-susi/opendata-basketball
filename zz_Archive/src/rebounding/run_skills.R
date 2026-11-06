# Step 3 and 4 of the rebounding framework: behaviour models and the three skill components, each tested
# for identification before any of them is allowed into the site's talent-aware forecast.
#   Rscript src/rebounding/run_skills.R [--refit]
# Needs run_flight.R and run_opportunity.R. Writes outputs/rebounding/skills/*.csv and caches its
# per-game evidence in outputs/cache/rebounding/skills_{gameId}.rds and the all-games fits in final_fits.rds.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
load_opportunity_cpp(here, cache)
suppressMessages(library(mgcv))
out_dir <- file.path(report, "skills")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
set.seed(20261027)

opp <- lapply(games, function(g) readRDS(file.path(cache, sprintf("opp_fold_%s.rds", g))))
names(opp) <- games
fold_scenes <- function(g) readRDS(file.path(cache, sprintf("scenes_%s.rds", g)))
idx_of <- function(g) which(bundle_game == g)

# ---- movement library (pooled behaviour; framework section 8) --------------------------------------------

mv_path <- file.path(cache, "movement_rows.rds")
if (!file.exists(mv_path) || "--refit" %in% args) {
  movement <- rbindlist(lapply(games, function(g) {
    sc <- fold_scenes(g)$release
    rbindlist(lapply(idx_of(g), function(i) if (length(sc[[i]])) movement_rows(bundles[[i]], sc[[i]])))
  }))
  saveRDS(movement, mv_path)
}
movement <- readRDS(mv_path)

# ---- per held-out game: anticipation, movement scores, box-out pairs and values -------------------------

only <- sub("^--game=", "", grep("^--game=", args, value = TRUE))
for (g in if (length(only)) as.integer(only) else games) {
  path <- file.path(cache, sprintf("skills_%s.rds", g))
  if (file.exists(path) && !"--refit" %in% args) next
  t0 <- Sys.time()
  sc <- fold_scenes(g)
  rel <- opp[[as.character(g)]]$release
  rim <- opp[[as.character(g)]]$rim
  lib <- movement[game_id != g]
  test_mv <- movement[game_id == g]
  # damping factors and the two Gaussian spreads, fitted on the training games
  damp <- fit_damping(lib)
  h <- ANT_FRAMES / FPS
  sd_stat <- sqrt(mean(c(lib$x1 - lib$x0, lib$y1 - lib$y0)^2))
  sd_damp <- sqrt(mean(c(lib$x1 - lib$x0 - damp$pos * lib$vx0 * h, lib$y1 - lib$y0 - damp$pos * lib$vy0 * h)^2))
  mscore <- score_movement(test_mv, lib, damp, sd_stat, sd_damp)
  ant <- rbindlist(lapply(idx_of(g), function(i) {
    if (!length(sc$release[[i]])) return(NULL)
    anticipation_episode(bundles[[i]], sc$release[[i]], lib, rel$acc, rel$fits$access_obstruction, seed = i, damp = damp)
  }))
  box <- rbindlist(lapply(idx_of(g), function(i) if (length(sc$release[[i]])) boxout_pairs(bundles[[i]], sc$release[[i]])))
  val <- rbindlist(lapply(idx_of(g), function(i) if (length(sc$rim[[i]])) boxout_value(sc$rim[[i]], rim$acc, rim$fits$access_obstruction)))
  saveRDS(list(movement = mscore, anticipation = ant, boxout = box, value = val, damp = damp), path)
  message(sprintf("Skills %s: %.0f s", g, as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}
if (length(only)) quit(save = "no")
sk <- lapply(games, function(g) readRDS(file.path(cache, sprintf("skills_%s.rds", g))))

# ---- movement validation -----------------------------------------------------------------------------------

mscore <- rbindlist(lapply(sk, `[[`, "movement"))
fwrite(mscore[, .(n = .N, error_ft = mean(err), log_score = mean(ls), cover80 = mean(cover80)), by = model][order(-log_score)],
       file.path(out_dir, "movement_validation.csv"))
fwrite(mscore[, .(n = .N, error_ft = mean(err), log_score = mean(ls)), by = .(role, model)][order(role, -log_score)],
       file.path(out_dir, "movement_by_role.csv"))

# ---- anticipation --------------------------------------------------------------------------------------------

ant <- rbindlist(lapply(sk, `[[`, "anticipation"))
ant[, `:=`(gain = v_obs - v_ref, team_gain = team_obs - team_ref, w = v_ref_sd)]
v0 <- rbindlist(lapply(games, function(g) {
  sc <- fold_scenes(g)$release
  rbindlist(lapply(idx_of(g), function(i) {
    s <- sc[[i]]
    if (!length(s)) return(NULL)
    st <- stack_scenes(list(s), opp[[as.character(g)]]$release$acc, character(0), TRUE)
    P <- predict_cr(st, opp[[as.character(g)]]$release$fits$access_obstruction)
    data.table(shot_id = s$id, pid = s$pl$pid, v0 = P[1, 1:10])
  }))
}))
ant <- merge(ant, v0, by = c("shot_id", "pid"))
ant <- merge(ant, episodes[, .(shot_id, shot_dist, three)], by = "shot_id")
ant[, games := uniqueN(game_id), by = canon]
fwrite(ant, file.path(out_dir, "anticipation_rows.csv"))
eligible <- ant[w >= EXPOSURE_MIN & !grepl("shooter", role)]
eligible[, `:=`(canon_f = factor(canon), role_f = factor(role), wt = w / mean(w))]
lim <- quantile(eligible$gain, c(0.01, 0.99))
eligible[, gain_w := pmin(pmax(gain, lim[1]), lim[2])]
a_re <- gam(gain_w ~ s(v0, k = 5) + role_f + s(shot_dist, k = 5) + three + s(canon_f, bs = "re"), weights = wt, data = eligible, method = "REML")
a_0 <- gam(gain_w ~ s(v0, k = 5) + role_f + s(shot_dist, k = 5) + three, weights = wt, data = eligible, method = "REML")
# player sd of a random intercept: sqrt(scale / smoothing parameter) (scale is 1 for the binomial model)
re_sd_of <- function(m, term) sqrt(m$sig2 / m$sp[[term]])
re_sd <- re_sd_of(a_re, "s(canon_f)")
a_lrt <- 2 * (as.numeric(logLik(a_re)) - as.numeric(logLik(a_0)))
# repeatability: role-adjusted gains averaged within player-game, correlated across the two games of 25 players
eligible[, resid := residuals(a_0)]
pg <- eligible[games == 2, .(m = weighted.mean(resid, wt), n = .N), by = .(canon, game_id)]
pg <- pg[, if (.N == 2) .(a = m[1], b = m[2], n1 = n[1], n2 = n[2]), by = canon]
a_rep <- if (nrow(pg) >= 5) cor(pg$a, pg$b) else NA_real_
re_coef <- coef(a_re)[grep("s\\(canon_f\\)", names(coef(a_re)))]
re_se <- sqrt(diag(vcov(a_re)))[grep("s\\(canon_f\\)", names(coef(a_re)))]
anticip_player <- eligible[, .(episodes = .N, exposure = sum(wt), raw_gain = weighted.mean(gain, wt),
                               team_gain = weighted.mean(team_gain, wt), games = games[1]), by = canon]
anticip_player <- merge(anticip_player, data.table(canon = as.integer(levels(eligible$canon_f)), effect = re_coef, effect_se = re_se), by = "canon")
fwrite(anticip_player[order(-effect)], file.path(out_dir, "anticipation_player.csv"))

# ---- boxing out ---------------------------------------------------------------------------------------------

box <- rbindlist(lapply(sk, `[[`, "boxout"))
fwrite(box[, .(pairs = .N, share = .N / nrow(box)), by = .(label, blocker_def)][order(blocker_def, -pairs)],
       file.path(out_dir, "boxout_labels.csv"))
fwrite(box[, !c("frames", "strength")], file.path(out_dir, "boxout_pairs.csv"))
bm <- box[established == TRUE & label != "ambiguous"]
bm[, `:=`(y = as.integer(label == "maintained"), order = as.integer(blocker_hoop < opponent_hoop),
          blk_f = factor(blocker_canon), opp_f = factor(opponent_canon))]
bm <- merge(bm, episodes[, .(shot_id, shot_dist, three)], by = "shot_id")
logl <- function(p, y) -mean(y * log(pmax(p, 1e-6)) + (1 - y) * log(pmax(1 - p, 1e-6)))
auc <- function(p, y) { r <- rank(p); n1 <- sum(y == 1); n0 <- sum(y == 0); if (!n1 || !n0) return(NA_real_); (sum(r[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0) }
box_cv <- rbindlist(lapply(games, function(g) {
  tr <- bm[game_id != g]; te <- bm[game_id == g]
  if (!nrow(te)) return(NULL)
  f_ord <- glm(y ~ order, binomial, tr)
  f_geo <- gam(y ~ s(gap, k = 5) + obs_at_est + I(opp_toward - blk_toward) + blocker_def + s(blocker_hoop, k = 5) + s(shot_dist, k = 5) + three + t_establish,
               family = binomial, data = tr, method = "REML")
  f_re <- gam(y ~ s(gap, k = 5) + obs_at_est + I(opp_toward - blk_toward) + blocker_def + s(blocker_hoop, k = 5) + s(shot_dist, k = 5) + three + t_establish +
                s(blk_f, bs = "re") + s(opp_f, bs = "re"), family = binomial, data = tr, method = "REML")
  te_re <- copy(te)
  # unseen players get the population (zero) effect
  te_re[!blk_f %in% levels(tr$blk_f), blk_f := levels(tr$blk_f)[1]]
  te_re[!opp_f %in% levels(tr$opp_f), opp_f := levels(tr$opp_f)[1]]
  unseen_b <- !te$blk_f %in% levels(tr$blk_f); unseen_o <- !te$opp_f %in% levels(tr$opp_f)
  lp <- predict(f_re, te_re, type = "terms")
  eta <- attr(lp, "constant") + rowSums(lp[, setdiff(colnames(lp), c("s(blk_f)", "s(opp_f)")), drop = FALSE]) +
    (!unseen_b) * lp[, "s(blk_f)"] + (!unseen_o) * lp[, "s(opp_f)"]
  p_re <- plogis(eta)
  preds <- list(base_rate = rep(mean(tr$y), nrow(te)), rim_order = predict(f_ord, te, type = "response"),
                geometry = predict(f_geo, te, type = "response"), geometry_player_effects = p_re)
  rbindlist(lapply(names(preds), function(m) data.table(game_id = g, model = m, p = preds[[m]], y = te$y)))
}))
box_sum <- box_cv[, .(n = .N, log_loss = logl(p, y), brier = mean((p - y)^2), auc = auc(p, y)), by = model]
gg <- box_cv[, .(ll = logl(p, y)), by = .(game_id, model)]
gg <- merge(gg, gg[model == "base_rate", .(game_id, ll0 = ll)], by = "game_id")
box_sum <- merge(box_sum, gg[, .(gain = mean(ll0 - ll), gain_se = sd(ll0 - ll) / sqrt(.N), games_better = sum(ll < ll0)), by = model], by = "model")
fwrite(box_sum[order(log_loss)], file.path(out_dir, "boxout_validation.csv"))
b_re <- gam(y ~ s(gap, k = 5) + obs_at_est + I(opp_toward - blk_toward) + blocker_def + s(blocker_hoop, k = 5) + s(shot_dist, k = 5) + three + t_establish +
              s(blk_f, bs = "re") + s(opp_f, bs = "re"), family = binomial, data = bm, method = "REML")
b_0 <- gam(y ~ s(gap, k = 5) + obs_at_est + I(opp_toward - blk_toward) + blocker_def + s(blocker_hoop, k = 5) + s(shot_dist, k = 5) + three + t_establish,
           family = binomial, data = bm, method = "REML")
b_lrt <- 2 * (as.numeric(logLik(b_re)) - as.numeric(logLik(b_0)))
bcoef <- coef(b_re)[grep("s\\(blk_f\\)", names(coef(b_re)))]
bse <- sqrt(diag(vcov(b_re)))[grep("s\\(blk_f\\)", names(coef(b_re)))]
val <- rbindlist(lapply(sk, `[[`, "value"))
fwrite(val, file.path(out_dir, "boxout_value_rows.csv"))
box_player <- merge(bm[, .(established = .N, maintained = sum(y)), by = .(canon = blocker_canon)],
                    data.table(canon = as.integer(levels(bm$blk_f)), effect = bcoef, effect_se = bse), by = "canon", all = TRUE)
box_player <- merge(box_player, val[obstruction_given >= 0.15, .(obstructing_scenes = .N, team_value = mean(team_value),
                                                                  own_value = mean(own_value)), by = canon], by = "canon", all = TRUE)
bm_rep <- bm[, .(m = mean(y - fitted(b_0)[.I]), n = .N), by = .(canon = blocker_canon, game_id)]
bm_rep <- bm_rep[, if (.N == 2) .(a = m[1], b = m[2]), by = canon]
b_rep <- if (nrow(bm_rep) >= 5) cor(bm_rep$a, bm_rep$b) else NA_real_
fwrite(box_player[order(-team_value)], file.path(out_dir, "boxout_player.csv"))

# ---- collection effects (all games) -------------------------------------------------------------------------

final_path <- file.path(cache, "final_fits.rds")
flight_all <- readRDS(file.path(cache, "flight_params_all.rds"))
scenes_all <- build_scenes(bundles, OPP_CHECKPOINTS, flight_all, launch_rows_all, file.path(cache, "scenes_all.rds"), "--refit" %in% args)
mode_acc <- function(cp) {
  a <- rbindlist(lapply(opp, function(f) as.data.table(f[[cp]]$acc)))
  modifyList(opp[[1]][[cp]]$acc, as.list(a[, .N, by = .(policy, react)][which.max(N), .(policy, react)]))
}
if (!file.exists(final_path) || "--refit" %in% args) {
  final <- lapply(names(OPP_CHECKPOINTS), function(cp) {
    s <- Filter(function(x) length(x) > 0L, scenes_all[[cp]])
    acc <- mode_acc(cp)
    players <- sort(unique(unlist(lapply(s, function(x) as.character(x$pl$canon)))))
    st <- stack_scenes(s, acc, players, TRUE)
    st0 <- stack_scenes(s, acc, players, FALSE)
    f3 <- fit_cr(st0, free_theta = c(TRUE, TRUE, FALSE, TRUE, TRUE, TRUE, TRUE))
    f4 <- fit_cr(st, start = f3$theta)
    f5 <- fit_cr(st, sd_u = 0.3, start = f4$theta)
    # posterior sd of each effect: outer product of per-episode gradients plus the prior's precision
    G <- vapply(seq_along(s) - 1L, function(e) {
      r <- cr_objective(c(f5$theta, f5$u), st$A, st$out_step, st$Z, st$pidx, st$y, st$dims, e,
                        c(rep(FALSE, 7), rep(TRUE, length(players))), 0, 0)
      -r$gradient[-(1:7)]
    }, numeric(length(players)))
    se <- 1 / sqrt(rowSums(G^2) + 1 / 0.3^2)
    on_court <- table(unlist(lapply(s, function(x) as.character(x$pl$canon))))
    won <- table(unlist(lapply(s, function(x) if (x$y <= 10) as.character(x$pl$canon[x$y]))))
    list(acc = acc, access = f3, access_obstruction = f4, effects = f5, players = players, se = se,
         on_court = on_court, won = won, ids = vapply(s, `[[`, "", "id"), stack = st)
  })
  names(final) <- names(OPP_CHECKPOINTS)
  saveRDS(lapply(final, function(f) f[setdiff(names(f), "stack")]), final_path)
  # parameter recovery: outcomes simulated from the fitted population model plus known effects, refitted
  st <- final$rim$stack
  rec <- rbindlist(lapply(c(0.3, 0.6), function(sd_true) rbindlist(lapply(1:3, function(rep) {
    set.seed(100 * rep + round(10 * sd_true))
    u_true <- rnorm(length(final$rim$players), 0, sd_true)
    P <- cr_predict(c(final$rim$access_obstruction$theta, u_true), st$A, st$out_step, st$Z, st$pidx, st$y, st$dims)
    ysim <- apply(P[, 1:12], 1, function(p) sample.int(12, 1, prob = p / sum(p))) - 1L
    st2 <- st; st2$y <- as.integer(ysim)
    f <- fit_cr(st2, sd_u = sd_true, free_theta = rep(FALSE, 7), start = final$rim$access_obstruction$theta)
    n_on <- as.numeric(final$rim$on_court[final$rim$players])
    data.table(sd_true = sd_true, rep = rep, cor_all = cor(u_true, f$u), cor_20plus = cor(u_true[n_on >= 20], f$u[n_on >= 20]),
               players_20plus = sum(n_on >= 20), shrink_sd = sd(f$u))
  }))))
  fwrite(rec, file.path(out_dir, "collection_recovery.csv"))
}
final <- readRDS(final_path)
coll <- rbindlist(lapply(names(final), function(cp) {
  f <- final[[cp]]
  data.table(checkpoint = cp, canon = as.integer(f$players), effect = f$effects$u, effect_se = f$se,
             scenes = as.integer(f$on_court[f$players]), rebounds = as.integer(ifelse(is.na(f$won[f$players]), 0, f$won[f$players])))
}))
fwrite(coll[order(checkpoint, -effect)], file.path(out_dir, "collection_player.csv"))
sens <- rbindlist(lapply(opp, function(f) rbindlist(lapply(names(f), function(cp) f[[cp]]$scores[model %like% "effects|access_obstruction",
                                                                                                  .(ll = mean(ll), n = .N), by = .(model, rebounder_seen)][, checkpoint := cp]))))
fwrite(sens[, .(log_loss = weighted.mean(ll, n), n = sum(n)), by = .(checkpoint, model, rebounder_seen)][order(checkpoint, rebounder_seen, log_loss)],
       file.path(out_dir, "collection_sensitivity.csv"))

# ---- identification tests (framework section 11 and step 4) -------------------------------------------------

rec <- fread(file.path(out_dir, "collection_recovery.csv"))
eff <- sens[, .(log_loss = weighted.mean(ll, n)), by = .(checkpoint, model, rebounder_seen)]
gain_seen <- eff[rebounder_seen == TRUE & model == "access_obstruction", .(checkpoint, base = log_loss)][
  eff[rebounder_seen == TRUE & model == "effects_sd0.3", .(checkpoint, eff = log_loss)], on = "checkpoint"]
ident <- data.table(
  component = c("Anticipation", "Boxing out (spatial obstruction proxy)", "Collection"),
  evidence = c(sprintf("%d player-episodes with exposure, %d players", nrow(eligible), uniqueN(eligible$canon)),
               sprintf("%d established pairs, %d blockers", nrow(bm), uniqueN(bm$blocker_canon)),
               sprintf("%d rim-checkpoint episodes, %d players", length(final$rim$ids), length(final$rim$players))),
  player_sd = c(re_sd, re_sd_of(b_re, "s(blk_f)"), sd(final$rim$effects$u)),
  likelihood_ratio = c(a_lrt, b_lrt, NA_real_),
  cross_game_r = c(a_rep, b_rep, NA_real_),
  heldout_gain_repeat = c(NA_real_, box_sum[model == "geometry_player_effects", gain] - box_sum[model == "geometry", gain],
                          gain_seen[checkpoint == "rim", base - eff]),
  recovery_r = c(NA_real_, NA_real_, rec[sd_true == 0.3, mean(cor_20plus)]))
ident[, passes := c(isTRUE(a_lrt > 3.84 && a_rep > 0.3), isTRUE(b_lrt > 3.84 && b_rep > 0.3),
                    isTRUE(heldout_gain_repeat[3] > 0 && recovery_r[3] > 0.5))]
ident[, used_in_site := ifelse(passes, "player effects", "pooled (population) only")]
fwrite(ident, file.path(out_dir, "identification.csv"))
fwrite(data.table(term = c("anticipation_player_sd", "anticipation_lrt", "boxout_lrt"), value = c(re_sd, a_lrt, b_lrt)),
       file.path(out_dir, "variance_components.csv"))
print(ident)
print(box_sum)
print(fread(file.path(out_dir, "movement_validation.csv")))
