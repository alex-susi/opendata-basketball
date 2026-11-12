## ═════════════════════════════════════════════════════════════════════════════
# Step 06 of the rebounding manual: a causal ball filter (position and velocity) with learned noise, judged on
# held-out forecasts 2, 5 and 10 frames ahead inside collision-free flight against persistence, constant-velocity and
# gravity-only forecasts. Folds and uncertainty are Step 03's frozen harness.
#   Rscript src/rebounding/run_step06.R
# Needs raw_*.rds, the Step 01 table and the Step 03 outputs. Settings: config/experiment.yaml (step06, fixed before
# any run on real data). Writes outputs/rebounding/step06/, reports/06_filter_diagnostics.md,
# gate_results/06_ball_filter.json and 06_tests.csv.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R", "contact_states.R",
            "ball_filter.R", "ball_noise.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step06
inf <- th3$information
cache <- file.path(root, "outputs", "cache", "rebounding")
s3 <- file.path(root, "outputs", "rebounding", "step03")
out <- file.path(root, "outputs", "rebounding", "step06")
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
ev <- th$evaluation
ini <- th$init
H <- unlist(ev$horizons_frames)
levels <- unlist(th$decision$coverage_levels)
g02 <- cfg$step02$detector





## ═════════════════════════════════════════════════════════════════════════════
## 01 - BALL TRACKS, SEGMENTS AND THE FREE-FLIGHT TAG --------------------------
## ═════════════════════════════════════════════════════════════════════════════

message("Step 06: tracks")
tracks <- list()
seg_tab <- list()
# One game at a time: each eligible episode's ball track and its free-flight segment.
for (g in matches$id) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  for (k in which(el$game_id == g)) {
    s <- el[k]
    tr <- episode_tracking(raw, s, home == s$off_team, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
    b <- merge(tr$ball, raw$frames[, .(frame, berr)], by = "frame", all.x = TRUE)
    start <- s$release_frame + ini$skip_after_release
    end_free <- fcoalesce(s$contact_proxy_frame, s$shot_end_frame) - 2L
    seg <- b[measured == TRUE & frame >= start & frame <= end_free]
    res <- if (nrow(seg) >= 4L) one_step_residuals(seg[, .(key = TRUE, t = (frame - start) / FPS, x, y, z)], g02$g_track_ft_s2, g02$fit_keys) else numeric()
    tracks[[s$episode_id]] <- list(ball = b, start = start, end_free = end_free, free = !length(res) || max(res) <= 1.0)
    seg_tab[[length(seg_tab) + 1L]] <- data.table(episode_id = s$episode_id, game_id = g, start = start, end_free = end_free,
                                                  measured_in_segment = nrow(seg), max_one_step_residual = if (length(res)) max(res) else NA_real_,
                                                  free = tracks[[s$episode_id]]$free)
  }
}
seg_tab <- rbindlist(seg_tab)
fwrite(seg_tab, file.path(out, "segments.csv"))
train_segment <- function(id) {
  tk <- tracks[[id]]
  tk$ball[measured == TRUE & frame >= tk$start & frame <= tk$end_free, .(frame, x, y, z)]
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PER-FOLD PARAMETERS AND HELD-OUT FORECASTS -----------------------------
## ═════════════════════════════════════════════════════════════════════════════

evaluate_episode <- function(id, par) {
  tk <- tracks[[id]]
  obs <- tk$ball[measured == TRUE & frame >= tk$start]
  origins <- (tk$start + 1L):max(tk$start + 1L, tk$end_free)
  rf <- run_filter(obs, origins, par)
  meas <- tk$ball[measured == TRUE]
  rows <- list()
  health <- list()
  # At each origin: filter health, then the forecast at each horizon against the baselines.
  for (j in seq_along(origins)) {
    st <- rf$states[[j]]
    t <- origins[j]
    if (is.null(st) || st$n_obs < ini$warmup_observations) next
    health[[length(health) + 1L]] <- as.list(cov_health(st$P))
    recent <- tk$ball[frame >= t - 10L & frame <= t - 1L]
    for (h in H) {
      tg <- meas[frame == t + h]
      if (!nrow(tg)) next
      z <- c(tg$x, tg$y, tg$z)
      fc <- forecast_state(st, h, par)
      bl <- baseline_forecasts(obs, t, h, par$g)
      d <- z - fc$mean
      m2 <- as.numeric(t(d) %*% solve(fc$cov) %*% d)
      base <- data.table(episode_id = id, origin = t, horizon = h, target = if (t + h <= tk$end_free) "free flight" else "crosses contact",
                         measured_share_10 = mean(recent$measured), pred_error = tk$ball[frame == t - 1L]$berr[1])
      rows[[length(rows) + 1L]] <- rbind(cbind(base, model = "kalman", err = sqrt(sum(d^2)), err_x = d[1], err_y = d[2], err_z = d[3], mahal2 = m2,
                                               nll = 0.5 * (m2 + log(det(fc$cov)) + 3 * log(2 * pi))),
                                         rbindlist(lapply(names(bl), function(m) {
                                           e <- z - bl[[m]]
                                           cbind(base, model = m, err = sqrt(sum(e^2)), err_x = e[1], err_y = e[2], err_z = e[3], mahal2 = NA_real_, nll = NA_real_)
                                         })))
    }
  }
  list(rows = rbindlist(rows), innov = if (nrow(rf$innov)) cbind(episode_id = id, rf$innov) else NULL,
       health = rbindlist(health))
}

message("Step 06: folds")
params <- list()
qll <- list()
ev_rows <- list()
innov <- list()
health <- list()
# Per outer fold: noise parameters fitted on the training episodes' free-flight segments.
for (k in sort(unique(fa$outer_fold))) {
  s <- fold_split(fa, k)
  train_ids <- intersect(s$train, seg_tab[free == TRUE & measured_in_segment >= 5L]$episode_id)
  fit <- fit_ball_params(lapply(train_ids, train_segment), unlist(th$q_grid), ini$velocity_sd_ft_s)
  params[[k]] <- data.table(outer_fold = k, test_game = s$test_game, r_x = fit$par$r[1], r_y = fit$par$r[2], r_z = fit$par$r[3],
                            g = fit$par$g, q = fit$par$q, n_segments = fit$noise$n_segments, n_obs = fit$noise$n_obs,
                            n_g = fit$noise$n_g, n_train_episodes = length(train_ids))
  qll[[k]] <- cbind(outer_fold = k, fit$q_loglik)
  for (id in s$test) {
    e <- evaluate_episode(id, fit$par)
    if (nrow(e$rows)) ev_rows[[length(ev_rows) + 1L]] <- cbind(outer_fold = k, e$rows)
    if (!is.null(e$innov)) innov[[length(innov) + 1L]] <- cbind(outer_fold = k, e$innov)
    if (nrow(e$health)) health[[length(health) + 1L]] <- e$health
  }
  message("  fold ", k, " q = ", fit$par$q, " g = ", round(fit$par$g, 2))
}
params <- rbindlist(params)
fwrite(params, file.path(out, "parameters_by_fold.csv"))
fwrite(rbindlist(qll), file.path(out, "q_selection.csv"))
fc <- rbindlist(ev_rows)
fc <- merge(fc, seg_tab[, .(episode_id, game_id, free)], by = "episode_id")
fc <- merge(fc, el[, .(episode_id, shot_range)], by = "episode_id")
fc[, model_version := th$model_version]
fwrite(fc, file.path(out, "ball_forecasts.csv.gz"))
innov <- rbindlist(innov)
health <- rbindlist(health)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - SCORES -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

prim <- fc[free == TRUE & target == "free flight"]
err_tab <- prim[, .(forecasts = .N, episodes = uniqueN(episode_id), mean_err = mean(err), median_err = median(err),
                    p90_err = quantile(err, 0.9), rmse_z = sqrt(mean(err_z^2))), by = .(horizon, model)][order(horizon, mean_err)]
fwrite(err_tab, file.path(out, "errors_by_horizon.csv"))
kal <- prim[model == "kalman"]
cov_tab <- rbindlist(lapply(levels, function(L) kal[, .(level = L, n = .N, coverage = mean(mahal2 <= qchisq(L, 3))), by = horizon]))
cov_all <- rbindlist(lapply(levels, function(L) kal[, .(horizon = "all", level = L, n = .N, coverage = mean(mahal2 <= qchisq(L, 3)))]))
cov_tab <- rbind(cov_tab[, horizon := as.character(horizon)], cov_all)
cov_tab[, within_tol := abs(coverage - level) <= th$decision$coverage_tolerance]
fwrite(cov_tab, file.path(out, "coverage.csv"))
kal[, `:=`(share_band = fifelse(measured_share_10 >= 0.5, "measured share >= 0.5", "measured share < 0.5"),
           err_band = cut(pred_error, quantile(pred_error, c(0, 1 / 3, 2 / 3, 1), na.rm = TRUE), include.lowest = TRUE,
                          labels = c("predError low third", "middle third", "high third")))]
strata <- rbind(kal[, .(stratum = share_band, n = .N, mean_err = mean(err), cov50 = mean(mahal2 <= qchisq(0.5, 3)), cov90 = mean(mahal2 <= qchisq(0.9, 3))), by = .(horizon, share_band)][, share_band := NULL],
                kal[!is.na(err_band), .(stratum = as.character(err_band), n = .N, mean_err = mean(err), cov50 = mean(mahal2 <= qchisq(0.5, 3)), cov90 = mean(mahal2 <= qchisq(0.9, 3))), by = .(horizon, err_band)][, err_band := NULL],
                kal[, .(stratum = shot_range, n = .N, mean_err = mean(err), cov50 = mean(mahal2 <= qchisq(0.5, 3)), cov90 = mean(mahal2 <= qchisq(0.9, 3))), by = .(horizon, shot_range)][, shot_range := NULL])
fwrite(strata[order(horizon, stratum)], file.path(out, "by_stratum.csv"))
coll <- fc[target == "crosses contact", .(forecasts = .N, mean_err = mean(err), median_err = median(err)), by = .(horizon, model)][order(horizon, mean_err)]
fwrite(coll, file.path(out, "errors_crossing_contact.csv"))
nis <- merge(innov[n_obs > ini$warmup_observations], seg_tab[, .(episode_id, free)], by = "episode_id")
nis_tab <- nis[, .(updates = .N, mean_nis = mean(nis), share_above_chi2_95 = mean(nis > qchisq(0.95, 3))), by = free]
fwrite(nis_tab, file.path(out, "innovations.csv"))

u <- th3$uncertainty
pe <- prim[model %in% c("kalman", "gravity_only"), .(e = mean(err)), by = .(model, horizon, episode_id, game_id)]
pe[, time_point := paste0("h", horizon)]
cmp <- rbindlist(lapply(H, function(h) {
  r <- paired_comparison(pe[horizon == h, .(model, time_point, episode_id, game_id, e)], "kalman", "gravity_only", paste0("h", h), "e",
                         u$bootstrap_reps, u$seed, u$level)$summary
  r[, non_inferior := hi < th$decision$margin_ft]
}))
fwrite(cmp, file.path(out, "paired_vs_gravity_only.csv"))
ni_ok <- all(cmp$non_inferior)
cov_ok <- all(cov_tab[horizon == "all"]$within_tol)
stab_ok <- nrow(health) > 0 && all(health$finite == 1) && all(health$symmetric == 1) && all(health$min_eig > -1e-9)





## ═════════════════════════════════════════════════════════════════════════════
## 04 - CHECKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                    expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", all(freeze_ok), TRUE, all(freeze_ok))
addc("every origin covariance finite, symmetric, smallest eigenvalue > -1e-9 (count)", sum(health$finite == 1 & health$symmetric == 1 & health$min_eig > -1e-9),
     nrow(health), stab_ok)
pt <- params[, .(ok = n_train_episodes == nrow(seg_tab[free == TRUE & measured_in_segment >= 5L & episode_id %in% fa[outer_fold != .BY$outer_fold]$episode_id])), by = outer_fold]
addc("each fold's parameters use only its training games' free segments", sum(pt$ok), nrow(pt), all(pt$ok))
set.seed(u$seed)
sample_ids <- seg_tab[, .(episode_id = sample(episode_id, min(.N, 5L))), by = game_id]$episode_id
p1 <- with(params[1], list(r = c(r_x, r_y, r_z), g = g, q = q, v_sd = ini$velocity_sd_ft_s))
# The filter run online must match the filter run on the whole track at the same time.
online <- all(vapply(sample_ids, function(id) {
  tk <- tracks[[id]]
  obs <- tk$ball[measured == TRUE & frame >= tk$start]
  ts <- unique(pmax(tk$start + 1L, c(tk$start + 4L, tk$end_free)))
  all(vapply(ts, function(t) {
    a <- run_filter(obs, t, p1)$states[[1]]
    b <- run_filter(obs[usable_from <= t], t, p1)$states[[1]]
    poisoned <- copy(obs)[usable_from > t, `:=`(x = x + 20, z = z - 9)]
    c2 <- run_filter(poisoned, t, p1)$states[[1]]
    identical(a, b) && identical(a, c2)
  }, NA))
}, NA))
addc("online state at t identical with later frames removed or corrupted (5 episodes per game)", online, TRUE, online)
k1 <- fa[outer_fold == 1L]$episode_id
again <- rbindlist(lapply(k1, function(id) evaluate_episode(id, p1)$rows))
same <- isTRUE(all.equal(again$err, fc[outer_fold == 1L][order(match(episode_id, k1))]$err, tolerance = 0)) ||
        isTRUE(all.equal(sort(again$err), sort(fc[outer_fold == 1L]$err), tolerance = 0))
addc("re-running fold 1 reproduces every forecast error", same, TRUE, same)
addc("forecast targets are measured frames only", fc[, all(!is.na(err))], TRUE, fc[, all(!is.na(err))])
addc("free-flight segments (step02 one-step rule)", sprintf("%d of %d", sum(seg_tab$free), nrow(seg_tab)), "reported", TRUE)
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
st_filter <- if (ni_ok && cov_ok && stab_ok) "PASS" else "BLOCKED"
# The step's markdown report.
lines <- c("# Step 06: causal ball filter",
           "",
           sprintf("Run %s by `src/rebounding/run_step06.R`; settings `config/experiment.yaml` (`step06`, config v%d), fixed before any",
                   format(Sys.Date()), cfg$config_version),
           "run on real data; folds and uncertainty are Step 03's frozen harness.",
           "",
           "**Filter.** State (x, y, z, vx, vy, vz) in the attack frame. Constant velocity with gravity on z, white-noise",
           "acceleration q, observation noise r per axis. Only measured ball frames are observations (single filled frames are",
           "treated as missing), each usable one frame after it, so a forecast at frame t uses frames up to t - 1. r and g come",
           "from the training games' free-flight arcs; q from a grid by the training innovation likelihood.",
           "",
           "## Learned parameters by fold", "", md_table(params, 3), "",
           sprintf("Free-flight segments: %d of %d (one-step arc residual never above 1.0 ft). Forecasts are scored only inside them,",
                   sum(seg_tab$free), nrow(seg_tab)),
           "from three observations on, at measured target frames before the contact proxy.",
           "",
           "## Held-out forecast error (ft, 3D)", "", md_table(err_tab, 3), "",
           sprintf("## Filter against gravity-only (non-inferiority margin %.2f ft): %s", th$decision$margin_ft, if (ni_ok) "met" else "not met"),
           "", md_table(cmp[, .(time_point, episodes, mean_diff, lo, hi, games_better, worst_game_diff, non_inferior)], 4), "",
           sprintf("## Predictive coverage (tolerance %.2f): %s", th$decision$coverage_tolerance, if (cov_ok) "met" else "not met"),
           "", md_table(cov_tab, 3), "",
           "## Innovations (normalised squared, 3 df: mean 3 if the noise is right)", "", md_table(nis_tab, 3), "",
           "## By stratum (filter)", "", md_table(strata[order(horizon, stratum)], 3), "",
           "## Forecasts that cross a contact (tagged, not in the gate)", "", md_table(coll, 3), "",
           "## Checks", "", md_table(checks), "",
           sprintf("**Decision: filter %s.** Stability: %s.", st_filter, if (stab_ok) "met" else "not met"),
           "",
           "## Limits", "",
           "- The vendor's ball track is already smoothed and partly filled; the filter's noise is the scatter around that track,",
           "  not the distance to the true ball, which this data cannot measure.",
           "- Free flight only. Rim, board and player contacts (Step 07) break the constant-velocity-with-gravity model.")
writeLines(lines, file.path(reports, "06_filter_diagnostics.md"))





## ═════════════════════════════════════════════════════════════════════════════
## 06 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

tests <- rbind(run_tests(here, root, "unit", "ball_filter"), run_tests(here, root, "gates", "step_06"), fill = TRUE)
fwrite(tests, file.path(gr, "06_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
harness_ok <- all(checks$pass) && tests_ok
status <- if (!harness_ok) "BLOCKED" else if (st_filter == "PASS") "PASS" else "PASS_BASELINE"
# The gate record.
rec <- list(step = "06", status = status,
            scope = sprintf("causal ball filter in free flight; %d episodes, %d free segments, horizons %s frames", nrow(seg_tab), sum(seg_tab$free), paste(H, collapse = "/")),
            components = list(kalman = st_filter, gravity_only = "reference (fallback if the filter is blocked)"),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit, filterpy = "ideas only (MIT)"),
            data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
            model_revision = list(model_version = th$model_version, step06_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                                  code_sha256 = setNames(lapply(c("ball_filter.R", "ball_noise.R"), function(f) sha256_file(file.path(here, "R", f))),
                                                         c("ball_filter.R", "ball_noise.R"))),
            repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit ball_filter; Rscript src/rebounding/run_tests.R gates step_06",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = all(checks$pass),
            heldout_metrics_file = "outputs/rebounding/step06/errors_by_horizon.csv",
            acceptance_criteria_version = sprintf("manual %s, config v%d (step06 fixed before any real-data run)", cfg$manual_revision, cfg$config_version),
            decision = list(non_inferior = ni_ok, coverage_ok = cov_ok, stable = stab_ok,
                            vs_gravity_only = cmp[, .(time_point, mean_diff = round(mean_diff, 4), hi = round(hi, 4), non_inferior)],
                            coverage = cov_tab[horizon == "all", .(level, coverage = round(coverage, 4), within_tol)]),
            evidence = c("outputs/rebounding/step06/", "outputs/rebounding/reports/06_filter_diagnostics.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("Noise is scatter around the vendor's smoothed track, not error against the true ball",
                              "Free flight only; contacts are Step 07"),
            decision_note = sprintf("Filter %s.", st_filter))
write_gate(file.path(gr, "06_ball_filter.json"), rec)

print(params)
print(err_tab)
print(cmp[, .(time_point, d = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4), non_inferior)])
print(cov_tab)
print(nis_tab)
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 06:", status, "| filter", st_filter, "\n")
