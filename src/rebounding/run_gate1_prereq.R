# Assumption checks for a path-departure contact / touch detector, before Gate 1 of the gated rebound roadmap.
#   Rscript src/rebounding/run_gate1_prereq.R
# Needs outputs/cache/rebounding/raw_*.rds, episodes.rds (run_audit.R) and gate0.rds (run_gate0.R).
# Writes outputs/rebounding/gate1_prereq/*.csv.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "gate1_prereq.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "gate1_prereq")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
audited <- readRDS(file.path(cache, "episodes.rds"))
g0 <- readRDS(file.path(cache, "gate0.rds"))$episodes
retained <- g0[retained == TRUE]$shot_id
ep <- audited$episodes
hoops <- audited$hoops

fits <- list(); resid <- list(); gaps <- list(); mids <- list(); reach <- list(); floors <- list()
for (g in matches$id) {
  message("Gate 1 checks: ", g)
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  raw$home_team <- matches$home_team$id[matches$id == g]
  e <- ep[game_id == g & !is.na(f0) & !is.na(f1) & (made %in% TRUE | shot_id %in% retained)]
  for (k in seq_len(nrow(e))) {
    s <- e[k]
    h <- hoops[game_id == g & left_hoop == s$left_hoop]
    hoop <- list(hx = h$hx, hy = h$hy)
    stop_frame <- fcoalesce(s$contact_frame, s$f1) - FLIGHT_STOP
    ff <- flight_fit(raw, s, stop_frame)
    if (!is.null(ff)) { fits[[length(fits) + 1L]] <- ff$row; resid[[length(resid) + 1L]] <- ff$residuals }
    if (s$made) next
    last <- max(s$rf, s$f1)
    gaps[[length(gaps) + 1L]] <- keyframe_gaps(raw, s, s$f0, last, hoop)[, tol := 0.015]
    gaps[[length(gaps) + 1L]] <- keyframe_gaps(raw, s, s$f0, last, hoop, tol = 0.001)[, tol := 0.001]
    mids[[length(mids) + 1L]] <- midpoint_deviation(raw, s, s$f0, last)
    floors[[length(floors) + 1L]] <- floor_minima(raw, s, hoop)
    if (s$grabbed %in% TRUE) reach[[length(reach) + 1L]] <- reach_geometry(raw, s, hoop)
  }
}
fits <- rbindlist(fits); resid <- rbindlist(resid); gaps <- rbindlist(gaps); mids <- rbindlist(mids)
reach <- rbindlist(reach); floors <- rbindlist(floors)
q <- function(v, p = c(0.1, 0.5, 0.9)) setNames(as.list(quantile(v, p, na.rm = TRUE)), paste0("p", 100 * p))

# ---- 1. gravity and horizontal acceleration in free flight (segments of at least 0.4 s) -------------------
long <- fits[span_s >= 0.4]
grav <- rbind(long[, c(list(group = "all", n = .N), q(g_fit), list(ax_median = median(ax_fit), ay_median = median(ay_fit)))],
              long[, c(list(n = .N), q(g_fit), list(ax_median = median(ax_fit), ay_median = median(ay_fit))),
                   by = .(group = fifelse(made, "made", "missed"))],
              long[, c(list(n = .N), q(g_fit), list(ax_median = median(ax_fit), ay_median = median(ay_fit))),
                   by = .(group = fifelse(left_hoop, "camera-left hoop", "camera-right hoop"))])
grav_game <- long[, c(list(n = .N), q(g_fit), list(ax_median = median(ax_fit))), by = .(game_id, left_hoop)][order(game_id, left_hoop)]

# ---- 2. leftover noise of the free-flight fits ------------------------------------------------------------
resid[, rnorm := sqrt(rx^2 + ry^2 + rz^2)]
resid[, band := cut(z, c(-Inf, 8, 12, Inf), labels = c("under 8 ft", "8-12 ft", "over 12 ft"))]
noise <- rbind(
  resid[, .(group = "all", frames = .N, sd_x = sd(rx), sd_y = sd(ry), sd_z = sd(rz), resid_p50 = median(rnorm),
            resid_p90 = quantile(rnorm, 0.9), pred_error_mean = mean(berr), within_pred_error = mean(rnorm <= berr))],
  resid[, .(frames = .N, sd_x = sd(rx), sd_y = sd(ry), sd_z = sd(rz), resid_p50 = median(rnorm),
            resid_p90 = quantile(rnorm, 0.9), pred_error_mean = mean(berr), within_pred_error = mean(rnorm <= berr)),
        by = .(group = as.character(band))])
fixed_g <- long[, .(n = .N, sd_z_free = median(sd_z), sd_z_gravity_fixed = median(sd_z_fixed_g),
                    worse_by_more_than_2x = mean(sd_z_fixed_g > 2 * sd_z))]

# ---- 3. rhythm of measured frames -------------------------------------------------------------------------
# both the audit's 0.015 ft midpoint tolerance and 0.001 ft (see section 4)
gap_tab <- rbind(gaps[, .(where = "all", gap = pmin(gap, 5L), tol)][, .N, by = .(tol, where, gap)],
                 gaps[near_rim == TRUE, .(where = "near the rim", gap = pmin(gap, 5L), tol)][, .N, by = .(tol, where, gap)])
gap_tab[, share := N / sum(N), by = .(tol, where)]
setorder(gap_tab, -tol, where, gap)
parity <- gaps[, .(keys = .N + 1L, one_parity = uniqueN(parity) == 1L, longest_gap = max(gap)), by = .(tol, shot_id)]
rhythm <- parity[, .(windows = .N, windows_one_parity = sum(one_parity), windows_with_gap_over_2 = sum(longest_gap > 2L),
                     longest_gap_frames = max(longest_gap)), by = tol]
grav_span <- fits[span_s > 0, .(n = .N, g_median = median(g_fit), g_iqr = IQR(g_fit), sd_z_median = median(sd_z)),
                  by = .(span_s = cut(span_s, c(0, 0.4, 0.6, 0.8, 1, 2)))][order(span_s)]

# ---- 4. the interpolation test's tolerance ----------------------------------------------------------------
mids[, dev_xz := pmax(dx, dz)]
brk <- c(-Inf, 1e-4, 0.005, 0.015, 0.05, 0.2, Inf)
lab <- c("< 0.0001", "0.0001-0.005", "0.005-0.015", "0.015-0.05", "0.05-0.2", ">= 0.2")
mid_tab <- mids[, .(frames = .N), by = .(deviation_ft = cut(dev_xz, brk, labels = lab))][order(deviation_ft)]
mid_tab[, share := frames / sum(frames)]
mid_y <- mids[dev_xz < 0.015, .(flagged = .N, y_also_midpoint = mean(dy < 0.015), y_dev_p99 = quantile(dy, 0.99))]

# ---- 5. ball to rebounder and the touch rule, raw vs shifted to the player frame --------------------------
reach_sum <- rbind(
  reach[, c(list(quantity = "rebounder-ball at rebound frame, raw ball (ft)"), q(d_raw_rf))],
  reach[, c(list(quantity = "rebounder-ball at rebound frame, shifted ball (ft)"), q(d_cor_rf))],
  reach[, c(list(quantity = "closest rebounder-ball, raw ball (ft)"), q(min_d_raw))],
  reach[, c(list(quantity = "closest rebounder-ball, shifted ball (ft)"), q(min_d_cor))],
  reach[, c(list(quantity = "ball height at that closest approach (ft)"), q(z_at_min))],
  reach[, c(list(quantity = "frames the touch rule moves when the ball is shifted"), q(touch_cor - touch_raw))])
reach_rates <- reach[, .(player_rebounds = .N, closest_within_2.5ft_shifted = mean(min_d_cor <= 2.5, na.rm = TRUE),
                         closest_within_2.5ft_raw = mean(min_d_raw <= 2.5, na.rm = TRUE),
                         closest_p90_shifted = quantile(min_d_cor, 0.9, na.rm = TRUE),
                         closest_ball_above_11ft = mean(z_at_min > 11, na.rm = TRUE),
                         closest_ball_z_p95 = quantile(z_at_min, 0.95, na.rm = TRUE),
                         touch_rule_changes = mean(touch_cor != touch_raw | xor(is.na(touch_cor), is.na(touch_raw)), na.rm = TRUE))]

# ---- 6. floor height ---------------------------------------------------------------------------------------
floor_game <- rbind(floors[, c(list(game_id = NA_integer_, minima = .N), q(z), list(below_zero = mean(z < 0)))],
                    floors[, c(list(minima = .N), q(z), list(below_zero = mean(z < 0))), by = game_id])

fwrite(fits, file.path(out, "flight_fits.csv"))
fwrite(grav, file.path(out, "gravity.csv")); fwrite(grav_game, file.path(out, "gravity_by_game_end.csv"))
fwrite(noise, file.path(out, "flight_noise.csv")); fwrite(fixed_g, file.path(out, "gravity_fixed_fit.csv"))
fwrite(grav_span, file.path(out, "gravity_by_span.csv")); fwrite(gap_tab, file.path(out, "keyframe_gaps.csv")); fwrite(rhythm, file.path(out, "keyframe_rhythm.csv"))
fwrite(mid_tab, file.path(out, "midpoint_deviation.csv")); fwrite(mid_y, file.path(out, "midpoint_y_check.csv"))
fwrite(reach_sum, file.path(out, "reach_geometry.csv")); fwrite(reach_rates, file.path(out, "reach_rates.csv"))
fwrite(floor_game, file.path(out, "floor_minima.csv"))
for (x in list(grav, grav_span, grav_game, noise, fixed_g, gap_tab, rhythm, mid_tab, mid_y, reach_sum, reach_rates, floor_game)) print(x)
