## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 24: rename the screener's-defender coverage "soft" to "drop" in saved files.
#   Rscript screen_coverage/01_scripts/24_rename_soft_to_drop.R            (dry run, lists what would change)
#   Rscript screen_coverage/01_scripts/24_rename_soft_to_drop.R --apply    (rewrites the files in place)
#
# SkillCorner's raw picks.scrDefType (and handoffs.setterDefType) say "soft" for a big who sits back below the screen.
# Coaches call that coverage drop. From 2026-11-16 every loader recodes "soft" to "drop" when it reads the raw event
# files (data/ itself is never touched), so rerunning any script gives "drop" labels. This one-off pass rewrites the
# files already saved from the old labels, so caches, outputs and the site agree without retraining:
#   .rds    every character value, factor level, name and dimname in the object
#   text    .csv, .json and .html outputs (site data, results tables)
# Raw aggregate column names (screener_picks_vs_soft and the like) stay as delivered. Words such as softmax, software
# and the CSS name soft-fill are left alone by the pattern.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
APPLY <- "--apply" %in% commandArgs(TRUE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - THE TEXT RULE -----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Order matters: the doubled forms first, then identifiers, then the bare word.
swap <- function(x) {
  x <- gsub("soft \\(drop\\)", "drop", x)
  x <- gsub("drop \\(soft\\)", "drop", x)
  x <- gsub("Soft \\(drop\\)", "Drop", x)
  x <- gsub("(?<![A-Za-z])(o|u|s|r)_soft(?![A-Za-z])", "\\1_drop", x, perl = TRUE)
  x <- gsub("scr_soft", "scr_drop", x, fixed = TRUE)
  x <- gsub("(over|under)soft", "\\1drop", x)
  x <- gsub("(?<![A-Za-z_-])soft(?![A-Za-z_-])", "drop", x, perl = TRUE)
  x <- gsub("(?<![A-Za-z_-])Soft(?![A-Za-z_-])", "Drop", x, perl = TRUE)
  x <- gsub("(?<![A-Za-z_-])SOFT(?![A-Za-z_-])", "DROP", x, perl = TRUE)
  # Keep the one sentence that names SkillCorner's raw label.
  gsub("SkillCorner's label is drop", "SkillCorner's label is soft", x, fixed = TRUE)
}

# Every string inside an R object: values, factor levels, names, dimnames. Returns the object and whether it changed.
walk <- function(o) {
  hit <- FALSE
  fix <- function(v) {
    if (!length(v) || !any(grepl("soft", v, ignore.case = TRUE), na.rm = TRUE)) return(v)
    w <- swap(v)
    if (!identical(w, v)) hit <<- TRUE
    w
  }
  rec <- function(z) {
    if (is.factor(z)) {
      levels(z) <- fix(levels(z))
    } else if (is.character(z)) {
      at <- attributes(z)
      z <- fix(z)
      attributes(z) <- at
    } else if (is.list(z) && !is.function(z) && !inherits(z, "torch_tensor") && !is.environment(z)) {
      cls <- class(z)
      dt <- is.data.table(z)
      for (i in seq_along(z)) {
        if (!is.null(z[[i]])) z[[i]] <- rec(z[[i]])
      }
      class(z) <- cls
      if (dt) z <- setalloccol(z)
    }
    if (!is.null(names(z))) names(z) <- fix(names(z))
    if (!is.null(dimnames(z))) dimnames(z) <- lapply(dimnames(z), function(d) if (is.null(d)) d else fix(d))
    z
  }
  out <- rec(o)
  list(obj = out, changed = hit)
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FILES TO VISIT ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

RDS_DIRS <- c("screen_coverage/02_cache", "screen_coverage/zz_Archive/02_cache", "archetypes/02_cache",
              "kickout_transformer/02_cache", "web/cache", "play_viewer/02_cache")
TXT_DIRS <- c("screen_coverage/03_outputs", "screen_coverage/zz_Archive/03_outputs", "archetypes/03_outputs",
              "kickout_transformer/03_outputs", "web/public/data", "web/cache", "web/outputs")
SKIP_TXT <- c("web/public/data/archetypes.html")   # its one "soft" is about archetype borders

rds <- unlist(lapply(file.path(root, RDS_DIRS), list.files, pattern = "\\.rds$", recursive = TRUE, full.names = TRUE))
txt <- unlist(lapply(file.path(root, TXT_DIRS), list.files, pattern = "\\.(csv|json|html)$", recursive = TRUE, full.names = TRUE))
txt <- txt[!sub(paste0(root, "/"), "", txt, fixed = TRUE) %in% SKIP_TXT]





## ═════════════════════════════════════════════════════════════════════════════
## 03 - REWRITE -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

log <- list()
for (f in txt) {
  # Whole file as one string so line endings and a missing final newline survive.
  s <- readChar(f, file.size(f), useBytes = TRUE)
  if (!grepl("soft", s, ignore.case = TRUE, useBytes = TRUE)) next
  Encoding(s) <- "UTF-8"
  s2 <- swap(s)
  if (identical(s2, s)) next
  n <- length(gregexpr("(?<![A-Za-z_-])[Ss]oft(?![A-Za-z_-])|[ours]_soft|scr_soft|(over|under)soft", s, perl = TRUE)[[1]])
  log[[length(log) + 1L]] <- data.table(file = f, kind = "text", lines = n)
  if (APPLY) writeChar(enc2utf8(s2), f, eos = NULL, useBytes = TRUE)
}
for (f in rds) {
  o <- tryCatch(readRDS(f), error = function(e) NULL)
  if (is.null(o)) next
  w <- walk(o)
  if (!w$changed) next
  log[[length(log) + 1L]] <- data.table(file = f, kind = "rds", lines = NA_integer_)
  if (APPLY) saveRDS(w$obj, f)
}
log <- rbindlist(log)
for (i in seq_len(nrow(log))) {
  cat(log$kind[i], log$lines[i], sub(paste0(root, "/"), "", log$file[i], fixed = TRUE), "\n")
}
cat(if (APPLY) "Rewritten:" else "Would rewrite:", nrow(log), "files\n")
