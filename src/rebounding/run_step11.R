# Step 11 of the rebounding manual: geometric obstruction, then whether it is worth anything. Pairwise obstruction of
# every player's routes to a fixed set of points around the hoop at release and rim + 0.2 s; geometry checks on real
# data (mirroring, rotation, zero distances, one-foot moves, target sensitivity); pairings that are never forced; the
# Step 04 logit with the two obstruction features against Step 04 itself in held-out games; the split of each player's
# collection, his side's chance and the model's obstruction contribution; and a blind review sample for box-out labels.
#   Rscript src/rebounding/run_step11.R
# Needs raw_*.rds, the Step 01, 03 and 04 outputs and outputs/cache/rebounding/step03_features.rds. Settings:
# config/experiment.yaml (step11, fixed before any real-data run). Writes outputs/rebounding/step11/,
# reports/11_boxout_validity.md, gate_results/11_obstruction.json and 11_tests.csv. The review sample, its pages and
# the blank sheet (step11/review/) are drawn once and never redrawn; a filled sheet is scored on every run.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R",
            "static_geometry.R", "conditional_choice.R", "player_motion.R", "spatial_prior.R", "positioning.R",
            "pairwise_obstruction.R", "boxout.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03; th4 <- cfg$step04; th <- cfg$step11
p <- th$score; pc <- th$pairing; pt <- th$perturbation; inf <- th3$information
cache <- file.path(root, "outputs", "cache", "rebounding")
o <- function(...) file.path(root, "outputs", "rebounding", ...)
out <- o("step11"); rev_dir <- file.path(out, "review")
dir.create(rev_dir, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
fz <- jsonlite::fromJSON(o("step03", "design_freeze.json"))
freeze_ok <- identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3)))) &&
  identical(fz$predictions_sha256, sha256_file(o("step03", "reference_baselines.csv.gz")))
if (!freeze_ok) stop("Step 03's design changed since it was frozen")

# ---- inputs (as Step 04) -------------------------------------------------------------------------------------------------
el <- fread(o("step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(o("step03", "fold_assignment.csv"))
choice <- choice_sets(el); labels <- episode_labels(el)
times <- unlist(th$times)
f3 <- readRDS(file.path(cache, "step03_features.rds"))$features[time_point %in% c(times, "release")]
assert_information_time(f3)
rel <- f3[time_point == "release"]
shot <- el[, .(episode_id, shooter_id, shot_dist, three, rim = shot_range == "rim (<5 ft)")]
sp <- merge(rel[, .(episode_id, pid, sx = x, sy = y)], shot[, .(episode_id, pid = shooter_id)], by = c("episode_id", "pid"))
shot <- merge(shot, sp[, .(episode_id, sx, sy)], by = "episode_id")
static_oof <- fread(o("step04", "static_oof.csv.gz"), colClasses = list(character = "outcome_id"))[time_point %in% times]
lam4 <- fread(o("step04", "lambda_selection.csv"))[selected == TRUE, .(time_point, outer_fold, lambda)]
tg <- obstruction_targets(th$targets)
tg_hoop <- data.table(tx = RIM_X, ty = 0)
cand_features <- c(PLAYER_FEATURES, OBSTRUCTION_FEATURES)
u <- th3$uncertainty; dec <- th3$decision
feat_key <- function(f) f[order(episode_id, pid)]

# ---- tracks: velocities at t and the frames before t (persistence) --------------------------------------------------------
message("Step 11: tracks")
eps <- list()
for (g in matches$id) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  for (k in which(el$game_id == g)) {
    s <- el[k]
    tr <- episode_tracking(raw, s, home == s$off_team, inf$keyframe_tol_ft, inf$ball_delay_frames, 25L)
    eps[[s$episode_id]] <- list(s = s, players = tr$players, ball = tr$ball)
  }
}
rm(raw)
#' Positions (as the Step 03 features) and causal velocities (Step 08 rule, last row within the carry) at frame t.
state_at <- function(id, t, pos) {
  v <- causal_velocity(eps[[id]]$players[frame <= t, .(frame, pid, x, y, det)], cfg$step08$velocity$window_frames %||% 6L,
                       cfg$step08$velocity$min_detected)
  v <- v[frame >= t - inf$player_carry_frames & !is.na(vx)][order(pid, -frame)][!duplicated(pid)]
  merge(pos, v[, .(pid, vx, vy)], by = "pid", all.x = TRUE)[, `:=`(vx = fcoalesce(vx, 0), vy = fcoalesce(vy, 0))][]
}

# ---- obstruction at each time, with the real-data geometry checks ------------------------------------------------------
res <- list(); geo <- list(); pairs_all <- list(); pert_rows <- list(); ctx_rows <- list()
for (tp in times) {
  message("Step 11: obstruction at ", tp)
  pl <- f3[time_point == tp, .(episode_id, pid, off, x, y, source_frame, frame_idx)]
  eo <- episode_obstruction(pl, tg, p, pc)
  res[[tp]] <- list(pl = pl, eo = eo)
  f0 <- feat_key(eo$features)
  # mirror left to right (the target set is symmetric) and rotate players and targets 30 degrees about the hoop
  mir <- feat_key(episode_obstruction(copy(pl)[, y := -y], tg, p, pc)$features)
  a <- pi / 6
  rot <- function(x, y) list(x = RIM_X + (x - RIM_X) * cos(a) - y * sin(a), y = (x - RIM_X) * sin(a) + y * cos(a))
  rp <- rot(pl$x, pl$y); rt <- rot(tg$tx, tg$ty)
  rotd <- feat_key(episode_obstruction(copy(pl)[, `:=`(x = rp$x, y = rp$y)], data.table(tx = rt$x, ty = rt$y), p, pc)$features)
  hoop_only <- feat_key(episode_obstruction(pl, tg_hoop, p, pc)$features)
  # one-foot moves
  set.seed(pt$seed + match(tp, times))
  ang <- runif(nrow(pl), 0, 2 * pi)
  pj <- copy(pl)[, `:=`(x = x + pt$shift_ft * cos(ang), y = y + pt$shift_ft * sin(ang))]
  ej <- episode_obstruction(pj, tg, p, pc)
  fj <- feat_key(ej$features)
  cls <- function(pg) pg[, .(episode_id, pid, cls = fifelse(pairing == "pair", paste("pair", runner), pairing))]
  pch <- merge(cls(eo$pairings), cls(ej$pairings), by = c("episode_id", "pid"))
  # context, not gated (owner decision 2026-11-05, after the first run): the same moves on Step 04's own features, in
  # units of each feature's spread, and whether the ten keep their order
  cols <- c("episode_id", "pid", "off", "x", "y", "source_frame")
  fa_ <- merge(static_features(pl[, ..cols], shot), eo$features, by = c("episode_id", "pid"))
  fb_ <- merge(static_features(pj[, ..cols], shot), ej$features, by = c("episode_id", "pid"))
  setkey(fa_, episode_id, pid); setkey(fb_, episode_id, pid)
  ctx_rows[[tp]] <- rbindlist(lapply(c(OBSTRUCTION_FEATURES, "inside_gap", "nearest_opp_dist", "n_within_6", "closeness_share",
                                       "opp_inside", "dist_hoop"), function(v)
    data.table(time_point = tp, feature = v, source = fifelse(v %in% OBSTRUCTION_FEATURES, "Step 11", "Step 04"), sd = sd(fa_[[v]]),
               mean_abs_change = mean(abs(fb_[[v]] - fa_[[v]])), change_in_sd = mean(abs(fb_[[v]] - fa_[[v]])) / sd(fa_[[v]]),
               rank_corr = cor(fa_[[v]], fb_[[v]], method = "spearman"))))
  pert_rows[[tp]] <- data.table(time_point = tp, player_episodes = nrow(f0),
                                mean_abs_change_blocked = mean(abs(fj$blocked_by_opp - f0$blocked_by_opp)),
                                mean_abs_change_blocking = mean(abs(fj$blocking_opp - f0$blocking_opp)),
                                pairing_changed = mean(pch$cls.x != pch$cls.y),
                                pairing_changed_among_paired = pch[cls.x != "none", mean(cls.x != cls.y)])
  geo[[tp]] <- data.table(time_point = tp,
                          mirror_max_diff = max(abs(as.matrix(mir[, ..OBSTRUCTION_FEATURES]) - as.matrix(f0[, ..OBSTRUCTION_FEATURES]))),
                          rotation_max_diff = max(abs(as.matrix(rotd[, ..OBSTRUCTION_FEATURES]) - as.matrix(f0[, ..OBSTRUCTION_FEATURES]))),
                          all_finite = all(vapply(eo$O, function(m) all(is.finite(m)), NA)),
                          rho_blocked_hoop_only = cor(f0$blocked_by_opp, hoop_only$blocked_by_opp, method = "spearman"),
                          rho_blocking_hoop_only = cor(f0$blocking_opp, hoop_only$blocking_opp, method = "spearman"))
}
geo <- rbindlist(geo); pert <- rbindlist(pert_rows)
pert_ctx <- rbindlist(ctx_rows)[order(time_point, -change_in_sd)]
fwrite(pert_ctx, file.path(out, "perturbation_context.csv"))
# pairs at zero distance on real data (two players reported at one spot): their score must be 0 and finite
zd <- rbindlist(lapply(times, function(tp) {
  pl <- res[[tp]]$pl
  pl[, {
    d <- as.matrix(dist(cbind(x, y))); diag(d) <- Inf
    w <- which(d < 0.05, arr.ind = TRUE)
    if (!nrow(w)) NULL else {
      O <- res[[tp]]$eo$O[[episode_id[1]]]
      .(n = nrow(w), max_score = max(O[cbind(as.character(pid[w[, 1]]), as.character(pid[w[, 2]]))]))
    }
  }, by = episode_id][, time_point := tp]
}))
geo[, zero_distance_pairs := vapply(time_point, function(tp) as.integer(sum(zd[time_point == tp]$n %||% 0L)), 0L)]

# ---- pair descriptors: persistence and closing speed for each player's main target ----------------------------------------
message("Step 11: pair persistence")
for (tp in times) {
  eo <- res[[tp]]$eo; pl <- res[[tp]]$pl
  rows <- list()
  for (id in names(eo$O)) {
    t <- pl[episode_id == id]$frame_idx[1]
    pg <- eo$pairings[episode_id == id & pairing != "none"]
    st <- state_at(id, t, pl[episode_id == id, .(pid, off, x, y)])
    if (nrow(pg)) {
      pg[, persistence := pair_persistence(eps[[id]]$players, t, pc$persistence_frames, pid, runner, tg, p, pc,
                                           inf$player_carry_frames)]
      ib <- match(pg$pid, st$pid); ir <- match(pg$runner, st$pid)
      pg[, `:=`(dist = sqrt((st$x[ib] - st$x[ir])^2 + (st$y[ib] - st$y[ir])^2),
                closing = closing_speed(st$x[ib], st$y[ib], st$vx[ib], st$vy[ib], st$x[ir], st$y[ir], st$vx[ir], st$vy[ir]),
                blocker_off = st$off[ib])]
    }
    rows[[id]] <- pg
    res[[tp]]$st[[id]] <- cbind(episode_id = id, st)
  }
  pairs_all[[tp]] <- cbind(time_point = tp, rbindlist(rows, fill = TRUE))
}
pairs_all <- rbindlist(pairs_all, fill = TRUE)
fwrite(pairs_all, file.path(out, "pairings.csv.gz"))
fwrite(rbindlist(lapply(times, function(tp) cbind(time_point = tp, res[[tp]]$eo$features))), file.path(out, "obstruction_features.csv.gz"))
pair_sum <- rbindlist(lapply(times, function(tp) {
  pg <- res[[tp]]$eo$pairings
  pg <- merge(pg, unique(res[[tp]]$pl[, .(episode_id, pid, off)]), by = c("episode_id", "pid"))
  pg[, .(players = .N, pair = mean(pairing == "pair"), ambiguous = mean(pairing == "ambiguous"), none = mean(pairing == "none"),
         median_o_best = median(o_best)), by = .(side = fifelse(off, "offence", "defence"))][, time_point := tp]
}))
pers_sum <- pairs_all[pairing == "pair", .(pairs = .N, median_persistence = median(persistence, na.rm = TRUE),
                                           held_all_frames = mean(persistence == 1, na.rm = TRUE),
                                           median_dist_ft = median(dist), median_closing_ft_s = median(closing)),
                      by = .(time_point, blocker = fifelse(blocker_off, "offence", "defence"))]

# ---- held-out models: Step 04 against Step 04 + obstruction ---------------------------------------------------------------
sf <- list(); cand <- list(); refit_diff <- c()
for (tp in times) {
  message("Step 11: models at ", tp)
  pl <- res[[tp]]$pl
  s4 <- static_features(pl[, .(episode_id, pid, off, x, y, source_frame)], shot)
  sf[[tp]] <- merge(s4, res[[tp]]$eo$features, by = c("episode_id", "pid"))[order(episode_id, -off, pid)]
  # Step 04 refitted with its own lambdas must reproduce its held-out predictions
  rf <- rbindlist(lapply(sort(unique(fa$outer_fold)), function(k) {
    s <- fold_split(fa[episode_id %in% unique(s4$episode_id)], k)
    clogit_fit_predict(s4, shot, labels, s$train, s$test, lam4[time_point == tp & outer_fold == k]$lambda, th4$clogit$maxit)$pred
  }))
  m <- merge(rf, static_oof[time_point == tp, .(episode_id, outcome_id, p4 = probability)], by = c("episode_id", "outcome_id"))
  refit_diff[tp] <- if (nrow(m) == nrow(static_oof[time_point == tp])) max(abs(m$probability - m$p4)) else Inf
  cand[[tp]] <- clogit_fold_predictions(sf[[tp]], shot, labels, fa, choice, unlist(th$model$lambda_grid), th4$clogit$maxit,
                                        th3$metrics$prob_floor, cand_features)
  cand[[tp]]$pred[, `:=`(model = "obstruction_clogit", time_point = tp)]
}
pred <- rbindlist(lapply(cand, `[[`, "pred"))
pred[, model_version := th$model_version]
fwrite(pred, file.path(out, "obstruction_oof.csv.gz"))
fwrite(rbindlist(lapply(times, function(tp) cbind(time_point = tp, cand[[tp]]$lambda))), file.path(out, "lambda_selection.csv"))
coef_tab <- rbindlist(lapply(times, function(tp) cbind(time_point = tp, cand[[tp]]$coef)))
fwrite(coef_tab, file.path(out, "coefficients.csv"))
valid <- check_predictions(pred, choice, th3$metrics$sum_tol)
allp <- rbind(static_oof[, .(model, time_point, episode_id, outcome_id, probability)],
              pred[, .(model, time_point, episode_id, outcome_id, probability)])
sc <- score_episodes(allp, choice, labels, th3$metrics$prob_floor)
cal <- calibration_classwise(allp, labels, unlist(th3$metrics$calibration_breaks))
summ <- merge(summarise_scores(sc), cal$ece, by = c("model", "time_point"))[order(match(time_point, times), model)]
fwrite(summ, file.path(out, "scores_summary.csv"))
cmp <- rbindlist(lapply(times, function(tp) {
  a <- paired_comparison(sc, "obstruction_clogit", "static_clogit", tp, "ll", u$bootstrap_reps, u$seed, u$level)$summary
  b <- paired_comparison(sc, "obstruction_clogit", "static_clogit", tp, "team_ll", u$bootstrap_reps, u$seed, u$level)$summary
  e <- summ[time_point == tp, setNames(ece, model)]
  rbind(a, b)[, `:=`(non_inferior = hi < dec$non_inferiority_margin_nats, superior = hi < 0 & drop_one_max < 0,
                     ece_candidate = e[["obstruction_clogit"]], ece_reference = e[["static_clogit"]])]
}))
cmp[, ece_ok := ece_candidate <= ece_reference + dec$calibration_ece_margin]
fwrite(cmp, file.path(out, "comparison.csv"))
by_game <- rbindlist(lapply(times, function(tp) paired_comparison(sc, "obstruction_clogit", "static_clogit", tp, "ll", 200L, u$seed, u$level)$by_game))
fwrite(by_game, file.path(out, "paired_by_game.csv"))
keep_ok <- all(cmp$non_inferior) && all(cmp$ece_ok)
improves <- cmp[metric == "ll", setNames(superior, time_point)]

# ---- contribution split at rim+0.2 (held-out fold models) ---------------------------------------------------------------
message("Step 11: contribution split")
ct <- th$contribution$time
lam_c <- cand[[ct]]$lambda[selected == TRUE, .(outer_fold, lambda)]
contrib <- rbindlist(lapply(sort(unique(fa$outer_fold)), function(k) {
  s <- fold_split(fa[episode_id %in% unique(sf[[ct]]$episode_id)], k)
  cf <- counterfactual_rows(sf[[ct]], res[[ct]]$eo$O, s$test)
  sh_cf <- merge(data.table(episode_id = unique(cf$episode_id))[, orig := sub("#.*$", "", episode_id)],
                 shot, by.x = "orig", by.y = "episode_id")[, orig := NULL]
  r <- clogit_fit_predict(rbind(sf[[ct]], cf, use.names = TRUE), rbind(shot, sh_cf, use.names = TRUE), labels, s$train,
                          unique(cf$episode_id), lam_c[outer_fold == k]$lambda, th4$clogit$maxit, cand_features)
  contribution_split(pred[time_point == ct & outer_fold == k, .(episode_id, outcome_id, probability)], r$pred, choice)
}))
roles <- rbindlist(lapply(unique(rel$episode_id), function(id)
  cbind(episode_id = id, assign_roles(rel[episode_id == id, .(pid, off, x, y)], shot[episode_id == id]$shooter_id))))
contrib <- merge(merge(contrib, roles, by = c("episode_id", "pid")), el[, .(episode_id, game_id)], by = "episode_id")
contrib <- merge(contrib, res[[ct]]$eo$features, by = c("episode_id", "pid"))
fwrite(contrib, file.path(out, "contribution_split.csv.gz"))
contrib_role <- Reduce(function(a, b) merge(a, b, by = c("role", "n", "games")), lapply(
  c("collection", "team_secures", "contrib_own", "contrib_mates", "contrib_team", "blocking_opp"), function(v)
    setnames(group_means(contrib, v, "role", 1000L, u$seed)[, .(role, n, games, mean, lo, hi)], c("mean", "lo", "hi"),
             c(v, paste0(v, "_lo"), paste0(v, "_hi")))))
fwrite(contrib_role, file.path(out, "contribution_by_role.csv"))
add_ok <- contrib[, max(abs(contrib_team - contrib_own - contrib_mates))]

# ---- information-time checks -------------------------------------------------------------------------------------------
pts <- fread(o("step03", "prediction_points.csv"))[time_point %in% times & defined == TRUE]
used <- unique(rbindlist(lapply(times, function(tp) res[[tp]]$pl[, .(episode_id, time_point = tp, frame_idx)])))
tt <- merge(used, el[, .(episode_id, rebound_frame)], by = "episode_id")
before_rebound <- all(tt$frame_idx < tt$rebound_frame)
planted <- copy(f3[time_point == "rim+0.2"])[1:10][, source_frame := frame_idx + 5L]
planted_caught <- inherits(try(assert_information_time(planted), silent = TRUE), "try-error")
s1 <- fold_split(fa[episode_id %in% unique(sf$`rim+0.2`$episode_id)], 1L)
lam1 <- cand$`rim+0.2`$lambda[outer_fold == 1 & selected == TRUE]$lambda
fp <- function(f, lab, split) clogit_fit_predict(f, shot, lab, split$train, split$test, lam1, th4$clogit$maxit, cand_features)$pred[, model := "obstruction_clogit"][]
inv <- label_invariance(fp, sf$`rim+0.2`, labels, choice, s1)

# ---- review sample (drawn once) ------------------------------------------------------------------------------------------
smp_file <- file.path(rev_dir, "sample.csv")
st_t <- rbindlist(res[["rim+0.2"]]$st)
cp <- candidate_pairs(res[["rim+0.2"]]$eo$O, st_t, rel[, .(episode_id, pid, x, y)], res[["rim+0.2"]]$eo$pairings)
if (!file.exists(smp_file)) {
  smp <- review_sample(cp, th$labels, pc)
  smp <- merge(smp, el[, .(episode_id, game_id, release_frame)], by = "episode_id")[order(item)]
  smp[, t_frame := res[["rim+0.2"]]$pl[match(smp$episode_id, episode_id)]$frame_idx]
  fwrite(smp, smp_file)
  message("Step 11: drew the review sample (", nrow(smp), " items)")
}
smp <- fread(smp_file)
sheet_file <- file.path(rev_dir, "reviewer_heldout.csv")
if (!file.exists(sheet_file))
  fwrite(smp[, .(item, page = (item - 1L) %/% 2L + 1L, label = "", contact_visible = "", confidence = "", note = "")], sheet_file)
draw_item <- function(e, it) {
  s <- e$s; t <- it$t_frame; a <- it$player_a; b <- it$player_b
  plr <- e$players[frame >= s$release_frame & frame <= min(t + 15L, s$rebound_frame)]
  at <- e$players[frame <= t][order(pid, -frame)][!duplicated(pid)]
  par(mar = c(1, 1, 3, 1))
  plot(NA, xlim = c(14, COURT_HALF_L + 1), ylim = c(-COURT_HALF_W, COURT_HALF_W), asp = 1, axes = FALSE, xlab = "", ylab = "",
       main = sprintf("Item %d   (t = %d frames after release; tracks from release to t + 15 frames)", it$item, t - s$release_frame),
       cex.main = 0.9)
  draw_half_court()
  bl <- e$ball[frame >= s$release_frame & frame <= min(t + 15L, s$rebound_frame)]
  points(bl$x, bl$y, pch = 16, cex = 0.3, col = "orange3")
  others <- at[!pid %in% c(a, b)]
  points(others$x, others$y, pch = fifelse(others$off, 1, 2), col = "grey45", cex = 1.2)
  for (w in list(list(id = a, col = "firebrick", lab = "A"), list(id = b, col = "royalblue3", lab = "B"))) {
    q <- plr[pid == w$id]
    lines(q$x, q$y, col = w$col, lwd = 2)
    q0 <- at[pid == w$id]
    points(q0$x, q0$y, pch = fifelse(q0$off, 19, 17), col = w$col, cex = 1.8)
    text(q0$x, q0$y, sprintf("%s (%s)", w$lab, fifelse(q0$off, "O", "D")), pos = 3, col = w$col, font = 2)
    points(q$x[1], q$y[1], pch = 4, col = w$col)
  }
  legend("bottomleft", c("filled: players A, B at t (circle offence, triangle defence)", "x: their spot at release",
                         "grey: other players at t", "orange: ball"), bty = "n", cex = 0.75)
  w <- dcast(plr[pid %in% c(a, b), .(frame, pid = fifelse(pid == a, "A", "B"), x, y)], frame ~ pid, value.var = c("x", "y"))[
    , d := sqrt((x_A - x_B)^2 + (y_A - y_B)^2)]
  par(mar = c(4, 4, 3, 1))
  plot((w$frame - s$release_frame), w$d, type = "l", lwd = 2, xlab = "frames after release", ylab = "A-B distance (ft)",
       main = "distance between A and B", cex.main = 0.9, ylim = c(0, max(8, max(w$d, na.rm = TRUE))))
  abline(v = t - s$release_frame, lty = 2); abline(h = c(2, 4), col = "grey80")
}
if (!length(list.files(rev_dir, "^heldout_.*\\.png$"))) {
  per_page <- 2L
  smp[, page := (item - 1L) %/% per_page + 1L]
  for (pg in unique(smp$page)) {
    png(file.path(rev_dir, sprintf("heldout_%02d.png", pg)), width = 1500, height = 560 * per_page, res = 100)
    layout(matrix(seq_len(2L * per_page), ncol = 2, byrow = TRUE), widths = c(1.9, 1))
    for (k in which(smp$page == pg)) draw_item(eps[[smp$episode_id[k]]], smp[k])
    dev.off()
  }
}
sheet <- fread(sheet_file, colClasses = "character")
sheet[, item := as.integer(item)]
labelled <- sheet[nzchar(label)]
review <- if (nrow(labelled)) score_review(sheet, smp, pc) else NULL
labels_met <- !is.null(review) && nrow(labelled) == nrow(smp) &&
  review$precision >= th$labels$target$precision && review$recall >= th$labels$target$recall

# ---- checks -----------------------------------------------------------------------------------------------------------------
ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                     expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", freeze_ok, TRUE, freeze_ok)
addc("mirroring the court left to right changes no feature (largest change, both times)", signif(max(geo$mirror_max_diff), 3), "< 1e-9",
     max(geo$mirror_max_diff) < 1e-9)
addc("rotating players and targets 30 degrees about the hoop changes no feature (largest change)", signif(max(geo$rotation_max_diff), 3),
     "< 1e-9", max(geo$rotation_max_diff) < 1e-9)
zmax <- if (nrow(zd)) max(zd$max_score) else 0
addc("every pair score finite; pairs reported at one spot (distance < 0.05 ft) score 0", sprintf("%s; %d pairs, max %.3g", all(geo$all_finite),
     sum(geo$zero_distance_pairs), zmax), "TRUE; 0", all(geo$all_finite) && zmax == 0)
pm1 <- pert[, max(mean_abs_change_blocked, mean_abs_change_blocking)]
addc("one-foot moves: mean |change| of the two features (worst time and feature)", signif(pm1, 3), paste("<=", pt$max_mean_abs_feature_change),
     pm1 <= pt$max_mean_abs_feature_change)
pm2 <- max(pert$pairing_changed)
addc("one-foot moves: share of players whose pairing changes (worst time)", signif(pm2, 3), paste("<=", pt$max_pairing_change),
     pm2 <= pt$max_pairing_change)
rho <- min(geo$rho_blocked_hoop_only, geo$rho_blocking_hoop_only)
addc("target sensitivity: Spearman correlation with the hoop-only target (lowest)", signif(rho, 3), paste(">=", th$targets$min_rho),
     rho >= th$targets$min_rho)
addc("features from frames <= t and t before the credited rebound (every episode and time)", before_rebound, TRUE, before_rebound)
addc("a planted future feature is caught", planted_caught, TRUE, planted_caught)
addc("candidate predictions unchanged when the test game's labels are altered (rim+0.2, fold 1)", inv, TRUE, inv)
addc("Step 04 refitted with its lambdas reproduces its held-out predictions (largest change)", paste(signif(refit_diff, 3), collapse = " / "),
     "< 1e-9", all(refit_diff < 1e-9))
addc("candidate prediction tables valid (12 outcomes, sum to 1)", sum(valid$ok), nrow(valid), all(valid$ok))
same <- sc[, .(eps = paste(sort(episode_id), collapse = ",")), by = .(model, time_point)][, uniqueN(eps), by = time_point]
addc("candidate and reference scored on the same episodes at each time", sum(same$V1 == 1L), length(times), all(same$V1 == 1L))
addc("every candidate fit converged", all(coef_tab$converged), TRUE, all(coef_tab$converged))
addc("contribution split adds up (largest |team - own - teammates|)", signif(add_ok, 3), "< 1e-9", add_ok < 1e-9)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))
fwrite(geo, file.path(out, "geometry_checks.csv")); fwrite(pert, file.path(out, "perturbation.csv"))
fwrite(pair_sum, file.path(out, "pairing_summary.csv")); fwrite(pers_sum, file.path(out, "persistence_summary.csv"))
geometry_ok <- all(checks$pass)

# ---- report -----------------------------------------------------------------------------------------------------------------
md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
ocoef <- coef_tab[term %in% OBSTRUCTION_FEATURES, .(fold_min = min(estimate), fold_median = median(estimate), fold_max = max(estimate)),
                  by = .(time_point, term)]
proxy_ok <- geometry_ok && keep_ok
lines <- c(
  "# Step 11: geometric obstruction and box-out validity",
  "",
  sprintf("Run %s by `src/rebounding/run_step11.R`; settings `config/experiment.yaml` (`step11`, config v%d), fixed before any",
          format(Sys.Date()), cfg$config_version),
  "real-data run. The measure is named **obstruction**: geometric blocking of a route from floor positions, not body",
  "contact. No video ships with the data and outside video is not allowed.",
  "",
  "**Measure.** O_ij = how much player i stands on player j's route to 15 fixed points around the hoop (the hoop and",
  "rings at 4 and 8 ft), averaged over the points: full weight when i is 0-3 ft ahead of j along the route and within",
  "about 1.5 ft of it, fading with distance ahead and to the side, zero when i is level with or behind j. Player",
  "features: blocked_by_opp (how much opponents block his routes) and blocking_opp (how much he blocks theirs).",
  "Pairings are each player's most-obstructed opponent, `none` below 0.25 (no pair forced) and `ambiguous` when a",
  "second opponent is within 0.1.",
  "",
  "## Geometry checks (real data)", "", md_table(geo, 4), "", md_table(pert, 3), "",
  "**Context, not gated** (owner decision 2026-11-05, after the first run; the gate stays as prespecified). The same",
  "one-foot moves applied to Step 04's features. The obstruction features move more in units of their spread (about",
  "0.25 SD against 0.16-0.18 for Step 04's relative features) but keep the ten players' order as well (rank",
  "correlation 0.95-0.97 against 0.91-0.96). The 0.05 limit had no scale reference; the miss is small.", "",
  md_table(pert_ctx, 3), "",
  "The target check is a substantive result: at rim + 0.2 s, being blocked on the way to the hoop and on the way to",
  "the area around it rank players differently (Spearman 0.75), so the measure depends on where a player is assumed",
  "to be going.", "",
  "## Pairings", "", md_table(pair_sum, 3), "",
  "Persistence over the 12 frames before t and closing speed of each player's paired opponent:", "", md_table(pers_sum, 3), "",
  sprintf("## Does it help predict the rebound? (held-out games): %s", if (keep_ok) "does not degrade" else "degrades"), "",
  "Candidate = Step 04's conditional logit plus the two obstruction features; reference = Step 04's own held-out",
  "predictions. Difference = candidate minus reference per rebound (negative is better); `non_inferior` needs `hi` <",
  sprintf("%.2f nats; `superior` needs `hi` < 0 and every drop-one-game mean < 0.", dec$non_inferiority_margin_nats), "",
  md_table(cmp[, .(time_point, metric, episodes, mean_diff, lo, hi, games_better, drop_one_max, non_inferior, superior,
                   ece_candidate, ece_reference, ece_ok)], 4), "",
  md_table(summ[, .(time_point, model, episodes, log_loss, brier, top1, top3, team_log_loss, ece)], 4), "",
  "Obstruction coefficients across the ten folds (per standard deviation):", "", md_table(ocoef, 3), "",
  "## Collection, team chance and obstruction contribution (rim + 0.2 s, held-out fold models)", "",
  "collection = P(the player is credited); team_secures = P(his side secures); contrib_* = predictions minus",
  "predictions with his blocking removed, for him, his teammates (and own team award) and his side. Model-implied",
  "associations, not effects of boxing out.", "",
  md_table(contrib_role[, .(role, n, games, collection, team_secures, blocking_opp, contrib_own, contrib_mates, contrib_mates_lo,
                            contrib_mates_hi, contrib_team)], 4), "",
  "## Box-out labels", "",
  sprintf("Held-aside sample: %d pairs at rim + 0.2 s (%s), pages `step11/review/heldout_*.png`, sheet", nrow(smp),
          paste(sprintf("%s %d", names(table(smp$stratum)), as.integer(table(smp$stratum))), collapse = ", ")),
  "`step11/review/reviewer_heldout.csv` (labels: boxout_by_A, boxout_by_B, screen, post_defense, proximity, converging,",
  "help, unclear). The pages show tracks only, not the score, the stratum or who is the blocker.",
  if (is.null(review)) "**Not labelled yet.**" else c(sprintf("Labelled %d of %d:", nrow(labelled), nrow(smp)), "", md_table(review, 3)),
  "",
  "Even when filled, tracking-plot labels measure agreement with a person's reading of the same floor positions, not",
  "contact, so box-out detection and box-out ability stay BLOCKED in this release (config `step11.labels`).", "",
  "## Checks", "", md_table(checks), "",
  "## Limits", "",
  "- Floor positions only: no body orientation, arms or contact; positions err by about 1.5 ft on average.",
  "- Targets are fixed points around the hoop, not where the ball goes; the Step 05 map is not validated.",
  "- Ten games; contributions come from a logit's coefficients and describe association, not what a box-out causes.",
  "- No player box-out effects were fitted (the manual allows them only after independent labels pass).")
writeLines(lines, o("reports", "11_boxout_validity.md"))

# ---- gate record ------------------------------------------------------------------------------------------------------------
tests <- rbind(run_tests(here, root, "unit", "obstruction"), run_tests(here, root, "unit", "static_model"),
               run_tests(here, root, "gates", "step_11"), fill = TRUE)
fwrite(tests, o("gate_results", "11_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
status <- if (proxy_ok && tests_ok) "PASS" else "BLOCKED"
code_files <- c("pairwise_obstruction.R", "boxout.R", "conditional_choice.R")
rec <- list(
  step = "11", status = status,
  scope = sprintf("obstruction proxy at release and rim+0.2 for %s episodes; held-out comparison with Step 04", paste(sapply(times, function(tp) uniqueN(res[[tp]]$pl$episode_id)), collapse = " / ")),
  components = list(obstruction_proxy_geometry = if (geometry_ok) "PASS" else "BLOCKED",
                    model_value = if (keep_ok) (if (any(improves)) "PASS (improves)" else "PASS (does not degrade)") else "BLOCKED (degrades)",
                    boxout_detection = "BLOCKED (no independent contact or box-out labels in permitted data)",
                    boxout_ability = "NOT_RUN (requires box-out detection)"),
  source_commits = list(skillcorner = cfg$dataset$upstream_commit, ReboundingPrediction = "derived.py ideas only (no licence)",
                        shotquality_offensive_rebounding = "matchup ideas only (no licence)", ReboundingImpact = "concept only (no licence)"),
  data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
  model_revision = list(model_version = th$model_version, step11_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                        code_sha256 = setNames(lapply(code_files, function(f) sha256_file(file.path(here, "R", f))), code_files),
                        predictions_sha256 = sha256_file(file.path(out, "obstruction_oof.csv.gz"))),
  repository_head = git_out(root, "rev-parse", "HEAD")[1],
  test_command = "Rscript src/rebounding/run_tests.R unit obstruction; Rscript src/rebounding/run_tests.R gates step_11",
  unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
  data_audit_passed = geometry_ok,
  heldout_metrics_file = "outputs/rebounding/step11/comparison.csv",
  acceptance_criteria_version = sprintf("manual %s, config v%d (step11 fixed before any real-data run)", cfg$manual_revision, cfg$config_version),
  decision = list(comparison = cmp[, .(time_point, metric, mean_diff = round(mean_diff, 5), lo = round(lo, 5), hi = round(hi, 5),
                                       non_inferior, superior, ece_ok)],
                  perturbation = pert, perturbation_context_not_gated = pert_ctx, geometry = geo, review = review,
                  owner_decision = "2026-11-05: keep Step 11 BLOCKED; no threshold changed; perturbation context added as a non-gating note"),
  deviations = list("conditional_choice.R takes an optional feature list (default = Step 04's); Step 04 refit reproduces its predictions"),
  evidence = c("outputs/rebounding/step11/", "outputs/rebounding/reports/11_boxout_validity.md"),
  reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
  open_risks = list("Proxy describes floor geometry only; no contact evidence exists in permitted data",
                    "Review sheet unlabelled; any labels would come from tracking plots",
                    "Fixed hoop-centred targets, not the ball's landing distribution"),
  decision_note = sprintf("Geometry %s; model value %s; box-out detection BLOCKED.", if (geometry_ok) "valid" else "not valid",
                          if (keep_ok) "does not degrade" else "degrades"))
write_gate(o("gate_results", "11_obstruction.json"), rec)

print(geo); print(pert); print(pair_sum); print(pers_sum)
print(cmp[, .(time_point, metric, d = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4), gb = games_better, non_inferior, superior, ece_ok)])
print(summ[, .(time_point, model, ll = round(log_loss, 4), top1 = round(top1, 3), tll = round(team_log_loss, 4), ece = round(ece, 4))])
print(ocoef); print(contrib_role[, .(role, n, collection = round(collection, 3), blocking = round(blocking_opp, 3), own = round(contrib_own, 4),
                                     mates = round(contrib_mates, 4), team = round(contrib_team, 4))])
print(smp[, .N, by = stratum])
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 11:", status, "\n")
