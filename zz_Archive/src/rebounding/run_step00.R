## ═════════════════════════════════════════════════════════════════════════════
# Step 00 of the rebounding manual: pinned sources, data provenance, locked environment, tests and the gate record.
#   Rscript src/rebounding/run_step00.R [--write-manifest] [--isolated-lib=PATH]
# --write-manifest  (re)builds outputs/rebounding/gate_results/data_checksums.csv from the data files, proving each
#                   against the upstream release (needs the git history and the local LFS store; about a minute).
# --isolated-lib    also runs the unit and Step 00 tests in a child process whose only library is PATH, which
#                   should hold exactly the lockfile (renv::restore(lockfile = "src/rebounding/renv.lock", library = PATH)).
# Writes gate_results/00_setup.json, 00_sources.csv, 00_packages.csv, 00_tests.csv. The fresh-checkout check
# (check_fresh_checkout.R) writes 00_fresh_checkout.json, which this script folds into the decision when present.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "step00.R", "step01.R")) source(file.path(here, "R", f))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - CONFIGURATION ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
sources <- yaml::read_yaml(file.path(here, "config", "sources.yaml"))
gr <- file.path(root, "outputs", "rebounding", "gate_results")
dir.create(gr, recursive = TRUE, showWarnings = FALSE)
fresh_copy <- identical(Sys.getenv("REBOUND_FRESH_COPY"), "1")
iso_lib <- sub("^--isolated-lib=", "", grep("^--isolated-lib=", args, value = TRUE))
manifest <- file.path(root, cfg$dataset$checksums)

if ("--write-manifest" %in% args) {
  t0 <- Sys.time()
  prov <- data_provenance(root, cfg$dataset$upstream_commit)
  fwrite(prov, manifest)
  message(sprintf("manifest: %d files, %.0f s", nrow(prov), as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - CHECKS AND TESTS -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

src <- source_checks(root, sources)
lk <- lockfile_check(file.path(here, "renv.lock"))
ver <- verify_manifest(root, manifest)
prov <- fread(manifest)
# Unit and gate tests, then the gate record.
tests <- rbind(run_tests(here, root, "unit"), run_tests(here, root, "gates", "step_00"), fill = TRUE)
iso <- if (length(iso_lib)) {
  u <- run_tests_isolated(here, iso_lib, "unit")
  g <- run_tests_isolated(here, iso_lib, "gates", "step_00")
  list(lib = iso_lib, unit_status = u$status, gate_status = g$status,
       summary = c(grep("^TESTS|^LIBRARIES", u$output, value = TRUE), grep("^TESTS|^LIBRARIES", g$output, value = TRUE)))
} else NULL
fresh_path <- file.path(gr, "00_fresh_checkout.json")
fresh <- if (file.exists(fresh_path) && !fresh_copy) jsonlite::read_json(fresh_path) else NULL
vc_paths <- c("src/rebounding/config/experiment.yaml", "src/rebounding/config/sources.yaml", "src/rebounding/renv.lock",
              "docs/project/SOURCE_REGISTER.md", "src/rebounding/R/step00.R", "src/rebounding/run_step00.R",
              "src/rebounding/run_tests.R", "src/rebounding/fetch_sources.R", "src/rebounding/check_fresh_checkout.R",
              "src/rebounding/tests/unit/test_determinism.R", "src/rebounding/tests/gates/test_step_00.R",
              cfg$dataset$checksums)
vc <- if (fresh_copy) NULL else vcs_check(root, vc_paths)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - GATE DECISION ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Acceptance criteria, then the gate record.
criteria <- list(sources_pinned_with_licence = all(src$at_commit & src$licence_as_recorded) && sum(src$excluded_paths_present) == 0L,
                 environment_matches_lockfile = lk$r_running == lk$r_locked && all(lk$packages$match),
                 isolated_install_runs_tests = if (is.null(iso)) NA else iso$unit_status == 0L && iso$gate_status == 0L,
                 deterministic_synthetic_test = nrow(tests[file == "test_determinism.R"]) > 0 && !any(tests[file == "test_determinism.R"]$failed > 0),
                 data_unmodified_and_checksummed = all(ver$ok) && all(prov$equals_upstream %in% TRUE),
                 under_version_control = if (is.null(vc)) NA else all(vc$tracked),
                 # the version-control test is the criterion above; every other test must pass
                 tests_pass = nrow(tests) > 0 && !any((tests$failed > 0 | tests$error) & !grepl("under version control", tests$test)),
                 fresh_checkout_reproduces = if (is.null(fresh)) NA else isTRUE(fresh$reproduced))
unmet <- names(criteria)[!vapply(criteria, isTRUE, NA)]
status <- if (!length(unmet)) "PASS" else "BLOCKED"

fwrite(src, file.path(gr, "00_sources.csv"))
fwrite(lk$packages, file.path(gr, "00_packages.csv"))
fwrite(tests, file.path(gr, "00_tests.csv"))
head_commit <- git_out(root, "rev-parse", "HEAD")[1]
# The gate record.
rec <- list(step = "00", status = status,
            scope = "project skeleton: pinned sources, data provenance, locked R environment, configuration, gate records",
            source_commits = setNames(as.list(src$commit), src$name),
            data_revision = list(upstream = cfg$dataset$upstream_commit, local_data_commit = cfg$dataset$local_data_commit,
                                 manifest = cfg$dataset$checksums, files = nrow(prov),
                                 tracking_equal_to_decompressed_upstream = sum(prov$equals_upstream[grepl("tracking", prov$path)] %in% TRUE)),
            model_revision = NULL, repository_head = head_commit, fresh_copy = fresh_copy,
            test_command = "Rscript src/rebounding/run_tests.R unit; Rscript src/rebounding/run_tests.R gates step_00",
            unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
            data_audit_passed = criteria$data_unmodified_and_checksummed,
            heldout_metrics_file = NULL, acceptance_criteria_version = sprintf("manual %s, config v%d", cfg$manual_revision, cfg$config_version),
            criteria = criteria, unmet = unmet,
            environment = list(r = lk$r_running, lockfile = "src/rebounding/renv.lock", packages = nrow(lk$packages),
                               mismatched = lk$packages[!(match)]$package, isolated = iso),
            fresh_checkout = fresh,
            untracked = if (is.null(vc)) NULL else vc[!(tracked)]$path,
            evidence = c("outputs/rebounding/gate_results/00_sources.csv", "outputs/rebounding/gate_results/00_packages.csv",
                         "outputs/rebounding/gate_results/00_tests.csv", cfg$dataset$checksums,
                         "outputs/rebounding/gate_results/00_fresh_checkout.json", "docs/project/SOURCE_REGISTER.md"),
            reviewer = "Claude (automated run); owner review pending", date = format(Sys.Date()),
            open_risks = list("ReboundingPrediction, tracking-study, ShotQuality, basketball-shot, ReboundingImpact and Charlychee have no licence: ideas only, no code reuse",
                              "Contract tables use gzip CSV, not parquet: the arrow build for R 4.4 is not reproducible from CRAN binaries"),
            decision_note = if (status == "PASS") "All Step 00 criteria met." else paste("Unmet:", paste(unmet, collapse = ", ")))
write_gate(file.path(gr, if (fresh_copy) "00_setup_fresh.json" else "00_setup.json"), rec)

print(src[, .(name, at_commit, licence, reuse, licence_as_recorded, excluded_paths_present)])
print(ver[!(ok)])
print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, skipped, error)])
if (!is.null(iso)) cat(iso$summary, sep = "\n")
str(criteria)
cat("STEP 00:", status, if (length(unmet)) paste("- unmet:", paste(unmet, collapse = ", ")) else "", "\n")
