## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 21: make the main-curve model the live model (owner, 2026-11-15).
#   Rscript screen_coverage/01_scripts/21_promote_main_curve.R
#
# The live model now stops training on the main time-weight curve and averages four random starts
# (03_train_transformer.R defaults since 2026-11-15). The timing experiment already trained exactly that model as its
# "none" version, in two runs per fold (starts 1-2 and 3-4; each start is seeded on its own, so the two runs average to
# what one four-start run gives). This script checks that each pair was built under the current rules and settings,
# copies its four networks into 02_cache/tf/ and writes tf/seqheads_<game>.rds in the form 03_train_transformer.R
# writes, so every later step reads them as the live folds. Rerunning 03_train_transformer.R --fold=<game> --force for
# all ten games rebuilds the same files from scratch (about 1 h at 8 folds in parallel).
#
# The model live until 2026-11-15 (flat stopping score, two starts) is kept in 02_cache/v2_flat_2026-11-12/tf/.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
cache_dir <- file.path(root, "screen_coverage", "02_cache")
src_dir <- file.path(cache_dir, "experiments", "timing", "none")
tf_dir <- file.path(cache_dir, "tf")
snap_dir <- file.path(cache_dir, "v2_flat_2026-11-12", "tf")
stopifnot(dir.exists(snap_dir), length(list.files(snap_dir, "^seqheads_[0-9]+[.]rds$")) == 10L)

# The settings the live model is trained with now (03_train_transformer.R, section 01).
SETTINGS <- list(MAX_EPOCHS = 150L, PATIENCE = 15L, BATCH = 128L, LR = 5e-4, WD = 5e-2, FRAMES_PER_EPOCH = 3L, EVERY = 3L,
                 K_STEPS = 9L)
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
games <- sort(unique(L$X$game_id))
avg2 <- function(a, b, k) (a[[k]] + b[[k]]) / 2

for (g in games) {
  a <- readRDS(file.path(src_dir, "tf_s1-2", sprintf("seqheads_%d.rds", g)))
  b <- readRDS(file.path(src_dir, "tf_s3-4", sprintf("seqheads_%d.rds", g)))
  # Same rules, screens, rows, standardisation and settings; no timing inputs or extra channels.
  for (o in list(a, b)) {
    stopifnot(identical(o$rules, PAST_ONLY_RULES), identical(o$screen_ids, L$P$id), o$timing$version == "none",
              is.na(o$timing$extra), !length(o$timing$step1_cols), identical(o$timing$ctx_cols, colnames(SQ$ctx)),
              identical(o$timing$settings, SETTINGS))
  }
  stopifnot(identical(a$rows, b$rows), identical(a$val_rows, b$val_rows), identical(a$norm, b$norm),
            identical(a$timing$seeds, 1:2), identical(b$timing$seeds, 3:4))
  # The four networks, under the names 03_train_transformer.R gives them.
  nets <- character(0)
  for (o in list(a, b)) {
    for (k in seq_along(o$nets)) {
      seed <- o$timing$seeds[k]
      to <- file.path(tf_dir, sprintf("seqheads_%d_seed%d.pt", g, seed))
      stopifnot(file.copy(file.path(dirname(file.path(src_dir, "tf_s1-2")), ifelse(seed <= 2, "tf_s1-2", "tf_s3-4"),
                                    basename(o$nets[k])), to, overwrite = TRUE))
      nets <- c(nets, to)
    }
  }
  saved <- list(variant = "seqheads", test_game = g, val_game = a$val_game, rows = a$rows, prob = avg2(a, b, "prob"),
                heads = avg2(a, b, "heads"), att = avg2(a, b, "att"), curves = rbind(a$curves, b$curves),
                best = rbind(a$best, b$best), seconds = a$seconds + b$seconds, nets = nets, norm = a$norm,
                k_steps = a$k_steps, rules = PAST_ONLY_RULES, screen_ids = L$P$id,
                stopping = list(curve = "main", seeds = 1:4, settings = SETTINGS), val_rows = a$val_rows,
                val_prob = avg2(a, b, "val_prob"), promoted_from = src_dir)
  saveRDS(saved, file.path(tf_dir, sprintf("seqheads_%d.rds", g)))
  cat("fold", g, "promoted: best epochs", paste(saved$best$epoch, collapse = "/"), "\n")
}
