# Run the rebounding tests.
#   Rscript src/rebounding/run_tests.R [unit|gates] [filter]
# e.g. `run_tests.R gates step_01` runs tests/gates/test_step_01.R. Exits non-zero when any expectation fails.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
trailing <- commandArgs(trailingOnly = TRUE)
dir <- if (length(trailing) >= 1L) trailing[1] else "unit"
filter <- if (length(trailing) >= 2L && nzchar(trailing[2])) trailing[2] else NULL
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "step00.R", "step01.R"))
  if (file.exists(file.path(here, "R", f))) source(file.path(here, "R", f))

root <- find_repo_root()
res <- run_tests(here, root, dir, filter)
print(res[, .(file, test = substr(test, 1, 70), expectations, failed, skipped, error)])
bad <- res[failed > 0 | error == TRUE]
cat(sprintf("TESTS %s%s: %d blocks, %d expectations, %d failed blocks, %d skipped\n", dir,
            if (is.null(filter)) "" else paste0(" (", filter, ")"), nrow(res), sum(res$expectations), nrow(bad),
            sum(res$skipped)))
cat("LIBRARIES", paste(.libPaths(), collapse = " | "), "\n")
quit(status = if (nrow(bad) || !nrow(res)) 1L else 0L)
