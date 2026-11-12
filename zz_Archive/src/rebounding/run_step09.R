## ═════════════════════════════════════════════════════════════════════════════
# Step 09 of the rebounding manual: rebound probabilities that combine player geometry with ball uncertainty and each
# player's access to the ball, at release and at rim + 0.2 s, judged against the Step 04 static model at the same time
# (Step 03's C3a and C3b). Ball inputs come from Steps 05 and 07 (exploratory, BLOCKED there); access from Step 08.
#   Rscript src/rebounding/run_step09.R
#   Rscript src/rebounding/run_step09.R --fold=k   (one fold, cached; run the ten as parallel processes, then the plain run)
# Needs raw_*.rds and the Step 01, 03, 04, 05, 06 and 08 outputs. Settings: config/experiment.yaml (step09, fixed
# before any real-data run). Writes outputs/rebounding/step09/, reports/09_model_comparison.md,
# gate_results/09_dynamic.json and 09_tests.csv.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R",
            "static_geometry.R", "conditional_choice.R", "spatial_prior.R", "physics.R", "particle_filter.R",
            "player_motion.R", "reach.R", "particle_integration.R", "dynamic_choice.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step09
inf <- th3$information
pt <- th$particles
cache <- file.path(root, "outputs", "cache", "rebounding")
o <- function(...) file.path(root, "outputs", "rebounding", ...)
out <- o("step09")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))

fz <- jsonlite::fromJSON(o("step03", "design_freeze.json"))
freeze_ok <- c(config = identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3)))),
               code = all(vapply(names(fz$code_sha256), function(f) identical(fz$code_sha256[[f]], sha256_file(file.path(here, "R", f))), NA)))
if (!all(freeze_ok)) stop("Step 03's design changed since it was frozen")

el <- fread(o("step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(o("step03", "fold_assignment.csv"))
choice <- choice_sets(el)
labels <- episode_labels(el)
f3 <- readRDS(file.path(cache, "step03_features.rds"))$features[time_point %in% unlist(th$times)]
pts <- fread(o("step03", "prediction_points.csv"))[time_point == "release", .(episode_id, t_rim = rim_arrival_frame)]
rel <- f3[time_point == "release"]
shot <- el[, .(episode_id, shooter_id, shot_dist, three, rim = shot_range == "rim (<5 ft)", shot_range)]
shot <- merge(shot, merge(rel[, .(episode_id, pid, sx = x, sy = y)], shot[, .(episode_id, pid = shooter_id)], by = c("episode_id", "pid"))[, .(episode_id, sx, sy)], by = "episode_id")
shot[, side := shot_side(sy)]
static4 <- fread(o("step04", "static_oof.csv.gz"), colClasses = list(character = "outcome_id"))
p6 <- fread(o("step06", "parameters_by_fold.csv"))
l8 <- fread(o("step08", "limits_and_damping_by_fold.csv"))
tg5 <- fread(o("step05", "spatial_targets.csv"))[!is.na(cell)]
grid <- spatial_grid(cfg$step05$domain)
OFF <- unlist(cfg$step07$origins$offsets_frames)
LEAD <- pt$analog_lead_frames
K <- pt$count
KP <- pt$prediction_count   # training particles; held-out prediction particles (deviation, config)
ep_index <- setNames(seq_len(nrow(el)), el$episode_id)
sf_at <- setNames(lapply(unlist(th$times), function(tp) static_features(f3[time_point == tp, .(episode_id, pid, off, x, y, source_frame)], shot)), unlist(th$times))
frame_at <- f3[, .(frame_idx = frame_idx[1]), by = .(episode_id, time_point)]





## ═════════════════════════════════════════════════════════════════════════════
## 01 - TRACKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Ball observations, causal player velocities, made-shot crossings.

message("Step 09: tracks")
eps <- list()
cross <- list()
for (g in matches$id) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  cross[[length(cross) + 1L]] <- made_crossings(raw, g)
  for (k in which(el$game_id == g)) {
    s <- el[k]
    tr <- episode_tracking(raw, s, home == s$off_team, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
    eps[[s$episode_id]] <- list(s = s, obs = tr$ball[measured == TRUE], players = tr$players, t_rim = pts[episode_id == s$episode_id]$t_rim)
  }
}
cross <- rbindlist(cross)

#' Players at frame t with causal velocities (Step 08), from player rows up to t only.
players_state <- function(players, t) {
  v <- causal_velocity(players[frame <= t, .(frame, pid, x, y, det)], cfg$step08$velocity$window_frames, cfg$step08$velocity$min_detected)
  st <- v[frame == t, .(pid, x, y, vx = fcoalesce(vx, 0), vy = fcoalesce(vy, 0))]
  st
}
#' A context: the games whose data a set of features may use (hoops, map, analog library, timing).
make_ctx <- function(games, k) {
  hh <- cross[game_id %in% games, .(hx = median(x), hy = median(y)), by = left_hoop]
  hoops <- setNames(lapply(hh$left_hoop, function(l) c(hh[left_hoop == l]$hx, hh[left_hoop == l]$hy, RIM_Z)), as.character(hh$left_hoop))
  g <- p6[outer_fold == k]$g
  ids <- fa[game_id %in% games]$episode_id
  tg <- tg5[episode_id %in% ids, .(episode_id, tx, ty, cell, shot_range, side)]
  map_fit <- fit_spatial(grid, tg, pt$map_bandwidth_ft, 0, pt$map_w_side, cfg$step05)
  rows <- rbindlist(lapply(intersect(ids, names(eps)), function(id) {
    e <- eps[[id]]
    if (is.na(e$t_rim)) return(NULL)
    org <- e$t_rim + OFF
    org <- org[org < e$s$rebound_frame]
    if (!length(org)) return(NULL)
    analog_rows(e$obs, org, OFF[seq_along(org)], LEAD, e$s$rebound_frame, hoops[[as.character(e$s$left_hoop)]], g)
  }))
  avail <- el[episode_id %in% ids, .(avail = median((rebound_frame - release_frame) / FPS)), by = shot_range]
  list(games = games, hoops = hoops, g = g, r = unlist(p6[outer_fold == k, .(r_x, r_y, r_z)]), map = map_fit,
       lib = if (nrow(rows)) analog_library(rows) else NULL, avail = avail,
       rp = modifyList(cfg$step08$reach, list(v_max = l8[outer_fold == k]$v_max)))
}
#' Access rows of one episode at one time under a context, from observations up to the time only.
episode_acc <- function(id, tp, ctx, n_part, seed, obs = eps[[id]]$obs, players = eps[[id]]$players) {
  e <- eps[[id]]
  t <- frame_at[episode_id == id & time_point == tp]$frame_idx
  if (!length(t)) return(NULL)
  st <- players_state(players, t)
  sh <- shot[episode_id == id]
  set.seed(seed)
  # At release the particles come from the spatial map; later they come from the ball filter.
  if (tp == "release") {
    M <- predict_spatial(ctx$map, "side_range_kde", sh$shot_range, sh$side)
    parts <- particles_from_map(M, grid, n_part)
    avail <- ctx$avail[shot_range == sh$shot_range]$avail
  } else {
    hoop <- ctx$hoops[[as.character(e$s$left_hoop)]]
    s2 <- two_point_state(obs[usable_from <= t], t, ctx$g)
    if (is.null(s2) || is.null(ctx$lib)) return(NULL)
    a <- analog_forecast(ctx$lib, s2, t - e$t_rim, LEAD, hoop, cfg$step07$empirical_k, ctx$r)
    parts <- particles_from_analog(a, n_part, hoop)
    avail <- LEAD / FPS
  }
  acc <- access_features(st, parts, avail, ctx$rp)
  if (is.null(acc)) NULL else cbind(episode_id = id, acc)
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FOLDS ------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# `--fold=k` computes and caches one fold (folds run as parallel processes: one fold takes about 3 minutes);
# a run without it computes any fold whose cache is missing or stale, then scores everything.

fold_key <- c(cfg = paste(openssl::sha256(yaml::as.yaml(th))), code = paste(vapply(c("particle_integration.R", "dynamic_choice.R"),
                                                                                   function(f) sha256_file(file.path(here, "R", f)), ""), collapse = ""))
fold_file <- function(k) file.path(cache, sprintf("step09_fold_%02d.rds", k))
# One outer fold: contexts, then at each time point the dynamic and access-only models with their checks.
run_fold <- function(k) {
  fc <- list(key = fold_key, fold = k, pred = list(), coef = list(), flags = list(), stab = list(), degr = list(), models = list())
  {
    s <- fold_split(fa, k)
    tr_games <- sort(unique(fa[episode_id %in% s$train]$game_id))
    ctx_test <- make_ctx(tr_games, k)
    inner <- setNames(lapply(tr_games, function(g) make_ctx(setdiff(tr_games, g), k)), tr_games)
    for (tp in unlist(th$times)) {
      sf <- sf_at[[tp]]
      ids_tp <- unique(sf$episode_id)
      tr_ids <- intersect(s$train, ids_tp)
      te_ids <- intersect(s$test, ids_tp)
      ti <- match(tp, unlist(th$times))
      acc_tr <- rbindlist(lapply(tr_ids, function(id) episode_acc(id, tp, inner[[as.character(el[episode_id == id]$game_id)]], K,
                                                                  th$stability$seed + 10L * ep_index[[id]] + ti)))
      acc_te <- rbindlist(lapply(te_ids, function(id) episode_acc(id, tp, ctx_test, KP, th$stability$seed + 10L * ep_index[[id]] + ti)))
      sc <- fit_scaler(sf, shot, tr_ids)
      asc <- fit_access_scaler(acc_tr, tr_ids)
      for (mname in c("dynamic", "access_only")) {
        feats <- if (mname == "dynamic") c(PLAYER_FEATURES, ACCESS_FEATURES) else ACCESS_FEATURES
        dtr <- dyn_design(sf, acc_tr, shot, tr_ids, sc, asc, feats)
        fit <- fit_dyn(dtr, dyn_labels(dtr, labels), th$model$lambda)
        pte <- predict_dyn_ids(fit, sf, acc_te, shot, te_ids, sc, asc, feats)
        fc$pred[[length(fc$pred) + 1L]] <- cbind(model = mname, time_point = tp, outer_fold = k, pte)
        fc$coef[[length(fc$coef) + 1L]] <- data.table(model = mname, time_point = tp, outer_fold = k, term = names(fit$beta),
                                                      estimate = unname(fit$beta), converged = fit$converged, n_train = length(tr_ids))
        if (mname == "dynamic") {
          fc$models[[paste(k, tp)]] <- list(fit = fit, scaler = sc, access_scaler = asc, version = th$model_version, ctx = ctx_test)
          # particle noise at prediction time: the same model, particles redrawn with another seed and with twice as many
          for (run in c("second seed", "twice the particles")) {
            nk <- if (run == "twice the particles") 2L * KP else KP
            sd0 <- if (run == "second seed") 7919L else 0L
            a2 <- rbindlist(lapply(te_ids, function(id) episode_acc(id, tp, ctx_test, nk, th$stability$seed + sd0 + 10L * ep_index[[id]] + ti)))
            fc$stab[[length(fc$stab) + 1L]] <- cbind(run = run, time_point = tp, predict_dyn_ids(fit, sf, a2, shot, te_ids, sc, asc, feats))
          }
          # Degraded ball at rim+0.2: a random share of the ball observations kept, then the same model.
          if (tp == "rim+0.2") {
            a3 <- rbindlist(lapply(te_ids, function(id) {
              ob <- eps[[id]]$obs
              set.seed(ep_index[[id]])
              keep <- sort(sample.int(nrow(ob), max(2L, round(nrow(ob) * th$degraded_ball$keep))))
              episode_acc(id, tp, ctx_test, KP, th$stability$seed + 10L * ep_index[[id]] + ti, obs = ob[keep])
            }))
            fc$degr[[length(fc$degr) + 1L]] <- cbind(time_point = tp, predict_dyn_ids(fit, sf, a3, shot, te_ids, sc, asc, feats))
          }
          fc$flags[[length(fc$flags) + 1L]] <- data.table(time_point = tp, outer_fold = k, episode_id = te_ids,
                                                          no_ball_forecast = !te_ids %in% acc_te$episode_id)
        }
      }
    }
  }
  saveRDS(fc, fold_file(k))
  message("  fold ", k, " done")
}
fold_arg <- as.integer(sub("^--fold=", "", grep("^--fold=", commandArgs(trailingOnly = TRUE), value = TRUE)))
if (length(fold_arg)) {
  run_fold(fold_arg)
  quit(save = "no")
}
message("Step 09: folds")
for (k in sort(unique(fa$outer_fold)))
  if (!file.exists(fold_file(k)) || !identical(readRDS(fold_file(k))$key, fold_key)) run_fold(k)
parts <- lapply(sort(unique(fa$outer_fold)), function(k) readRDS(fold_file(k)))
fc <- lapply(setNames(nm = c("pred", "coef", "flags", "stab", "degr", "models")), function(n) do.call(c, lapply(parts, `[[`, n)))
pred <- rbindlist(fc$pred)
coefs <- rbindlist(fc$coef)
flags <- rbindlist(fc$flags)
stab <- rbindlist(fc$stab)
degr <- rbindlist(fc$degr)
pred <- merge(pred, frame_at, by = c("episode_id", "time_point"))
pred[, model_version := th$model_version]
fwrite(pred[order(model, time_point, outer_fold, episode_id, outcome_id)], file.path(out, "dynamic_oof.csv.gz"))
fwrite(coefs, file.path(out, "coefficients.csv"))
fwrite(flags, file.path(out, "flags.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SCORES, DECISIONS, CALIBRATION -----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

valid <- check_predictions(pred[, .(model, time_point, episode_id, outcome_id, probability)], choice, th3$metrics$sum_tol)
st4 <- static4[, .(model = "static_clogit", time_point, episode_id, outcome_id, probability)]
allp <- rbind(pred[, .(model, time_point, episode_id, outcome_id, probability)], st4)
sc_all <- score_episodes(allp, choice, labels, th3$metrics$prob_floor)
cal <- calibration_classwise(allp, labels, unlist(th3$metrics$calibration_breaks))
summ <- merge(summarise_scores(sc_all), cal$ece, by = c("model", "time_point"))[order(time_point, log_loss)]
fwrite(summ, file.path(out, "scores_summary.csv"))
fwrite(cal$bins, file.path(out, "calibration_classwise.csv"))
fwrite(calibration_groups(allp, choice, labels), file.path(out, "calibration_groups.csv"))
tcal <- calibration_team(sc_all[, .(model, time_point, p_off, y_off)], unlist(th3$metrics$team_calibration_breaks))
fwrite(tcal$large, file.path(out, "calibration_team_large.csv"))
u <- th3$uncertainty
dec <- th3$decision
pc <- function(a, b, tp, metric = "ll") paired_comparison(sc_all, a, b, tp, metric, u$bootstrap_reps, u$seed, u$level)
c3a <- pc("dynamic", "static_clogit", "release")
c3b <- pc("dynamic", "static_clogit", "rim+0.2")
ex <- rbindlist(lapply(unlist(th$times), function(tp) rbind(pc("access_only", "static_clogit", tp)$summary, pc("dynamic", "access_only", tp)$summary,
                                                            pc("dynamic", "static_clogit", tp, "team_ll")$summary)))
cmp <- rbind(cbind(test = "C3a (confirmatory)", c3a$summary), cbind(test = "C3b (confirmatory)", c3b$summary), cbind(test = "exploratory", ex))
cmp[, `:=`(superior = hi < 0 & drop_one_max < 0, non_inferior = hi < dec$non_inferiority_margin_nats)]
fwrite(cmp, file.path(out, "comparisons.csv"))
fwrite(rbind(c3a$by_game, c3b$by_game), file.path(out, "c3_by_game.csv"))
ece <- dcast(summ[model %in% c("dynamic", "static_clogit")], time_point ~ model, value.var = "ece")
ece[, ok := dynamic <= static_clogit + dec$calibration_ece_margin]
c3a_ok <- decide(c3a$summary, "non_inferiority", dec$non_inferiority_margin_nats)
c3b_ok <- decide(c3b$summary, "superiority", dec$non_inferiority_margin_nats)
cal_ok <- all(ece$ok)
sub <- merge(sc_all[model %in% c("dynamic", "static_clogit")], el[, .(episode_id, shot_range, credited_outcome)], by = "episode_id")
sub <- merge(sub, flags[, .(episode_id, time_point, no_ball_forecast)], by = c("episode_id", "time_point"), all.x = TRUE)
fail <- rbind(sub[, .(group = paste("shot range:", shot_range), n = .N, log_loss = mean(ll), top1 = mean(top1)), by = .(time_point, model, shot_range)][, shot_range := NULL],
              sub[, .(group = paste("outcome:", credited_outcome), n = .N, log_loss = mean(ll), top1 = mean(top1)), by = .(time_point, model, credited_outcome)][, credited_outcome := NULL],
              sub[no_ball_forecast %in% TRUE, .(group = "no ball forecast (flagged)", n = .N, log_loss = mean(ll), top1 = mean(top1)), by = .(time_point, model)])
fwrite(fail[order(time_point, group, model)], file.path(out, "by_subgroup.csv"))

# particle stability and the degraded ball
base_ll <- sc_all[model == "dynamic", .(time_point, episode_id, ll0 = ll)]
st_sc <- score_episodes(stab[, .(model = run, time_point, episode_id, outcome_id, probability)], choice, labels, th3$metrics$prob_floor)
st_tab <- merge(st_sc[, .(run = model, time_point, episode_id, ll)], base_ll, by = c("time_point", "episode_id"))[
  , .(episodes = .N, mean_abs_diff = mean(abs(ll - ll0)), mean_diff = mean(ll - ll0)), by = .(run, time_point)]
st_tab[, stable := mean_abs_diff < th$stability$max_mean_abs_diff_nats & abs(mean_diff) < th$stability$max_mean_diff_nats]
fwrite(st_tab, file.path(out, "particle_stability.csv"))
top_of <- function(p) p[!outcome_id %in% c("team_off", "team_def"), .(top = max(probability)), by = episode_id]
dg <- merge(top_of(degr), top_of(pred[model == "dynamic" & time_point == "rim+0.2"]), by = "episode_id", suffixes = c("_degraded", "_full"))
dg_tab <- dg[, .(episodes = .N, mean_top_full = mean(top_full), mean_top_degraded = mean(top_degraded), rise = mean(top_degraded - top_full))]
dg_tab[, ok := rise <= th$degraded_ball$max_top_prob_rise]
fwrite(dg_tab, file.path(out, "degraded_ball.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - CHECKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Including a causal replay through predict_rebound()

ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                    expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", all(freeze_ok), TRUE, all(freeze_ok))
addc("predictions valid (12 outcomes, finite, non-negative, sum to 1)", sum(valid$ok), nrow(valid), all(valid$ok))
same_eps <- sc_all[, .(eps = paste(sort(episode_id), collapse = ",")), by = .(model, time_point)][, uniqueN(eps), by = time_point]
addc("dynamic, access-only and static scored on the same episodes and time points", sum(same_eps$V1 == 1L), nrow(same_eps), all(same_eps$V1 == 1L))
po <- merge(allp, choice[, .(episode_id, outcome_id, side)], by = c("episode_id", "outcome_id"))[, .(p_off = sum(probability[side == "off"]), total = sum(probability)), by = .(model, time_point, episode_id)]
addc("P(OREB) = offensive players + offensive team award, and the 12 outcomes sum to 1", signif(max(abs(po$total - 1)), 3), "< 1e-9", max(abs(po$total - 1)) < 1e-9)
addc("every fit converged", sum(coefs[, all(converged), by = .(model, time_point, outer_fold)]$V1), coefs[, uniqueN(paste(model, time_point, outer_fold))],
     all(coefs$converged))
addc("particle draws stable (second seed, twice the particles)", paste(round(st_tab$mean_abs_diff, 4), collapse = " / "),
     sprintf("mean |diff| < %.2f, |mean diff| < %.2f", th$stability$max_mean_abs_diff_nats, th$stability$max_mean_diff_nats), all(st_tab$stable))
addc("confidence does not rise when half the ball frames are dropped (mean top probability change)", round(dg_tab$rise, 4),
     paste("<=", th$degraded_ball$max_top_prob_rise), dg_tab$ok)
# causal replay: predict_rebound on fold 1 episodes from inputs built at the frame, with later tracking corrupted
k1 <- 1L
replay_ids <- head(intersect(fa[outer_fold == k1]$episode_id, unique(pred[time_point == "rim+0.2"]$episode_id)), 12L)
models_k1 <- list(release = fc$models[[paste(k1, "release")]], `rim+0.2` = fc$models[[paste(k1, "rim+0.2")]])
# Inputs for a causal replay; `corrupt` scrambles everything after t.
make_inputs <- function(corrupt) function(id, t) {
  e <- eps[[id]]
  tp <- if (!is.na(e$t_rim) && t >= e$t_rim) "rim+0.2" else "release"
  ob <- e$obs
  plr <- e$players
  if (corrupt) {
    ob <- copy(ob)[usable_from > t, `:=`(x = x + 20, z = z + 5)]
    plr <- copy(plr)[frame > t, `:=`(x = x - 25, y = -y)]
  }
  ctx <- models_k1[[tp]]$ctx
  acc <- episode_acc(id, tp, ctx, KP, th$stability$seed + 10L * ep_index[[id]] + match(tp, unlist(th$times)), obs = ob, players = plr)
  pos <- features_at(plr[frame <= t, .(frame, pid, off, x, y, det)], t, inf$player_carry_frames)
  sfi <- static_features(cbind(episode_id = id, pos[, .(pid, off, x, y, source_frame)]), shot)
  list(kind = tp, sf = sfi, acc = if (is.null(acc)) acc_empty else acc, shot = shot, flags = if (is.null(acc)) "no ball forecast" else character())
}
acc_empty <- data.table(episode_id = character(), pid = integer(), k = integer(), access_margin = numeric(), best_access = numeric())
replay_ok <- all(vapply(replay_ids, function(id) {
  t <- frame_at[episode_id == id & time_point == "rim+0.2"]$frame_idx
  a <- predict_rebound(id, t, make_inputs(FALSE), models_k1)
  b <- predict_rebound(id, t, make_inputs(TRUE), models_k1)
  oof <- pred[model == "dynamic" & time_point == "rim+0.2" & episode_id == id]
  m <- merge(a$players[, .(outcome_id = player_id, p = p_player)], oof[, .(outcome_id, q = probability)], by = "outcome_id")
  isTRUE(all.equal(a$players, b$players, tolerance = 0)) && max(abs(m$p - m$q)) < 1e-10 && nrow(m) == 10L
}, NA))
addc("predict_rebound replays the out-of-fold predictions and ignores corrupted later frames (12 episodes)", replay_ok, TRUE, replay_ok)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - REPORT -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
st_dyn <- if (c3a_ok && c3b_ok && cal_ok) "PASS" else if (c3a_ok) "PASS_BASELINE" else "BLOCKED"
cf <- coefs[model == "dynamic" & term %in% ACCESS_FEATURES, .(mean = mean(estimate), min = min(estimate), max = max(estimate)), by = .(time_point, term)]
# The step's markdown report.
lines <- c("# Step 09: rebound probabilities with ball uncertainty and player access",
           "",
           sprintf("Run %s by `src/rebounding/run_step09.R`; settings `config/experiment.yaml` (`step09`, config v%d), fixed before any",
                   format(Sys.Date()), cfg$config_version),
           "real-data run. Compared with the Step 04 static conditional logit at the same time point (Step 03's C3a and C3b).",
           "",
           sprintf("**Model.** For each ball particle (30 per training episode, %d per held-out prediction), one softmax over the 12 outcomes with the Step 04 player features plus each", KP),
           "player's access margin to that particle (Step 08 arrival rule) and whether he has the best margin; the episode's",
           "probabilities are the average over particles. Particles: the Step 05 release map at release; the Step 07 analog",
           "forecast of the ball 0.4 s ahead at rim + 0.2 s (both exploratory). A training episode's particles come from models",
           "fitted without the test game and without its own game. Lambda 3, no temperature.",
           sprintf(paste("**Deviation.** Held-out predictions use %d particles (owner decision after the first run, which used 30 and failed",
                         "the stability check; kept in `step09/first_run_30_particles/`). The fitted models are unchanged."), KP),
           "",
           "## Held-out scores", "", md_table(summ[, .(time_point, model, episodes, log_loss, brier, top1, top3, team_log_loss, ece)], 4), "",
           "## Confirmatory tests", "",
           md_table(cmp[, .(test, candidate, reference, time_point, metric, mean_diff, lo, hi, games_better, drop_one_max, superior, non_inferior)], 4), "",
           sprintf("- C3a (release, non-inferiority, margin %.2f): **%s**.", dec$non_inferiority_margin_nats, if (c3a_ok) "met" else "not met"),
           sprintf("- C3b (rim + 0.2 s, superiority): **%s**.", if (c3b_ok) "met" else "not met"),
           sprintf("- Calibration (class-wise ECE at most static + %.2f): %s.", dec$calibration_ece_margin, if (cal_ok) "met" else "not met"),
           sprintf("- **Step 09: %s.**", st_dyn), "", md_table(ece, 4), "",
           "## Access coefficients (per standard deviation, range over folds)", "", md_table(cf, 3), "",
           "## Particle stability and the degraded ball", "", md_table(st_tab, 4), "", md_table(dg_tab, 4), "",
           "## By subgroup", "", md_table(fail[order(time_point, group, model)], 3), "",
           "## Checks", "", md_table(checks), "",
           "## Limits", "",
           "- The ball inputs are not validated (Steps 05 and 07 BLOCKED); any gain is a gain in held-out scores, not proof the",
           "  ball forecasts are right.",
           "- Two time points only; ten games; no player heights or skills.")
writeLines(lines, o("reports", "09_model_comparison.md"))





## ═════════════════════════════════════════════════════════════════════════════
## 06 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

tests <- rbind(run_tests(here, root, "unit", "dynamic"), run_tests(here, root, "gates", "step_09"), fill = TRUE)
fwrite(tests, o("gate_results", "09_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
harness_ok <- all(checks$pass) && tests_ok
status <- if (!harness_ok) "BLOCKED" else st_dyn
# The gate record.
rec <- list(step = "09", status = status,
            scope = sprintf("dynamic 12-outcome probabilities at release and rim + 0.2 s (%d and %d episodes)", uniqueN(pred[time_point == "release"]$episode_id),
                            uniqueN(pred[time_point == "rim+0.2"]$episode_id)),
            components = list(dynamic = st_dyn, access_only = "exploratory", shipped = if (st_dyn == "PASS") "dynamic" else if (st_dyn == "PASS_BASELINE") "dynamic at release / static at rim+0.2" else "Step 04 static"),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit),
            data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
            model_revision = list(model_version = th$model_version, step09_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                                  code_sha256 = setNames(lapply(c("particle_integration.R", "dynamic_choice.R"), function(f) sha256_file(file.path(here, "R", f))),
                                                         c("particle_integration.R", "dynamic_choice.R"))),
            repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit dynamic; Rscript src/rebounding/run_tests.R gates step_09",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = all(checks$pass),
            heldout_metrics_file = "outputs/rebounding/step09/scores_summary.csv",
            acceptance_criteria_version = sprintf("manual %s, config v%d (step09 fixed before any real-data run; step03 C3a/C3b)", cfg$manual_revision, cfg$config_version),
            decision = list(C3a = c3a_ok, C3b = c3b_ok, calibration = cal_ok,
                            tests = cmp[test != "exploratory", .(test, mean_diff = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4), drop_one_max = round(drop_one_max, 4))]),
            evidence = c("outputs/rebounding/step09/", "outputs/rebounding/reports/09_model_comparison.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("Ball inputs exploratory (Steps 05 and 07 BLOCKED)", "Two time points only", "Ten games"),
            deviations = list(list(item = "prediction particles", decision = sprintf("%d per held-out prediction (first run: 30, failed stability; kept in step09/first_run_30_particles/); training particles 30, unchanged", KP))),
            decision_note = sprintf("C3a %s, C3b %s, calibration %s.", c3a_ok, c3b_ok, cal_ok))
write_gate(o("gate_results", "09_dynamic.json"), rec)

print(summ[, .(time_point, model, ll = round(log_loss, 4), top1 = round(top1, 3), top3 = round(top3, 3), tll = round(team_log_loss, 4), ece = round(ece, 4))])
print(cmp[, .(test, candidate, reference, time_point, metric, d = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4), drop1 = round(drop_one_max, 4))])
print(ece)
print(cf)
print(st_tab)
print(dg_tab)
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 09:", status, "\n")
