## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 33: make the switch-part positions model the live model (owner, 2026-11-19).
#   Rscript screen_coverage/01_scripts/33_promote_switch_positions.R
#
# The live model since 2026-11-19: the same time-aware transformer, inputs and training settings as before, with its
# final layer split in two (R/seq_transformer.R, n_sw). The switch part also reads the four screen players' position
# groups (guard, wing or big as 0/1 for the handler, the screener and their two defenders; 12 inputs), each game's
# groups refitted without that game (28_fold_positions.R, 29_build_personnel.R). The under-or-over and show-or-drop
# part reads the same shared notes as before and never the groups. No possession memory.
#
# It was trained as 03_train_transformer.R --personnel --positions=hard --pos-into=switch --memory=no, in two runs
# per fold (starts 1-2 and 3-4; each start seeded on its own, so the two runs average to one four-start run). This
# script checks each pair, copies its four networks into 02_cache/tf/ and writes tf/seqheads_<game>.rds in the form
# 03_train_transformer.R writes, so every later step reads them as the live folds. It also saves the groups the
# switch part reads to 02_cache/positions_live.rds, for checks that rerun the networks (05_test_past_only.R).
#
# The model live from 2026-11-15 to 2026-11-19 (one shared final layer, no groups) is kept in
# 02_cache/v2_main_2026-11-15/tf/.
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
src_dir <- file.path(cache_dir, "experiments", "personnel_hard_swhead_nomem")
tf_dir <- file.path(cache_dir, "tf")
snap_dir <- file.path(cache_dir, "v2_main_2026-11-15", "tf")
SETTINGS <- list(MAX_EPOCHS = 150L, PATIENCE = 15L, BATCH = 128L, LR = 5e-4, WD = 5e-2, FRAMES_PER_EPOCH = 3L, EVERY = 3L,
                 K_STEPS = 9L)
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
PI <- readRDS(file.path(cache_dir, "experiments", "personnel", "inputs.rds"))
games <- sort(unique(L$X$game_id))
avg2 <- function(a, b, k) (a[[k]] + b[[k]]) / 2





## ═════════════════════════════════════════════════════════════════════════════
## 01 - KEEP THE MODEL BEING REPLACED ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The outgoing live folds, copied once (a rerun of this script finds them in place and leaves them alone).
if (!dir.exists(snap_dir)) {
  dir.create(snap_dir, recursive = TRUE)
  old <- list.files(tf_dir, "^seqheads_[0-9]+(_seed[0-9]+[.]pt|[.]rds)$", full.names = TRUE)
  stopifnot(length(old) == 50L, all(file.copy(old, snap_dir)))
  # Point the snapshot's fold files at their own networks.
  for (f in list.files(snap_dir, "^seqheads_[0-9]+[.]rds$", full.names = TRUE)) {
    o <- readRDS(f)
    stopifnot(is.null(o$personnel))
    o$nets <- file.path(snap_dir, basename(o$nets))
    saveRDS(o, f)
  }
  cat("Outgoing live model kept in", snap_dir, "\n")
}
stopifnot(length(list.files(snap_dir, "^seqheads_[0-9]+[.]rds$")) == 10L)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PROMOTE THE SWITCH-PART MODEL ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

for (g in games) {
  a <- readRDS(file.path(src_dir, "tf_s1-2", sprintf("seqheads_%d.rds", g)))
  b <- readRDS(file.path(src_dir, "tf_s3-4", sprintf("seqheads_%d.rds", g)))
  # Same rules, screens, rows, standardisation and settings; groups in the switch part only, no memory.
  for (o in list(a, b)) {
    p <- o$personnel
    stopifnot(identical(o$rules, PAST_ONLY_RULES), identical(o$screen_ids, L$P$id), p$positions == "hard", p$pos_into == "switch",
              !p$memory, p$pos_players == "all", identical(p$ctx_cols, colnames(SQ$ctx)), identical(p$feats, SQ$feats),
              length(p$sw_cols) == 12L, identical(p$settings, SETTINGS))
  }
  stopifnot(identical(a$rows, b$rows), identical(a$val_rows, b$val_rows), identical(a$norm, b$norm),
            identical(a$personnel$seeds, 1:2), identical(b$personnel$seeds, 3:4))
  # The four networks, under the names 03_train_transformer.R gives them.
  nets <- character(0)
  for (o in list(a, b)) {
    for (k in seq_along(o$nets)) {
      seed <- o$personnel$seeds[k]
      from <- file.path(src_dir, if (seed <= 2) "tf_s1-2" else "tf_s3-4", basename(o$nets[k]))
      to <- file.path(tf_dir, sprintf("seqheads_%d_seed%d.pt", g, seed))
      stopifnot(file.copy(from, to, overwrite = TRUE))
      nets <- c(nets, to)
    }
  }
  saved <- list(variant = "seqheads", test_game = g, val_game = a$val_game, rows = a$rows, prob = avg2(a, b, "prob"),
                heads = avg2(a, b, "heads"), att = avg2(a, b, "att"), curves = rbind(a$curves, b$curves),
                best = rbind(a$best, b$best), seconds = a$seconds + b$seconds, nets = nets, norm = a$norm,
                k_steps = a$k_steps, rules = PAST_ONLY_RULES, screen_ids = L$P$id,
                stopping = list(curve = "main", seeds = 1:4, settings = SETTINGS), val_rows = a$val_rows,
                val_prob = avg2(a, b, "val_prob"), promoted_from = src_dir,
                switch_part = list(inputs = a$personnel$sw_cols, positions = "hard", source = "28_fold_positions.R"))
  saveRDS(saved, file.path(tf_dir, sprintf("seqheads_%d.rds", g)))
  cat("fold", g, "promoted: best epochs", paste(saved$best$epoch, collapse = "/"), "\n")
}

# The groups the switch part reads, per held-out game (four screen players, 0/1), for checks that rerun the networks.
saveRDS(list(pos = lapply(PI$pos_hard, function(a) a[, 1:4, , drop = FALSE]), cols = PI$pos_cols, screen_ids = PI$screen_ids,
             rules = PI$rules, slots = c("handler", "screener", "handler's defender", "screener's defender")),
        file.path(cache_dir, "positions_live.rds"))
cat("Wrote", file.path(cache_dir, "positions_live.rds"), "\n")
