## ═════════════════════════════════════════════════════════════════════════════
# Step 04 of the rebounding manual: the static rebounding baseline. A grouped conditional logit over the 12 outcomes
# from player geometry (C1, at release; also fitted at rim + 0.2 s as the same-time static model Step 09 needs) and a
# binary offensive-rebound model (C2, at release), both fitted per leave-one-game-out fold with lambda chosen inside
# the nine training games, and judged with Step 03's frozen harness and rules.
#   Rscript src/rebounding/run_step04.R
# Needs the Step 03 outputs and outputs/cache/rebounding/step03_features.rds. Settings: config/experiment.yaml
# (step04, fixed before any fit). Writes outputs/rebounding/step04/, reports/04_static_model.md,
# gate_results/04_static.json and 04_tests.csv.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R", "static_geometry.R",
            "conditional_choice.R", "team_rebound.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step04
cache <- file.path(root, "outputs", "cache", "rebounding")
s3 <- file.path(root, "outputs", "rebounding", "step03")
out <- file.path(root, "outputs", "rebounding", "step04")
reports <- file.path(root, "outputs", "rebounding", "reports")
gr <- file.path(root, "outputs", "rebounding", "gate_results")
dir.create(out, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - STEP 03'S FROZEN DESIGN MUST BE THE ONE IN FORCE -----------------------
## ═════════════════════════════════════════════════════════════════════════════

fz <- jsonlite::fromJSON(file.path(s3, "design_freeze.json"))
freeze_ok <- c(config = identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3)))),
               code = all(vapply(names(fz$code_sha256), function(f) identical(fz$code_sha256[[f]], sha256_file(file.path(here, "R", f))), NA)),
               predictions = identical(fz$predictions_sha256, sha256_file(file.path(s3, "reference_baselines.csv.gz"))))
if (!all(freeze_ok)) stop("Step 03's design changed since it was frozen: ", paste(names(freeze_ok)[!freeze_ok], collapse = ", "))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - INPUTS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(file.path(s3, "fold_assignment.csv"))
choice <- choice_sets(el)
labels <- episode_labels(el)
f3 <- readRDS(file.path(cache, "step03_features.rds"))$features
times <- unlist(th$times)
f3 <- f3[time_point %in% times]
assert_information_time(f3)
rel <- f3[time_point == "release"]
shot <- el[, .(episode_id, shooter_id, shot_dist, three, rim = shot_range == "rim (<5 ft)")]
sp <- merge(rel[, .(episode_id, pid, sx = x, sy = y)], shot[, .(episode_id, pid = shooter_id)], by = c("episode_id", "pid"))
shot <- merge(shot, sp[, .(episode_id, sx, sy)], by = "episode_id")
if (nrow(shot) != nrow(el)) stop("a shooter is missing from the ten players at release")
base_pred <- fread(file.path(s3, "reference_baselines.csv.gz"), colClasses = list(character = "outcome_id"))[time_point %in% times]
refs <- unlist(th3$confirmatory[[which(vapply(th3$confirmatory, `[[`, "", "id") == "C1")]]$references)
u <- th3$uncertainty
dec <- th3$decision





## ═════════════════════════════════════════════════════════════════════════════
## 03 - FITS -------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

sf_at <- list()
cl <- list()
for (tp in times) {
  message("Step 04: conditional logit at ", tp)
  pl <- f3[time_point == tp, .(episode_id, pid, off, x, y, source_frame)]
  sf_at[[tp]] <- static_features(pl, shot)
  cl[[tp]] <- clogit_fold_predictions(sf_at[[tp]], shot, labels, fa, choice, unlist(th$clogit$lambda_grid),
                                      th$clogit$maxit, th3$metrics$prob_floor)
  cl[[tp]]$pred[, `:=`(model = "static_clogit", time_point = tp)]
}
message("Step 04: offensive-rebound model")
ef <- episode_features(rel[, .(episode_id, pid, off, x, y)], shot)
orb <- oreb_fold_predictions(ef, labels, fa, unlist(th$oreb$lambda_grid), th$clogit$maxit)
const <- constant_oreb_predictions(labels, fa, ef$episode_id)

pred <- rbindlist(lapply(cl, `[[`, "pred"))
pred <- merge(pred, unique(f3[, .(episode_id, time_point, frame_idx)]), by = c("episode_id", "time_point"))
pred[, model_version := th$model_version]
setcolorder(pred, c("model", "model_version", "time_point", "frame_idx", "episode_id", "outer_fold", "test_game", "n_train",
                    "outcome_id", "probability"))
setorder(pred, time_point, outer_fold, episode_id, outcome_id)
fwrite(pred, file.path(out, "static_oof.csv.gz"))
fwrite(rbindlist(lapply(times, function(tp) cbind(time_point = tp, cl[[tp]]$lambda))), file.path(out, "lambda_selection.csv"))
fwrite(rbindlist(lapply(times, function(tp) cbind(time_point = tp, cl[[tp]]$coef))), file.path(out, "coefficients.csv"))
oreb_out <- merge(orb$pred, const[, .(episode_id, p_off_constant = p_off)], by = "episode_id")
fwrite(merge(oreb_out, labels[, .(episode_id, y_off)], by = "episode_id"), file.path(out, "oreb_oof.csv"))
fwrite(orb$lambda, file.path(out, "oreb_lambda_selection.csv"))
fwrite(orb$coef, file.path(out, "oreb_coefficients.csv"))
fwrite(ef, file.path(out, "oreb_features.csv"))
fwrite(rbindlist(lapply(times, function(tp) cbind(time_point = tp, sf_at[[tp]]))), file.path(out, "player_features.csv.gz"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - SCORES -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

valid <- check_predictions(pred, choice, th3$metrics$sum_tol)
allp <- rbind(base_pred[, .(model, time_point, episode_id, outcome_id, probability)],
              pred[, .(model, time_point, episode_id, outcome_id, probability)])
sc <- score_episodes(allp, choice, labels, th3$metrics$prob_floor)
cal <- calibration_classwise(allp, labels, unlist(th3$metrics$calibration_breaks))
summ <- merge(summarise_scores(sc), cal$ece, by = c("model", "time_point"))
summ <- summ[order(match(time_point, times), log_loss)]
fwrite(summ, file.path(out, "scores_summary.csv"))
fwrite(cal$bins[model %in% c("static_clogit", "selected_reference")], file.path(out, "calibration_classwise.csv"))
fwrite(calibration_groups(allp[model %in% c("static_clogit", "selected_reference", "nearest_hoop", "role_prior_by_range")],
                          choice, labels), file.path(out, "calibration_groups.csv"))

c1 <- decide_against(sc, "static_clogit", refs, "release", "superiority", dec$non_inferiority_margin_nats,
                     reps = u$bootstrap_reps, seed = u$seed, level = u$level)
ece <- summ[time_point == "release" & model %in% c("static_clogit", "selected_reference"), setNames(ece, model)]
c1_cal_ok <- unname(ece["static_clogit"] <= ece["selected_reference"] + dec$calibration_ece_margin)
c1_pass <- c1$pass && c1_cal_ok
fwrite(c1$by_reference, file.path(out, "c1_by_reference.csv"))
rim <- decide_against(sc, "static_clogit", refs, "rim+0.2", "superiority", dec$non_inferiority_margin_nats,
                      reps = u$bootstrap_reps, seed = u$seed, level = u$level)
fwrite(rim$by_reference, file.path(out, "rim02_by_reference.csv"))
by_game <- rbindlist(lapply(c("selected_reference", "nearest_hoop", "role_prior_by_range"), function(r)
  rbindlist(lapply(times, function(tp) paired_comparison(sc, "static_clogit", r, tp, "ll", 200L, u$seed, u$level)$by_game))))
fwrite(by_game, file.path(out, "paired_by_game.csv"))

# C2: binary OREB model against the constant training rate
tsc <- rbind(orb$pred[, .(model = "oreb_logit", episode_id, p_off)], const[, .(model = "constant_oreb", episode_id, p_off)])
tsc <- merge(tsc, labels[, .(episode_id, game_id, y_off)], by = "episode_id")
tsc[, `:=`(time_point = "release", team_ll = binary_log_loss(p_off, y_off), team_brier = (p_off - y_off)^2)]
c2 <- paired_comparison(tsc, "oreb_logit", "constant_oreb", "release", "team_ll", u$bootstrap_reps, u$seed, u$level)
c2_large <- tsc[model == "oreb_logit", abs(mean(p_off) - mean(y_off))]
c2_pass <- decide(c2$summary, "superiority", dec$non_inferiority_margin_nats) && c2_large <= dec$team_calibration_in_large_max
team_sum <- rbind(tsc[, .(episodes = .N, team_log_loss = mean(team_ll), team_brier = mean(team_brier), mean_p_off = mean(p_off),
                          oreb_rate = mean(y_off)), by = model],
                  sc[time_point == "release" & model == "static_clogit", .(model = "static_clogit (implied)", episodes = .N,
                                                                           team_log_loss = mean(team_ll), team_brier = mean(team_brier), mean_p_off = mean(p_off), oreb_rate = mean(y_off))])
fwrite(team_sum, file.path(out, "oreb_scores.csv"))
fwrite(rbind(c2$summary, paired_comparison(rbind(tsc[model == "constant_oreb", .(model, time_point, episode_id, game_id, team_ll)],
                                                 sc[time_point == "release" & model == "static_clogit", .(model, time_point, episode_id, game_id, team_ll)]),
                                           "static_clogit", "constant_oreb", "release", "team_ll", u$bootstrap_reps, u$seed, u$level)$summary),
       file.path(out, "c2_comparisons.csv"))
fwrite(calibration_team(tsc, unlist(th3$metrics$team_calibration_breaks))$bins, file.path(out, "oreb_calibration.csv"))

# failure cases: where the logit gains or loses against the selected reference
sl <- merge(sc[model == "static_clogit", .(time_point, episode_id, game_id, ll_model = ll, top1, p_true)],
            sc[model == "selected_reference", .(time_point, episode_id, ll_ref = ll)], by = c("time_point", "episode_id"))
sl <- merge(sl, el[, .(episode_id, shot_range, credited_outcome, identity_suspect, blocked, complex_shot_type)], by = "episode_id")
sl[, diff := ll_model - ll_ref]
fail <- rbind(sl[, .(group = "all", episodes = .N, log_loss = mean(ll_model), diff_vs_reference = mean(diff), top1 = mean(top1)), by = time_point],
              sl[, .(group = paste("shot range:", shot_range), episodes = .N, log_loss = mean(ll_model), diff_vs_reference = mean(diff),
                     top1 = mean(top1)), by = .(time_point, shot_range)][, shot_range := NULL],
              sl[, .(group = paste("outcome:", credited_outcome), episodes = .N, log_loss = mean(ll_model), diff_vs_reference = mean(diff),
                     top1 = mean(top1)), by = .(time_point, credited_outcome)][, credited_outcome := NULL],
              sl[identity_suspect == FALSE, .(group = "without identity_suspect", episodes = .N, log_loss = mean(ll_model),
                                              diff_vs_reference = mean(diff), top1 = mean(top1)), by = time_point],
              sl[blocked == TRUE, .(group = "blocked shots", episodes = .N, log_loss = mean(ll_model), diff_vs_reference = mean(diff),
                                    top1 = mean(top1)), by = time_point])
fwrite(fail[order(match(time_point, times))], file.path(out, "by_subgroup.csv"))
fwrite(sl[order(-diff)][, .SD[1:15], by = time_point], file.path(out, "worst_episodes.csv"))

# interpretation only: one fit on all ten games, lambda by leave-one-game-out over the ten
all_ids <- unique(sf_at$release$episode_id)
lam_all <- rbindlist(lapply(unlist(th$clogit$lambda_grid), function(l) {
  p <- rbindlist(lapply(sort(unique(fa$outer_fold)), function(k) {
    s <- fold_split(fa, k)
    clogit_fit_predict(sf_at$release, shot, labels, s$train, s$test, l, th$clogit$maxit)$pred
  }))
  p[, `:=`(model = "clogit", time_point = "release")]
  data.table(lambda = l, logo_log_loss = mean(score_episodes(p, choice, labels)$ll))
}))
l_all <- lam_all[logo_log_loss == min(logo_log_loss)][, max(lambda)]
full <- clogit_fit_predict(sf_at$release, shot, labels, all_ids, all_ids[1], l_all, th$clogit$maxit)
coef_all <- data.table(term = names(full$fit$beta), estimate_per_sd = unname(full$fit$beta),
                       sd = c(full$scaler$sd, rep(NA, 2), rep(full$scaler$shot_sd, 2)), lambda = l_all)
coef_all[, estimate_per_unit := estimate_per_sd / fifelse(is.na(sd), 1, sd)]
fold_sd <- cl$release$coef[, .(fold_min = min(estimate), fold_max = max(estimate), sign_changes = uniqueN(sign(round(estimate, 6))) > 1), by = term]
coef_all <- merge(coef_all, fold_sd, by = "term", sort = FALSE)
fwrite(coef_all, file.path(out, "coefficients_all_games.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - CHECKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                    expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force (config, harness code, baseline predictions)", all(freeze_ok), TRUE, all(freeze_ok))
addc("prediction tables valid (12 outcomes, finite, non-negative, sum to 1)", sum(valid$ok), nrow(valid), all(valid$ok))
addc("exactly one credited outcome per choice set", nrow(merge(labels, choice, by = c("episode_id", "outcome_id"))), nrow(labels),
     nrow(merge(labels, choice, by = c("episode_id", "outcome_id"))) == nrow(labels))
same_eps <- sc[, .(eps = paste(sort(episode_id), collapse = ",")), by = .(model, time_point)][, uniqueN(eps), by = time_point]
addc("logit scored on exactly the baselines' episodes at each time point", sum(same_eps$V1 == 1L), length(times), all(same_eps$V1 == 1L))
coefs <- rbindlist(lapply(times, function(tp) cbind(time_point = tp, cl[[tp]]$coef)))
prov <- unique(coefs[, .(time_point, outer_fold, scaler_episodes)])
prov[, expected := vapply(seq_len(.N), function(i) nrow(fa[episode_id %in% unique(f3[time_point == prov$time_point[i]]$episode_id) &
                                                         outer_fold != prov$outer_fold[i]]), 0L)]
addc("scalers and fits use exactly the nine training games' episodes", sum(prov$scaler_episodes == prov$expected), nrow(prov),
     all(prov$scaler_episodes == prov$expected))
addc("every fit converged", sum(coefs[, all(converged), by = .(time_point, outer_fold)]$V1), nrow(prov),
     all(coefs$converged) && all(orb$coef$converged))
s1 <- fold_split(fa, 1L)
lam1 <- cl$release$lambda[outer_fold == 1 & selected == TRUE]$lambda
fp <- function(f, lab, split) clogit_fit_predict(f, shot, lab, split$train, split$test, lam1, th$clogit$maxit)$pred[, model := "static_clogit"][]
inv <- label_invariance(fp, sf_at$release, labels, choice, s1)
addc("logit predictions unchanged when the test game's labels are altered (fold 1)", inv, TRUE, inv)
fp_leak <- function(f, lab, split) {
  p <- merge(fp(f, lab, split), lab[, .(episode_id, truth = outcome_id)], by = "episode_id")
  p[, probability := 0.5 * probability + 0.5 * (outcome_id == truth)][, truth := NULL][]
}
leak <- !label_invariance(fp_leak, sf_at$release, labels, choice, s1)
addc("planted test-label leak is detected", leak, TRUE, leak)
lamo <- orb$lambda[outer_fold == 1 & selected == TRUE]$lambda
alt <- copy(labels)[episode_id %in% s1$test, y_off := !y_off]
inv_o <- isTRUE(all.equal(predict_oreb(fit_oreb(ef, labels, s1$train, lamo), ef, s1$test),
                          predict_oreb(fit_oreb(ef, alt, s1$train, lamo), ef, s1$test), tolerance = 0))
addc("OREB predictions unchanged when the test game's labels are flipped (fold 1)", inv_o, TRUE, inv_o)
a <- clogit_fit_predict(sf_at$release, shot, labels, s1$train, s1$test, lam1, th$clogit$maxit)$pred
set.seed(u$seed)
b <- clogit_fit_predict(sf_at$release[sample(.N)], shot[sample(.N)], labels, s1$train, s1$test, lam1, th$clogit$maxit)$pred
perm <- max(abs(merge(a, b, by = c("episode_id", "outcome_id"))[, probability.x - probability.y]))
addc("reordering candidate rows changes no player's probability (fold 1, largest change)", signif(perm, 3), "< 1e-7", perm < 1e-7)
m <- 0.3048
plm <- f3[time_point == "release", .(episode_id, pid, off, x = x * m, y = y * m, source_frame)]
shm <- copy(shot)[, `:=`(sx = sx * m, sy = sy * m, shot_dist = shot_dist * m)]
cm <- clogit_fit_predict(static_features(plm, shm, hoop = c(RIM_X * m, 0), ft = m), shm, labels, s1$train, s1$test, lam1, th$clogit$maxit)$pred
unit_d <- max(abs(merge(a, cm, by = c("episode_id", "outcome_id"))[, probability.x - probability.y]))
addc("features in metres give the same probabilities (fold 1, largest change)", signif(unit_d, 3), "< 1e-6", unit_d < 1e-6)
plr <- f3[time_point == "release", .(episode_id, pid, off, x, y = -y, source_frame)]
shr <- copy(shot)[, sy := -sy]
cr <- clogit_fit_predict(static_features(plr, shr), shr, labels, s1$train, s1$test, lam1, th$clogit$maxit)$pred
rot_d <- max(abs(merge(a, cr, by = c("episode_id", "outcome_id"))[, probability.x - probability.y]))
addc("mirroring the court left to right gives the same probabilities (fold 1, largest change)", signif(rot_d, 3), "< 1e-6", rot_d < 1e-6)
again <- clogit_fold_predictions(sf_at$release, shot, labels, fa, choice, unlist(th$clogit$lambda_grid), th$clogit$maxit, th3$metrics$prob_floor)
rep_ok <- isTRUE(all.equal(again$pred$probability, cl$release$pred$probability, tolerance = 0))
addc("re-running the release fits reproduces every prediction exactly", rep_ok, TRUE, rep_ok)
cst <- abs(tsc[model == "constant_oreb", mean(team_ll)] - fread(file.path(s3, "scores_team.csv"))[model == "constant_oreb" & time_point == "release"]$team_log_loss)
addc("constant OREB reference equals Step 03's", signif(cst, 3), "< 1e-9", cst < 1e-9)
addc("top-1 counted once per rebound", sc[, .N, by = .(model, time_point, episode_id)][, max(N)], 1, sc[, .N, by = .(model, time_point, episode_id)][, max(N)] == 1L)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 06 - REPORT -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
c1t <- c1$by_reference[, .(reference, mean_diff, lo, hi, games_better, drop_one_max, pass)]
rimt <- rim$by_reference[, .(reference, mean_diff, lo, hi, games_better, drop_one_max, pass)]
lam_tab <- rbindlist(lapply(times, function(tp) cl[[tp]]$lambda[selected == TRUE, .N, by = lambda][, time_point := tp]))
status_clogit <- if (c1_pass) "PASS" else "BLOCKED"
status_oreb <- if (c2_pass) "PASS" else "BLOCKED"
# The step's markdown report.
lines <- c("# Step 04: static rebounding model",
           "",
           sprintf("Run %s by `src/rebounding/run_step04.R`; settings `config/experiment.yaml` (`step04`, config v%d), fixed before any fit.",
                   format(Sys.Date()), cfg$config_version),
           "Folds, outcomes, scoring and decision rules are Step 03's frozen harness. Step 02 is BLOCKED: the target is the credited",
           sprintf("outcome (ten players, team award to either side) of %d missed shots.", nrow(el)),
           "",
           "## Models",
           "",
           "- **Grouped conditional logit** over the 12 outcomes. Player features at t: distance to the hoop, distance minus the",
           "  ten's mean, nearest opponent, inside gap, opponents and teammates nearer the hoop, angle from the shooter's line,",
           "  offence, shooter, distance x shot distance, shooter on a rim shot, players within 6 ft, closeness share. Team awards",
           "  are alternatives with a constant and a shot-distance slope. Standardised and L2-penalised on the training games;",
           "  lambda by inner leave-one-game-out. Fitted at release (C1) and at rim + 0.2 s (exploratory; Step 09's C3b reference).",
           "- **Binary OREB model** (C2): logistic regression on shot distance, three, the two nearest offensive and defensive",
           "  hoop distances, offence minus defence mean distance, and attackers nearer the hoop than their assigned defender",
           "  (five-against-five assignment minimising total distance).",
           "- **Boosted challenger**: not run (optional in the manual, only after the logit passes).",
           "",
           sprintf("## C1: conditional logit at release: %s", status_clogit),
           "",
           "Paired log-loss difference, logit minus each reference (negative is better). Superiority needs `hi` < 0 and every",
           "drop-one-game mean < 0:", "", md_table(c1t, 4), "",
           sprintf("Class-wise ECE: logit %.4f, selected reference %.4f (allowed: reference + %.2f): %s.", ece["static_clogit"],
                   ece["selected_reference"], dec$calibration_ece_margin, if (c1_cal_ok) "met" else "not met"),
           "",
           sprintf("## C2: binary OREB model at release: %s", status_oreb),
           "", md_table(team_sum, 4), "",
           sprintf("Paired binary log loss, model minus constant: %.4f (interval %.4f to %.4f, better in %d of %d games, drop-one max %.4f).",
                   c2$summary$mean_diff, c2$summary$lo, c2$summary$hi, c2$summary$games_better, c2$summary$games, c2$summary$drop_one_max),
           sprintf("Calibration in the large: |mean P(OREB) - rate| = %.4f (allowed %.2f).", c2_large, dec$team_calibration_in_large_max),
           "",
           "## Scores at both time points (held-out games)",
           "", md_table(summ[, .(time_point, model, episodes, log_loss, brier, top1, top3, team_log_loss, ece)], 4), "",
           "## Exploratory: logit at rim + 0.2 s against every baseline", "", md_table(rimt, 4), "",
           "## Lambda chosen (folds)", "", md_table(lam_tab), "",
           "## Coefficients (all ten games, for reading only; per standard deviation)",
           "", md_table(coef_all[, .(term, estimate_per_sd, fold_min, fold_max, sign_changes)], 3), "",
           "`dist_hoop` and `dist_minus_mean` differ by a per-shot constant, so the softmax splits one distance effect between",
           "them (and `dist_x_shot`); read them together. Fold ranges show how stable each term is across held-out games.",
           "",
           "## Where it gains and loses (difference against the selected reference)",
           "", md_table(fail, 4), "",
           "## Checks", "", md_table(checks), "",
           "## Limits",
           "",
           "- Ten games: intervals are indicative. Leave one game out trains on later games; teams recur across games.",
           "- Release geometry only; no velocities, no ball. The rim + 0.2 s fit uses positions then, still without the ball.",
           "- Coefficients describe association in these games, not effects of moving a player.")
writeLines(lines, file.path(reports, "04_static_model.md"))





## ═════════════════════════════════════════════════════════════════════════════
## 07 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

tests <- rbind(run_tests(here, root, "unit", "static_model"), run_tests(here, root, "gates", "step_04"), fill = TRUE)
fwrite(tests, file.path(gr, "04_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
harness_ok <- all(checks$pass) && tests_ok
status <- if (!harness_ok) "BLOCKED" else if (c1_pass) "PASS" else "PASS_BASELINE"
best_base <- summ[time_point == "release" & model %in% th3$baselines$models][which.min(log_loss)]
# The gate record.
rec <- list(step = "04", status = status,
            scope = sprintf("static models at release on %d eligible misses (12-class credited outcome; binary OREB); Step 02 BLOCKED", nrow(el)),
            components = list(static_clogit = status_clogit, oreb_logit = status_oreb, boosted_challenger = "NOT_RUN",
                              shipped_static_model = if (c1_pass) "static_clogit" else paste("best Step 03 baseline:", best_base$model)),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit),
            data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
            model_revision = list(model_version = th$model_version, step04_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                                  code_sha256 = setNames(lapply(c("static_geometry.R", "conditional_choice.R", "team_rebound.R"), function(f)
                                    sha256_file(file.path(here, "R", f))), c("static_geometry.R", "conditional_choice.R", "team_rebound.R")),
                                  predictions_sha256 = sha256_file(file.path(out, "static_oof.csv.gz"))),
            repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit static_model; Rscript src/rebounding/run_tests.R gates step_04",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = all(checks$pass),
            heldout_metrics_file = "outputs/rebounding/step04/scores_summary.csv",
            acceptance_criteria_version = sprintf("manual %s, config v%d (step03 rules; step04 settings fixed before any fit)", cfg$manual_revision, cfg$config_version),
            c1 = list(pass = c1_pass, superiority_over_every_reference = c1$pass, ece_ok = c1_cal_ok,
                      by_reference = c1$by_reference[, .(reference, mean_diff = round(mean_diff, 5), lo = round(lo, 5), hi = round(hi, 5),
                                                         drop_one_max = round(drop_one_max, 5), pass)]),
            c2 = list(pass = c2_pass, mean_diff = round(c2$summary$mean_diff, 5), lo = round(c2$summary$lo, 5), hi = round(c2$summary$hi, 5),
                      drop_one_max = round(c2$summary$drop_one_max, 5), calibration_in_large = round(c2_large, 5)),
            evidence = c("outputs/rebounding/step04/", "outputs/rebounding/reports/04_static_model.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("Ten game clusters: intervals are indicative only", "dist_hoop and dist_minus_mean are not separately identified",
                              "No velocity or ball information at release"),
            decision_note = sprintf("C1 %s, C2 %s.", status_clogit, status_oreb))
write_gate(file.path(gr, "04_static.json"), rec)

print(summ[, .(time_point, model, ll = round(log_loss, 4), top1 = round(top1, 3), top3 = round(top3, 3), tll = round(team_log_loss, 4), ece = round(ece, 4))], nrows = 50)
print(c1$by_reference[, .(reference, d = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4), drop1 = round(drop_one_max, 4), pass)])
print(team_sum)
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 04:", status, "| C1", status_clogit, "| C2", status_oreb, "\n")
