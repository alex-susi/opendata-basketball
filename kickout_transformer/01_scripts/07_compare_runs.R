## ═════════════════════════════════════════════════════════════════════════════
# Step 7: did a change help? Compare the current run with a saved earlier run, catch by catch.
#   Rscript kickout_transformer/01_scripts/07_compare_runs.R --drop-other [--before=3class_before_time_to_act]
#
# --before names a folder under kickout_transformer/02_cache/ (and the matching folder under
# kickout_transformer/03_outputs/) holding an earlier run's
# predictions and its own catches.rds. Catches are matched on pass_id, so the comparison is always on the same plays.
# Every difference is paired (the same catch scored twice) with a 95% interval from resampling whole games.
#
# Subsets reported:
#   all catches, strict kickouts
#   clock changed     catches whose clock input changed (time to act differs from the filled-in shot clock)
#   under 24 s left   catches with less than 24 s on the game clock
# Also lists the earlier run's film-study plays with both runs' predictions.
#
# Writes kickout_transformer/03_outputs/<run>/compare_<before>.csv and compare_<before>_film_plays.csv.
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
# The earlier run to compare with: a folder name under kickout_transformer/02_cache/ and 03_outputs/.
hit <- grep("^--before=", commandArgs(TRUE), value = TRUE)
BEFORE <- if (length(hit)) sub("^--before=", "", hit) else "3class_before_time_to_act"
before_cache <- file.path(root, "kickout_transformer", "02_cache", BEFORE)
before_out <- file.path(root, "kickout_transformer", "03_outputs", BEFORE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - BOTH RUNS' PREDICTIONS -------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' All held-out predictions of one run, keyed by pass_id.
load_run <- function(cache_dir, catches_path) {
  meta <- readRDS(catches_path)$meta
  if (DROP_OTHER) meta <- meta[label != "other"][, row := .I]
  tf <- list.files(cache_dir, "^tf_(freeze|hist)_[0-9]+\\.rds$", full.names = TRUE)
  pred <- rbind(readRDS(file.path(cache_dir, "pred_baselines.rds")), rbindlist(lapply(tf, function(f) readRDS(f)$pred)))
  pred[meta, on = "row", `:=`(pass_id = i.pass_id, label = i.label)]
  pred[, logloss := row_logloss(as.matrix(.SD), label), .SDcols = PROB_COLS]
  pred
}
before <- load_run(before_cache, file.path(before_cache, "catches.rds"))
after <- load_run(paths$cache, file.path(paths$base_cache, "catches.rds"))
meta <- kt_load_catches(paths)$meta

# Pair each catch's prediction across the two runs and flag catches whose clock input changed.
both <- merge(before[, c("pass_id", "model", "logloss", PROB_COLS), with = FALSE],
              after[, c("pass_id", "model", "logloss", PROB_COLS), with = FALSE],
              by = c("pass_id", "model"), suffixes = c("_before", "_after"))
both[meta, on = "pass_id", `:=`(game_id = i.game_id, kickout = i.kickout, label = i.label,
                                clock_changed = abs(i.time_to_act - i.shot_clock) > 0.01, late = i.game_clock < 24)]
stopifnot(both[, .N, by = model][, all(N == nrow(meta))])





## ═════════════════════════════════════════════════════════════════════════════
## 02 - LOG LOSS BEFORE AND AFTER ----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Paired change in log loss per subset and model, with a game-bootstrap interval.
subsets <- list(`all catches` = quote(rep(TRUE, .N)), `strict kickouts` = quote(kickout == TRUE),
                `clock changed` = quote(clock_changed == TRUE), `under 24 s left` = quote(late == TRUE))
tab <- rbindlist(lapply(names(subsets), function(s) {
  both[eval(subsets[[s]]), {
    ci <- game_bootstrap(logloss_after - logloss_before, game_id)
    .(subset = s, n = .N, before = mean(logloss_before), after = mean(logloss_after),
      change = ci[["mean"]], lo = ci[["lo"]], hi = ci[["hi"]])
  }, by = model]
}))
tab <- tab[model %in% c("logistic", "transformer_freeze", "transformer_hist")]
fwrite(tab, file.path(paths$out, sprintf("compare_%s.csv", BEFORE)))
cat(sprintf("Log loss before vs after (%s -> current); change < 0 means the change helped:\n", BEFORE))
print(tab[, .(subset, model, n, before = round(before, 3), after = round(after, 3), change = round(change, 3),
              lo = round(lo, 3), hi = round(hi, 3))])





## ═════════════════════════════════════════════════════════════════════════════
## 03 - THE EARLIER FILM-STUDY PLAYS -------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

film_path <- file.path(before_out, "film_study_plays.csv")
if (file.exists(film_path)) {
  film <- fread(film_path)
  pct <- function(p) sprintf("%.0f%%", 100 * p)
  # For those plays: the probability each run gave to what actually happened.
  fp <- both[pass_id %in% film$pass_id & model %in% c("logistic", "transformer_freeze")]
  fp[, `:=`(p_actual_before = fcase(label == "shot", p_shot_before, label == "drive", p_drive_before, default = p_pass_before),
            p_actual_after = fcase(label == "shot", p_shot_after, label == "drive", p_drive_after, default = p_pass_after))]
  fp[meta, on = "pass_id", `:=`(time_to_act = i.time_to_act, shot_clock_filled = i.shot_clock)]
  fp <- film[, .(file, pass_id)][fp, on = "pass_id"][order(file, model)]
  fwrite(fp, file.path(paths$out, sprintf("compare_%s_film_plays.csv", BEFORE)))
  cat("\nEarlier film-study plays: probability given to what actually happened, before -> after\n")
  print(fp[, .(file, model, actual = label, clock_in = sprintf("%.0f -> %.0f s", shot_clock_filled, time_to_act),
               before = pct(p_actual_before), after = pct(p_actual_after))])
}
