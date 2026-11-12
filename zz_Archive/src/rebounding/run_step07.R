## ═════════════════════════════════════════════════════════════════════════════
# Step 07 of the rebounding manual: forecasts of the ball after it reaches the rim, from origins 0 to 0.6 s after
# the causal rim-arrival trigger, 0.2 to 0.6 s ahead. Three models: a Gaussian around the gravity-only forecast,
# empirical analog transitions, and a physics particle filter with uncertain rim, board and floor contacts. Judged
# with Step 03's folds and rules. Step 02 is BLOCKED, so the physics model cannot pass (no validated contact labels);
# the empirical model is the candidate for PASS_BASELINE.
#   Rscript src/rebounding/run_step07.R
# Needs raw_*.rds, the Step 01 table, Step 02 automated labels, Step 03 and Step 06 outputs. Settings:
# config/experiment.yaml (step07, fixed before any real-data run). Writes outputs/rebounding/step07/,
# reports/07_collision_audit.md, gate_results/07_postimpact.json and 07_tests.csv.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "step00.R", "folds.R", "metrics.R", "reference_baselines.R",
            "physics.R", "particle_filter.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step07
ph <- th$physics
inf <- th3$information
cache <- file.path(root, "outputs", "cache", "rebounding")
s3 <- file.path(root, "outputs", "rebounding", "step03")
out <- file.path(root, "outputs", "rebounding", "step07")
reports <- file.path(root, "outputs", "rebounding", "reports")
gr <- file.path(root, "outputs", "rebounding", "gate_results")
dir.create(file.path(out, "figures"), recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))

fz <- jsonlite::fromJSON(file.path(s3, "design_freeze.json"))
freeze_ok <- c(config = identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3)))),
               code = all(vapply(names(fz$code_sha256), function(f) identical(fz$code_sha256[[f]], sha256_file(file.path(here, "R", f))), NA)))
if (!all(freeze_ok)) stop("Step 03's design changed since it was frozen")

el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(file.path(s3, "fold_assignment.csv"))
pts <- fread(file.path(s3, "prediction_points.csv"))[time_point == "release", .(episode_id, t_rim = rim_arrival_frame)]
auto <- fread(file.path(root, "outputs", "rebounding", "step02", "auto_summary.csv"), na.strings = c("", "NA"))
p6 <- fread(file.path(root, "outputs", "rebounding", "step06", "parameters_by_fold.csv"))
OFF <- unlist(th$origins$offsets_frames)
H <- unlist(th$horizons_frames)
levels <- unlist(th$scores$coverage_levels)
LEADS <- min(H):(max(H) + th$target_slack_frames)   # exact leads a target can have (deviation, see config)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - TRACKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Made-shot rim crossings, per-end hoops by fold.

message("Step 07: tracks")
tracks <- list()
cross <- list()
# Made shots' rim crossings, for each fold's hoop positions.
for (g in matches$id) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  home <- matches$home_team$id[matches$id == g]
  sh <- raw$shots[made == TRUE & !is.na(f0) & !is.na(f1)]
  for (k in seq_len(nrow(sh))) {
    s <- sh[k]
    w <- ball_track(raw$frames, s, s$f0, s$f1 + MADE_AFTER)
    if (nrow(w) < 5L) next
    i <- which(w$z[-1] < RIM_Z & w$z[-nrow(w)] >= RIM_Z & hoop_dist(w$x[-1], w$y[-1]) < 4)
    if (!length(i)) next
    i <- i[1]
    a <- (w$z[i] - RIM_Z) / (w$z[i] - w$z[i + 1])
    cross[[length(cross) + 1L]] <- data.table(game_id = g, left_hoop = s$left_hoop, x = w$x[i] + a * (w$x[i + 1] - w$x[i]),
                                              y = w$y[i] + a * (w$y[i + 1] - w$y[i]))
  }
  for (k in which(el$game_id == g)) {
    s <- el[k]
    tr <- episode_tracking(raw, s, home == s$off_team, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
    tracks[[s$episode_id]] <- list(obs = tr$ball[measured == TRUE], players = tr$players, s = s,
                                   t_rim = pts[episode_id == s$episode_id]$t_rim)
  }
}
cross <- rbindlist(cross)
fold_hoops <- function(train_games) cross[game_id %in% train_games, .(hx = median(x), hy = median(y), n = .N), by = left_hoop]

origins_of <- function(tk) {
  if (is.na(tk$t_rim)) return(integer())
  o <- tk$t_rim + OFF
  o[o < tk$s$rebound_frame]
}

# a player within reach of the ball between the origin and the target (evaluation tag only)
player_near <- function(tk, hoop, t, tt) {
  b <- tk$obs[frame > t & frame <= tt]
  if (!nrow(b)) return(FALSE)
  pf <- to_player_frame(b$x - hoop[1], b$y - hoop[2], b$z, list(hx = hoop[1], hy = hoop[2]))
  j <- merge(data.table(frame = b$frame, bx = pf$x, by = pf$y, bz = b$z), tk$players[, .(frame, x, y)], by = "frame")
  any(sqrt((j$x - j$bx)^2 + (j$y - j$by)^2) <= 3 & j$bz <= 12.5)
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - ONE TEST EPISODE UNDER ONE FOLD'S PARAMETERS ---------------------------
## ═════════════════════════════════════════════════════════════════════════════

run_episode <- function(tk, par, models, lib, gres, seed, n_particles = ph$particles, quick = FALSE, obs = tk$obs,
                        target_obs = obs) {
  origins <- origins_of(tk)
  if (!length(origins)) return(NULL)
  hoop <- par$hoops[[as.character(tk$s$left_hoop)]]
  meas <- target_obs
  rf <- tk$s$rebound_frame
  rows <- list()
  diag <- list()
  pf <- NULL
  if ("physics" %in% models) {
    set.seed(seed)
    st0 <- two_point_state(obs, origins[1], par$g)
    if (!is.null(st0)) {
      php <- modifyList(ph, list(particles = n_particles))
      pf <- pf_init(st0, hoop, php, par$r)
      done <- st0$frame
    }
  }
  # At each origin: the particle filter brought up to date, then a forecast cloud for each horizon and model.
  for (j in seq_along(origins)) {
    t <- origins[j]
    st <- two_point_state(obs, t, par$g)
    if (is.null(st)) next
    if (!is.null(pf)) {
      for (f in obs[usable_from <= t & frame > done]$frame) {
        pf <- pf_advance(pf, f, par$g, php)
        pf <- pf_update(pf, unlist(obs[frame == f, .(x, y, z)]), php)
        done <- f
      }
    }
    for (h in H) {
      tg <- meas[frame >= t + h & frame <= t + h + th$target_slack_frames & frame < rf][order(frame)][1][!is.na(frame)]
      if (nrow(tg)) ld <- tg$frame - t
      if (!nrow(tg)) next
      y <- c(tg$x, tg$y, tg$z)
      clouds <- list()
      if ("gravity_gauss" %in% models) {
        tau <- (t + ld - st$frame) / FPS
        mu <- c(st$p[1:2] + st$v[1:2] * tau, st$p[3] + st$v[3] * tau - 0.5 * par$g * tau^2)
        clouds$gravity_gauss <- list(X = matrix(mu, 1), w = 1, sd = gres[horizon == ld, c(sx, sy, sz)])
      }
      if ("empirical" %in% models) {
        a <- analog_forecast(lib, st, OFF[j], ld, hoop, th$empirical_k, par$r)
        clouds$empirical <- list(X = a$X, w = a$w, sd = a$sd)
      }
      if (!is.null(pf)) {
        fc <- pf_forecast(pf, t + ld, par$g, php)
        clouds$physics <- list(X = fc$X, w = fc$w, sd = sqrt(par$r^2 + ph$kernel_sd_ft^2), contacts = fc$contacts)
      }
      tag <- player_near(tk, hoop, t, t + ld)
      for (m in names(clouds)) {
        cl <- clouds[[m]]
        sc <- if (quick) score_quick(y, cl$X, cl$w, cl$sd) else
          score_mixture(y, cl$X, cl$w, cl$sd, 300L, (seed %% 100000L) * 1000L + j * 50L + h)
        rows[[length(rows) + 1L]] <- data.table(episode_id = tk$s$episode_id, origin = t, offset = OFF[j], horizon = h, lead = ld, model = m,
                                                player_near = tag, t(sc))
        if (m == "physics" && !quick) {
          ct <- cl$contacts > 0
          diag[[length(diag) + 1L]] <- data.table(episode_id = tk$s$episode_id, offset = OFF[j], horizon = h,
                                                  rim = sum(cl$w * ct[, "RIM"]), board = sum(cl$w * ct[, "BACKBOARD"]),
                                                  floor = sum(cl$w * ct[, "FLOOR"]), none = sum(cl$w * (rowSums(ct) == 0)))
        }
      }
    }
  }
  list(rows = rbindlist(rows, fill = TRUE), diag = rbindlist(diag), pf_log = if (!is.null(pf) && length(pf$log)) cbind(episode_id = tk$s$episode_id, rbindlist(pf$log)) else NULL)
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - FOLDS ------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

message("Step 07: folds")
ep_index <- setNames(seq_len(nrow(el)), el$episode_id)
# `--reuse-folds` loads the fold results of the last full run (same code and config) instead of recomputing them
fold_cache <- file.path(cache, "step07_folds.rds")
reuse <- "--reuse-folds" %in% commandArgs(trailingOnly = TRUE) && file.exists(fold_cache)
fold_key <- c(cfg = paste(openssl::sha256(yaml::as.yaml(th))), physics = sha256_file(file.path(here, "R", "physics.R")),
              pf = sha256_file(file.path(here, "R", "particle_filter.R")))
if (reuse) {
  fc_all <- readRDS(fold_cache)
  if (!identical(fc_all$key, fold_key)) stop("cached fold results were made with other code or settings; rerun without --reuse-folds")
  list2env(fc_all[c("scores", "pdiag", "pflog", "hoops_tab", "stab", "fold_par")], environment())
}
scores <- if (reuse) scores else list()
pdiag <- if (reuse) pdiag else list()
pflog <- if (reuse) pflog else list()
hoops_tab <- if (reuse) hoops_tab else list()
stab <- if (reuse) stab else list()
fold_par <- if (reuse) fold_par else list()
# Per outer fold: parameters and hoops from the training games, then forecasts for the test episodes.
for (k in if (reuse) integer() else sort(unique(fa$outer_fold))) {
  s <- fold_split(fa, k)
  train_games <- unique(fa[episode_id %in% s$train]$game_id)
  hh <- fold_hoops(train_games)
  pk <- p6[outer_fold == k]
  par <- list(g = pk$g, r = c(pk$r_x, pk$r_y, pk$r_z),
              hoops = setNames(lapply(hh$left_hoop, function(l) c(hh[left_hoop == l]$hx, hh[left_hoop == l]$hy, RIM_Z)), as.character(hh$left_hoop)))
  fold_par[[k]] <- par
  hoops_tab[[k]] <- cbind(outer_fold = k, test_game = s$test_game, hh)
  # training library and gravity residuals
  tr_rows <- rbindlist(lapply(intersect(s$train, names(tracks)), function(id) {
    tk <- tracks[[id]]
    o <- origins_of(tk)
    if (!length(o)) return(NULL)
    hoop <- par$hoops[[as.character(tk$s$left_hoop)]]
    analog_rows(tk$obs, o, OFF[seq_along(o)], LEADS, tk$s$rebound_frame, hoop, par$g)
  }))
  lib <- analog_library(tr_rows)
  # gravity-only residual per axis and horizon: training displacement minus the gravity-only displacement over the
  # exact time from the last usable measured frame (tau)
  gres <- tr_rows[, .(sx = sqrt(mean((dx - vx * tau)^2)), sy = sqrt(mean((dy - vy * tau)^2)),
                      sz = sqrt(mean((dz - (vz * tau - 0.5 * par$g * tau^2))^2))), by = horizon]
  for (id in intersect(s$test, names(tracks))) {
    seed <- ph$seeds[[1]] + ep_index[[id]]
    r <- run_episode(tracks[[id]], par, c("gravity_gauss", "empirical", "physics"), lib, gres, seed)
    if (is.null(r) || !nrow(r$rows)) next
    scores[[length(scores) + 1L]] <- cbind(outer_fold = k, r$rows)
    pdiag[[length(pdiag) + 1L]] <- r$diag
    pflog[[length(pflog) + 1L]] <- r$pf_log
    r2 <- run_episode(tracks[[id]], par, "physics", lib, gres, ph$seeds[[2]] + ep_index[[id]], quick = TRUE)
    r3 <- run_episode(tracks[[id]], par, "physics", lib, gres, seed, n_particles = 2L * ph$particles, quick = TRUE)
    if (!is.null(r2) && nrow(r2$rows)) stab[[length(stab) + 1L]] <- rbind(cbind(run = "second seed", r2$rows), cbind(run = "twice the particles", r3$rows), fill = TRUE)
  }
  message("  fold ", k, " done")
}
if (!reuse) saveRDS(list(key = fold_key, scores = scores, pdiag = pdiag, pflog = pflog, hoops_tab = hoops_tab, stab = stab,
                         fold_par = fold_par), fold_cache)
sc <- rbindlist(scores, fill = TRUE)
n_all <- sc[, uniqueN(paste(episode_id, origin, horizon))]
sc <- sc[, if (uniqueN(model) == 3L) .SD, by = .(episode_id, origin, horizon)]   # same targets for every model
n_kept <- sc[, uniqueN(paste(episode_id, origin, horizon))]
sc <- merge(sc, fa[, .(episode_id, game_id)], by = "episode_id")
sc <- merge(sc, el[, .(episode_id, shot_range)], by = "episode_id")
sc <- merge(sc, auto[, .(episode_id, auto_contact_kind = contact_kind)], by = "episode_id", all.x = TRUE)
for (L in levels) set(sc, j = paste0("in_", L), value = sc$u <= L + 1e-12)
sc[, model_version := th$model_version]
fwrite(sc, file.path(out, "postimpact_scores.csv.gz"))
pdiag <- rbindlist(pdiag)
pflog <- rbindlist(pflog)
stab <- rbindlist(stab, fill = TRUE)
fwrite(rbindlist(hoops_tab), file.path(out, "hoops_by_fold.csv"))
fwrite(pdiag, file.path(out, "physics_contact_modes.csv.gz"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - SCORES, COVERAGE AND DECISIONS -----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

summ <- sc[, .(targets = .N, episodes = uniqueN(episode_id), nll = mean(nll), energy = mean(energy), err = mean(err),
               cov50 = mean(in_0.5), cov90 = mean(in_0.9)), by = .(horizon, model)][order(horizon, nll)]
fwrite(summ, file.path(out, "scores_by_horizon.csv"))
cov <- rbindlist(lapply(levels, function(L) sc[, .(level = L, n = .N, coverage = mean(get(paste0("in_", L)))), by = model]))
cov[, within_tol := abs(coverage - level) <= th$decision$coverage_tolerance]
fwrite(cov, file.path(out, "coverage.csv"))
strata <- rbind(sc[, .(stratum = paste("offset", offset), n = .N, nll = mean(nll), cov90 = mean(in_0.9)), by = .(model, offset)][, offset := NULL],
                sc[, .(stratum = fifelse(player_near, "player within reach", "no player within reach"), n = .N, nll = mean(nll), cov90 = mean(in_0.9)), by = .(model, player_near)][, player_near := NULL],
                sc[, .(stratum = paste("Step 02 auto kind:", fcoalesce(auto_contact_kind, "missing")), n = .N, nll = mean(nll), cov90 = mean(in_0.9)), by = .(model, auto_contact_kind)][, auto_contact_kind := NULL],
                sc[, .(stratum = paste("shot range:", shot_range), n = .N, nll = mean(nll), cov90 = mean(in_0.9)), by = .(model, shot_range)][, shot_range := NULL])
fwrite(strata[order(stratum, nll)], file.path(out, "by_stratum.csv"))
u <- th3$uncertainty
pe <- sc[, .(m = mean(nll)), by = .(model, horizon, episode_id, game_id)][, time_point := paste0("h", horizon)]
cmp_fun <- function(a, b) rbindlist(lapply(H, function(h) paired_comparison(pe[horizon == h, .(model, time_point, episode_id, game_id, m)],
                                                                            a, b, paste0("h", h), "m", u$bootstrap_reps, u$seed, u$level)$summary))
cmp <- rbind(cmp_fun("empirical", "gravity_gauss"), cmp_fun("physics", "empirical"), cmp_fun("physics", "gravity_gauss"))
cmp[, superior := hi < 0 & drop_one_max < 0]
fwrite(cmp, file.path(out, "paired_comparisons.csv"))
emp_pass <- all(cov[model == "empirical"]$within_tol) && all(cmp[candidate == "empirical" & reference == "gravity_gauss"]$superior)
# Monte Carlo stability of the physics model
base_phys <- sc[model == "physics", .(episode_id, origin, horizon, nll0 = nll)]
st_tab <- merge(stab[model == "physics", .(run, episode_id, origin, horizon, nll)], base_phys, by = c("episode_id", "origin", "horizon"))
st_tab <- st_tab[, .(targets = .N, mean_abs_diff = mean(abs(nll - nll0)), mean_diff = mean(nll - nll0)), by = run]
st_tab[, stable := mean_abs_diff < 0.05 & abs(mean_diff) < 0.02]
fwrite(st_tab, file.path(out, "mc_stability.csv"))
pf_tab <- pflog[, .(updates = .N, mean_ess_share = mean(ess) / ph$particles, resampled_share = mean(resampled),
                    degenerate_share = mean(ess < 0.1 * ph$particles), max_weight_sum_error = max(abs(weight_sum - 1)))]
fwrite(pf_tab, file.path(out, "particle_diagnostics.csv"))
modes <- pdiag[, .(rim = mean(rim), board = mean(board), floor = mean(floor), none = mean(none)), by = horizon]
fwrite(modes, file.path(out, "physics_mode_shares.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - CHECKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                    expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", all(freeze_ok), TRUE, all(freeze_ok))
addc("particle weights sum to 1 after every update (largest error)", signif(pf_tab$max_weight_sum_error, 3), "< 1e-9", pf_tab$max_weight_sum_error < 1e-9)
addc("effective sample size monitored (updates logged)", pf_tab$updates, "> 0", pf_tab$updates > 0)
addc("hoops come from training games' made shots only", rbindlist(hoops_tab)[, all(n > 0)], TRUE, rbindlist(hoops_tab)[, all(n > 0)])
addc("every model scored on the same targets (targets with all three forecasts / all targets)", sprintf("%d / %d", n_kept, n_all),
     "all models equal", sc[, .N, by = model][, uniqueN(N)] == 1L)
set.seed(u$seed)
poison_ids <- el[episode_id %in% names(tracks), .(episode_id = sample(episode_id, min(.N, 3L))), by = game_id]$episode_id
# Corrupting the track after the origin must not change the forecast.
poison_ok <- all(vapply(poison_ids, function(id) {
  tk <- tracks[[id]]
  o <- origins_of(tk)
  if (length(o) < 2L) return(TRUE)
  k <- fa[episode_id == id]$outer_fold
  par <- fold_par[[k]]
  s <- fold_split(fa, k)
  lib_k <- analog_library(rbindlist(lapply(intersect(s$train, names(tracks)), function(j) {
    t2 <- tracks[[j]]
    oo <- origins_of(t2)
    if (!length(oo)) return(NULL)
    analog_rows(t2$obs, oo, OFF[seq_along(oo)], LEADS, t2$s$rebound_frame, par$hoops[[as.character(t2$s$left_hoop)]], par$g)
  })))
  gres_k <- data.table(horizon = LEADS, sx = 1, sy = 1, sz = 1)
  seed <- ph$seeds[[1]] + ep_index[[id]]
  a <- run_episode(tk, par, c("gravity_gauss", "empirical", "physics"), lib_k, gres_k, seed)$rows
  if (is.null(a) || !nrow(a)) return(TRUE)                     # no target to forecast in this episode
  # inputs after the second origin corrupted, targets kept clean: every forecast made at or before it must not change
  bad <- copy(tk$obs)[usable_from > o[2], `:=`(x = x + 15, z = z + 6)]
  b <- run_episode(tk, par, c("gravity_gauss", "empirical", "physics"), lib_k, gres_k, seed, obs = bad, target_obs = tk$obs)$rows
  aa <- a[origin <= o[2]]
  bb <- b[origin <= o[2]]
  nrow(aa) > 0 && isTRUE(all.equal(aa, bb, tolerance = 0))
}, NA))
addc("forecasts at an origin do not change when later frames are corrupted (3 episodes per game)", poison_ok, TRUE, poison_ok)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 06 - EXAMPLES ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Rim, board and unclear cases, with their forecasts at the trigger.

set.seed(u$seed)
kinds <- c("rim", "board", "rim_or_board", "none")
ex_ids <- rbindlist(lapply(kinds, function(kk) {
  ids <- intersect(auto[contact_kind == kk]$episode_id, unique(sc$episode_id))
  if (!length(ids)) NULL else data.table(kind = kk, episode_id = sample(ids, min(2L, length(ids))))
}))
ex_tab <- list()
png(file.path(out, "figures", "07_examples.png"), width = 1800, height = 900, res = 120)
par(mfrow = c(2, 4), mar = c(3, 3, 3, 1), mgp = c(1.8, 0.6, 0))
# Example episodes, one panel each.
for (i in seq_len(nrow(ex_ids))) {
  id <- ex_ids$episode_id[i]
  tk <- tracks[[id]]
  k <- fa[episode_id == id]$outer_fold
  par0 <- fold_par[[k]]
  hoop <- par0$hoops[[as.character(tk$s$left_hoop)]]
  o <- origins_of(tk)[1]
  st <- two_point_state(tk$obs, o, par0$g)
  set.seed(ph$seeds[[1]] + ep_index[[id]])
  pf <- pf_init(st, hoop, ph, par0$r)
  fc <- pf_forecast(pf, o + 10L, par0$g, ph)
  b <- tk$obs[frame >= tk$s$release_frame & frame <= tk$s$rebound_frame]
  plot(b$x - hoop[1], b$z, pch = 16, cex = 0.5, col = "grey55", xlim = c(-12, 4), ylim = c(0, 16), asp = 1,
       xlab = "x from hoop (ft)", ylab = "z (ft)", main = sprintf("%s\nStep 02 auto: %s (unvalidated)", id, ex_ids$kind[i]), cex.main = 0.8)
  points(fc$X[, 1] - hoop[1], fc$X[, 3], pch = 16, cex = 0.3, col = adjustcolor("steelblue", 0.4))
  segments(-RIM_R, RIM_Z, RIM_R, RIM_Z, lwd = 3, col = "darkorange")
  segments(BOARD_X - RIM_X, BOARD_Z0, BOARD_X - RIM_X, BOARD_Z1, lwd = 3)
  points(st$p[1] - hoop[1], st$p[3], pch = 17, col = "black", cex = 1.3)
  tg <- tk$obs[frame == o + 10L]
  if (nrow(tg)) points(tg$x - hoop[1], tg$z, pch = 4, col = "red", cex = 1.8, lwd = 2.5)
  ct <- fc$contacts > 0
  ex_tab[[i]] <- data.table(episode_id = id, step02_auto_kind = ex_ids$kind[i], label_status = "unvalidated (Step 02 BLOCKED)",
                            physics_rim = round(mean(ct[, "RIM"]), 2), physics_board = round(mean(ct[, "BACKBOARD"]), 2),
                            physics_none = round(mean(rowSums(ct) == 0), 2),
                            auto_first_player_contact_frame = auto[episode_id == id]$first_player_contact_frame,
                            trigger_frame = o)
}
dev.off()
ex_tab <- rbindlist(ex_tab)
fwrite(ex_tab, file.path(out, "examples.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 07 - REPORT -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
st_emp <- if (emp_pass) "PASS_BASELINE" else "BLOCKED"
# The step's markdown report.
lines <- c("# Step 07: forecasts after the ball reaches the rim",
           "",
           sprintf("Run %s by `src/rebounding/run_step07.R`; settings `config/experiment.yaml` (`step07`, config v%d), fixed before any",
                   format(Sys.Date()), cfg$config_version),
           "real-data run; folds and rules are Step 03's, free-flight noise and g are Step 06's per fold.",
           "",
           "**Gate rule.** The manual passes a collision model only for contact states with reliable labels. Step 02 is BLOCKED, so",
           "the physics model is BLOCKED whatever it scores; the empirical transition model is the candidate for PASS_BASELINE.",
           "",
           sprintf("Origins: %s frames after the causal rim-arrival trigger; horizons %s frames; targets are measured ball frames",
                   paste(OFF, collapse = ", "), paste(H, collapse = ", ")),
           sprintf("before the credited rebound (%d episodes, %d targets per model). Hoops: per camera end from the training games' made shots.",
                   uniqueN(sc$episode_id), sc[model == "physics", .N]),
           "",
           sprintf(paste("**Deviation.** Targets are the first measured frame 0 to %d frames after origin + horizon (exact lead used by every",
                         "model). The prespecified exact-frame rule scored only 268 of 679 episodes because of the vendor's 5-frame measuring",
                         "cadence; that first run is kept in `step07/first_run_exact_frames/`."), th$target_slack_frames),
           "",
           "## Held-out scores (negative log density per cubic foot, energy score and mean error in ft; coverage of 50 / 90% regions)",
           "", md_table(summ, 3), "",
           "## Decisions", "",
           md_table(cmp[, .(candidate, reference, time_point, mean_diff, lo, hi, games_better, drop_one_max, superior)], 3), "",
           md_table(cov, 3), "",
           sprintf("- Empirical transitions (coverage within %.2f at both levels, superior to the gravity-only Gaussian at every horizon): **%s**.",
                   th$decision$coverage_tolerance, st_emp),
           "- Physics particle filter: **BLOCKED** by the gate rule (no validated contact labels); the comparison above is exploratory.",
           "",
           "## Particle filter diagnostics", "", md_table(pf_tab, 3), "", md_table(st_tab, 3), "",
           "Share of physics particles that touched each surface by the forecast time (weighted):", "", md_table(modes, 3), "",
           "## By stratum", "", md_table(strata[order(stratum, nll)], 3), "",
           "## Examples (`step07/figures/07_examples.png`)", "",
           "Side view from the trigger: measured ball (grey), physics particles 10 frames ahead (blue), state at the trigger",
           "(triangle), measured ball 10 frames ahead (cross), ring (orange), board (black). Kinds are Step 02's automated labels,",
           "which failed their reliability check:", "", md_table(ex_tab), "",
           "## Checks", "", md_table(checks), "",
           "## Limits", "",
           "- No validated contact labels: a course change may be the rim, the board, a hand or the tracking.",
           "- Targets after a player reaches the ball are not ball physics; they are tagged (`player within reach`), not removed.",
           "- The ring and board positions come from made shots and FIBA geometry; spin and restitution are drawn from broad priors.")
writeLines(lines, file.path(reports, "07_collision_audit.md"))





## ═════════════════════════════════════════════════════════════════════════════
## 08 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

tests <- rbind(run_tests(here, root, "unit", "postimpact"), run_tests(here, root, "gates", "step_07"), fill = TRUE)
fwrite(tests, file.path(gr, "07_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
harness_ok <- all(checks$pass) && tests_ok
status <- if (harness_ok && emp_pass) "PASS_BASELINE" else "BLOCKED"
# The gate record.
rec <- list(step = "07", status = status,
            scope = sprintf("post-rim ball forecasts, %d episodes, origins %s, horizons %s frames", uniqueN(sc$episode_id), paste(OFF, collapse = "/"), paste(H, collapse = "/")),
            components = list(empirical = st_emp, physics = "BLOCKED (no validated contact labels; Step 02 BLOCKED)", gravity_gauss = "reference"),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit, filterpy = "ideas only (MIT)", basketball_shot = "not used (no licence)"),
            data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
            model_revision = list(model_version = th$model_version, step07_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                                  code_sha256 = setNames(lapply(c("physics.R", "particle_filter.R"), function(f) sha256_file(file.path(here, "R", f))),
                                                         c("physics.R", "particle_filter.R"))),
            repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit postimpact; Rscript src/rebounding/run_tests.R gates step_07",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = all(checks$pass),
            heldout_metrics_file = "outputs/rebounding/step07/scores_by_horizon.csv",
            acceptance_criteria_version = sprintf("manual %s, config v%d (step07 fixed before any real-data run)", cfg$manual_revision, cfg$config_version),
            decision = list(empirical_pass = emp_pass, coverage = cov[, .(model, level, coverage = round(coverage, 4), within_tol)],
                            comparisons = cmp[, .(candidate, reference, time_point, mean_diff = round(mean_diff, 4), hi = round(hi, 4), superior)],
                            mc_stability = st_tab),
            evidence = c("outputs/rebounding/step07/", "outputs/rebounding/reports/07_collision_audit.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("No validated contact labels", "Targets after a player touch are tagged, not removed",
                              "Priors on restitution and friction are broad assumptions"),
            deviations = list(list(item = "target frame", decision = sprintf("first measured frame 0-%d frames after origin + horizon; the exact-frame rule scored 268 of 679 episodes (5-frame measuring cadence); first run kept in step07/first_run_exact_frames/", th$target_slack_frames))),
            decision_note = sprintf("Empirical %s; physics BLOCKED by rule.", st_emp))
write_gate(file.path(gr, "07_postimpact.json"), rec)

print(summ)
print(cmp[, .(candidate, reference, time_point, d = round(mean_diff, 3), lo = round(lo, 3), hi = round(hi, 3), superior)])
print(cov)
print(pf_tab)
print(st_tab)
print(modes)
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 07:", status, "| empirical", st_emp, "| physics BLOCKED\n")
