# Gate 00 of the rebounding manual: sources pinned with a licence disposition, environment matches the lockfile,
# configuration complete, supplied data unmodified and checksummed, artefacts under version control.
# Run through src/rebounding/run_tests.R or run_step00.R (they load the modules into `env`).

cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
sources <- yaml::read_yaml(file.path(here, "config", "sources.yaml"))
fresh_copy <- identical(Sys.getenv("REBOUND_FRESH_COPY"), "1")

test_that("the experiment configuration has every section the manual asks for", {
  expect_true(all(c("dataset", "units", "target", "splits", "seeds", "prediction_times", "model_ladder", "paths") %in% names(cfg)))
  expect_equal(cfg$units$fps, 25)
  expect_equal(cfg$units$frame_seconds, 0.04)
  expect_equal(cfg$units$length, "ft")
  expect_setequal(unlist(cfg$dataset$games), c(114243, 114234, 114169, 114099, 114086, 178442, 179612, 184439, 188630, 191313))
  expect_match(cfg$dataset$upstream_commit, "^[0-9a-f]{40}$")
  expect_setequal(names(cfg$model_ladder), LETTERS[1:6])
})

test_that("every source is checked out at its pinned commit with its licence as recorded", {
  sc <- source_checks(root, sources)
  expect_true(all(sc$present), info = paste(sc[!(present)]$name, collapse = ", "))
  expect_true(all(sc$at_commit), info = paste(sc[!(at_commit)]$name, collapse = ", "))
  expect_true(all(sc$licence_as_recorded), info = paste(sc[!(licence_as_recorded)]$name, collapse = ", "))
  expect_equal(sum(sc$excluded_paths_present), 0L)
  expect_true(all(sc$reuse %in% c("adapt", "ideas")))
  expect_true(all(sc[reuse == "adapt"]$licence != "none found"))
})

test_that("the source register names every pinned commit", {
  reg <- paste(readLines(file.path(root, "docs", "project", "SOURCE_REGISTER.md"), warn = FALSE), collapse = "\n")
  for (s in sources) expect_true(grepl(s$commit, reg, fixed = TRUE), info = s$name)
  expect_true(grepl(cfg$dataset$upstream_commit, reg, fixed = TRUE))
})

test_that("the running R and every package match the lockfile", {
  lk <- lockfile_check(file.path(here, "renv.lock"))
  expect_equal(lk$r_running, lk$r_locked)
  expect_true(all(lk$packages$match), info = paste(lk$packages[!(match)]$package, collapse = ", "))
})

test_that("the supplied data files match the committed checksum manifest and the upstream release", {
  manifest <- file.path(root, cfg$dataset$checksums)
  expect_true(file.exists(manifest))
  v <- verify_manifest(root, manifest)
  expect_true(all(v$ok), info = paste(v[!(ok)]$path, collapse = ", "))
  m <- fread(manifest)
  expect_true(all(m$equals_upstream %in% TRUE), info = paste(m[!(equals_upstream %in% TRUE)]$path, collapse = ", "))
  expect_true(all(m[grepl("tracking", path)]$upstream_object_verified %in% TRUE))
  expect_equal(nrow(m[grepl("_tracking_data\\.jsonl$", path)]), 10L)
})

test_that("configuration, lockfile, register, code and tests are under version control", {
  skip_if(fresh_copy, "a fresh copy is not a git checkout")
  skip_if(identical(Sys.getenv("REBOUND_SKIP_VCS"), "1"), "version control is judged by the parent run")
  paths <- c("src/rebounding/config/experiment.yaml", "src/rebounding/config/sources.yaml", "src/rebounding/renv.lock",
             "docs/project/SOURCE_REGISTER.md", "src/rebounding/R/step00.R", "src/rebounding/run_step00.R",
             "src/rebounding/fetch_sources.R", "src/rebounding/tests/gates/test_step_00.R", cfg$dataset$checksums)
  vc <- vcs_check(root, paths)
  expect_true(all(vc$tracked), info = paste(vc[!(tracked)]$path, collapse = ", "))
})
