## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 34: freeze the live model as a release (coverage product plan, Phase 2, 2026-11-21).
#   Rscript screen_coverage/01_scripts/34_freeze_release.R
#
# Copies everything the live screen-coverage model needs into one dated release folder, records how it was built,
# and checks that its saved probabilities can be rebuilt from its saved networks. Nothing the live site or the
# pipeline reads is changed.
#
#   1. Copy the live fold files and networks (02_cache/tf/), the inputs they were trained and scored on
#      (logistic_per_frame.rds, sequences.rds, per_frame_features.rds), the position groups the switch part reads
#      (positions_live.rds, experiments/personnel/inputs.rds and positions_by_fold.rds) and the site's coverage
#      files (web/public/data/coverage_*.json) into 02_cache/releases/<RELEASE_ID>/, and mark the copies read-only.
#      A rerun finds the folder in place, copies nothing and checks every file against the recorded hash instead.
#   2. Record the commit, R and package versions, the past-only rules, label order, prediction offsets, history,
#      feature and context names, every fold's test / validation / training games, starts, best epochs,
#      standardisation and switch-part inputs, and a SHA-256 hash of every file.
#   3. Rerun every fold's four saved networks on all of its held-out rows and compare with the saved probabilities.
#   4. If a one-start retrain of fold 184439 exists (section 05 gives the command), compare it with the release's
#      start-1 network weight by weight; writes repro_retrain.csv.
#
# Writes 02_cache/releases/<RELEASE_ID>/ (the copies and manifest.json) and, for the repository,
# screen_coverage/03_outputs/releases/<RELEASE_ID>/: manifest.json, files.csv (path, bytes, hash), folds.csv,
# cohort_ids.csv (the 1,463 scored screens) and repro_probabilities.csv (per fold, largest difference between rerun
# and saved probabilities). Stops if any copy, hash or rerun check fails.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "seq_transformer.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
torch_set_num_threads(1L)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The live model promoted on 2026-11-19 (33_promote_switch_positions.R): position groups in the switch part.
RELEASE_ID <- "live_2026-11-19_switch_positions"
cache_dir <- file.path(root, "screen_coverage", "02_cache")
rel_dir <- file.path(cache_dir, "releases", RELEASE_ID)
out_dir <- file.path(root, "screen_coverage", "03_outputs", "releases", RELEASE_ID)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Largest allowed gap between rerun and saved probabilities (the same networks on the same inputs).
TOL <- 1e-6

# The files to freeze, as paths relative to the repository root. Each is copied to the same relative place inside
# the release folder (02_cache/ is dropped from the front).
tf_files <- list.files(file.path(cache_dir, "tf"), "^seqheads_[0-9]+(_seed[0-9]+[.]pt|[.]rds)$")
SOURCES <- c(file.path("screen_coverage", "02_cache", "tf", tf_files),
             file.path("screen_coverage", "02_cache", c("positions_live.rds", "logistic_per_frame.rds", "sequences.rds",
                                                         "per_frame_features.rds")),
             file.path("screen_coverage", "02_cache", "experiments", "personnel", c("inputs.rds", "positions_by_fold.rds")),
             file.path("web", "public", "data", c("coverage_frames.json", "coverage_attention.json", "coverage_lanes.json")))
stopifnot(length(tf_files) == 50L)
release_path <- function(src) file.path(rel_dir, sub("^screen_coverage/02_cache/", "", src))
sha256 <- function(path) digest::digest(file = path, algo = "sha256")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - COPY OR CHECK THE RELEASE ----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

src_hash <- vapply(file.path(root, SOURCES), sha256, "")
files <- data.table(path = SOURCES,
                    release_path = sub(paste0("^", root, "/"), "", release_path(SOURCES)),
                    bytes = file.size(file.path(root, SOURCES)),
                    sha256 = unname(src_hash))
manifest_path <- file.path(rel_dir, "manifest.json")

if (!dir.exists(rel_dir)) {
  # First run: copy, mark read-only, then hash the copies.
  for (k in seq_len(nrow(files))) {
    to <- file.path(root, files$release_path[k])
    dir.create(dirname(to), recursive = TRUE, showWarnings = FALSE)
    stopifnot(file.copy(file.path(root, files$path[k]), to, copy.date = TRUE))
    Sys.chmod(to, "0444")
  }
  cat("Copied", nrow(files), "files to", rel_dir, "\n")
} else {
  cat("Release folder exists; checking the copies against the live files and the recorded hashes\n")
  if (file.exists(manifest_path)) stopifnot(identical(sort(jsonlite::fromJSON(manifest_path)$files$path), sort(files$path)))
}
copy_hash <- vapply(file.path(root, files$release_path), sha256, "")
files[, copy_matches := unname(copy_hash) == sha256]
if (!all(files$copy_matches)) {
  print(files[copy_matches == FALSE])
  stop("Release copies differ from the live files")
}
if (file.exists(manifest_path)) {
  old <- as.data.table(jsonlite::fromJSON(manifest_path)$files)
  chk <- merge(old[, .(path, old = sha256)], files[, .(path, sha256)], by = "path")
  if (any(chk$old != chk$sha256)) {
    print(chk[old != sha256])
    stop("Live files changed since the release was frozen")
  }
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - HOW THE MODEL WAS BUILT ------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- L$X
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
POS <- readRDS(file.path(cache_dir, "positions_live.rds"))
games <- sort(unique(X$game_id))
stopifnot(identical(SQ$screen_ids, L$P$id), identical(POS$screen_ids, L$P$id), identical(L$rules, PAST_ONLY_RULES))

git <- function(...) tryCatch(system2("git", c("-C", shQuote(root), ...), stdout = TRUE), error = function(e) NA_character_)
pkgs <- c("torch", "data.table", "jsonlite", "nnet", "ggplot2", "digest")

# One row per fold: which games it tested, validated and trained on, and how each start stopped.
folds <- rbindlist(lapply(games, function(g) {
  o <- read_fold(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", g)), L)
  stopifnot(!is.null(o$switch_part), identical(o$stopping$seeds, 1:4))
  data.table(test_game = g, val_game = o$val_game, train_games = paste(setdiff(games, c(g, o$val_game)), collapse = " "),
             test_rows = length(o$rows), test_screens = uniqueN(X$idx[o$rows]), seeds = paste(o$best$seed, collapse = " "),
             best_epochs = paste(o$best$epoch, collapse = " "), val_main_logloss = paste(round(o$best$val_logloss, 6), collapse = " "),
             train_seconds = round(o$seconds), promoted_from = sub(paste0("^", root, "/"), "", o$promoted_from))
}))
fwrite(folds, file.path(out_dir, "folds.csv"))

# Each fold's standardisation, kept with its feature names.
norms <- lapply(setNames(games, games), function(g) {
  o <- readRDS(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", g)))
  list(mu = setNames(o$norm$mu, SQ$feats), sdv = setNames(o$norm$sdv, SQ$feats), cmu = as.list(o$norm$cmu), csd = as.list(o$norm$csd))
})
o1 <- readRDS(file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", games[1])))

# The 1,463 scored screens and their four players.
cohort <- L$P[, .(id, game_id, poss, chance, period, f0, call, H, S, BD, SD)]
fwrite(cohort, file.path(out_dir, "cohort_ids.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - RERUN THE SAVED NETWORKS -----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The inputs exactly as 03_train_transformer.R builds them for a fold's held-out rows: the 1.6 s history from
# sequences.rds (seq_history, mirrored per row), standardised with the fold's training means; the context scaled
# with the fold's training means; the four screen players' 0/1 groups for the switch part.
NS <- dim(SQ$base)[1]
flat <- matrix(SQ$base, nrow = NS * dim(SQ$base)[2])
repro <- rbindlist(lapply(games, function(g) {
  o <- readRDS(file.path(rel_dir, "tf", sprintf("seqheads_%d.rds", g)))
  nets <- lapply(file.path(rel_dir, "tf", basename(o$nets)), torch_load)
  for (n in nets) n$eval()
  pa <- POS$pos[[as.character(g)]]
  chunks <- split(o$rows, ceiling(seq_along(o$rows) / 2000))
  prob <- do.call(rbind, lapply(chunks, function(r) {
    h <- seq_history(flat, NS, X$idx[r], X$off[r], o$k_steps, SQ$base_offs, SQ$step, SQ$feats, SQ$flip)
    xt <- standardise_history(h, o$norm)
    ct <- torch_tensor(scale(SQ$ctx[r, , drop = FALSE], o$norm$cmu, o$norm$csd))
    st <- torch_tensor(do.call(cbind, lapply(1:4, function(s) pa[X$idx[r], s, , drop = TRUE])))
    Reduce(`+`, lapply(nets, function(n) as_array(with_no_grad(joint_logp(n(xt, ct, st))$exp())))) / length(nets)
  }))
  d <- abs(prob - o$prob)
  cat(sprintf("fold %d: %d rows, largest difference %.2e\n", g, nrow(d), max(d)))
  data.table(test_game = g, rows = nrow(d), max_abs_diff = max(d), mean_abs_diff = mean(d), row_sums_ok = all(abs(rowSums(prob) - 1) < 1e-5))
}))
fwrite(repro, file.path(out_dir, "repro_probabilities.csv"))
if (any(repro$max_abs_diff > TOL) || !all(repro$row_sums_ok)) stop("Rerun probabilities differ from the saved ones")





## ═════════════════════════════════════════════════════════════════════════════
## 05 - RETRAINING CHECK -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Does training reproduce? When the one-start rerun of RETRAIN_FOLD exists (03_train_transformer.R --fold=184439
# --personnel --positions=hard --pos-into=switch --memory=no --seeds=1 --out-dir=<RETRAIN_DIR>), compare its network
# with the release's start-1 network: best epoch, validation score, every weight, and the held-out probabilities.
RETRAIN_FOLD <- 184439L
RETRAIN_DIR <- file.path(cache_dir, "experiments", "coverage_product", "phase2_repro", "live_seed1")
retrain <- NULL
rt_path <- file.path(RETRAIN_DIR, sprintf("seqheads_%d.rds", RETRAIN_FOLD))
if (file.exists(rt_path)) {
  rt <- readRDS(rt_path)
  lv <- readRDS(file.path(rel_dir, "tf", sprintf("seqheads_%d.rds", RETRAIN_FOLD)))
  a <- torch_load(file.path(RETRAIN_DIR, sprintf("seqheads_%d_seed1.pt", RETRAIN_FOLD)))$state_dict()
  b <- torch_load(file.path(rel_dir, "tf", sprintf("seqheads_%d_seed1.pt", RETRAIN_FOLD)))$state_dict()
  stopifnot(identical(names(a), names(b)))
  w_diff <- max(vapply(names(a), function(k) max(abs(as_array(a[[k]]) - as_array(b[[k]]))), 0))
  # The release's start-1 network alone on the same held-out rows (the fold file only keeps the 4-start average).
  n1 <- torch_load(file.path(rel_dir, "tf", sprintf("seqheads_%d_seed1.pt", RETRAIN_FOLD)))
  n1$eval()
  pa <- POS$pos[[as.character(RETRAIN_FOLD)]]
  p1 <- do.call(rbind, lapply(split(lv$rows, ceiling(seq_along(lv$rows) / 2000)), function(r) {
    h <- seq_history(flat, NS, X$idx[r], X$off[r], lv$k_steps, SQ$base_offs, SQ$step, SQ$feats, SQ$flip)
    st <- torch_tensor(do.call(cbind, lapply(1:4, function(s) pa[X$idx[r], s, , drop = TRUE])))
    as_array(with_no_grad(joint_logp(n1(standardise_history(h, lv$norm), torch_tensor(scale(SQ$ctx[r, , drop = FALSE], lv$norm$cmu, lv$norm$csd)), st))$exp()))
  }))
  retrain <- data.table(fold = RETRAIN_FOLD, seed = 1L, release_best_epoch = lv$best[seed == 1]$epoch, rerun_best_epoch = rt$best$epoch,
                        release_val = lv$best[seed == 1]$val_logloss, rerun_val = rt$best$val_logloss,
                        max_weight_diff = w_diff, max_prob_diff = max(abs(rt$prob - p1)), same_norm = isTRUE(all.equal(rt$norm, lv$norm)),
                        rerun_seconds = round(rt$seconds))
  print(retrain)
  fwrite(retrain, file.path(out_dir, "repro_retrain.csv"))
}





## ═════════════════════════════════════════════════════════════════════════════
## 06 - MANIFEST ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

manifest <- list(
  release_id = RELEASE_ID,
  frozen = format(Sys.time(), "%Y-%m-%d %H:%M %Z"),
  description = paste("Live screen-coverage transformer since 2026-11-19: time-aware, two heads, hard guard / wing / big groups of",
                      "the four screen players in the switch part only, no possession memory, main-curve stopping, 4 starts"),
  promotion_script = "screen_coverage/01_scripts/33_promote_switch_positions.R",
  training_invocation = paste("Rscript screen_coverage/01_scripts/03_train_transformer.R --fold=<game> --personnel --positions=hard",
                              "--pos-into=switch --memory=no --seeds=1,2 (and --seeds=3,4); the two runs average to one four-start model"),
  commit = git("rev-parse", "HEAD"),
  uncommitted = git("status", "--short"),
  r_version = R.version.string,
  packages = as.list(vapply(pkgs, function(p) as.character(packageVersion(p)), "")),
  platform = R.version$platform,
  rules = list(past_only = PAST_ONLY_RULES, max_gap_frames = MAX_GAP, known_after_frames = KNOWN_AFTER, prior_weight = PRIOR_W),
  labels = L$calls,
  prediction_offsets_frames = range(L$offs),
  fps = FPS,
  history = list(steps = o1$k_steps, step_frames = SQ$step, stored_offsets_frames = range(SQ$base_offs)),
  features = SQ$feats,
  mirrored_features = SQ$flip,
  context = colnames(SQ$ctx),
  switch_part_inputs = o1$switch_part$inputs,
  switch_part_slots = POS$slots,
  stopping = o1$stopping,
  window_curves = WINDOW_CURVES,
  cohort = list(screens = nrow(L$P), frame_rows = nrow(X), games = games),
  folds = folds,
  standardisation = norms,
  repro_probabilities = repro,
  repro_retrain = retrain,
  files = files[, .(path, release_path, bytes, sha256)]
)
json <- jsonlite::toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, digits = NA)
writeLines(json, file.path(out_dir, "manifest.json"))
fwrite(files, file.path(out_dir, "files.csv"))
if (!file.exists(manifest_path)) {
  writeLines(json, manifest_path)
  Sys.chmod(manifest_path, "0444")
}
cat("Release", RELEASE_ID, "frozen and checked:", nrow(files), "files, largest rerun difference",
    format(max(repro$max_abs_diff), digits = 3), "\n")
