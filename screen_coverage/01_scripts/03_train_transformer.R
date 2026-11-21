## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 3: train the live time-aware, two-head transformer, leave-one-game-out.
#   Rscript screen_coverage/01_scripts/03_train_transformer.R --fold=<gameId> [--force]
#
# Needs 01_logistic_baseline.R and 02_build_sequences.R. It is never told when the screen comes; it sees each player's
# last 1.6 s (nine steps, R/seq_transformer.R) and the screen-level context (time to act, the defense's earlier calls,
# closeness, and the memory of contact: the closest the handler has been to the screener over the last 2 s, and how
# long ago).
#
# Training: the next game in order is the validation game, eight games train; each epoch draws 3 random prediction
# frames per training screen, evenly across -2 s to +1 s; early stopping on the validation game's log loss weighted
# by the fixed "main" time curve (R/window_weights.R: full weight from -0.9 s to +0.24 s around the pick frame, ramps
# to zero at -1.8 s and +0.5 s), on its every third frame with weight > 0; four random starts averaged (each seeded
# on its own, so separate runs of starts 1-2 and 3-4 average to the same model). Since 2026-11-15; before that the
# stopping score counted every third frame from -2 s to +1 s equally and two starts were averaged (snapshot
# 02_cache/v2_flat_2026-11-12/). Standardisation uses the training screens only. Each player's history is mirrored
# with the prediction frame so that the screener is on the y >= 0 side then. The validation game's predictions at
# every frame are saved with the test game's.
#
# Writes screen_coverage/02_cache/tf/seqheads_<gameId>.rds: for the test game's rows (in the row order of
# logistic_per_frame.rds) the five joint-call probabilities, the three head probabilities (switch, under | not
# switch, show | not switch), the four screen rows' attention across players (last layer, heads averaged), the
# training curves, the standardisation, and the rules the inputs were built under; and the trained networks,
# tf/seqheads_<gameId>_seed<k>.pt, so that 05_test_past_only.R can rerun a prediction from changed inputs.
# Since 2026-11-12 the inputs are past-only (R/past_only.R) and the defense's calls so far use an even-split prior.
#
# Lane experiment (2026-11-15): --variant=A|B|C [--seeds=1,2] trains on
# screen_coverage/02_cache/experiments/lanes/<variant>/sequences.rds (02_build_sequences.R --variant) and writes to
# that folder's tf_s<seeds>/. The roll-lane distance and closing speed are standardised with the valid training
# entries only and set to 0 (in standardised space) wherever their flag is 0. Without --variant nothing changes.
#
# Timing experiment (2026-11-15): --timing=none|physics|learned [--seeds=1,2] trains under the fixed time weights
# (R/window_weights.R, curve "main"): early stopping on the main-curve weighted log loss of the validation game (its
# every third frame with weight > 0), and the validation game's predictions at every frame are saved with the test
# game's. physics / learned add the step-1 time-to-screen inputs of 17_time_to_screen.R for this fold to the context
# (physics: screener time to stop, handler-screener time to meet, and their flags; learned: the median estimate and its
# 10-90% spread); none adds nothing (the current model's settings under the new stopping rule). Writes to
# screen_coverage/02_cache/experiments/timing/<timing>/tf_s<seeds>/. With --extra=hoop_speed (2026-11-15) each player
# also gets his speed toward or away from the hoop as a movement channel; files go to <timing>+hoop_speed/.
#
# Personnel experiment (2026-11-19): --personnel [--seeds=1,2] trains the live model's settings plus the inputs of
# 29_build_personnel.R: each player's guard / wing / big probability as three movement channels (from this fold's
# positions, 28_fold_positions.R, which never saw the test game; 0 when the player is absent; not mirrored) and the
# possession's memory (earlier switch, earlier pick, cross-match) as three context columns. Writes to
# screen_coverage/02_cache/experiments/personnel/tf_s<seeds>/. With --positions=hard (owner, 2026-11-19) each player's
# channels are his most likely group as 0/1 indicators instead of the three probabilities; files go to personnel_hard/.
# With --positions=none (owner, 2026-11-19) there are no position channels, only the memory; files go to personnel_memory/.
#
# --out-dir=<folder> (2026-11-21, coverage product plan): write the fold file and networks to that folder instead
# (relative to the repository root unless absolute), so reruns never land in the live or older experiment folders.
# Everything else is unchanged; the fold file also records the folder and the arguments it was run with.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "seq_transformer.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
torch_set_num_threads(1L)
arg <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), commandArgs(TRUE), value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
FOLD <- as.integer(arg("fold"))
VARIANT <- arg("variant", NA_character_)
TIMING <- arg("timing", NA_character_)
EXTRA <- arg("extra", NA_character_)
PERSONNEL <- "--personnel" %in% commandArgs(TRUE)
POS_FORM <- arg("positions", "soft")
if (!POS_FORM %in% c("soft", "hard", "none")) stop("Unknown --positions: ", POS_FORM)
# --memory=no leaves the possession's memory out (positions only); --pos-players=defenders gives position channels to
# the two screen defenders only (roster slots 3 and 4), the other eight players get zeros.
USE_MEMORY <- arg("memory", "yes") != "no"
POS_PLAYERS <- arg("pos-players", "all")
if (!POS_PLAYERS %in% c("all", "defenders")) stop("Unknown --pos-players: ", POS_PLAYERS)
# --pos-into=switch (owner, 2026-11-19): the four screen players' groups (handler, screener and their defenders, 3 each)
# go into the switch part of the head only, never into the players' movement rows or the coverage part
# (R/seq_transformer.R, n_sw). Default "players": position channels on the players' rows, as in the earlier runs.
POS_INTO <- arg("pos-into", "players")
if (!POS_INTO %in% c("players", "switch")) stop("Unknown --pos-into: ", POS_INTO)
# The split-head control (owner, 2026-11-19): --positions=none --pos-into=switch --memory=no builds the same split
# final layer with nothing added, so the split itself can be judged apart from the positions.
CONTROL <- PERSONNEL && POS_FORM == "none" && POS_INTO == "switch" && !USE_MEMORY
if (PERSONNEL && POS_FORM == "none" && !USE_MEMORY && !CONTROL) stop("--positions=none with --memory=no adds nothing")
if (POS_INTO == "switch" && POS_PLAYERS != "all") stop("--pos-into=switch uses the four screen players")
if (POS_INTO == "switch" && POS_FORM == "none" && !CONTROL) stop("--pos-into=switch with --positions=none is the control: add --memory=no")
# Live and timing runs stop on the main time curve and average four starts; the closed lane experiment keeps the
# flat stopping score and two starts it was run with.
WEIGHTED <- is.na(VARIANT)
SEEDS <- as.integer(strsplit(arg("seeds", if (WEIGHTED) "1,2,3,4" else "1,2"), ",")[[1]])
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
cache_dir <- file.path(root, "screen_coverage", "02_cache")
seq_path <- file.path(cache_dir, "sequences.rds")
tf_dir <- file.path(cache_dir, "tf")
if (!is.na(VARIANT) && !is.na(TIMING)) stop("--variant and --timing are separate experiments")
if (PERSONNEL && (!is.na(VARIANT) || !is.na(TIMING))) stop("--personnel is a separate experiment from --variant and --timing")
if (PERSONNEL) {
  version_dir <- paste0(c(soft = "personnel", hard = "personnel_hard", none = "personnel_memory")[[POS_FORM]],
                        if (POS_PLAYERS == "defenders") "_def" else "", if (POS_INTO == "switch") "_swhead" else "",
                        if (USE_MEMORY) "" else "_nomem")
  if (CONTROL) version_dir <- "split_head_control"
  tf_dir <- file.path(cache_dir, "experiments", version_dir, paste0("tf_s", paste(range(SEEDS), collapse = "-")))
} else if (!is.na(VARIANT)) {
  source(file.path(root, "screen_coverage", "01_scripts", "R", "lane_variants.R"))
  if (!VARIANT %in% names(LANE_VARIANTS)) stop("Unknown --variant: ", VARIANT)
  seq_path <- file.path(lane_dir(root, VARIANT), "sequences.rds")
  tf_dir <- lane_tf_dir(root, VARIANT, SEEDS)
} else if (!is.na(TIMING)) {
  source(file.path(root, "screen_coverage", "01_scripts", "R", "time_to_screen.R"))
  if (!TIMING %in% c("none", "physics", "learned")) stop("Unknown --timing: ", TIMING)
  if (!is.na(EXTRA) && EXTRA != "hoop_speed") stop("Unknown --extra: ", EXTRA)
  version_dir <- if (is.na(EXTRA)) TIMING else paste(TIMING, EXTRA, sep = "+")
  tf_dir <- file.path(cache_dir, "experiments", "timing", version_dir, paste0("tf_s", paste(range(SEEDS), collapse = "-")))
} else if (!identical(SEEDS, 1:4) && !PERSONNEL) stop("--seeds is for the lane, timing and personnel experiments only")
if (!is.na(EXTRA) && is.na(TIMING)) stop("--extra is for the timing experiment only (with --timing)")
OUT_DIR <- arg("out-dir", NA_character_)
if (!is.na(OUT_DIR)) {
  tf_dir <- if (grepl("^([A-Za-z]:)?[/\\\\]", OUT_DIR)) OUT_DIR else file.path(root, OUT_DIR)
  if (normalizePath(tf_dir, winslash = "/", mustWork = FALSE) == normalizePath(file.path(cache_dir, "tf"), winslash = "/", mustWork = FALSE)) {
    stop("--out-dir must not be the live folder 02_cache/tf")
  }
}
cat("Writing to", tf_dir, "\n")
dir.create(tf_dir, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(tf_dir, sprintf("seqheads_%d.rds", FOLD))
if (file.exists(out_path) && !"--force" %in% commandArgs(TRUE)) quit(save = "no")





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Training: random starts averaged (seeds 1 and 2 unless --seeds), epoch cap, early-stopping patience, batch size,
# learning rate, weight decay.
N_SEEDS <- length(SEEDS)
MAX_EPOCHS <- as.integer(arg("max-epochs", "150"))     # lowered only for smoke tests
PATIENCE <- 15L
BATCH <- 128L
LR <- 5e-4
WD <- 5e-2

# Prediction frames drawn per screen each epoch, validation frame spacing, and history steps per player.
FRAMES_PER_EPOCH <- 3L
EVERY <- 3L
K_STEPS <- 9L





## ═════════════════════════════════════════════════════════════════════════════
## 02 - DATA AND FOLDS ---------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Step-1 rows and step-2 histories. `flat` reshapes the base array so that one row is one (frame, screen) pair.
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
SQ <- readRDS(seq_path)
if (!identical(L$rules, PAST_ONLY_RULES) || !identical(SQ$rules, PAST_ONLY_RULES) || !identical(SQ$screen_ids, L$P$id)) {
  stop("Inputs were built under other rules or for other screens: rerun 01_logistic_baseline.R and 02_build_sequences.R")
}
if (!is.na(VARIANT) && (!identical(SQ$variant, VARIANT) || !identical(SQ$feats, lane_feats(VARIANT)))) {
  stop(seq_path, " does not hold variant ", VARIANT, "'s features: rerun 02_build_sequences.R --variant=", VARIANT)
}
X <- L$X
CALLS <- L$calls
base <- SQ$base
# --extra=hoop_speed: one more movement channel per player and frame, his speed away from (+) or toward (-) the
# hoop, from the cached position and 0.2 s velocity (0 when he is absent). It does not change when the history is
# mirrored (the hoop is on y = 0), so it is not in SQ$flip.
if (identical(EXTRA, "hoop_speed")) {
  fx <- base[, , , "x"]
  fy <- base[, , , "y"]
  hv <- -((HOOP_X - fx) * base[, , , "vx"] - fy * base[, , , "vy"]) / pmax(hoop_dist(fx, fy), 1e-6)
  hv[base[, , , "present"] != 1] <- 0
  nm <- c(dimnames(base)[[4]], "hoop_v")
  base <- array(c(base, hv), c(dim(base)[1:3], length(nm)), dimnames = list(NULL, NULL, NULL, nm))
  SQ$feats <- nm
  rm(fx, fy, hv)
}
# --personnel: this fold's guard / wing / big probabilities as three channels per player (the same at every frame, 0
# when he is absent), then the possession's memory as context (below).
if (PERSONNEL) {
  PI <- readRDS(file.path(cache_dir, "experiments", "personnel", "inputs.rds"))
  if (!identical(PI$rules, PAST_ONLY_RULES) || !identical(PI$screen_ids, L$P$id)) stop("inputs.rds is stale: rerun 29_build_personnel.R")
}
# --positions=none leaves the position channels out (memory only).
if (PERSONNEL && POS_FORM != "none" && POS_INTO == "players") {
  pa <- (if (POS_FORM == "hard") PI$pos_hard else PI$pos)[[as.character(FOLD)]]
  if (POS_PLAYERS == "defenders") pa[, -(3:4), ] <- 0
  pres <- base[, , , "present"] == 1
  add <- lapply(seq_along(PI$pos_cols), function(k) {
    # [screens, players, frames] recycles the fold's [screens, players] matrix over frames, then [screens, frames, players].
    v <- aperm(array(pa[, , k], c(dim(base)[1], dim(base)[3], dim(base)[2])), c(1, 3, 2))
    v[!pres] <- 0
    v
  })
  nm <- c(dimnames(base)[[4]], PI$pos_cols)
  base <- array(c(base, unlist(add)), c(dim(base)[1:3], length(nm)), dimnames = list(NULL, NULL, NULL, nm))
  SQ$feats <- nm
  rm(add, pres)
}
NS <- dim(base)[1]
NB <- dim(base)[2]
NF <- dim(base)[4]
flat <- matrix(base, nrow = NS * NB)                      # row (b - 1) * NS + s, columns player-major within feature
y_all <- match(X$call, CALLS)
ctx_all <- SQ$ctx
# Timing experiment: this fold's step-1 inputs, every game estimated by models that never saw it (17_time_to_screen.R).
step1_cols <- character(0)
if (!is.na(TIMING) && TIMING != "none") {
  S1 <- readRDS(file.path(cache_dir, "experiments", "timing", "step1.rds"))
  if (!identical(S1$rules, PAST_ONLY_RULES) || !identical(S1$screen_ids, L$P$id)) stop("step1.rds is stale: rerun 17_time_to_screen.R")
  step1_cols <- if (TIMING == "physics") TTS_PHYSICS else TTS_LEARNED
  ctx_all <- cbind(ctx_all, S1$folds[[as.character(FOLD)]]$m[, step1_cols, drop = FALSE])
}
if (PERSONNEL && USE_MEMORY) ctx_all <- cbind(ctx_all, PI$mem)
# --pos-into=switch: per prediction row, the four screen players' groups from this fold's positions (12 columns, 0/1
# for hard groups), fed to the switch part only. NULL otherwise, and the head is the live one.
sw_all <- NULL
if (PERSONNEL && POS_INTO == "switch" && !CONTROL) {
  pa <-(if (POS_FORM == "hard") PI$pos_hard else PI$pos)[[as.character(FOLD)]]
  sw_all <- do.call(cbind, lapply(1:4, function(s) pa[X$idx, s, , drop = TRUE]))
  colnames(sw_all) <- as.vector(t(outer(c("h", "s", "bd", "sd"), PI$pos_cols, paste, sep = "_")))
}

# Leave one game out: the fold's game is the test set, the next game in order validates, the other eight train.
games <- sort(unique(X$game_id))
val_g <- games[(match(FOLD, games) %% length(games)) + 1L]
tr <- which(!X$game_id %in% c(FOLD, val_g))
va <- which(X$game_id == val_g & X$off %% EVERY == 0L)
te <- which(X$game_id == FOLD)
# Live and timing runs: validation frames are those with weight on the main curve, and the loss is weighted by it.
w_va <- rep(1, length(va))
if (WEIGHTED) {
  va <- which(X$game_id == val_g & X$off %% EVERY == 0L & window_weight(X$off, "main") > 0)
  w_va <- window_weight(X$off[va], "main")
}
va_all <- which(X$game_id == val_g)
tr_by_screen <- split(tr, X$idx[tr])

#' Raw history [n, 10, 9, NF] for prediction rows r: steps now, -0.2 s, ..., -1.6 s, mirrored per row
#' (R/past_only.R, seq_history).
history <- function(r) seq_history(flat, NS, X$idx[r], X$off[r], K_STEPS, SQ$base_offs, SQ$step, SQ$feats, SQ$flip)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - STANDARDISATION --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# standardisation from the training screens (present player-frames only)
tr_s <- unique(X$idx[tr])
pres <- base[tr_s, , , "present"] == 1
mu <- vapply(seq_len(NF), function(f) {
  v <- base[tr_s, , , f]
  mean(v[pres])
}, 0)
sdv <- vapply(seq_len(NF), function(f) {
  v <- base[tr_s, , , f]
  sd(v[pres])
}, 0)
mu[SQ$feats %in% SQ$flip] <- 0
sdv[sdv < 1e-6] <- 1
mu[SQ$feats == "present"] <- 0
sdv[SQ$feats == "present"] <- 1
# Lane experiment: each masked channel (roll distance, closing speed) from its valid training entries only; its flag
# stays 0/1. Invalid entries are set to 0 after standardising (standardise_history, R/seq_transformer.R).
masked <- if (is.null(SQ$masked)) character(0) else SQ$masked
n_valid <- integer(0)
for (f in names(masked)) {
  k <- match(f, SQ$feats)
  ok <- base[tr_s, , , masked[[f]]] == 1
  n_valid[f] <- sum(ok)
  if (!n_valid[f]) stop("No valid training entries for ", f, " in fold ", FOLD)
  v <- base[tr_s, , , k]
  mu[k] <- mean(v[ok])
  sdv[k] <- sd(v[ok])
  if (!is.finite(sdv[k]) || sdv[k] < 1e-6) sdv[k] <- 1
}
for (f in unique(unname(masked))) {
  mu[SQ$feats == f] <- 0
  sdv[SQ$feats == f] <- 1
}
if (length(masked)) cat("Valid training entries:", paste(names(n_valid), n_valid, sep = " = ", collapse = ", "), "\n")
norm_x <- list(mu = mu, sdv = sdv, feats = SQ$feats, masked = masked)
# Model inputs for prediction rows r: standardised histories and context. The validation inputs are built once.
as_x <- function(r) standardise_history(history(r), norm_x)
cmu <- colMeans(ctx_all[tr, ])
csd <- apply(ctx_all[tr, ], 2, sd)
csd[csd < 1e-6] <- 1
as_c <- function(r) torch_tensor(scale(ctx_all[r, , drop = FALSE], cmu, csd))
# The switch part's position inputs (0/1, not standardised), or NULL for the live head.
as_s <- function(r) if (is.null(sw_all)) NULL else torch_tensor(sw_all[r, , drop = FALSE])
Xva <- as_x(va)
Cva <- as_c(va)
Sva <- as_s(va)
Yva <- torch_tensor(y_all[va], dtype = torch_long())
Wva <- torch_tensor(w_va / sum(w_va))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - TRAINING ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Loss: mean negative log probability of the true joint call. Each random start's best network is saved here.
nll <- function(logits, yy) -joint_logp(logits)$gather(2, yy$unsqueeze(2))$mean()
# Validation loss: weighted by the time curve in the timing experiment (equal weights otherwise, the same as nll).
nll_va <- function(logits) -(joint_logp(logits)$gather(2, Yva$unsqueeze(2))$squeeze(2) * Wva)$sum()
net_path <- function(seed) file.path(tf_dir, sprintf("seqheads_%d_seed%d.pt", FOLD, seed))

t0 <- Sys.time()
# One random start: train with early stopping on the validation game, then predict the test game with the best weights.
fit_seed <- function(seed) {
  torch_manual_seed(seed)
  set.seed(seed)
  net <- seq_heads_transformer(n_feat = NF, n_ctx = ncol(ctx_all), n_steps = K_STEPS, n_sw = if (is.null(sw_all)) 0L else ncol(sw_all),
                               split = PERSONNEL && POS_INTO == "switch")
  opt <- optim_adamw(net$parameters, lr = LR, weight_decay = WD)
  best <- Inf
  best_state <- NULL
  best_ep <- 0L
  curve <- list()
  # Each epoch draws FRAMES_PER_EPOCH fresh frames per training screen and shuffles them into batches.
  for (ep in seq_len(MAX_EPOCHS)) {
    net$train()
    draw <- unlist(lapply(tr_by_screen, function(rr) rr[sample.int(length(rr), FRAMES_PER_EPOCH)]), use.names = FALSE)
    draw <- sample(draw)
    batches <- split(draw, ceiling(seq_along(draw) / BATCH))
    nb <- length(batches)
    # Fold a one-row last batch into the batch before it.
    if (nb > 1 && length(batches[[nb]]) == 1) {
      batches[[nb - 1]] <- c(batches[[nb - 1]], batches[[nb]])
      batches[[nb]] <- NULL
    }
    tot <- 0
    for (b in batches) {
      loss <- nll(net(as_x(b), as_c(b), as_s(b)), torch_tensor(y_all[b], dtype = torch_long()))
      opt$zero_grad()
      loss$backward()
      opt$step()
      tot <- tot + loss$item() * length(b)
    }
    # Validation loss: keep the best epoch's weights and stop after PATIENCE epochs without improvement.
    net$eval()
    vl <- with_no_grad(nll_va(net(Xva, Cva, Sva))$item())
    curve[[ep]] <- data.table(seed = seed, epoch = ep, train = tot / length(draw), val = vl)
    if (vl < best - 1e-4) {
      best <- vl
      best_ep <- ep
      best_state <- lapply(net$state_dict(), function(t) t$clone())
    } else if (ep - best_ep >= PATIENCE) break
  }
  # Predict the test game in chunks of 2,000 rows: joint and per-head probabilities, and the screen four's attention.
  net$load_state_dict(best_state)
  net$eval()
  torch_save(net, net_path(seed))
  chunks <- split(te, ceiling(seq_along(te) / 2000))
  parts <- lapply(chunks, function(r) {
    o <- with_no_grad(net(as_x(r), as_c(r), as_s(r), return_attention = TRUE))
    w <- as_array(o$attention[[length(o$attention)]])
    list(prob = as_array(joint_logp(o$logits)$exp()), heads = as_array(torch_sigmoid(o$logits)),
         att = apply(w[, , 1:4, , drop = FALSE], c(1, 4), mean))
  })
  # Live and timing runs: the validation game's joint-call probabilities at every frame, for selection scores later.
  val_prob <- NULL
  if (WEIGHTED) {
    vchunks <- split(va_all, ceiling(seq_along(va_all) / 2000))
    val_prob <- do.call(rbind, lapply(vchunks, function(r) as_array(with_no_grad(joint_logp(net(as_x(r), as_c(r), as_s(r)))$exp()))))
  }
  list(prob = do.call(rbind, lapply(parts, `[[`, "prob")), heads = do.call(rbind, lapply(parts, `[[`, "heads")),
       att = do.call(rbind, lapply(parts, `[[`, "att")), curve = rbindlist(curve), best_ep = best_ep, best_val = best,
       val_prob = val_prob)
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - AVERAGE THE RANDOM STARTS AND SAVE -------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

fits <- lapply(SEEDS, fit_seed)
avg <- function(k) Reduce(`+`, lapply(fits, `[[`, k)) / N_SEEDS
saved <- list(variant = "seqheads", test_game = FOLD, val_game = val_g, rows = te, prob = avg("prob"), heads = avg("heads"),
              att = avg("att"), curves = rbindlist(lapply(fits, `[[`, "curve")),
              best = data.table(seed = SEEDS, epoch = vapply(fits, `[[`, 0L, "best_ep"), val_logloss = vapply(fits, `[[`, 0, "best_val")),
              seconds = as.numeric(Sys.time() - t0, units = "secs"), nets = vapply(SEEDS, net_path, ""),
              norm = list(mu = mu, sdv = sdv, cmu = cmu, csd = csd), k_steps = K_STEPS, rules = PAST_ONLY_RULES,
              screen_ids = L$P$id)
# Lane experiment: which variant and seeds, its feature axis and masks, and how many valid entries set the scaling.
if (!is.na(VARIANT)) {
  saved$lane <- list(variant = VARIANT, seeds = SEEDS, feats = SQ$feats, masked = masked, n_valid = n_valid,
                     settings = list(MAX_EPOCHS = MAX_EPOCHS, PATIENCE = PATIENCE, BATCH = BATCH, LR = LR, WD = WD,
                                     FRAMES_PER_EPOCH = FRAMES_PER_EPOCH, EVERY = EVERY, K_STEPS = K_STEPS))
  saved$norm$feats <- SQ$feats
  saved$norm$masked <- masked
}
# Live and timing runs: the stopping curve, the starts, and the validation game's predictions. Timing experiment:
# which version, the step-1 columns added and the feature axis.
if (WEIGHTED) {
  saved$stopping <- list(curve = "main", seeds = SEEDS,
                         settings = list(MAX_EPOCHS = MAX_EPOCHS, PATIENCE = PATIENCE, BATCH = BATCH, LR = LR, WD = WD,
                                         FRAMES_PER_EPOCH = FRAMES_PER_EPOCH, EVERY = EVERY, K_STEPS = K_STEPS))
  saved$val_rows <- va_all
  saved$val_prob <- avg("val_prob")
}
if (!is.na(TIMING)) {
  saved$timing <- list(version = TIMING, extra = EXTRA, feats = SQ$feats, seeds = SEEDS, step1_cols = step1_cols,
                       curve = "main", ctx_cols = colnames(ctx_all), settings = saved$stopping$settings)
}
if (PERSONNEL) {
  saved$personnel <- list(positions = POS_FORM, pos_players = POS_PLAYERS, pos_into = POS_INTO, sw_cols = colnames(sw_all), memory = USE_MEMORY, feats = SQ$feats, ctx_cols = colnames(ctx_all), seeds = SEEDS, curve = "main",
                          positions_made = readRDS(file.path(cache_dir, "experiments", "personnel", "positions_by_fold.rds"))$made,
                          settings = saved$stopping$settings)
}
if (!is.na(OUT_DIR)) saved$run <- list(out_dir = tf_dir, args = commandArgs(TRUE))
saveRDS(saved, out_path)
message(sprintf("seqheads fold %d: best epochs %s, val log loss %s, %.0f s", FOLD,
                paste(vapply(fits, `[[`, 0L, "best_ep"), collapse = "/"),
                paste(round(vapply(fits, `[[`, 0, "best_val"), 3), collapse = "/"), as.numeric(Sys.time() - t0, units = "secs")))
