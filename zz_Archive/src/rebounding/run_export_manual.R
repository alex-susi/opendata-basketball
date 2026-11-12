## ═════════════════════════════════════════════════════════════════════════════
# The step-by-step manual's results for the site: every gate record (status, scope, components, decision) and the
# result tables the Rebounding tab's section 12 reads. Numbers are copied from outputs/rebounding/ as they are, rounded
# for size; nothing is refitted here.
#   Rscript src/rebounding/run_export_manual.R
# Needs the gate records in outputs/rebounding/gate_results/ and the step outputs they cite. Writes
# web/public/data/rebounding_manual.json.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
root <- find_repo_root()
o <- function(...) file.path(root, "outputs", "rebounding", ...)
rd <- function(...) fread(o(...), na.strings = c("", "NA"))

#' Round every double column to `d` significant digits (keeps small differences readable, files small).
tidy <- function(d, digits = 4) {
  d <- as.data.table(d)
  for (c in names(d)) if (is.double(d[[c]])) set(d, j = c, value = signif(d[[c]], digits))
  d[]
}





## ═════════════════════════════════════════════════════════════════════════════
## 01 - GATE RECORDS -----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

gate_files <- c("00_setup", "01_episodes", "02_contact_states", "03_evaluation", "04_static", "05_spatial", "06_ball_filter",
                "07_postimpact", "08_reachability", "09_dynamic", "10_movement", "11_obstruction")
gates <- lapply(gate_files, function(g) {
  r <- jsonlite::fromJSON(o("gate_results", paste0(g, ".json")), simplifyVector = FALSE)
  comp <- r$components %||% r$labels_by_type
  comp_rows <- if (is.null(comp)) list() else lapply(names(comp), function(k) {
    v <- comp[[k]]
    list(name = k, status = if (is.list(v)) (v$status %||% "") else as.character(v))
  })
  list(step = r$step, file = g, status = r$status, scope = r$scope %||% "", decision = r$decision_note %||% "",
       date = r$date %||% "", components = comp_rows, deviations = length(r$deviations %||% list()))
})





## ═════════════════════════════════════════════════════════════════════════════
## 02 - RESULT TABLES ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

s4 <- rd("step04", "scores_summary.csv")
s9 <- rd("step09", "scores_summary.csv")
scores <- rbind(s4, s9[model != "static_clogit"], fill = TRUE)[
  , .(model, time_point, episodes, log_loss, brier, top1, top3, team_log_loss, ece)]
cmp_cols <- c("time_point", "metric", "episodes", "mean_diff", "lo", "hi", "games_better", "drop_one_max")
c1 <- rd("step04", "c1_by_reference.csv")[, c("reference", cmp_cols, "pass"), with = FALSE]
c3 <- rd("step09", "comparisons.csv")[, c("test", "candidate", "reference", cmp_cols, "superior", "non_inferior"), with = FALSE]
ag <- rd("step02", "agreement.csv")[pair %in% c("reviewer1_vs_reviewer2", "auto_vs_reviewer2"),
                                    .(pair, type, measure, agree, n, value, target)]
ag_dec <- rd("step02", "agreement_decisions.csv")[pair %in% c("reviewer1_vs_reviewer2", "auto_vs_reviewer2"), .(pair, type, status, unmet)]
cov <- rbind(cbind(step = "05", rd("step05", "coverage.csv")[, .(model, level, n, coverage, within_tol)]),
             cbind(step = "06", rd("step06", "coverage.csv")[, .(model = fifelse(horizon == "all", "Filter, every horizon pooled", paste0("Filter, ", horizon, " frames ahead")), level, n, coverage, within_tol)]),
             cbind(step = "07", rd("step07", "coverage.csv")[, .(model, level, n, coverage, within_tol)]))
mov <- rd("step08", "paired_movement.csv")[, .(candidate, reference, horizon = time_point, metric, episodes, mean_diff, lo, hi, games_better, superior)]
s11cmp <- rd("step11", "comparison.csv")[, c(cmp_cols, "non_inferior", "superior", "ece_candidate", "ece_reference", "ece_ok"), with = FALSE]

doc <- list(built = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
            manual_revision = yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$manual_revision,
            gates = gates,
            labels = list(agreement = tidy(ag), decisions = ag_dec),
            scores = tidy(scores), c1 = tidy(c1), c3 = tidy(c3),
            coverage = tidy(cov), movement = tidy(mov),
            opportunity = list(by_role = tidy(rd("step10", "by_role.csv")),
                               onset_curve = tidy(rd("step10", "response_onset_curve.csv")),
                               ranks = tidy(rd("step10", "credited_rebounder_ranks.csv"))),
            obstruction = list(comparison = tidy(s11cmp), geometry = tidy(rd("step11", "geometry_checks.csv")),
                               perturbation = tidy(rd("step11", "perturbation.csv")),
                               perturbation_context = tidy(rd("step11", "perturbation_context.csv")),
                               contribution = tidy(rd("step11", "contribution_by_role.csv")),
                               pairings = tidy(rd("step11", "pairing_summary.csv"))))
dest <- file.path(root, "web", "public", "data", "rebounding_manual.json")
jsonlite::write_json(doc, dest, auto_unbox = TRUE, dataframe = "rows", na = "null", null = "null", digits = NA)
cat("wrote", dest, sprintf("(%.0f KB)\n", file.size(dest) / 1024))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - STEP 09'S HELD-OUT FORECASTS FOR THE PLAY VIEWER -----------------------
## ═════════════════════════════════════════════════════════════════════════════

# One file per game.

# Each episode's two forecasts (release and rim + 0.2 s) from the fold model fitted without its game
# (step09/dynamic_oof.csv.gz), with the frame each was made at. Players in the choice set's order (offence first).
el <- rd("step01", "rebound_episodes.csv")[eligible == TRUE, .(episode_id, game_id, release_off_ids, release_def_ids)]
oof <- fread(o("step09", "dynamic_oof.csv.gz"), colClasses = list(character = "outcome_id"))[model == "dynamic"]
gate09 <- jsonlite::fromJSON(o("gate_results", "09_dynamic.json"))
gdir <- file.path(root, "web", "public", "data", "rebounding_manual")
dir.create(gdir, showWarnings = FALSE)
# One file per game: each episode's held-out forecasts at release and rim+0.2.
for (g in sort(unique(el$game_id))) {
  ids <- el[game_id == g]
  eps <- lapply(seq_len(nrow(ids)), function(i) {
    e <- ids[i]
    pid <- c(strsplit(e$release_off_ids, ";")[[1]], strsplit(e$release_def_ids, ";")[[1]])
    d <- oof[episode_id == e$episode_id]
    if (!nrow(d)) return(NULL)
    steps <- lapply(split(d, by = "time_point")[intersect(c("release", "rim+0.2"), unique(d$time_point))], function(s) {
      pr <- setNames(s$probability, s$outcome_id)
      list(f = s$frame_idx[1], tp = s$time_point[1], fold = s$outer_fold[1], pid = as.integer(pid),
           p = round(unname(pr[pid]), 4), team_off = round(pr[["team_off"]], 4), team_def = round(pr[["team_def"]], 4))
    })
    list(id = e$episode_id, steps = unname(steps))
  })
  out <- list(game = g, model = "dynamic (Step 09)", gate = gate09$status, built = doc$built, episodes = Filter(Negate(is.null), eps))
  jsonlite::write_json(out, file.path(gdir, sprintf("%s.json", g)), auto_unbox = TRUE, digits = NA)
}
cat("wrote", length(unique(el$game_id)), "game files to", gdir, "\n")
