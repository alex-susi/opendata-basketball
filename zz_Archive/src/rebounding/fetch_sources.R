# Fetch every third-party source of the rebounding manual into external/ at its pinned commit.
#   Rscript src/rebounding/fetch_sources.R
# Commits and excluded paths come from src/rebounding/config/sources.yaml. A checkout already at its commit is left
# alone. Excluded paths (outside data, e.g. ReboundingPrediction's NBA SportVU games) are never checked out.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "step00.R"))

root <- find_repo_root()
sources <- yaml::read_yaml(file.path(here, "config", "sources.yaml"))
dir.create(file.path(root, "external"), showWarnings = FALSE)
Sys.setenv(GIT_LFS_SKIP_SMUDGE = "1")
run <- function(dir, ...) {
  # core.longpaths: Windows otherwise refuses git object paths beyond 260 characters under a deep folder
  status <- system2("git", c("-c", "core.longpaths=true", "-C", shQuote(dir), ...))
  if (status != 0) stop("git ", paste(c(...), collapse = " "), " failed in ", dir)
}
for (s in sources) {
  dir <- file.path(root, "external", s$name)
  if (identical(git_out(dir, "rev-parse", "HEAD")[1], s$commit)) {
    message(s$name, ": at ", substr(s$commit, 1, 7))
    next
  }
  if (dir.exists(dir)) stop(dir, " exists at another commit; remove it first")
  dir.create(dir)
  run(dir, "init", "-q")
  run(dir, "remote", "add", "origin", s$url)
  # A blob-less fetch of the one commit, then a sparse checkout that leaves the excluded paths out.
  run(dir, "fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", s$commit)
  if (length(s$exclude)) {
    run(dir, "sparse-checkout", "set", "--no-cone", shQuote("/*"), vapply(s$exclude, function(p) shQuote(paste0("!/", p)), ""))
  }
  run(dir, "checkout", "-q", "FETCH_HEAD")
  message(s$name, ": fetched ", substr(s$commit, 1, 7))
}
print(source_checks(root, sources)[, .(name, at_commit, licence_as_recorded, excluded_paths_present)])
