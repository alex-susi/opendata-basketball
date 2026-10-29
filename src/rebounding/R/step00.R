# Step 00 of the rebounding manual: pinned sources, data provenance, the locked environment, version control and
# the machine-readable gate record every later step writes.
# Requires data.table, yaml, jsonlite, openssl.

if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a)) b else a

#' Run git in a folder; NA (not an error) when git fails, so a missing checkout is reported rather than fatal.
git_out <- function(dir, ...) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(dir), ...), stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(out, "status")) || !length(out)) NA_character_ else out
}

#' SHA-256 of a file, or of a .gz file's decompressed bytes, streamed.
sha256_file <- function(path, gunzip = FALSE) {
  con <- if (gunzip) gzcon(file(path, "rb")) else file(path, "rb")
  on.exit(close(con))
  paste(openssl::sha256(con))   # paste drops the hash class, so identical() compares plain strings
}

#' Every pinned source's checkout: present, at its commit, licence file as recorded, excluded paths absent.
source_checks <- function(root, sources) {
  rbindlist(lapply(sources, function(s) {
    dir <- file.path(root, "external", s$name)
    present <- dir.exists(file.path(dir, ".git"))
    head <- if (present) git_out(dir, "rev-parse", "HEAD")[1] else NA_character_
    lic_files <- if (present) grep("^(licen[cs]e|copying)", list.files(dir), ignore.case = TRUE, value = TRUE) else character()
    lic_ok <- if (is.null(s$licence_file)) !length(lic_files) else s$licence_file %in% lic_files
    excluded <- unlist(s$exclude)
    leaked <- if (present && length(excluded)) length(Sys.glob(file.path(dir, sub("/$", "", excluded)))) else 0L
    data.table(name = s$name, url = s$url, commit = s$commit, licence = s$licence, reuse = s$reuse, present = present,
               head = head, at_commit = identical(head, s$commit), licence_as_recorded = present && lic_ok,
               excluded_paths_present = leaked)
  }))
}

#' Provenance of every supplied data file: size and SHA-256, and whether it equals the upstream release.
#' Tracking files are compared with their Git LFS object at HEAD and, when the upstream .gz object is in the local
#' LFS store, with that file decompressed. Every other file is compared with its blob at the upstream commit.
data_provenance <- function(root, upstream) {
  files <- sort(list.files(file.path(root, "data"), recursive = TRUE))
  lfs_store <- file.path(git_out(root, "rev-parse", "--path-format=absolute", "--git-common-dir")[1], "lfs", "objects")
  pointer_oid <- function(ref) {
    p <- git_out(root, "cat-file", "-p", ref)
    if (anyNA(p)) NA_character_ else sub("^oid sha256:", "", grep("^oid sha256:", p, value = TRUE))[1]
  }
  rbindlist(lapply(files, function(f) {
    path <- file.path(root, "data", f)
    sha <- sha256_file(path)
    rel <- paste0("data/", f)
    if (grepl("_tracking_data\\.jsonl$", f)) {
      head_oid <- pointer_oid(paste0("HEAD:", rel))
      gz_oid <- pointer_oid(paste0(upstream, ":", rel, ".gz"))
      gz_path <- if (is.na(gz_oid)) NA_character_ else file.path(lfs_store, substr(gz_oid, 1, 2), substr(gz_oid, 3, 4), gz_oid)
      gz_ok <- !is.na(gz_path) && file.exists(gz_path)
      data.table(path = rel, bytes = file.size(path), sha256 = sha, upstream_path = paste0(rel, ".gz"),
                 upstream_sha256 = gz_oid,
                 upstream_object_verified = gz_ok && identical(sha256_file(gz_path), gz_oid),
                 equals_upstream = if (gz_ok) identical(sha256_file(gz_path, gunzip = TRUE), sha) else NA,
                 how = "decompressed upstream .gz LFS object", equals_head_lfs_object = identical(head_oid, sha))
    } else {
      blob <- git_out(root, "rev-parse", paste0(upstream, ":", rel))[1]
      data.table(path = rel, bytes = file.size(path), sha256 = sha, upstream_path = rel, upstream_sha256 = NA_character_,
                 upstream_object_verified = NA, equals_upstream = identical(git_out(root, "hash-object", shQuote(path))[1], blob),
                 how = "git blob at the upstream commit", equals_head_lfs_object = NA)
    }
  }))
}

#' Current data files against the committed manifest: same file set, same sizes and hashes.
verify_manifest <- function(root, manifest) {
  m <- fread(manifest, colClasses = list(character = c("sha256", "upstream_sha256")))
  now <- data.table(path = paste0("data/", sort(list.files(file.path(root, "data"), recursive = TRUE))))
  now[, bytes := file.size(file.path(root, path))]
  now[, sha256 := vapply(file.path(root, path), sha256_file, "")]
  j <- merge(m[, .(path, m_bytes = bytes, m_sha = sha256)], now, by = "path", all = TRUE)
  j[, ok := !is.na(m_sha) & !is.na(sha256) & m_bytes == bytes & m_sha == sha256]
  j[]
}

#' Locked package versions against the versions a library actually provides.
lockfile_check <- function(lockfile, lib = .libPaths()) {
  lk <- jsonlite::fromJSON(lockfile, simplifyVector = FALSE)
  pk <- rbindlist(lapply(lk$Packages, function(p) data.table(package = p$Package, locked = p$Version)))
  pk[, installed := vapply(package, function(p) tryCatch(as.character(packageVersion(p, lib.loc = lib)),
                                                          error = function(e) NA_character_), "")]
  pk[, match := !is.na(installed) & mapply(function(a, b) !is.na(a) && package_version(a) == package_version(b), installed, locked)]
  list(r_locked = lk$R$Version, r_running = paste(R.version$major, R.version$minor, sep = "."), packages = pk[])
}

#' Whether each path is tracked by git and unchanged against HEAD.
vcs_check <- function(root, paths) {
  rbindlist(lapply(paths, function(p) {
    tracked <- !is.na(git_out(root, "ls-files", "--error-unmatch", shQuote(p))[1])
    dirty <- git_out(root, "status", "--porcelain", "--", shQuote(p))
    data.table(path = p, exists = file.exists(file.path(root, p)), tracked = tracked,
               clean = tracked && all(is.na(dirty)))
  }))
}

#' Run the testthat files of one tests/ folder (optionally those whose name matches `filter`) with `here` and `root`
#' visible to them; returns one row per test block.
run_tests <- function(here, root, dir, filter = NULL) {
  suppressPackageStartupMessages(library(testthat))
  env <- new.env(parent = globalenv())
  env$here <- normalizePath(here, winslash = "/")   # test_dir runs each file from its own folder
  env$root <- root
  r <- as.data.frame(testthat::test_dir(file.path(here, "tests", dir), filter = filter, env = env, reporter = "silent",
                                        stop_on_failure = FALSE, stop_on_warning = FALSE, load_package = "none"))
  if (!nrow(r)) return(data.table())
  data.table(dir = dir, file = r$file, test = r$test, expectations = r$nb, failed = r$failed, skipped = r$skipped,
             error = r$error, warnings = r$warning)
}

#' Run a tests/ folder in a child Rscript whose only library is `lib` (plus R's own), as a clean install would.
#' @return list(status, output).
run_tests_isolated <- function(here, lib, dir, filter = "") {
  old <- Sys.getenv(c("R_LIBS_USER", "R_LIBS", "REBOUND_SKIP_VCS"), unset = NA)
  on.exit(for (k in names(old)) if (is.na(old[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(old[k])))
  Sys.setenv(R_LIBS_USER = normalizePath(lib, winslash = "/"), R_LIBS = "", REBOUND_SKIP_VCS = "1")
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"), c(shQuote(file.path(here, "run_tests.R")), dir, filter),
                                  stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, output = out)
}

#' The manual's status record for a step, written as JSON next to its evidence.
write_gate <- function(path, rec) {
  jsonlite::write_json(rec, path, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA)
  invisible(rec)
}
