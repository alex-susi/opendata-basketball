## ═════════════════════════════════════════════════════════════════════════════
# Step 10 of the rebounding manual: positioning versus movement. Each player's opportunity Q over the release-time
# reference ball distribution (Step 05 map) at release and at the rim-arrival trigger, its decomposition into movement
# and information, the access gained over the damped "ignores the ball" forecast (Step 08), the first sustained move
# toward the ball, role summaries and, only if identifiable, player effects.
#   Rscript src/rebounding/run_step10.R
# Needs raw_*.rds and the Step 01, 03, 05, 06 and 08 outputs (and the Step 05 map cache). Settings: config/experiment.yaml
# (step10, fixed before any real-data run). Writes outputs/rebounding/step10/, reports/10_movement_attribution.md,
# gate_results/10_movement.json and 10_tests.csv.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R",
            "spatial_prior.R", "physics.R", "particle_filter.R", "player_motion.R", "reach.R", "particle_integration.R",
            "opportunity_value.R", "response.R", "positioning.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step10
op <- th$opportunity
rs <- th$response
inf <- th3$information
# threshold variants: the prespecified sensitivity values plus the reporting curve (owner deviation 2026-11-05), base excluded
thr_var <- setdiff(sort(unique(c(unlist(rs$sensitivity$toward_ft_s), unlist(rs$threshold_curve)))), rs$toward_ft_s)
cache <- file.path(root, "outputs", "cache", "rebounding")
o <- function(...) file.path(root, "outputs", "rebounding", ...)
out <- o("step10")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
fz <- jsonlite::fromJSON(o("step03", "design_freeze.json"))
freeze_ok <- identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3))))
if (!freeze_ok) stop("Step 03's design changed since it was frozen")

el <- fread(o("step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(o("step03", "fold_assignment.csv"))
pts <- fread(o("step03", "prediction_points.csv"))
t_rim <- pts[time_point == "rim+0" & defined == TRUE, .(episode_id, t_r = frame_idx)]
f3 <- readRDS(file.path(cache, "step03_features.rds"))$features[time_point %in% c("release", "rim+0")]
maps <- readRDS(file.path(cache, "step05_spatial_prior.rds"))
grid <- maps$grid
p6 <- fread(o("step06", "parameters_by_fold.csv"))
l8 <- fread(o("step08", "limits_and_damping_by_fold.csv"))
OFF <- unlist(cfg$step07$origins$offsets_frames)
LEAD <- cfg$step09$particles$analog_lead_frames
ids <- intersect(t_rim$episode_id, el$episode_id)
ep_index <- setNames(seq_len(nrow(el)), el$episode_id)
shot <- el[, .(episode_id, shooter_id, shot_range, game_id, release_frame, rebound_frame, left_hoop)]
side <- merge(f3[time_point == "release", .(episode_id, pid, sy = y)], shot[, .(episode_id, pid = shooter_id)], by = c("episode_id", "pid"))
shot <- merge(shot, side[, .(episode_id, side = shot_side(sy))], by = "episode_id")





## ═════════════════════════════════════════════════════════════════════════════
## 01 - TRACKS AND PER-FOLD CONTEXTS -------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

message("Step 10: tracks")
eps <- list()
cross <- list()
for (g in matches$id) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  cross[[length(cross) + 1L]] <- made_crossings(raw, g)
  for (k in which(el$game_id == g)) {
    s <- el[k]
    # 25 frames of player history before release, so every velocity window (up to 10 frames) exists at release
    tr <- episode_tracking(raw, s, home == s$off_team, inf$keyframe_tol_ft, inf$ball_delay_frames, 25L)
    eps[[s$episode_id]] <- list(s = s, obs = tr$ball[measured == TRUE], players = tr$players)
  }
}
cross <- rbindlist(cross)
# One fold's context: hoops, gravity and the per-fold models.
ctx_of <- function(k) {
  s <- fold_split(fa, k)
  games <- unique(fa[episode_id %in% s$train]$game_id)
  hh <- cross[game_id %in% games, .(hx = median(x), hy = median(y)), by = left_hoop]
  hoops <- setNames(lapply(hh$left_hoop, function(l) c(hh[left_hoop == l]$hx, hh[left_hoop == l]$hy, RIM_Z)), as.character(hh$left_hoop))
  g <- p6[outer_fold == k]$g
  rows <- rbindlist(lapply(intersect(s$train, ids), function(id) {
    e <- eps[[id]]
    tr0 <- t_rim[episode_id == id]$t_r
    org <- tr0 + OFF
    org <- org[org < e$s$rebound_frame]
    analog_rows(e$obs, org, OFF[seq_along(org)], LEAD, e$s$rebound_frame, hoops[[as.character(e$s$left_hoop)]], g)
  }))
  list(hoops = hoops, g = g, r = unlist(p6[outer_fold == k, .(r_x, r_y, r_z)]), lib = analog_library(rows),
       rp = modifyList(cfg$step08$reach, list(v_max = l8[outer_fold == k]$v_max)), lambda = l8[outer_fold == k]$lambda,
       vmax = l8[outer_fold == k]$v_max)
}
ctxs <- lapply(sort(unique(fa$outer_fold)), ctx_of)
avail_of <- function(g, range) el[game_id != g & shot_range == range, median((rebound_frame - release_frame) / FPS)]

#' Player state at frame t from Step 03 positions and causal velocities over `window` frames (positions offset by
#' `jitter`, a constant per player, when given).
state_at <- function(id, t, window = rs$window_frames, jitter = NULL) {
  pl <- eps[[id]]$players[frame <= t, .(frame, pid, x, y, det, off)]
  if (!is.null(jitter)) {
    pl <- merge(pl, jitter, by = "pid")
    pl[, `:=`(x = x + jx, y = y + jy)][, c("jx", "jy") := NULL]
  }
  v <- causal_velocity(pl[, .(frame, pid, x, y, det)], window, cfg$step08$velocity$min_detected)
  merge(v[frame == t, .(pid, x, y, vx = fcoalesce(vx, 0), vy = fcoalesce(vy, 0))], unique(pl[, .(pid, off)]), by = "pid")
}
ref_particles <- function(id, model, seed) {
  sh <- shot[episode_id == id]
  set.seed(seed)
  B <- particles_from_map(maps$maps[[model]][[id]], grid, op$particles)
  B[, frame := sh$release_frame + as.integer(round(avail_of(sh$game_id, sh$shot_range) * FPS))]
  B
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PER EPISODE ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Decomposition, reference sensitivity, response.

message("Step 10: episodes")
rows <- list()
resp <- list()
qseed <- list()
# Per episode: decomposition, reference sensitivity and response.
for (id in ids) {
  e <- eps[[id]]
  sh <- shot[episode_id == id]
  k <- fa[episode_id == id]$outer_fold
  cx <- ctxs[[k]]
  tr0 <- e$s$release_frame
  tt <- t_rim[episode_id == id]$t_r
  s_r <- state_at(id, tr0)
  s_t <- state_at(id, tt)
  if (nrow(s_r) != 10L || nrow(s_t) != 10L) next
  s_base <- damped_state(s_r, (tt - tr0) / FPS, cx$lambda, cx$vmax)
  seed <- op$seed + ep_index[[id]]
  B_ref <- ref_particles(id, "side_range_kde", seed)
  hoop <- cx$hoops[[as.character(e$s$left_hoop)]]
  st2 <- two_point_state(e$obs[usable_from <= tt], tt, cx$g)
  B_t <- if (is.null(st2)) NULL else {
    a <- analog_forecast(cx$lib, st2, 0, LEAD, hoop, cfg$step07$empirical_k, cx$r)
    set.seed(seed + 1L)
    b <- particles_from_analog(a, op$particles, hoop)
    b[, frame := tt + LEAD]
    b
  }
  d <- decompose_opportunity(s_r, tr0, s_t, tt, s_base, B_ref, B_t, cx$rp, op$sigma_s)
  for (m in unlist(th$decomposition$reference_sensitivity)) {
    dm <- decompose_opportunity(s_r, tr0, s_t, tt, s_base, ref_particles(id, m, seed), NULL, cx$rp, op$sigma_s)[, .(pid, move, vs_baseline)]
    setnames(dm, c("pid", paste0("move_", m), paste0("vs_", m)))
    d <- merge(d, dm, by = "pid")
  }
  d2 <- decompose_opportunity(s_r, tr0, s_t, tt, s_base, ref_particles(id, "side_range_kde", seed + 7919L), NULL, cx$rp, op$sigma_s)
  qseed[[length(qseed) + 1L]] <- merge(d[, .(pid, move, vs_baseline)], d2[, .(pid, move2 = move, vs2 = vs_baseline)], by = "pid")
  roles <- assign_roles(s_r, sh$shooter_id)
  rows[[length(rows) + 1L]] <- cbind(episode_id = id, game_id = sh$game_id, shot_range = sh$shot_range,
                                     merge(merge(d, roles, by = "pid"), s_r[, .(pid, off)], by = "pid"))
  # response onset toward the reference distribution's centre, with its sensitivity variants
  target <- c(mean(B_ref$bx), mean(B_ref$by))
  hz <- tt + 10L
  vel <- function(window, jitter = NULL) {
    pl <- e$players[frame <= hz, .(frame, pid, x, y, det)]
    if (!is.null(jitter)) {
      pl <- merge(pl, jitter, by = "pid")
      pl[, `:=`(x = x + jx, y = y + jy)][, c("jx", "jy") := NULL]
    }
    causal_velocity(pl, window, cfg$step08$velocity$min_detected)
  }
  set.seed(seed + 2L)
  jit <- data.table(pid = s_r$pid, jx = rnorm(10, 0, rs$sensitivity$position_error_ft), jy = rnorm(10, 0, rs$sensitivity$position_error_ft))
  v0 <- vel(rs$window_frames)
  variants <- c(list(base = list(v = v0, rs = rs)),
                setNames(lapply(unlist(rs$sensitivity$window_frames), function(w) list(v = vel(w), rs = rs)), paste0("window ", unlist(rs$sensitivity$window_frames))),
                setNames(lapply(thr_var, function(s0) list(v = v0, rs = modifyList(rs, list(toward_ft_s = s0)))),
                         paste0("threshold ", thr_var, " ft/s")),
                list(`position error 1 ft` = list(v = vel(rs$window_frames, jit), rs = rs)))
  for (vn in names(variants))
    resp[[length(resp) + 1L]] <- cbind(episode_id = id, variant = vn, response_onset(variants[[vn]]$v, tr0, hz, target, variants[[vn]]$rs))
}
pm <- rbindlist(rows)
resp <- rbindlist(resp)
qseed <- rbindlist(qseed)
pm <- merge(pm, resp[variant == "base", .(episode_id, pid, response, onset_s, toward_release)], by = c("episode_id", "pid"))
pm[, model_version := th$model_version]
fwrite(pm, file.path(out, "opportunity_movement.csv.gz"))
fwrite(resp, file.path(out, "response_onsets.csv.gz"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SUMMARIES BY ROLE ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

u <- th3$uncertainty
role_tab <- merge(merge(group_means(pm, "q_release_ref", "role", 1000L, u$seed)[, .(role, n, q_release = mean)],
                        group_means(pm, "move", "role", 1000L, u$seed)[, .(role, move = mean, move_lo = lo, move_hi = hi)], by = "role"),
                  group_means(pm, "vs_baseline", "role", 1000L, u$seed)[, .(role, vs_baseline = mean, vs_lo = lo, vs_hi = hi)], by = "role")
role_tab <- merge(role_tab, pm[, .(responded = mean(response == "response"), already_moving = mean(response == "already moving"),
                                   no_response = mean(response == "no response"), median_onset_s = median(onset_s, na.rm = TRUE)), by = role], by = "role")
fwrite(role_tab[order(role)], file.path(out, "by_role.csv"))
ctx_tab <- group_means(pm, "vs_baseline", c("off", "shot_range"), 1000L, u$seed)
fwrite(ctx_tab, file.path(out, "by_side_and_shot_range.csv"))
dec_tab <- pm[!is.na(info), .(player_episodes = .N, total = mean(total), move = mean(move), info = mean(info), interaction = mean(interaction))]
fwrite(dec_tab, file.path(out, "decomposition_means.csv"))
# does gaining access predict the credited rebound? (association, within the episode's ten)
lab <- el[rebounded == TRUE, .(episode_id, rebounder_id)]
assoc <- merge(pm, lab, by = "episode_id")[, .(rebounder = pid == rebounder_id, vs_baseline, q_release_ref, q_later_ref, episode_id)]
assoc <- assoc[, .(rank_vs = frank(-vs_baseline, ties.method = "min")[rebounder], rank_q_later = frank(-q_later_ref, ties.method = "min")[rebounder],
                   rank_q_release = frank(-q_release_ref, ties.method = "min")[rebounder]), by = episode_id]
assoc_tab <- assoc[, .(episodes = .N, top1_by_vs_baseline = mean(rank_vs == 1), top1_by_q_later = mean(rank_q_later == 1),
                       top1_by_q_release = mean(rank_q_release == 1), top3_by_q_later = mean(rank_q_later <= 3))]
fwrite(assoc_tab, file.path(out, "credited_rebounder_ranks.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - PLAYER EFFECTS, ONLY IF IDENTIFIABLE -----------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ef <- th$effects
meas <- ef$measure
pm[, adj := get(meas) - mean(get(meas)), by = role]
pl_tab <- pm[, .(n = .N, games = uniqueN(game_id), mean = mean(adj), within_var = var(adj)), by = pid]
fwrite(pm[, .(episodes = .N), by = .(pid, game_id)], file.path(out, "exposure_by_player_game.csv"))
elig <- pl_tab[n >= ef$player_min_episodes]
shr <- eb_shrink(elig)
sens <- rbindlist(lapply(unlist(ef$prior_sensitivity), function(s) eb_shrink(elig, s)[, .(pid, scale = s, shrunk_s = shrunk)]))
sens <- merge(sens, shr[, .(pid, shrunk)], by = "pid")
sign_change <- sens[, .(share_sign_change = mean(sign(shrunk_s) != sign(shrunk) & shrunk != 0)), by = scale]
two <- pm[pid %in% pl_tab[games == 2]$pid, .(m = mean(adj), n = .N), by = .(pid, game_id)][order(pid, game_id)]
two <- two[, .(a = m[1], b = m[2], na = n[1], nb = n[2]), by = pid][!is.na(b)]
rel <- if (nrow(two) >= 3) cor(two$a, two$b) else NA_real_
fwrite(merge(shr, pl_tab[, .(pid, games)], by = "pid")[order(-shrunk)], file.path(out, "player_effects_shrunk.csv"))
fwrite(two, file.path(out, "player_split_by_game.csv"))
claims_ok <- isTRUE(rel >= 0.3) && all(sign_change$share_sign_change <= 0.1)





## ═════════════════════════════════════════════════════════════════════════════
## 05 - CHECKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                    expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", freeze_ok, TRUE, freeze_ok)
idg <- pm[!is.na(total), max(abs(total - (move + info + interaction)))]
addc("decomposition adds up (largest |total - move - info - interaction|)", signif(idg, 3), "< 1e-9", idg < 1e-9)
addc("movement measured with the same reference distribution at both times (one particle set per episode)", TRUE, TRUE, TRUE)
rho <- c(pooled_move = cor(pm$move, pm$move_pooled_kde, method = "spearman"), zone_move = cor(pm$move, pm$move_zone_bins, method = "spearman"),
         pooled_vs = cor(pm$vs_baseline, pm$vs_pooled_kde, method = "spearman"), zone_vs = cor(pm$vs_baseline, pm$vs_zone_bins, method = "spearman"))
addc("reference sensitivity: Spearman correlation with other Step 05 maps (move and vs_baseline)", paste(round(rho, 3), collapse = " / "),
     paste(">=", th$decomposition$min_rho), all(rho >= th$decomposition$min_rho))
qs <- qseed[, .(move = mean(abs(move - move2)), vs = mean(abs(vs_baseline - vs2)))]
addc("particle redraw changes Q measures little (mean absolute change, move / vs_baseline)", sprintf("%.4f / %.4f", qs$move, qs$vs), "< 0.02",
     qs$move < 0.02 && qs$vs < 0.02)
base <- resp[variant == "base", .(episode_id, pid, r0 = response, o0 = onset_s)]
stab <- merge(resp[variant != "base"], base, by = c("episode_id", "pid"))[
  , .(players = .N, class_changed = mean(response != r0), median_onset_shift_frames = median(abs(onset_s - o0) * FPS, na.rm = TRUE)), by = variant]
# Deviation (owner, 2026-11-05): threshold variants are judged on class change only; their onset timing is the curve below
stab[, rule := fifelse(grepl("^threshold", variant), "class change only (onset reported as a curve)", "class change and onset shift")]
stab[, stable := class_changed <= 0.2 & (grepl("^threshold", variant) | is.na(median_onset_shift_frames) | median_onset_shift_frames <= 3)]
fwrite(stab, file.path(out, "response_stability.csv"))
addc("response classes stable under smoothing, threshold and position-error variants; onsets stable under smoothing and position error",
     sum(stab$stable), nrow(stab), all(stab$stable))
# onset curve: response share and onset quartiles by role at every threshold of the curve
cv <- merge(resp[variant == "base" | grepl("^threshold", variant)],
            unique(pm[, .(episode_id, pid, role, game_id)]), by = c("episode_id", "pid"))
cv[, threshold_ft_s := fifelse(variant == "base", as.numeric(rs$toward_ft_s), as.numeric(sub("threshold ([0-9.]+) ft/s", "\\1", variant)))]
cv <- cv[threshold_ft_s %in% unlist(rs$threshold_curve)]
curve_of <- function(d) d[, .(players = .N, responded = mean(response == "response"),
                              onset_q25_s = quantile(onset_s, 0.25, na.rm = TRUE), onset_median_s = median(onset_s, na.rm = TRUE),
                              onset_q75_s = quantile(onset_s, 0.75, na.rm = TRUE)), by = threshold_ft_s]
curve_tab <- rbind(cbind(role = "all players", curve_of(cv)), cv[, curve_of(.SD), by = role])[order(role, threshold_ft_s)]
fwrite(curve_tab, file.path(out, "response_onset_curve.csv"))
addc("player effects reported with exposure (episodes and games per player)", nrow(pl_tab), "players", TRUE)
addc("episodes measured (with a rim arrival and ten players at both times) / with a rim arrival", sprintf("%d / %d", uniqueN(pm$episode_id), length(ids)),
     "reported", TRUE)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))
meas_ok <- all(checks$pass)





## ═════════════════════════════════════════════════════════════════════════════
## 06 - REPORT -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
# The step's markdown report.
lines <- c("# Step 10: positioning, movement and response",
           "",
           sprintf("Run %s by `src/rebounding/run_step10.R`; settings `config/experiment.yaml` (`step10`, config v%d), fixed before any",
                   format(Sys.Date()), cfg$config_version),
           "real-data run. Reference ball distribution: the Step 05 release map (not validated), so every measure is exploratory",
           "with respect to it. Later time: the rim-arrival trigger (the ball's flight before the rim).",
           "",
           "**Measures.** Q = a player's expected chance of reaching the ball over the reference distribution (logistic in his",
           "arrival margin, sigma 0.45 s). Move = Q at the rim arrival minus Q at release, same distribution in absolute time:",
           "0 for ideal pursuit, negative when time passes faster than he closes. vs_baseline = Q at the rim arrival minus Q of",
           "the damped forecast that ignores the ball: access gained by reading the shot. Info = Q at release under the updated",
           "ball forecast minus under the reference (player fixed).",
           "",
           "## By role (game bootstrap intervals)", "", md_table(role_tab[order(role)], 3), "",
           "## By side and shot range (vs_baseline)", "", md_table(ctx_tab, 3), "",
           "## Decomposition (mean over player-episodes with an updated forecast)", "", md_table(dec_tab, 4), "",
           "## Does it line up with the credited rebounder? (association, rank within the ten)", "", md_table(assoc_tab, 3), "",
           "## Response onset stability", "",
           "Threshold variants are judged on class change only; their onset timing is reported as the curve below (owner",
           "deviation 2026-11-05, after the first run's 8 ft/s variant shifted the median onset by 5 frames).", "",
           md_table(stab, 3), "",
           "## Response onset by speed threshold (curve)", "",
           "Onset = first frame of 5 in a row moving toward the ball's expected landing spot at least this fast (and 3 ft/s",
           "faster than at release). Read onsets as a curve: a higher bar is reached later by construction.", "",
           md_table(curve_tab, 2), "",
           sprintf("## Player effects (%s, role-adjusted, empirical Bayes; players with at least %d episodes: %d)", meas, ef$player_min_episodes, nrow(elig)), "",
           sprintf("Split-by-game reliability over %d players seen in two games: r = %s (needed >= 0.3).", nrow(two), formatC(rel, digits = 3, format = "f")),
           "", md_table(sign_change, 3), "",
           sprintf("**Player-level claims: %s.** %s", if (claims_ok) "supported" else "not supported",
                   if (claims_ok) "" else "Results are reported as descriptive role and context measures only."), "",
           "## Checks", "", md_table(checks), "",
           "## Limits", "",
           "- An onset is an observed response, not a physiological reaction time. Players who anticipate move before release",
           "  (\"already moving\"); players with transition duty do not crash by design (\"no response\").",
           "- Reference distribution and arrival rule are assumptions (Steps 05 and 08); no player heights or speeds of their own.",
           "- 179 of 204 players appear in only one game, so player-level differences cannot be checked across games for them.")
writeLines(lines, o("reports", "10_movement_attribution.md"))





## ═════════════════════════════════════════════════════════════════════════════
## 07 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

tests <- rbind(run_tests(here, root, "unit", "opportunity"), run_tests(here, root, "gates", "step_10"), fill = TRUE)
fwrite(tests, o("gate_results", "10_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
status <- if (meas_ok && tests_ok) "PASS" else "BLOCKED"
# The gate record.
rec <- list(step = "10", status = status,
            scope = sprintf("opportunity, movement and response measures for %d episodes (%d player-episodes); exploratory against the Step 05 reference",
                            uniqueN(pm$episode_id), nrow(pm)),
            components = list(measurements = if (meas_ok) "PASS" else "BLOCKED", player_claims = if (claims_ok) "PASS" else "BLOCKED (descriptive only)"),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit, LaurieOnTracking = "control-probability logistic adapted (MIT)"),
            data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
            model_revision = list(model_version = th$model_version, step10_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                                  code_sha256 = setNames(lapply(c("opportunity_value.R", "response.R", "positioning.R"), function(f) sha256_file(file.path(here, "R", f))),
                                                         c("opportunity_value.R", "response.R", "positioning.R"))),
            repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit opportunity; Rscript src/rebounding/run_tests.R gates step_10",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = meas_ok,
            heldout_metrics_file = "outputs/rebounding/step10/by_role.csv",
            acceptance_criteria_version = sprintf("manual %s, config v%d (step10 fixed before any real-data run)", cfg$manual_revision, cfg$config_version),
            decision = list(reliability_r = rel, sign_change = sign_change, reference_rho = as.list(round(rho, 4)), response_stability = stab,
                            response_onset_curve_all = curve_tab[role == "all players"]),
            deviations = list("Onset timing reported as a curve over 5-8 ft/s; threshold variants judged on class change only (owner, 2026-11-05)",
                              "25 frames of player history before release so every velocity window exists at release (bug fix, 2026-11-05)"),
            evidence = c("outputs/rebounding/step10/", "outputs/rebounding/reports/10_movement_attribution.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("Reference distribution not validated (Step 05 BLOCKED)", "Most players seen in one game only",
                              "Onsets are observed responses, not reaction times; their timing depends on the speed threshold"),
            decision_note = sprintf("Measurements %s; player claims %s.", if (meas_ok) "robust" else "not robust", if (claims_ok) "supported" else "not supported"))
write_gate(o("gate_results", "10_movement.json"), rec)

print(role_tab[order(role)])
print(ctx_tab)
print(dec_tab)
print(assoc_tab)
print(stab)
print(curve_tab)
print(sign_change)
cat("reliability r =", rel, "over", nrow(two), "players\n")
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 10:", status, "| player claims", if (claims_ok) "PASS" else "BLOCKED", "\n")
