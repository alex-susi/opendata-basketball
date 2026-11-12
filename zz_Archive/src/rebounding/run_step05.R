## ═════════════════════════════════════════════════════════════════════════════
# Step 05 of the rebounding manual: a release-time spatial distribution of where rebounds are credited, judged with
# Step 03's frozen folds and rules. Target: the credited rebounder's position (Step 02 BLOCKED, so no first-contact
# location); it is not the ball's free landing point.
#   Rscript src/rebounding/run_step05.R
# Needs the Step 01 table, the Step 03 outputs, outputs/cache/rebounding/step03_features.rds and raw_*.rds. Settings:
# config/experiment.yaml (step05, fixed before any fit). Writes outputs/rebounding/step05/ (targets, per-episode
# scores, coverage, comparisons, selection, figures), reports/05_spatial_prior.md, gate_results/05_spatial.json,
# 05_tests.csv, and the full cell maps to outputs/cache/rebounding/step05_spatial_prior.rds (git-ignored).
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "step00.R", "folds.R", "metrics.R", "spatial_prior.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th3 <- cfg$step03
th <- cfg$step05
cache <- file.path(root, "outputs", "cache", "rebounding")
s3 <- file.path(root, "outputs", "rebounding", "step03")
out <- file.path(root, "outputs", "rebounding", "step05")
reports <- file.path(root, "outputs", "rebounding", "reports")
gr <- file.path(root, "outputs", "rebounding", "gate_results")
dir.create(file.path(out, "figures"), recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))

fz <- jsonlite::fromJSON(file.path(s3, "design_freeze.json"))
freeze_ok <- c(config = identical(fz$step03_config_sha256, paste(openssl::sha256(yaml::as.yaml(th3)))),
               code = all(vapply(names(fz$code_sha256), function(f) identical(fz$code_sha256[[f]], sha256_file(file.path(here, "R", f))), NA)))
if (!all(freeze_ok)) stop("Step 03's design changed since it was frozen: ", paste(names(freeze_ok)[!freeze_ok], collapse = ", "))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - TARGETS AND RELEASE INPUTS ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

el <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))[eligible == TRUE]
fa <- fread(file.path(s3, "fold_assignment.csv"))
grid <- spatial_grid(th$domain)
rel <- readRDS(file.path(cache, "step03_features.rds"))$features[time_point == "release"]
sp <- merge(rel[, .(episode_id, pid, sy = y)], el[, .(episode_id, pid = shooter_id)], by = c("episode_id", "pid"))
if (nrow(sp) != nrow(el)) stop("a shooter is missing at release")
episodes <- merge(el[, .(episode_id, game_id, shot_range)], sp[, .(episode_id, side = shot_side(sy))], by = "episode_id")
tg <- rbindlist(lapply(matches$id, function(g) {
  r <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  e <- el[game_id == g]
  rb <- r$rebounds[match(e$rebound_event_id, r$rebounds$reb_id)]
  tr <- r$players[data.table(frame = e$rebound_frame, pid = e$rebounder_id), on = .(frame, pid)]
  data.table(episode_id = e$episode_id, rebounded = e$rebounded, ex = -rb$rx_cam, ey = -rb$ry_cam,
             trx = tr$x * e$flip, try = tr$y * e$flip)
}))
tg[, source := fifelse(!rebounded, "team award (no location)", fifelse(!is.na(ex), "rebounds.location",
                                                                       fifelse(!is.na(trx), "tracked rebounder (fallback)", "missing")))]
tg[, `:=`(tx = fifelse(source == "rebounds.location", ex, trx), ty = fifelse(source == "rebounds.location", ey, try))]
tg[rebounded == FALSE, c("tx", "ty") := NA_real_]
tg[, cell := cell_index(grid, tx, ty)]
tg <- merge(tg, episodes, by = "episode_id")
fwrite(tg[, .(episode_id, game_id, rebounded, source, tx = round(tx, 4), ty = round(ty, 4), cell, shot_range, side,
              location_vs_tracked_ft = round(sqrt((ex - trx)^2 + (ey - try)^2), 4))], file.path(out, "spatial_targets.csv"))
targets <- tg[!is.na(cell), .(episode_id, tx, ty, cell, shot_range, side)]





## ═════════════════════════════════════════════════════════════════════════════
## 02 - OUT-OF-FOLD MAPS -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

message("Step 05: fitting")
r <- spatial_fold_predictions(grid, episodes[, .(episode_id, shot_range, side)], targets, fa, th)
sc <- merge(r$scores, fa[, .(episode_id, game_id)], by = "episode_id")
sc[, `:=`(time_point = "release", model_version = th$model_version)]
levels <- unlist(th$scores$coverage_levels)
for (L in levels) set(sc, j = paste0("in_", L), value = sc$u <= L + 1e-12)
fwrite(sc, file.path(out, "spatial_oof.csv.gz"))
fwrite(r$selection, file.path(out, "selection.csv"))
saveRDS(list(grid = grid, maps = r$maps, selection = r$selection, model_version = th$model_version),
        file.path(cache, "step05_spatial_prior.rds"))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - COVERAGE, SCORES AND COMPARISONS ---------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Coverage of each prediction region (a Wilson interval on the share of targets inside it), by any grouping.
cov_tab <- function(d, by) rbindlist(lapply(levels, function(L) d[, {
  k <- sum(get(paste0("in_", L)))
  w <- wilson(k, .N)
  .(level = L, n = .N, coverage = k / .N, lo = w[["lo"]], hi = w[["hi"]], mean_area = mean(get(paste0("area_", L))))
}, by = by]))
cov <- cov_tab(sc, "model")
cov[, within_tol := abs(coverage - level) <= th$decision$coverage_tolerance]
fwrite(cov, file.path(out, "coverage.csv"))
# Coverage by shot range and by game, with the quality and fallback flags for the subsets below.
sc <- merge(sc, el[, .(episode_id, identity_suspect, low_quality = ball_keyframe <= quantile(ball_keyframe, 0.25) |
                         player_detected <= quantile(player_detected, 0.25))], by = "episode_id")
sc <- merge(sc, tg[, .(episode_id, fallback = source == "tracked rebounder (fallback)", shot_range)], by = "episode_id")
cov_range <- cov_tab(sc, c("model", "shot_range"))
fwrite(cov_range, file.path(out, "coverage_by_shot_range.csv"))
cov_game <- cov_tab(sc, c("model", "game_id"))
fwrite(cov_game, file.path(out, "coverage_by_game.csv"))
summ <- sc[, .(episodes = .N, nll = mean(nll), area_50 = mean(area_0.5), area_80 = mean(area_0.8), area_95 = mean(area_0.95)), by = model]
cw <- dcast(cov, model ~ level, value.var = "coverage")
setnames(cw, c("model", paste0("coverage_", levels)))
summ <- merge(summ, cw, by = "model")
summ <- summ[order(nll)]
fwrite(summ, file.path(out, "scores_summary.csv"))
sub <- rbind(sc[, .(subgroup = paste("shot range:", shot_range), episodes = .N, nll = mean(nll), coverage_80 = mean(in_0.8)), by = .(model, shot_range)][, shot_range := NULL],
             sc[low_quality == TRUE, .(subgroup = "low tracking quality", episodes = .N, nll = mean(nll), coverage_80 = mean(in_0.8)), by = model],
             sc[identity_suspect == TRUE, .(subgroup = "identity_suspect", episodes = .N, nll = mean(nll), coverage_80 = mean(in_0.8)), by = model],
             sc[fallback == TRUE, .(subgroup = "location from tracking (fallback)", episodes = .N, nll = mean(nll), coverage_80 = mean(in_0.8)), by = model])
fwrite(sub[order(subgroup, nll)], file.path(out, "by_subgroup.csv"))
u <- th3$uncertainty
pc <- function(a, b) paired_comparison(sc, a, b, "release", "nll", u$bootstrap_reps, u$seed, u$level)
pairs <- list(c("pooled_kde", "uniform"), c("side_range_kde", "pooled_kde"), c("range_kde", "pooled_kde"),
              c("zone_bins", "pooled_kde"), c("side_range_kde", "range_kde"))
cmp <- lapply(pairs, function(p) pc(p[1], p[2]))
cmp_sum <- rbindlist(lapply(cmp, `[[`, "summary"))
cmp_sum[, `:=`(superior = hi < 0 & drop_one_max < 0,
               confirmatory = paste(candidate, reference) %in% c("pooled_kde uniform", "side_range_kde pooled_kde"))]
fwrite(cmp_sum, file.path(out, "paired_comparisons.csv"))
fwrite(rbindlist(lapply(cmp, `[[`, "by_game")), file.path(out, "paired_by_game.csv"))
cov_ok <- function(m) all(cov[model == m]$within_tol)
pooled_pass <- cmp_sum[candidate == "pooled_kde" & reference == "uniform"]$superior && cov_ok("pooled_kde")
cand_pass <- cmp_sum[candidate == "side_range_kde" & reference == "pooled_kde"]$superior && cov_ok("side_range_kde")





## ═════════════════════════════════════════════════════════════════════════════
## 04 - CHECKS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ck <- list()
addc <- function(check, value, expected, pass) ck[[length(ck) + 1L]] <<- data.table(check = check, value = as.character(value),
                                                                                    expected = as.character(expected), pass = pass)
addc("Step 03 design freeze in force", all(freeze_ok), TRUE, all(freeze_ok))
sums <- unlist(lapply(r$maps, function(ml) vapply(ml, sum, 0)))
mins <- unlist(lapply(r$maps, function(ml) vapply(ml, min, 0)))
addc("every map sums to 1 over the domain (largest error)", signif(max(abs(sums - 1)), 3), "< 1e-9", max(abs(sums - 1)) < 1e-9)
addc("every map is positive and finite", sum(mins > 0 & is.finite(mins)), length(mins), all(mins > 0 & is.finite(mins)))
addc("maps exist for every eligible episode and model", length(sums), nrow(el) * length(SPATIAL_MODELS), length(sums) == nrow(el) * length(SPATIAL_MODELS))
addc("grid cell area (sq ft)", grid$area, 1, grid$area == 1)
addc("every player rebound has a location inside the domain", nrow(targets), sum(el$rebounded), nrow(targets) == sum(el$rebounded))
gap_med <- median(sqrt((tg$ex - tg$trx)^2 + (tg$ey - tg$try)^2), na.rm = TRUE)
addc("rebounds.location agrees with the tracked rebounder (median gap, ft)", round(gap_med, 4), "< 0.5", gap_med < 0.5)
ntr <- r$selection[, .(n_train = n_train[1]), by = outer_fold]
ntr[, expected := vapply(outer_fold, function(k) nrow(targets[episode_id %in% fa[outer_fold != k]$episode_id]), 0L)]
addc("each fold's maps are fitted on exactly its training games' locations", sum(ntr$n_train == ntr$expected), nrow(ntr), all(ntr$n_train == ntr$expected))
addc("one bandwidth and two weights chosen per fold, from the configured grids",
     r$selection[chosen == TRUE, .N, by = outer_fold][, all(N == 3L)], TRUE, r$selection[chosen == TRUE, .N, by = outer_fold][, all(N == 3L)])
message("Step 05: invariance and reproducibility reruns")
g1 <- fa[outer_fold == 1L]$game_id[1]
moved <- copy(targets)[episode_id %in% fa[game_id == g1]$episode_id, `:=`(tx = 5, ty = 20)][, cell := cell_index(grid, tx, ty)]
r2 <- spatial_fold_predictions(grid, episodes[, .(episode_id, shot_range, side)], moved, fa, th)
ids1 <- fa[outer_fold == 1L]$episode_id
inv <- all(vapply(SPATIAL_MODELS, function(m) isTRUE(all.equal(r2$maps[[m]][ids1], r$maps[[m]][ids1], tolerance = 0)), NA))
addc("held-out locations never reach their own maps (fold 1's locations moved: its maps unchanged)", inv, TRUE, inv)
r3 <- spatial_fold_predictions(grid, episodes[, .(episode_id, shot_range, side)], targets, fa, th)
same <- isTRUE(all.equal(r3$scores, r$scores, tolerance = 0))
addc("re-running reproduces every score exactly", same, TRUE, same)
checks <- rbindlist(ck)
fwrite(checks, file.path(out, "checks.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - FIGURES ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# All ten games, display only (settings most often chosen in the folds)

mode_of <- function(s) r$selection[chosen == TRUE & setting == s, .N, by = value][order(-N, value)]$value[1]
fit_all <- fit_spatial(grid, targets, mode_of("bandwidth"), mode_of("w_range"), mode_of("w_side"), th)
ranges <- c("rim (<5 ft)", "midrange (other 2s)", "three")
zmax <- max(predict_spatial(fit_all, "side_range_kde", ranges[1], 1L)) * 0.8
png(file.path(out, "figures", "05_heatmaps_all_games.png"), width = 1800, height = 1050, res = 130)
par(mfrow = c(2, 3), mar = c(0.5, 0.5, 2.5, 0.5))
draw_map(predict_spatial(fit_all, "pooled_kde", ranges[1], 1L), grid, sprintf("pooled (h = %g ft), all shots", fit_all$h), zmax = zmax)
draw_map(predict_spatial(fit_all, "zone_bins", ranges[1], 1L), grid, "zone bins", zmax = zmax)
plot.new()
text(0.5, 0.5, paste("Credited rebound location, not where\nthe ball would land untouched.\nShots from the y >= 0 side",
                     "(top);\nlines: 50 / 80 / 95% regions.\nHoop at right."), cex = 1)
for (rg in ranges) draw_map(predict_spatial(fit_all, "side_range_kde", rg, 1L), grid,
                            sprintf("side and range (w = %g): %s", fit_all$w_side, rg), zmax = zmax)
dev.off()
set.seed(u$seed)
ex <- sc[model == "side_range_kde"][, .SD[sample(.N, 2)], by = shot_range]
png(file.path(out, "figures", "05_heldout_examples.png"), width = 1800, height = 1050, res = 130)
par(mfrow = c(2, 3), mar = c(0.5, 0.5, 2.5, 0.5))
for (i in seq_len(nrow(ex))) {
  e <- ex[i]
  t1 <- targets[episode_id == e$episode_id]
  sh <- rel[episode_id == e$episode_id & pid == el[episode_id == e$episode_id]$shooter_id]
  draw_map(r$maps$side_range_kde[[e$episode_id]], grid, sprintf("%s (held out)\n%s, nll %.2f, u %.2f", e$episode_id, e$shot_range, e$nll, e$u))
  points(sh$x, sh$y, pch = 17, col = "darkorange3", cex = 1.4)
  points(t1$tx, t1$ty, pch = 4, col = "red", cex = 1.8, lwd = 2.5)
}
dev.off()





## ═════════════════════════════════════════════════════════════════════════════
## 06 - REPORT -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

md_table <- function(d, digits = 3) {
  d <- copy(d)
  for (c in names(d)) if (is.numeric(d[[c]]) && !is.integer(d[[c]])) set(d, j = c, value = formatC(d[[c]], digits = digits, format = "f"))
  c(paste("|", paste(names(d), collapse = " | "), "|"), paste("|", paste(rep("---", ncol(d)), collapse = " | "), "|"),
    apply(d, 1, function(r) paste("|", paste(r, collapse = " | "), "|")))
}
st_cand <- if (cand_pass) "PASS" else "BLOCKED"
st_pool <- if (pooled_pass) "PASS" else "BLOCKED"
src_tab <- tg[, .N, by = source]
sel_tab <- r$selection[chosen == TRUE, .N, by = .(setting, value)][order(setting, value)]
# The step's markdown report.
lines <- c("# Step 05: release-time spatial prior of credited rebound locations",
           "",
           sprintf("Run %s by `src/rebounding/run_step05.R`; settings `config/experiment.yaml` (`step05`, config v%d), fixed before any fit;",
                   format(Sys.Date()), cfg$config_version),
           "folds and decision rules are Step 03's frozen harness.",
           "",
           "**Target.** The credited rebounder's position at the rebound frame (`rebounds.location` turned into the attack frame).",
           "It is **not** where the ball would land if nobody touched it, and not the first contact (Step 02 BLOCKED). Floor",
           "location only: ball height and time to access are not modelled.",
           "", md_table(src_tab), "",
           sprintf("Domain: the attacked half court, %d x %d cells of 1 sq ft. Inputs at release: shot range and the side the shot", grid$nx, grid$ny),
           "comes from. The realised location is used only as a training target and a score.",
           "",
           "## Models",
           "",
           "- **uniform**: every cell equal. **zone bins**: distance rings x 6 angle sectors around the hoop, smoothed shares.",
           "- **pooled kernel**: Gaussian kernel density of the training locations (bandwidth by inner leave-one-game-out),",
           sprintf("  renormalised over the half court, mixed with the uniform at %.0f%%.", 100 * th$epsilon_uniform),
           "- **range kernel**: pooled shrunk toward the shot range's own density (weight by inner leave-one-game-out).",
           "- **side and range kernel** (confirmatory candidate): as range, with every training shot mirrored to come from the",
           "  same side, and the map mirrored back for a test shot from the other side.",
           "", "Settings chosen in the folds:", "", md_table(sel_tab), "",
           "## Held-out scores (630 credited locations, 10 games)", "",
           "Negative log density per sq ft (lower is better); coverage of the 50 / 80 / 95% highest-density regions; mean area.",
           "", md_table(summ, 3), "",
           "## Decisions", "",
           md_table(cmp_sum[, .(candidate, reference, mean_diff, lo, hi, games_better, drop_one_max, superior, confirmatory)], 4), "",
           sprintf("- Pooled kernel as the baseline (superior to uniform, coverage within %.2f): **%s**.", th$decision$coverage_tolerance, st_pool),
           sprintf("- Side and range kernel (superior to pooled, coverage within %.2f): **%s**.", th$decision$coverage_tolerance, st_cand),
           sprintf(paste("- Zone bins (exploratory, the broad training-only prior the manual's hard-stop table falls back to when the",
                         "kernel prior is poorly calibrated): coverage within %.2f at every level: %s. Adopting it would be a",
                         "deviation from the prespecified baseline and needs an owner decision."),
                   th$decision$coverage_tolerance, if (cov_ok("zone_bins")) "yes" else "no"),
           "", "Coverage with Wilson 95% intervals:", "", md_table(cov[, .(model, level, n, coverage, lo, hi, mean_area, within_tol)], 3), "",
           "By shot range and game: `coverage_by_shot_range.csv`, `coverage_by_game.csv`. Subgroups:", "",
           md_table(sub[model %in% c("pooled_kde", "side_range_kde")][order(subgroup, model)], 3), "",
           sprintf("Team awards (%d) have no location and are outside this target. Clean catches and tip chains cannot be separated", sum(!el$rebounded)),
           "(Step 02 BLOCKED).",
           "",
           "## Figures", "",
           "- `step05/figures/05_heatmaps_all_games.png`: maps fitted on all ten games (display only).",
           "- `step05/figures/05_heldout_examples.png`: six held-out misses with their out-of-fold map, shooter (triangle) and",
           "  credited location (cross).",
           "", "## Checks", "", md_table(checks), "",
           "## Limits", "",
           "- The target is where the rebound was credited, which already reflects who reached the ball; it is not a ball",
           "  landing distribution and must not be read as one.",
           "- Ten games; 630 locations. Shot angle enters only as its side; shot distance only as the three ranges.")
writeLines(lines, file.path(reports, "05_spatial_prior.md"))





## ═════════════════════════════════════════════════════════════════════════════
## 07 - GATE RECORD ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

tests <- rbind(run_tests(here, root, "unit", "spatial_prior"), run_tests(here, root, "gates", "step_05"), fill = TRUE)
fwrite(tests, file.path(gr, "05_tests.csv"))
tests_ok <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
harness_ok <- all(checks$pass) && tests_ok
status <- if (!harness_ok) "BLOCKED" else if (cand_pass) "PASS" else if (pooled_pass) "PASS_BASELINE" else "BLOCKED"
# The gate record.
rec <- list(step = "05", status = status,
            scope = sprintf("release-time 2D map of the credited rebound location (%d player rebounds; team awards outside the target)", nrow(targets)),
            components = list(side_range_kde = st_cand, pooled_kde = st_pool, range_kde = "exploratory", zone_bins = "exploratory"),
            source_commits = list(skillcorner = cfg$dataset$upstream_commit, TrueImpactShotCharts = "ideas only (MIT), no code copied"),
            data_revision = list(upstream = cfg$dataset$upstream_commit, step03_freeze = fz$frozen_at),
            model_revision = list(model_version = th$model_version, step05_config_sha256 = paste(openssl::sha256(yaml::as.yaml(th))),
                                  code_sha256 = sha256_file(file.path(here, "R", "spatial_prior.R")),
                                  scores_sha256 = sha256_file(file.path(out, "spatial_oof.csv.gz"))),
            repository_head = git_out(root, "rev-parse", "HEAD")[1],
            test_command = "Rscript src/rebounding/run_tests.R unit spatial_prior; Rscript src/rebounding/run_tests.R gates step_05",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = all(checks$pass),
            heldout_metrics_file = "outputs/rebounding/step05/scores_summary.csv",
            acceptance_criteria_version = sprintf("manual %s, config v%d (step05 fixed before any fit; step03 rules)", cfg$manual_revision, cfg$config_version),
            comparisons = cmp_sum[, .(candidate, reference, mean_diff = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4),
                                      drop_one_max = round(drop_one_max, 4), superior, confirmatory)],
            coverage = cov[model %in% c("pooled_kde", "side_range_kde"), .(model, level, coverage = round(coverage, 4), within_tol)],
            evidence = c("outputs/rebounding/step05/", "outputs/rebounding/reports/05_spatial_prior.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("Target is the credited location, not the ball's free landing point", "Ten games, 630 locations",
                              "Team awards have no location"),
            fallback = list(rule = "manual hard stop: spatial prior poorly calibrated -> broad train-only prior, no high-precision landing zones",
                            zone_bins_coverage_within_tolerance = cov_ok("zone_bins"), adopted = FALSE,
                            note = "zone_bins was exploratory, not the prespecified baseline; adopting it needs an owner decision"),
            decision_note = sprintf("Pooled kernel %s; side and range kernel %s.", st_pool, st_cand))
write_gate(file.path(gr, "05_spatial.json"), rec)

print(summ)
print(cmp_sum[, .(candidate, reference, d = round(mean_diff, 4), lo = round(lo, 4), hi = round(hi, 4), drop1 = round(drop_one_max, 4), superior)])
print(cov[model %in% c("pooled_kde", "side_range_kde", "range_kde")])
print(sel_tab)
print(checks[, .(check = substr(check, 1, 80), value, pass)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
cat("STEP 05:", status, "| pooled", st_pool, "| side and range", st_cand, "\n")
