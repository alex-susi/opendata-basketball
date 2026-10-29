# Reproduce Step 00 from a clean copy of the repository, as a new checkout would.
#   Rscript src/rebounding/check_fresh_checkout.R --lib=PATH [--dir=PATH]
# The copy holds exactly the files git would check out (tracked plus new, unignored files; nothing ignored: no
# external/, no caches). data/ is linked to this checkout's data (a directory junction) because the copy would
# otherwise download the same 1.7 GB again; Step 00 then verifies those files against the committed manifest.
# In the copy, fetch_sources.R fetches every source from GitHub at its pinned commit, and run_step00.R runs with
# PATH as the only package library (restore it from src/rebounding/renv.lock first).
# Writes outputs/rebounding/gate_results/00_fresh_checkout.json here.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "step00.R"))

root <- find_repo_root()
lib <- sub("^--lib=", "", grep("^--lib=", args, value = TRUE))
if (!length(lib) || !dir.exists(lib)) stop("--lib=PATH must name a library restored from src/rebounding/renv.lock")
dir <- sub("^--dir=", "", grep("^--dir=", args, value = TRUE))
if (!length(dir)) dir <- file.path(tempdir(), "rebound_fresh")
#' Remove a previous copy. Its data/ is a junction to this checkout's data, so the link is removed on its own first
#' (Directory.Delete without recursion deletes a junction, never its target) and the copy is only deleted once the
#' link is gone. Refuses anything that does not look like a copy made by this script.
remove_copy <- function(dir) {
  if (!dir.exists(dir)) return(invisible())
  if (normalizePath(dir, winslash = "/") == root || !file.exists(file.path(dir, "src", "rebounding", "check_fresh_checkout.R")))
    stop(dir, " is not a fresh copy made by this script; not deleting it")
  # built by hand: normalizePath() would follow the junction to the real data folder
  link <- gsub("/", "\\\\", file.path(normalizePath(dir, winslash = "/"), "data"))
  if (file.exists(link)) {
    ps <- sprintf("$i = Get-Item -LiteralPath '%s' -Force; if ($i.LinkType -eq 'Junction') { [System.IO.Directory]::Delete('%s', $false) } else { exit 3 }", link, link)
    status <- system2("powershell", c("-NoProfile", "-Command", shQuote(ps)))
    if (status != 0 || file.exists(link)) stop(link, " is not a junction or could not be removed; not deleting the copy")
  }
  # PowerShell with the \\?\ prefix, because the sources' git pack files pass Windows' 260-character limit; refuses
  # while any link (reparse point) is left inside the copy
  win <- gsub("/", "\\\\", normalizePath(dir, winslash = "/"))
  ps <- sprintf(paste("$d = '\\\\?\\%s'; if (Get-ChildItem -LiteralPath $d -Recurse -Force -Attributes ReparsePoint",
                      "-ErrorAction SilentlyContinue) { exit 4 }; Remove-Item -LiteralPath $d -Recurse -Force"), win)
  status <- system2("powershell", c("-NoProfile", "-Command", shQuote(ps)))
  if (status != 0 || dir.exists(dir)) stop("could not remove ", dir, " (status ", status, ")")
}
remove_copy(dir)
dir.create(dir, recursive = TRUE)

files <- git_out(root, "ls-files", "--cached", "--others", "--exclude-standard")
files <- files[!startsWith(files, "data/") & file.exists(file.path(root, files))]
for (d in unique(dirname(files))) dir.create(file.path(dir, d), recursive = TRUE, showWarnings = FALSE)
copied <- file.copy(file.path(root, files), file.path(dir, files))
if (!all(copied)) stop("could not copy: ", paste(files[!copied], collapse = ", "))
if (!Sys.junction(file.path(root, "data"), file.path(dir, "data"))) stop("could not link data/")
message(sprintf("copied %d files to %s", length(files), dir))

rscript <- file.path(R.home("bin"), "Rscript")
old <- Sys.getenv(c("R_LIBS_USER", "R_LIBS", "REBOUND_FRESH_COPY"), unset = NA)
Sys.setenv(R_LIBS_USER = normalizePath(lib, winslash = "/"), R_LIBS = "", REBOUND_FRESH_COPY = "1")
step <- function(script) {
  out <- suppressWarnings(system2(rscript, shQuote(file.path(dir, "src", "rebounding", script)), stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, output = out)
}
wd <- setwd(dir)
fetch <- step("fetch_sources.R")
run <- step("run_step00.R")
setwd(wd)
for (k in names(old)) if (is.na(old[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(old[k]))

rec_path <- file.path(dir, "outputs", "rebounding", "gate_results", "00_setup_fresh.json")
rec <- if (file.exists(rec_path)) jsonlite::read_json(rec_path) else NULL
crit <- rec$criteria
# A copy is not a git checkout and has no fresh-checkout record of its own, so those two criteria are not judged there.
judged <- crit[setdiff(names(crit), c("under_version_control", "fresh_checkout_reproduces", "isolated_install_runs_tests"))]
summary <- list(
  date = format(Sys.time(), "%Y-%m-%d %H:%M"), copy = normalizePath(dir, winslash = "/"), files_copied = length(files),
  library = normalizePath(lib, winslash = "/"), repository_head = git_out(root, "rev-parse", "HEAD")[1],
  uncommitted_files_included = length(git_out(root, "ls-files", "--others", "--exclude-standard")),
  fetch_status = fetch$status, run_status = run$status,
  fresh_criteria = judged, fresh_status = rec$status %||% NA, fresh_unmet = rec$unmet,
  reproduced = fetch$status == 0L && !is.null(judged) && all(vapply(judged, isTRUE, NA)),
  tail = tail(run$output, 6))
write_gate(file.path(root, "outputs", "rebounding", "gate_results", "00_fresh_checkout.json"), summary)
cat(tail(fetch$output, 12), sep = "\n")
cat(tail(run$output, 14), sep = "\n")
cat("FRESH CHECKOUT:", if (summary$reproduced) "reproduced" else "NOT reproduced", "\n")
