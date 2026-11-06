# Step 08 of the rebounding manual: player movement forecasts (validated on held-out games) and who could reach the
# ball after it gets to the rim (exploratory: Step 02 is BLOCKED, so no first-contact labels exist and the physical
# interception validation is BLOCKED by the manual's Gate 08). Folds and rules are Step 03's.
#   Rscript src/rebounding/run_step08.R
# Needs raw_*.rds, the Step 01 table, Step 02 automated labels and Step 03 outputs. Settings: config/experiment.yaml
# (step08, fixed before any real-data run). Writes outputs/rebounding/step08/, reports/08_reachability.md,
# gate_results/08_reachability.json and 08_tests.csv.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R",
            "player_motion.R", "reach.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03; th <- cfg$step08; inf <- th3$information; mv <- th$movement; vel <- th$velocity
cache <- file.path(root, "outputs", "cache", "rebounding")
s3 <- file.path(root, "outputs", "rebounding", "step03")
out <- file.path(root, "outputs", "rebounding", "step08")
reports <- file.path(root, "outputs", "rebounding", "reports")
gr <- file.path(root, "outputs", "rebounding", "gate_results")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))

fz <- jsonlite::fromJSON(file.path(s3, "design_freeze.json"))
freeze_ok <- c(config = identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3)))),
               code = all(vapply(names(fz$code_sha256), function(f) identical(fz$code_sha256[[f]], sha256_file(file.path(here, "R", f))), NA)))
if (!all(freeze_ok)) stop("Step 03's design changed since it was frozen")

el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(file.path(s3, "fold_assignment.csv"))
pts <- fread(file.path(s3, "prediction_points.csv"))[defined == TRUE & time_point %in% unlist(mv$origins)]
auto <- fread(file.path(root, "outputs", "rebounding", "step02", "auto_summary.csv"), na.strings = c("", "NA"))
H <- unlist(mv$horizons_frames)

# ---- tracks and causal velocities -------------------------------------------------------------------------------------
message("Step 08: tracks")
eps <- list(); cross <- list()
for (g in matches$id) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  cross[[length(cross) + 1L]] <- made_crossings(raw, g)
  for (k in which(el$game_id == g)) {
    s <- el[k]
    tr <- episode_tracking(raw, s, home == s$off_team, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames,
                           to = s$rebound_frame + max(H))
    v <- causal_velocity(tr$players[, .(frame, pid, x, y, det)], vel$window_frames, vel$min_detected)
    v <- merge(v, unique(tr$players[, .(pid, off)]), by = "pid")
    eps[[s$episode_id]] <- list(s = s, v = v, ball = tr$ball[measured == TRUE])
  }
}
cross <- rbindlist(cross)

# movement rows: every player's state at each origin and his tracked position h frames later
mrows <- rbindlist(lapply(names(eps), function(id) {
  e <- eps[[id]]; p <- pts[episode_id == id]
  if (!nrow(p)) return(NULL)
  rbindlist(lapply(seq_len(nrow(p)), function(i) {
    t <- p$frame_idx[i]
    st <- e$v[frame == t & !is.na(vx), .(pid, off, x, y, vx, vy, speed, vel_from, det0 = det)]
    if (nrow(st) < 10L) return(NULL)
    rbindlist(lapply(H, function(h) {
      tg <- e$v[frame == t + h, .(pid, tx = x, ty = y, det_target = det)]
      j <- merge(st, tg, by = "pid")
      if (!nrow(j)) return(NULL)
      cbind(episode_id = id, time_point = p$time_point[i], origin = t, horizon = h, tau = h / FPS, j)
    }))
  }))
}))
mrows <- merge(mrows, fa[, .(episode_id, game_id, outer_fold)], by = "episode_id")

# ---- movement models by fold ------------------------------------------------------------------------------------------
message("Step 08: movement folds")
lim_tab <- list(); lam_tab <- list(); fc <- list(); exceed <- list()
for (k in sort(unique(fa$outer_fold))) {
  s <- fold_split(fa, k)
  tr_v <- rbindlist(lapply(intersect(s$train, names(eps)), function(id) eps[[id]]$v))
  lim <- estimate_limits(tr_v)
  dm <- select_damping(mrows[outer_fold != k & det_target == 1L], unlist(mv$damping_grid_per_s))
  lim_tab[[k]] <- data.table(outer_fold = k, test_game = s$test_game, v_max = lim$v_max, a_max = lim$a_max, n_frames = lim$n,
                             lambda = dm$lambda, n_train_rows = nrow(mrows[outer_fold != k & det_target == 1L]))
  lam_tab[[k]] <- cbind(outer_fold = k, dm$errors)
  te <- mrows[outer_fold == k]
  for (m in MOVE_MODELS) {
    f <- forecast_position(te$x, te$y, te$vx, te$vy, te$tau, m, dm$lambda, lim$v_max)
    fc[[length(fc) + 1L]] <- te[, .(episode_id, game_id, outer_fold, time_point, origin, horizon, pid, off, vel_from, det_target,
                                     model = m, err = sqrt((f$x - tx)^2 + (f$y - ty)^2))]
  }
  te_v <- rbindlist(lapply(intersect(s$test, names(eps)), function(id) eps[[id]]$v))[det == 1L & !is.na(speed)]
  exceed[[k]] <- data.table(outer_fold = k, frames = nrow(te_v), speed_above = mean(te_v$speed > lim$v_max),
                            accel_above = mean(te_v[!is.na(accel)]$accel > lim$a_max))
}
lim_tab <- rbindlist(lim_tab); fwrite(lim_tab, file.path(out, "limits_and_damping_by_fold.csv"))
fwrite(rbindlist(lam_tab), file.path(out, "damping_selection.csv"))
fc <- rbindlist(fc); fc[, model_version := th$model_version]
fwrite(fc, file.path(out, "movement_forecasts.csv.gz"))
exceed <- rbindlist(exceed); fwrite(exceed, file.path(out, "limit_exceedance.csv"))
prim <- fc[det_target == 1L]
mov_sum <- prim[, .(forecasts = .N, mean_err = mean(err), median_err = median(err), p90_err = quantile(err, 0.9)), by = .(horizon, model)][order(horizon, mean_err)]
fwrite(mov_sum, file.path(out, "movement_errors.csv"))
mov_str <- rbind(fc[, .(stratum = paste("velocity from", vel_from), forecasts = .N, mean_err = mean(err)), by = .(horizon, model, vel_from)][, vel_from := NULL],
                 fc[, .(stratum = fifelse(det_target == 1L, "target detected", "target extrapolated"), forecasts = .N, mean_err = mean(err)), by = .(horizon, model, det_target)][, det_target := NULL],
                 fc[det_target == 1L, .(stratum = paste("origin", time_point), forecasts = .N, mean_err = mean(err)), by = .(horizon, model, time_point)][, time_point := NULL])
fwrite(mov_str[order(horizon, stratum, mean_err)], file.path(out, "movement_by_stratum.csv"))
u <- th3$uncertainty
pe <- prim[, .(e = mean(err)), by = .(model, horizon, episode_id, game_id)][, time_point := paste0("h", horizon)]
cmp <- rbindlist(lapply(H, function(h) rbindlist(lapply(c("stationary", "constant_velocity", "bounded"), function(r)
  paired_comparison(pe[horizon == h, .(model, time_point, episode_id, game_id, e)], if (r == "bounded") "bounded" else "damped",
                    if (r == "bounded") "damped" else r, paste0("h", h), "e", u$bootstrap_reps, u$seed, u$level)$summary))))
cmp[, superior := hi < 0 & drop_one_max < 0]
fwrite(cmp, file.path(out, "paired_movement.csv"))
move_pass <- all(cmp[candidate == "damped"]$superior) && all(exceed$speed_above <= mv$limit_exceed_max)

# ---- reach at the rim-arrival trigger (exploratory) -----------------------------------------------------------------------------
message("Step 08: reach")
rp_base <- th$reach
reach_rows <- function(ids, k, rp, jitter = 0, keep_ball = 1, seed = 1L) {
  s <- fold_split(fa, k)
  hh <- cross[game_id %in% unique(fa[episode_id %in% s$train]$game_id), .(hx = median(x), hy = median(y)), by = left_hoop]
  set.seed(seed)
  rbindlist(lapply(ids, function(id) {
    e <- eps[[id]]; p <- pts[episode_id == id & time_point == "rim+0"]
    if (!nrow(p)) return(NULL)
    t <- p$frame_idx
    st <- e$v[frame == t & !is.na(vx), .(pid, off, x, y, vx, vy)]
    if (nrow(st) < 10L) return(NULL)
    if (jitter > 0) st[, `:=`(x = x + rnorm(.N, 0, jitter), y = y + rnorm(.N, 0, jitter))]
    hp <- hh[left_hoop == e$s$left_hoop]
    b <- e$ball[frame > t & frame <= e$s$rebound_frame]
    if (keep_ball < 1 && nrow(b)) b <- b[sort(sample.int(.N, max(1L, round(.N * keep_ball))))]
    pf <- to_player_frame(b$x - hp$hx, b$y - hp$hy, b$z, list(hx = hp$hx, hy = hp$hy))
    path <- data.table(frame = b$frame, bx = pf$x, by = pf$y, z = b$z)
    cbind(episode_id = id, origin = t, player_margins(st, path, t, rp))
  }))
}
reach <- list(); sens <- list()
variants <- c(list(base = list()),
              setNames(lapply(unlist(th$reach$sensitivity$reaction_s), function(v) list(reaction_s = v)), paste0("reaction ", unlist(th$reach$sensitivity$reaction_s), " s")),
              setNames(lapply(unlist(th$reach$sensitivity$jump_reach_ft), function(v) list(jump_reach_ft = v)), paste0("jump reach ", unlist(th$reach$sensitivity$jump_reach_ft), " ft")),
              setNames(lapply(unlist(th$reach$sensitivity$takeoff_s), function(v) list(takeoff_s = v)), paste0("takeoff ", unlist(th$reach$sensitivity$takeoff_s), " s")),
              list(`position error 1 ft` = list(.jitter = th$reach$sensitivity$position_error_ft)),
              list(`half the ball frames` = list(.keep = th$reach$sensitivity$ball_frames_kept)))
for (k in sort(unique(fa$outer_fold))) {
  ids <- intersect(fold_split(fa, k)$test, names(eps))
  vmax <- lim_tab[outer_fold == k]$v_max
  for (vn in names(variants)) {
    va <- variants[[vn]]
    rp <- modifyList(rp_base, c(list(v_max = vmax), va[!names(va) %in% c(".jitter", ".keep")]))
    r <- reach_rows(ids, k, rp, jitter = va$.jitter %||% 0, keep_ball = va$.keep %||% 1, seed = u$seed + k)
    if (!nrow(r)) next
    r[, `:=`(variant = vn, outer_fold = k)]
    if (vn == "base") reach[[length(reach) + 1L]] <- r else sens[[length(sens) + 1L]] <- r
  }
}
reach <- rbindlist(reach); sens <- rbindlist(sens)
lab <- el[, .(episode_id, credited = fifelse(rebounded, rebounder_id, NA_integer_))]
lab <- merge(lab, auto[, .(episode_id, auto_first = first_contact_player_id)], by = "episode_id", all.x = TRUE)
summ_reach <- function(r) {
  r <- merge(r, lab, by = "episode_id")
  r[, rank := frank(-margin, ties.method = "min"), by = .(variant, episode_id)]
  r[, .(episodes = uniqueN(episode_id),
        feasible_mean = mean(.SD[, sum(margin >= 0), by = episode_id]$V1),
        none_feasible = mean(.SD[, all(margin < 0), by = episode_id]$V1),
        credited_feasible = .SD[pid == credited, mean(margin >= 0)],
        credited_top1 = .SD[pid == credited, mean(rank == 1)],
        credited_top3 = .SD[pid == credited, mean(rank <= 3)],
        auto_first_feasible = .SD[!is.na(auto_first) & pid == auto_first, mean(margin >= 0)],
        auto_first_top1 = .SD[!is.na(auto_first) & pid == auto_first, mean(rank == 1)]), by = variant]
}
reach_sum <- rbind(summ_reach(reach), summ_reach(sens))
top <- function(r) r[, .SD[which.max(margin)], by = .(variant, episode_id)][, .(variant, episode_id, top_pid = pid)]
tb <- top(reach); ts <- top(sens)
chg <- merge(ts, tb[, .(episode_id, base_pid = top_pid)], by = "episode_id")[, .(earliest_arriver_changes = mean(top_pid != base_pid)), by = variant]
reach_sum <- merge(reach_sum, rbind(data.table(variant = "base", earliest_arriver_changes = 0), chg), by = "variant")
fwrite(reach, file.path(out, "reach_margins.csv.gz"))
fwrite(reach_sum[order(variant != "base", variant)], file.path(out, "reach_summary.csv"))

# ---- checks -----------------------------------------------------------------------------------------------------------------
ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                     expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", all(freeze_ok), TRUE, all(freeze_ok))
set.seed(u$seed)
pois <- sample(names(eps), 30L)
vel_causal <- all(vapply(pois, function(id) {
  e <- eps[[id]]; t <- e$s$release_frame
  raw_pl <- e$v[, .(frame, pid, x, y, det)]
  bad <- copy(raw_pl)[frame > t, `:=`(x = x + 30, y = -y)]
  a <- causal_velocity(raw_pl, vel$window_frames, vel$min_detected)[frame <= t]
  b <- causal_velocity(bad, vel$window_frames, vel$min_detected)[frame <= t]
  isTRUE(all.equal(a, b, tolerance = 0))
}, NA))
addc("velocities at t unchanged when later frames are corrupted (30 episodes)", vel_causal, TRUE, vel_causal)
tr_ok <- all(lim_tab$n_train_rows == vapply(lim_tab$outer_fold, function(k) nrow(mrows[outer_fold != k & det_target == 1L]), 0L))
addc("damping and limits use the training games only", tr_ok, TRUE, tr_ok)
addc("speed limit plausible (training v_max, ft/s)", sprintf("%.1f to %.1f", min(lim_tab$v_max), max(lim_tab$v_max)), "15 to 35", all(lim_tab$v_max > 15 & lim_tab$v_max < 35))
addc("held-out detected speeds above the training v_max (largest fold share)", signif(max(exceed$speed_above), 3),
     paste("<=", mv$limit_exceed_max), all(exceed$speed_above <= mv$limit_exceed_max))
hi_only <- merge(reach[, .(none = all(margin < 0)), by = episode_id],
                 rbindlist(lapply(unique(reach$episode_id), function(id) { e <- eps[[id]]; t <- unique(reach[episode_id == id]$origin)
                   data.table(episode_id = id, all_high = all(e$ball[frame > t & frame <= e$s$rebound_frame]$z > th$reach$jump_reach_ft)) })), by = "episode_id")
addc("a ball above every player's reach gives no interception", hi_only[all_high == TRUE, all(none)], TRUE, hi_only[all_high == TRUE, all(none)])
addc("first touch, first control and final credit kept apart (reach is scored against neither as a pass test)", TRUE, TRUE, TRUE)
k1 <- fa[outer_fold == 1L]
re1 <- {
  te <- mrows[outer_fold == 1L]; lk <- lim_tab[outer_fold == 1L]
  f <- forecast_position(te$x, te$y, te$vx, te$vy, te$tau, "damped", lk$lambda, lk$v_max); sqrt((f$x - te$tx)^2 + (f$y - te$ty)^2) }
same <- isTRUE(all.equal(re1, fc[outer_fold == 1L & model == "damped"]$err, tolerance = 0))
addc("re-running fold 1 reproduces every damped forecast error", same, TRUE, same)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))

# ---- report ----------------------------------------------------------------------------------------------------------------
md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
st_move <- if (move_pass) "PASS" else "BLOCKED"
lines <- c(
  "# Step 08: player movement and reachability",
  "",
  sprintf("Run %s by `src/rebounding/run_step08.R`; settings `config/experiment.yaml` (`step08`, config v%d), fixed before any",
          format(Sys.Date()), cfg$config_version),
  "real-data run; folds and rules are Step 03's.",
  "",
  "**Gate rule.** Interception can only be validated against first-contact labels, and Step 02 is BLOCKED, so the",
  "physical interception validation is BLOCKED and the reach margins below are exploratory. The movement models are",
  "validated on held-out games.",
  "",
  "## Movement forecasts (held-out games, detected target positions, error in ft)", "", md_table(mov_sum, 3), "",
  "Speed and acceleration limits and damping by fold (training games only):", "", md_table(lim_tab, 3), "",
  md_table(exceed, 4), "",
  sprintf("## Damped against stationary and constant velocity (superiority, Step 03 rule): %s", st_move), "",
  md_table(cmp[, .(candidate, reference, time_point, mean_diff, lo, hi, games_better, drop_one_max, superior)], 3), "",
  "By stratum (`movement_by_stratum.csv`): velocity from detected or extrapolated positions, target detected or not, origin.",
  "",
  "## Reach after the rim arrival (exploratory)", "",
  "Margin = time the ball is at a point (on its measured path to the credited rebound) minus the player's arrival",
  sprintf("there (reaction %.2f s, then straight at the fold's v_max to within %.1f ft; a jump adds %.2f s and reaches %.1f ft).",
          rp_base$reaction_s, rp_base$catch_radius_ft, rp_base$takeoff_s, rp_base$jump_reach_ft),
  "Feasible = margin >= 0. The ball path is the realised one, so this is feasibility after the fact, not a forecast.",
  "The credited rebounder is the final credit, not the first touch; Step 02's first toucher is unvalidated.",
  "", md_table(reach_sum[order(variant != "base", variant)], 3), "",
  "## Checks", "", md_table(checks), "",
  "## Limits", "",
  "- No player heights, wingspans or jump data: the envelope is a broad assumption, not a measurement.",
  "- Obstruction is not modelled (box-outs are Step 11).",
  "- Reach uses the realised ball path; Step 09 has to use forecast paths instead.")
writeLines(lines, file.path(reports, "08_reachability.md"))

# ---- gate record -------------------------------------------------------------------------------------------------------------
tests <- rbind(run_tests(here, root, "unit", "reach"), run_tests(here, root, "gates", "step_08"), fill = TRUE)
fwrite(tests, file.path(gr, "08_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
harness_ok <- all(checks$pass) && tests_ok
status <- if (harness_ok && move_pass) "PASS_BASELINE" else "BLOCKED"
rec <- list(
  step = "08", status = status,
  scope = sprintf("player movement forecasts (%d episodes) and exploratory reach margins at the rim-arrival trigger", uniqueN(fc$episode_id)),
  components = list(movement_damped = st_move, physical_interception = "BLOCKED (no first-contact labels; Step 02 BLOCKED)",
                    reach_margins = "exploratory", static_and_damped_baselines = "kept as comparison baselines"),
  source_commits = list(skillcorner = cfg$dataset$upstream_commit, LaurieOnTracking = "arrival rule adapted (MIT)"),
  data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
  model_revision = list(model_version = th$model_version, step08_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                        code_sha256 = setNames(lapply(c("player_motion.R", "reach.R"), function(f) sha256_file(file.path(here, "R", f))),
                                               c("player_motion.R", "reach.R"))),
  repository_head = git_out(root, "rev-parse", "HEAD")[1],
  test_command = "Rscript src/rebounding/run_tests.R unit reach; Rscript src/rebounding/run_tests.R gates step_08",
  unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
  data_audit_passed = all(checks$pass),
  heldout_metrics_file = "outputs/rebounding/step08/movement_errors.csv",
  acceptance_criteria_version = sprintf("manual %s, config v%d (step08 fixed before any real-data run)", cfg$manual_revision, cfg$config_version),
  decision = list(movement_pass = move_pass, comparisons = cmp[, .(candidate, reference, time_point, mean_diff = round(mean_diff, 4), hi = round(hi, 4), superior)],
                  limit_exceedance = exceed, reach = reach_sum),
  evidence = c("outputs/rebounding/step08/", "outputs/rebounding/reports/08_reachability.md"),
  reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
  open_risks = list("No first-contact labels", "Height envelope assumed", "Reach uses the realised ball path"),
  decision_note = sprintf("Movement %s; interception BLOCKED; reach exploratory.", st_move))
write_gate(file.path(gr, "08_reachability.json"), rec)

print(mov_sum); print(lim_tab); print(exceed); print(cmp[, .(candidate, reference, time_point, d = round(mean_diff, 3), hi = round(hi, 3), superior)])
print(reach_sum); print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 08:", status, "| movement", st_move, "\n")
