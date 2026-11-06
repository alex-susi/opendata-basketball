# Step 03 of the rebounding manual: frozen evaluation design, reference baselines and the scoring harness.
#   Rscript src/rebounding/run_step03.R
# Needs outputs/cache/rebounding/raw_*.rds (extract_windows.R) and the Step 01 episode table. Settings are
# config/experiment.yaml (step03), fixed before any baseline was scored. Step 02 is BLOCKED, so the only label is
# the credited outcome (ten players at release, team award to either side).
# Writes outputs/rebounding/step03/ (folds, prediction points, baseline predictions, scores, comparisons,
# calibration, leakage checks, design freeze), outputs/rebounding/reports/03_evaluation_design.md and
# gate_results/03_evaluation.json, 03_tests.csv. About five minutes.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step03
inf <- th$information
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "step03")
reports <- file.path(root, "outputs", "rebounding", "reports")
gr <- file.path(root, "outputs", "rebounding", "gate_results")
for (d in c(out, reports, gr)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
ep <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))
el <- ep[eligible == TRUE]
gate02 <- jsonlite::fromJSON(file.path(gr, "02_contact_states.json"))
if (gate02$status != "BLOCKED") message("Step 02 is ", gate02$status, ": this run still uses the credited outcome only")

# ---- design freeze: the settings, the harness code and the inputs, hashed before anything is scored --------------
cfg_text <- yaml::as.yaml(th)
freeze <- list(frozen_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), config_version = cfg$config_version,
               step03_config_sha256 = paste(openssl::sha256(cfg_text)),
               code_sha256 = setNames(lapply(c("folds.R", "metrics.R", "reference_baselines.R"), function(f)
                 sha256_file(file.path(here, "R", f))), c("folds.R", "metrics.R", "reference_baselines.R")),
               episodes_sha256 = sha256_file(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv")),
               seeds = cfg$seeds, bootstrap_seed = th$uncertainty$seed, model_version = th$model_version,
               note = "Later steps compare against these baselines under these rules; a change needs a new config_version.")
# Written once. A rerun must match it; changing the design means recording why in the decision log, raising
# config_version and deleting design_freeze.json by hand.
freeze_path <- file.path(out, "design_freeze.json")
frozen <- if (file.exists(freeze_path)) jsonlite::fromJSON(freeze_path) else NULL
if (!is.null(frozen)) {
  changed <- c(config = frozen$step03_config_sha256 != freeze$step03_config_sha256,
               code = !identical(unlist(frozen$code_sha256), unlist(freeze$code_sha256)),
               episodes = frozen$episodes_sha256 != freeze$episodes_sha256)
  if (any(changed)) stop("the Step 03 design changed since ", frozen$frozen_at, " (", paste(names(changed)[changed], collapse = ", "),
                         "); see the comment above this check")
  freeze$frozen_at <- frozen$frozen_at
}

# ---- folds ----------------------------------------------------------------------------------------------------
games <- data.table(game_id = matches$id, date = matches$date_time)
fa <- fold_assignment(el, games)
fold_chk <- check_folds(fa)
fwrite(fa, file.path(out, "fold_assignment.csv"))
choice <- choice_sets(el)
labels <- episode_labels(el)
if (nrow(merge(labels, choice, by = c("episode_id", "outcome_id"))) != nrow(labels))
  stop("a credited outcome is outside its episode's choice set")

# ---- prediction points and causal features, game by game ---------------------------------------------------------
set.seed(th$uncertainty$seed)
poison_ids <- el[, .(episode_id = sample(episode_id, min(.N, 5L))), by = game_id]$episode_id
pts <- list(); feats <- list(); poison <- list()
for (g in matches$id) {
  message("Step 03: ", g)
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  for (k in which(el$game_id == g)) {
    s <- el[k]
    home_off <- home == s$off_team
    tr <- episode_tracking(raw, s, home_off, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
    p <- prediction_points(tr, s, th)
    pts[[length(pts) + 1L]] <- p
    for (i in which(p$defined)) {
      f <- features_at(tr$players, p$frame_idx[i], inf$player_carry_frames)
      feats[[length(feats) + 1L]] <- cbind(episode_id = s$episode_id, time_point = p$time_point[i],
                                           frame_idx = p$frame_idx[i], f)
    }
    if (s$episode_id %in% poison_ids)
      poison[[length(poison) + 1L]] <- data.table(episode_id = s$episode_id, game_id = g, points = sum(p$defined),
                                                  unchanged = poisoning_invariance(raw, s, home_off, th, p))
  }
}
pts <- rbindlist(pts)
feat <- merge(rbindlist(feats), el[, .(episode_id, shot_range)], by = "episode_id", sort = FALSE)   # known at release
poison <- rbindlist(poison)
assert_information_time(feat)
time_points <- unique(pts$time_point)
pts[, confirmatory := time_point %in% unlist(th$confirmatory_times)]
fwrite(merge(pts, fa[, .(episode_id, game_id, outer_fold)], by = "episode_id")[order(outer_fold, episode_id, frame_idx)],
       file.path(out, "prediction_points.csv"))
saveRDS(list(points = pts, features = feat), file.path(cache, "step03_features.rds"))

# ---- reference baselines: outer-fold predictions at every time point ------------------------------------------------
run_baselines <- function() {
  res <- lapply(time_points, function(tp) {
    f <- feat[time_point == tp]
    if (!nrow(f)) return(NULL)
    r <- fold_predictions(f, labels, fa, choice, th$baselines$smoothing, th$metrics$prob_floor)
    r$pred[, time_point := tp]
    r$selection[, time_point := tp]
    r
  })
  res <- res[!vapply(res, is.null, NA)]
  pred <- rbindlist(lapply(res, `[[`, "pred"))
  pred <- merge(pred, unique(feat[, .(episode_id, time_point, frame_idx)]), by = c("episode_id", "time_point"))
  pred[, model_version := th$model_version]
  setcolorder(pred, c("model", "model_version", "time_point", "frame_idx", "episode_id", "outer_fold", "test_game",
                      "n_train", "outcome_id", "probability"))
  list(pred = pred[order(model, match(time_point, time_points), outer_fold, episode_id, outcome_id)],
       selection = rbindlist(lapply(res, `[[`, "selection")))
}
base <- run_baselines()
pred <- base$pred
selection <- base$selection
valid <- check_predictions(pred, choice, th$metrics$sum_tol)
pred_path <- file.path(out, "reference_baselines.csv.gz")
fwrite(pred, pred_path)
fwrite(selection, file.path(out, "baseline_selection.csv"))
fwrite(valid, file.path(out, "prediction_validity.csv"))

# the binary OREB reference: the training games' share of offensive outcomes, per fold and time point
const <- rbindlist(lapply(time_points, function(tp) {
  ids <- unique(feat[time_point == tp]$episode_id)
  if (!length(ids)) return(NULL)
  f <- fa[episode_id %in% ids]
  rbindlist(lapply(sort(unique(f$outer_fold)), function(k) {
    s <- fold_split(f, k)
    data.table(model = "constant_oreb", time_point = tp, episode_id = s$test, p_off = mean(labels[episode_id %in% s$train]$y_off))
  }))
}))

# ---- scores ------------------------------------------------------------------------------------------------------
sc <- score_episodes(pred[, .(model, time_point, episode_id, outcome_id, probability)], choice, labels, th$metrics$prob_floor)
const <- merge(const, labels[, .(episode_id, game_id, y_off)], by = "episode_id")
const[, `:=`(team_ll = -(y_off * log(p_off) + (1 - y_off) * log(1 - p_off)), team_brier = (p_off - y_off)^2)]
fwrite(sc, file.path(out, "scores_episode.csv.gz"))
summ <- summarise_scores(sc)
team_summ <- rbind(summ[, .(model, time_point, episodes, team_log_loss, team_brier, mean_p_off, oreb_rate)],
                   const[, .(episodes = .N, team_log_loss = mean(team_ll), team_brier = mean(team_brier),
                             mean_p_off = mean(p_off), oreb_rate = mean(y_off)), by = .(model, time_point)])
cal <- calibration_classwise(pred[, .(model, time_point, episode_id, outcome_id, probability)], labels,
                             unlist(th$metrics$calibration_breaks))
summ <- merge(summ, cal$ece, by = c("model", "time_point"))
order_tp <- function(d) d[order(match(time_point, time_points), match(model, c(BASELINES, "selected_reference")))]
summ <- order_tp(summ)
fwrite(summ, file.path(out, "scores_summary.csv"))
fwrite(order_tp(team_summ), file.path(out, "scores_team.csv"))
by_game <- summarise_scores(sc, by = c("model", "time_point", "game_id"))
fwrite(by_game, file.path(out, "scores_by_game.csv"))
susp <- el[identity_suspect == TRUE]$episode_id
fwrite(order_tp(summarise_scores(sc[!episode_id %in% susp])), file.path(out, "scores_without_identity_suspect.csv"))
fwrite(cal$bins, file.path(out, "calibration_classwise.csv"))
fwrite(calibration_groups(pred[, .(model, time_point, episode_id, outcome_id, probability)], choice, labels),
       file.path(out, "calibration_groups.csv"))
tcal <- calibration_team(rbind(sc[, .(model, time_point, p_off, y_off)], const[, .(model, time_point, p_off, y_off)]),
                         unlist(th$metrics$team_calibration_breaks))
fwrite(tcal$bins, file.path(out, "calibration_team.csv"))
fwrite(tcal$large, file.path(out, "calibration_team_large.csv"))

# ---- paired comparisons (all exploratory: baselines only) -----------------------------------------------------------
u <- th$uncertainty
cmp <- list(); cmp_game <- list()
add_cmp <- function(scores, a, b, tp, metric) {
  r <- paired_comparison(scores, a, b, tp, metric, u$bootstrap_reps, u$seed, u$level)
  cmp[[length(cmp) + 1L]] <<- r$summary
  cmp_game[[length(cmp_game) + 1L]] <<- r$by_game
}
team_sc <- rbind(sc[, .(model, time_point, episode_id, game_id, team_ll)], const[, .(model, time_point, episode_id, game_id, team_ll)])
for (tp in unique(sc$time_point)) {
  for (m in c(BASELINES[-1], "selected_reference")) add_cmp(sc, m, "uniform", tp, "ll")
  for (m in setdiff(BASELINES, "uniform")) add_cmp(sc, "selected_reference", m, tp, "ll")
  for (m in c(BASELINES, "selected_reference")) add_cmp(team_sc, m, "constant_oreb", tp, "team_ll")
}
cmp <- rbindlist(cmp)
cmp[, `:=`(superiority = hi < 0 & drop_one_max < 0, non_inferior = hi < th$decision$non_inferiority_margin_nats,
           confirmatory = FALSE)]
fwrite(cmp, file.path(out, "paired_comparisons.csv"))
fwrite(rbindlist(cmp_game), file.path(out, "paired_by_game.csv"))

# ---- leakage, invariance and reproducibility checks ---------------------------------------------------------------
lk <- list()
addl <- function(check, value, expected, pass, note = "")
  lk[[length(lk) + 1L]] <<- data.table(check = check, value = as.character(value), expected = as.character(expected),
                                        pass = pass, note = note)
for (i in seq_len(nrow(fold_chk))) addl(fold_chk$check[i], fold_chk$value[i], fold_chk$expected[i], fold_chk$pass[i])
prov <- unique(pred[, .(time_point, outer_fold, test_game, n_train)])
prov_ok <- all(vapply(seq_len(nrow(prov)), function(i) {
  ids <- unique(feat[time_point == prov$time_point[i]]$episode_id)
  tr <- fa[episode_id %in% ids & outer_fold != prov$outer_fold[i]]
  nrow(tr) == prov$n_train[i] && !(prov$test_game[i] %in% tr$game_id)
}, NA))
addl("baseline fits use exactly the training games' episodes at their time point", prov_ok, TRUE, prov_ok)
fp_base <- function(feat_tp, lab, split) {
  fit <- fit_baselines(feat_tp, lab, split$train, th$baselines$smoothing)
  predict_baselines(fit, feat_tp, split$test)
}
fp_leaky <- function(feat_tp, lab, split) {   # planted: half the mass on each test episode's credited outcome
  p <- fp_base(feat_tp, lab, split)
  p <- merge(p, lab[, .(episode_id, truth = outcome_id)], by = "episode_id")
  p[, probability := 0.5 * probability + 0.5 * (outcome_id == truth)][, truth := NULL][]
}
fr <- feat[time_point == "release"]
fa_r <- fa[episode_id %in% fr$episode_id]
inv <- vapply(sort(unique(fa_r$outer_fold)), function(k) label_invariance(fp_base, fr, labels, choice, fold_split(fa_r, k)), NA)
addl("baseline predictions unchanged when the test game's labels are altered (release, every fold)", sum(inv), length(inv), all(inv))
leaky <- !label_invariance(fp_leaky, fr, labels, choice, fold_split(fa_r, 1L))
addl("planted test-label leak is detected by the label-invariance check", leaky, TRUE, leaky)
planted <- copy(feat[time_point == "release"][1:10])
planted[, source_frame := source_frame + 30L]   # a feature read at release + 1.2 s, e.g. a position at the rebound
caught <- inherits(try(assert_information_time(planted), silent = TRUE), "try-error")
addl("planted future-only feature is rejected by the information-time check", caught, TRUE, caught)
addl("features never read a frame after their information time", nrow(feat[source_frame > frame_idx]), 0,
     nrow(feat[source_frame > frame_idx]) == 0)
addl("future-frame poisoning leaves triggers and features unchanged (5 episodes per game, every defined point)",
     sum(poison$unchanged), nrow(poison), all(poison$unchanged))
again <- run_baselines()
same <- isTRUE(all.equal(again$pred, pred, tolerance = 0)) && isTRUE(all.equal(again$selection, selection, tolerance = 0))
addl("re-running the baselines reproduces every prediction exactly", same, TRUE, same)
c2 <- paired_comparison(sc, "role_prior", "uniform", "release", "ll", u$bootstrap_reps, u$seed, u$level)$summary
same_boot <- isTRUE(all.equal(c2, cmp[candidate == "role_prior" & reference == "uniform" & time_point == "release" & metric == "ll",
                                       names(c2), with = FALSE], tolerance = 0, check.attributes = FALSE))
addl("re-running a comparison with the same seed reproduces its interval", same_boot, TRUE, same_boot)
addl("every prediction table is valid (choice set, finite, non-negative, sums to 1)", sum(valid$ok), nrow(valid), all(valid$ok))
same_eps <- sc[, .(eps = paste(sort(episode_id), collapse = ",")), by = .(model, time_point)][, uniqueN(eps), by = time_point]
addl("every model is scored on the same episodes at each time point", sum(same_eps$V1 == 1L), nrow(same_eps), all(same_eps$V1 == 1L))
n_team <- sum(labels$outcome_id %in% c("team_off", "team_def"))
addl("one label definition for every model (episode_labels), team awards kept as team outcomes",
     sprintf("%d player / %d team", nrow(labels) - n_team, n_team), "both > 0", n_team > 0 && n_team < nrow(labels))
addl("episodes outside the Step 01 population are in no prediction", sum(!unique(pred$episode_id) %in% el$episode_id), 0,
     all(unique(pred$episode_id) %in% el$episode_id))
addl("no probability floored before the log", sum(sc$floored), 0, sum(sc$floored) == 0)
if (!is.null(frozen)) {
  same_frozen <- identical(sha256_file(pred_path), frozen$predictions_sha256)
  addl("predictions equal those of the frozen design", same_frozen, TRUE, same_frozen, paste("frozen", frozen$frozen_at))
}
leak <- rbindlist(lk)
fwrite(leak, file.path(out, "leakage_checks.csv"))

# ---- population by game and time point (tracking-study: exclusions that bias a clean-looking test set) -------------
popg <- pts[, .(defined = sum(defined), no_rim_arrival = sum(reason == "no rim arrival"),
                resolved_before_t = sum(reason == "rebound at or before t"), too_few_players = sum(reason == "fewer than ten players")),
            by = .(game_id = el$game_id[match(episode_id, el$episode_id)], time_point)]
popg <- merge(popg, el[, .(eligible = .N, team_award_share = mean(!rebounded), oreb_share = mean(side == "off")), by = game_id], by = "game_id")
popg[, defined_share := defined / eligible]
fwrite(popg[order(game_id, match(time_point, time_points))], file.path(out, "population_by_game.csv"))
excl <- ep[eligible == FALSE, .N, by = .(game_id, exclusion)][order(game_id, -N)]
fwrite(excl, file.path(out, "excluded_by_game.csv"))
rim_vs_proxy <- pts[time_point == "rim+0" & !is.na(rim_arrival_frame)]
rim_vs_proxy <- merge(rim_vs_proxy, el[, .(episode_id, release_frame, contact_proxy_frame, shot_end_frame)], by = "episode_id")
rim_desc <- rim_vs_proxy[, .(fired = .N, of = nrow(el),
                             median_after_release_s = median((rim_arrival_frame - release_frame) / FPS),
                             minus_contact_proxy_frames_median = median(rim_arrival_frame - contact_proxy_frame, na.rm = TRUE),
                             before_contact_proxy_share = mean(rim_arrival_frame <= contact_proxy_frame, na.rm = TRUE),
                             within_3_frames_of_proxy = mean(abs(rim_arrival_frame - contact_proxy_frame) <= 3, na.rm = TRUE))]
fwrite(rim_desc, file.path(out, "rim_arrival_vs_contact_proxy.csv"))
if (is.null(frozen)) write_gate(freeze_path, c(freeze, list(predictions_sha256 = sha256_file(pred_path))))

# ---- report -------------------------------------------------------------------------------------------------------
md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
no_rim <- el[episode_id %in% pts[time_point == "release" & is.na(rim_arrival_frame)]$episode_id]
oreb_gap <- tcal$large[time_point == "release"]
pt_tab <- pts[, .(defined = sum(defined), no_rim_arrival = sum(reason == "no rim arrival"),
                  resolved_before_t = sum(reason == "rebound at or before t"),
                  too_few_players = sum(reason == "fewer than ten players")), by = time_point]
key_cols <- summ[time_point %in% unlist(th$confirmatory_times),
                 .(time_point, model, episodes, log_loss, brier, top1, top3, team_log_loss, ece)]
sel_tab <- selection[selected == TRUE, .N, by = .(time_point, model)][order(match(time_point, time_points), -N)]
cmp_tab <- cmp[time_point %in% unlist(th$confirmatory_times) & metric == "ll" & reference == "uniform",
               .(time_point, candidate, mean_diff, lo, hi, games_better, worst_game)]
lines <- c(
  "# Step 03: evaluation design, reference baselines and scoring harness",
  "",
  sprintf("Run %s by `src/rebounding/run_step03.R`; settings `config/experiment.yaml` (`step03`, config v%d), frozen in",
          format(Sys.Date()), cfg$config_version),
  "`outputs/rebounding/step03/design_freeze.json` before any baseline was scored. Step 02 is BLOCKED, so every model",
  "is scored on the credited outcome only: the ten players tracked at release, or a team award to either side.",
  "",
  "## Design",
  "",
  sprintf("- **Population**: the %d Step 01 eligible episodes; the %d excluded episodes stay out of every model.", nrow(el), sum(!ep$eligible)),
  "- **Folds**: leave one game out, fold k holds out the k-th game by date; inner folds leave one game out within the",
  "  nine training games and are used only for tuning and for choosing the reference baseline.",
  "- **Information time**: a forecast at frame t reads tracking frames up to t. Ball frames count once the next",
  "  frame shows they are measured (not the vendor's midpoint fill), so the ball lags one frame. The hoop is the",
  "  nominal one; the calibrated hoops come from the test game's own made shots and are not used.",
  "- **Time points**: release (shots.startFrame), and a causal rim-arrival trigger (first measured ball frame at least",
  "  6 frames after release, within 4.5 ft of the hoop horizontally, between 7 and 14 ft high, below an earlier high",
  "  point) plus 0 to 1.4 s. Pre-contact is not used: its only definitions are after-the-fact proxies. A point exists",
  "  only while the ball is loose (t before the credited rebound frame), the same rule for every model.",
  "- **Baselines** (fitted on the nine training games per fold and time point): uniform over players; side prior",
  "  (constant OREB rate split over the five of each side); role prior (side x hoop-distance rank within side);",
  "  nearest to hoop (rank among all ten); inside rule (rank of the hoop-distance gap to the nearest opponent). All",
  "  give the two team awards the training games' rates. Config v2 adds role prior and nearest to hoop fitted",
  "  separately for each shot range (rim under 5 ft, other twos, threes), each with smoothed per-range team-award",
  "  rates; they were added after the v1 scores were seen, as candidates only. The selected reference is the baseline with the lowest",
  "  inner leave-one-game-out log loss on the training games. Binary OREB reference: the training OREB share.",
  "- **Scores**: per episode, never per player row: 12-class log loss (primary), Brier, top-1/top-3 with ties",
  "  counted against the model; binary OREB log loss and Brier; class-wise and team calibration.",
  "- **Uncertainty and decisions** (for later steps): paired per-episode differences; game bootstrap and a t interval",
  "  on per-game means, the wider one used; mean with each game dropped. Superiority needs the upper bound below 0",
  sprintf("  and every drop-one mean below 0; non-inferiority needs the upper bound below %.2f nats. Ten games are too", th$decision$non_inferiority_margin_nats),
  "  few for precise inference.",
  "- **Confirmatory comparisons** (later steps): C1 static conditional logit superior to every baseline and to the",
  "  selected reference at release, each tested on its own (config v3); C2",
  "  binary OREB model vs constant rate at release; C3a/C3b dynamic vs same-time static at release (non-inferiority)",
  "  and at rim + 0.2 s (superiority). Everything else is exploratory.",
  "",
  "## Prediction points",
  "", md_table(pt_tab), "",
  sprintf("The rim-arrival trigger fired in %d of %d episodes, a median %.2f s after release; it is at or before the",
          rim_desc$fired, nrow(el), rim_desc$median_after_release_s),
  sprintf("Step 01 contact proxy in %.0f%% of them (median %+g frames) and within 3 frames of it in %.0f%%.",
          100 * rim_desc$before_contact_proxy_share, rim_desc$minus_contact_proxy_frames_median, 100 * rim_desc$within_3_frames_of_proxy),
  sprintf(paste("Of the %d episodes it misses, %d are blocked shots, %d have no rim or board contact by the Step 01 proxy",
                "(airballs) and %d other; their rim-anchored points are undefined for every model."),
          nrow(no_rim), sum(no_rim$blocked), sum(!no_rim$blocked & no_rim$contact_kind == "none"),
          sum(!no_rim$blocked & no_rim$contact_kind != "none")),
  "",
  "## Reference baselines at the confirmatory time points (held-out games)",
  "", md_table(key_cols), "",
  "Baseline chosen as the selected reference (folds):", "", md_table(sel_tab), "",
  "Paired log-loss differences against uniform (negative is better; interval is the conservative one):", "",
  md_table(cmp_tab), "",
  sprintf(paste("The rank-only baselines (nearest to hoop, inside rule) ignore side, so their P(OREB) at release averages",
                "%.3f and %.3f against an OREB rate of %.3f; side and role priors are calibrated for it (%.3f, %.3f)."),
          oreb_gap[model == "nearest_hoop"]$mean_p_off, oreb_gap[model == "inside_rule"]$mean_p_off, oreb_gap$oreb_rate[1],
          oreb_gap[model == "side_prior"]$mean_p_off, oreb_gap[model == "role_prior"]$mean_p_off),
  "Top-1 counts ties against the model, so baselines that tie whole sides (uniform, side prior) score 0 unless a team",
  "award is the single most likely outcome.",
  "",
  "All time points, by-game scores, calibration and every comparison are in `outputs/rebounding/step03/`.",
  "",
  "## Leakage, invariance and reproducibility checks",
  "", md_table(leak[, .(check, value, expected, pass)]), "",
  "## Limits",
  "",
  "- Leave one game out trains on games played after the test game (October to May); season drift is not tested.",
  "- Teams recur across games (Gran Canaria, Breogan and Zaragoza twice), so folds share players.",
  "- Delivered player positions may already be smoothed or extrapolated by the vendor using later frames; the",
  "  information rule is causal with respect to the delivered frames only.",
  "- The loose-ball rule uses the credited rebound frame to decide whether a point exists. Every model shares it, but",
  "  scores at late points are conditional on the ball still being loose.",
  sprintf("- %d of %d credited player rebounds are `identity_suspect`; scores without them are in", length(susp), sum(el$rebounded)),
  "  `scores_without_identity_suspect.csv`.")
writeLines(lines, file.path(reports, "03_evaluation_design.md"))

# ---- gate record -------------------------------------------------------------------------------------------------
crit <- list(
  folds_by_game = all(fold_chk$pass),
  predictions_valid = all(valid$ok),
  baselines_training_only = prov_ok && all(inv),
  leakage_checks_fire = leaky && caught,
  causal_points_and_features = all(poison$unchanged) && nrow(feat[source_frame > frame_idx]) == 0,
  reproducible = same && same_boot && (is.null(frozen) || same_frozen),
  identical_definitions = all(same_eps$V1 == 1L) && all(unique(pred$episode_id) %in% el$episode_id),
  harness_outputs = all(file.exists(file.path(out, c("fold_assignment.csv", "reference_baselines.csv.gz", "scores_summary.csv",
                                                     "paired_comparisons.csv", "calibration_classwise.csv", "leakage_checks.csv")))))
tests <- rbind(run_tests(here, root, "unit", "evaluation"), run_tests(here, root, "gates", "step_03"), fill = TRUE)
fwrite(tests, file.path(gr, "03_tests.csv"))
crit$tests_pass <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
unmet <- names(crit)[!vapply(crit, isTRUE, NA)]
status <- if (!length(unmet)) "PASS" else "BLOCKED"
rec <- list(
  step = "03", status = status,
  scope = sprintf(paste("leave-one-game-out harness, reference baselines and scoring for the credited outcome (12 classes) of",
                        "%d eligible misses at %d time points; Step 02 BLOCKED, so no contact-state target"), nrow(el), length(time_points)),
  source_commits = list(skillcorner = cfg$dataset$upstream_commit),
  data_revision = list(upstream = cfg$dataset$upstream_commit, manifest = cfg$dataset$checksums,
                       episodes_sha256 = freeze$episodes_sha256),
  model_revision = list(model_version = th$model_version, step03_config_sha256 = freeze$step03_config_sha256,
                        code_sha256 = freeze$code_sha256, predictions_sha256 = sha256_file(pred_path)),
  repository_head = git_out(root, "rev-parse", "HEAD")[1],
  test_command = "Rscript src/rebounding/run_tests.R unit evaluation; Rscript src/rebounding/run_tests.R gates step_03",
  unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
  data_audit_passed = all(leak$pass),
  heldout_metrics_file = "outputs/rebounding/step03/scores_summary.csv",
  acceptance_criteria_version = sprintf(paste("manual %s, config v%d (step03 first fixed %s before any baseline was scored;",
                                              "v2 added two shot-range baselines and v3 made C1 stricter after the v1/v2",
                                              "baseline scores were seen; decision log)"),
                                        cfg$manual_revision, cfg$config_version, "2026-10-30"),
  criteria = crit, unmet = unmet,
  baselines_at_release = summ[time_point == "release", .(model, log_loss = round(log_loss, 4), top1 = round(top1, 4),
                                                         team_log_loss = round(team_log_loss, 4))],
  confirmatory = th$confirmatory,
  deviations = list(
    list(item = "pre-contact prediction point",
         decision = paste("Not used: no causal definition exists (contact frames are after-the-fact proxies; Step 02 labels BLOCKED).",
                          "Replaced by a causal rim-arrival trigger, fixed in config before scoring.")),
    list(item = "file formats and paths",
         decision = "CSV / gzip CSV instead of parquet, R instead of Python, as in Steps 00-02 (config `paths`).")),
  evidence = c("outputs/rebounding/step03/", "outputs/rebounding/reports/03_evaluation_design.md",
               "outputs/rebounding/step03/design_freeze.json", "outputs/rebounding/step03/leakage_checks.csv"),
  reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
  open_risks = list("Ten game clusters: intervals are indicative only",
                    "Leave one game out trains on later games; season drift untested",
                    "The rim-arrival trigger is not validated against labelled contacts (Step 02 BLOCKED)",
                    "Vendor smoothing of player tracks may use later frames"),
  decision_note = if (status == "PASS") "Folds, information rule, baselines, scoring and decision rules frozen; harness checks pass." else
    paste("Unmet:", paste(unmet, collapse = ", ")))
write_gate(file.path(gr, "03_evaluation.json"), rec)

print(pt_tab)
print(summ[, .(time_point, model, episodes, log_loss = round(log_loss, 4), brier = round(brier, 4), top1 = round(top1, 3),
               top3 = round(top3, 3), team_ll = round(team_log_loss, 4), ece = round(ece, 4))], nrows = 200)
print(leak[, .(check = substr(check, 1, 90), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 03:", status, if (length(unmet)) paste("- unmet:", paste(unmet, collapse = ", ")) else "", "\n")
