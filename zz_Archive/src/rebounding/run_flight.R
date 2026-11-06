# Step 2 of the rebounding framework: fit and validate the ball-flight models, leave one game out.
#   Rscript src/rebounding/run_flight.R [--refit]
# Each fold is cached in outputs/cache/rebounding/flight_fold_{gameId}.rds, so an interrupted run resumes.
# Writes outputs/rebounding/flight/*.csv and the all-games parameters (flight_params_all.rds, params.json).

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
out_dir <- file.path(report, "flight")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
CONTACT_GRID <- CJ(e_rim_hi = c(0.6, 0.75, 0.9), rim_jitter = c(0.35, 0.6, 1.0), obs_scale = c(0.2, 0.45, 0.8))
CONTACT_SUBSAMPLE <- 100L

checkpoints <- function(b) {
  tm <- bundle_times(b)
  c(release = 0, early = if (is.na(tm$contact) || tm$contact > 0.4) 0.32 else NA,
    contact = if (is.na(tm$contact)) NA else tm$contact - 0.04, after = if (is.na(tm$contact)) NA else tm$contact + 0.2)
}

#' Everything one fold fits on its training games.
fit_flight <- function(train, lib, seed) {
  set.seed(seed)
  kf <- fit_kf_noise(train)
  fl <- fit_floor(train)
  base <- phys_par(z_floor = fl$z_floor, e_floor = fl$e_floor, mu_floor = fl$mu_floor, sigma_a = sqrt(kf$q))
  with_c <- Filter(function(b) !is.na(bundle_times(b)$contact), train)
  sub <- with_c[sample(length(with_c), min(CONTACT_SUBSAMPLE, length(with_c)))]
  # Contact parameters and the observation scale together, by the multi-step predictive score of post-contact
  # keyframes. The scale is not the Kalman one: one-step likelihood on the smoothed track drives it to its
  # floor, which left every multi-step forecast overconfident in the first build.
  grid <- copy(CONTACT_GRID)
  grid[, score := mapply(function(e, j, s) contact_score(sub, modifyList(base, list(e_rim_hi = e, e_rim_lo = max(0.05, e - 0.35),
                                                                                     rim_jitter = j)), c(s, s), lib),
                         e_rim_hi, rim_jitter, obs_scale)]
  best <- grid[which.max(score)]
  sig <- c(best$obs_scale, best$obs_scale)
  phys <- modifyList(base, list(e_rim_hi = best$e_rim_hi, e_rim_lo = max(0.05, best$e_rim_hi - 0.35), rim_jitter = best$rim_jitter))
  # spread of the two simple forecasts, by horizon and axis, from training residuals
  res <- rbindlist(lapply(sample(train, min(300L, length(train))), function(b) {
    tm <- bundle_times(b)
    rbindlist(lapply(na.omit(checkpoints(b)[-1]), function(t0) {
      tg <- targets_for(b, t0, tm)
      if (!nrow(tg)) return(NULL)
      g <- gaussian_forecasts(b, t0, tg$t - t0, kf)
      rbindlist(lapply(c("cv", "ballistic"), function(mod) if (!is.null(g[[mod]]))
        rbindlist(Map(function(f, k) data.table(model = mod, horizon = tg$h[k], ex = f$m[1] - tg$x[k], ey = f$m[2] - tg$y[k],
                                                ez = f$m[3] - tg$z[k]), g[[mod]], seq_len(nrow(tg))))))
    }))
  }))
  spread <- res[, .(sx = sqrt(mean(ex^2)), sy = sqrt(mean(ey^2)), sz = sqrt(mean(ez^2))), by = .(model, horizon)]
  list(kf = kf, floor = fl, sig = sig, phys = phys, grid = grid, spread = spread, contact_lib = contact_library(train, kf))
}

#' Score every model at every checkpoint of the held-out games.
score_flight <- function(test, fit, lib) {
  R <- c(fit$sig[1]^2, fit$sig[1]^2, fit$sig[2]^2)
  free <- modifyList(fit$phys, list(contacts = 0L))
  rbindlist(lapply(seq_along(test), function(i) {
    b <- test[[i]]
    tm <- bundle_times(b)
    cps <- checkpoints(b)
    rbindlist(lapply(names(cps)[!is.na(cps)], function(cp) {
      t0 <- cps[[cp]]
      tg <- targets_for(b, t0, tm)
      if (!nrow(tg)) return(NULL)
      clouds <- list()
      st <- pf_at(b, t0, fit$phys, fit$sig, lib, seed = i)
      fp <- forecast_paths(st$S, tg$t - t0, fit$phys, seed = 5000L + i)
      clouds$particle_contact <- lapply(seq_len(nrow(tg)), function(k) cbind(fp$x[, k], fp$y[, k], fp$z[, k]))
      st0 <- pf_at(b, t0, free, fit$sig, lib, seed = i)
      fp0 <- forecast_paths(st0$S, tg$t - t0, free, seed = 5000L + i)
      clouds$particle_no_contact <- lapply(seq_len(nrow(tg)), function(k) cbind(fp0$x[, k], fp0$y[, k], fp0$z[, k]))
      if (cp == "contact") {
        S <- empirical_contact_particles(b, t0, fit$kf, fit$contact_lib, seed = i)
        if (!is.null(S)) {
          fe <- forecast_paths(S, tg$t - t0, free, seed = 7000L + i, miss = FALSE)
          clouds$empirical_bounce <- lapply(seq_len(nrow(tg)), function(k) cbind(fe$x[, k], fe$y[, k], fe$z[, k]))
        }
      }
      if (cp != "release") {
        g <- gaussian_forecasts(b, t0, tg$t - t0, fit$kf, fit$spread)
        for (mod in names(g)) clouds[[mod]] <- lapply(g[[mod]], gauss_cloud)
      }
      rbindlist(lapply(names(clouds), function(mod) rbindlist(lapply(seq_len(nrow(tg)), function(k) {
        sc <- score_cloud(clouds[[mod]][[k]], c(tg$x[k], tg$y[k], tg$z[k]), R)
        if (is.null(sc)) return(NULL)
        as.data.table(as.list(sc))[, `:=`(model = mod, checkpoint = cp, horizon = tg$h[k], shot_id = b$id, game_id = b$game_id)]
      }))))
    }))
  }), fill = TRUE)
}

#' Untouched floor landings: forecast first floor contact against bounces nobody was near (within 4 ft).
score_landing <- function(test, fit, lib) {
  free <- modifyList(fit$phys, list(contacts = 0L))
  R <- c(fit$sig[1]^2, fit$sig[1]^2, 1)
  rbindlist(lapply(seq_along(test), function(i) {
    b <- test[[i]]
    s <- b$shot
    tm <- bundle_times(b)
    if (is.na(tm$bounce) || is.na(s$bounce_near) || s$bounce_near <= 4 || (!is.na(tm$control) && tm$control < tm$bounce))
      return(NULL)
    y <- c(s$bounce_x - b$hoop$hx, s$bounce_y - b$hoop$hy, 0)
    cps <- checkpoints(b)
    rbindlist(lapply(c("release", "contact", "after"), function(cp) {
      t0 <- cps[[cp]]
      if (is.na(t0) || t0 > tm$bounce - 0.12) return(NULL)
      st <- pf_at(b, t0, fit$phys, fit$sig, lib, seed = i)
      L <- first_landing(st$S, 5, fit$phys, 9000L + i)
      L <- L[L[, 4] == 0 & !is.na(L[, 1]), , drop = FALSE]
      out <- list()
      if (nrow(L) >= 20L) out$particle_contact <- L
      if (cp == "contact") {
        S <- empirical_contact_particles(b, t0, fit$kf, fit$contact_lib, seed = i)
        if (!is.null(S)) {
          L2 <- first_landing(S, 5, free, 9500L + i)
          L2 <- L2[!is.na(L2[, 1]), , drop = FALSE]
          if (nrow(L2) >= 20L) out$empirical_bounce <- L2
        }
      }
      rbindlist(lapply(names(out), function(mod) {
        L <- out[[mod]]
        sc <- score_cloud(cbind(L[, 2], L[, 3], 0), y, R)
        if (is.null(sc)) return(NULL)
        sc[["logscore"]] <- sc[["logscore"]] - dnorm(0, 0, 1, log = TRUE)
        as.data.table(as.list(sc))[, `:=`(model = mod, checkpoint = cp, time_err = median(L[, 1]) - (tm$bounce - t0),
                                          out_share = mean(abs(L[, 3]) > COURT_HALF_W | L[, 2] > COURT_HALF_L - RIM_X),
                                          shot_id = b$id, game_id = b$game_id)]
      }))
    }))
  }), fill = TRUE)
}

only <- sub("^--game=", "", grep("^--game=", args, value = TRUE))
for (g in if (length(only)) as.integer(only) else games) {
  path <- file.path(cache, sprintf("flight_fold_%s.rds", g))
  if (file.exists(path) && !"--refit" %in% args) next
  t_start <- Sys.time()
  train <- bundles[bundle_game != g]
  test <- bundles[bundle_game == g]
  lib <- launch_rows_all[game_id != g]
  fit <- fit_flight(train, lib, seed = g)
  scores <- score_flight(test, fit, lib)
  landing <- score_landing(test, fit, lib)
  saveRDS(list(fit = fit, scores = scores, landing = landing), path)
  message(sprintf("Flight fold %s: %d scores, %.0f s", g, nrow(scores), as.numeric(difftime(Sys.time(), t_start, units = "secs"))))
}

if (length(only)) quit(save = "no")
folds <- lapply(games, function(g) readRDS(file.path(cache, sprintf("flight_fold_%s.rds", g))))
scores <- rbindlist(lapply(folds, `[[`, "scores"), fill = TRUE)
landing <- rbindlist(lapply(folds, `[[`, "landing"), fill = TRUE)
summ <- scores[, .(n = .N, logscore = mean(logscore), err_ft = mean(err), err_xy_ft = mean(err_xy), cover50 = mean(cover50),
                   cover80 = mean(cover80), cover90 = mean(cover90), radius90_ft = mean(radius90)), by = .(checkpoint, horizon, model)]
setorder(summ, checkpoint, horizon, -logscore)
fwrite(summ, file.path(out_dir, "validation_summary.csv"))
fwrite(scores[, .(logscore = mean(logscore), err_ft = mean(err), n = .N), by = .(game_id, checkpoint, model)],
       file.path(out_dir, "validation_by_game.csv"))
fwrite(landing[, .(n = .N, logscore = mean(logscore), err_xy_ft = mean(err_xy), cover50 = mean(cover50), cover80 = mean(cover80),
                   cover90 = mean(cover90), radius90_ft = mean(radius90), time_err_s = mean(time_err), out_share = mean(out_share)),
               by = .(checkpoint, model)], file.path(out_dir, "landing_validation.csv"))
fwrite(rbindlist(lapply(seq_along(folds), function(k) {
  f <- folds[[k]]$fit
  data.table(game_id = games[k], q = f$kf$q, sig_xy = f$sig[1], sig_z = f$sig[2], z_floor = f$floor$z_floor,
             e_floor = f$floor$e_floor, mu_floor = f$floor$mu_floor, n_bounces = f$floor$n_bounces,
             e_rim_hi = f$phys$e_rim_hi, rim_jitter = f$phys$rim_jitter, contact_lib = nrow(f$contact_lib))
})), file.path(out_dir, "fold_parameters.csv"))
fwrite(rbindlist(lapply(seq_along(folds), function(k) folds[[k]]$fit$grid[, game_id := games[k]])),
       file.path(out_dir, "contact_grid.csv"))

all_path <- file.path(cache, "flight_params_all.rds")
if (!file.exists(all_path) || "--refit" %in% args) saveRDS(fit_flight(bundles, launch_rows_all, seed = 1L), all_path)
all <- readRDS(all_path)
jsonlite::write_json(list(kalman = all$kf, floor = all$floor, observation_scale = all$sig,
                          physics = all$phys[setdiff(names(all$phys), "contacts")], contact_grid = all$grid),
                     file.path(out_dir, "params.json"), auto_unbox = TRUE, digits = 6, pretty = TRUE)
print(summ)
