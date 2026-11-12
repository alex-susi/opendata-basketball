## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 3: train the live time-aware, two-head transformer, leave-one-game-out.
#   Rscript screen_coverage/01_scripts/03_train_transformer.R --fold=<gameId> [--force]
#
# Needs 01_logistic_baseline.R and 02_build_sequences.R. It is never told when the screen comes; it sees each player's
# last 1.6 s (nine steps, R/seq_transformer.R) and the screen-level context (time to act, the defense's earlier calls,
# closeness, and the memory of contact: the closest the handler has been to the screener over the last 2 s, and how
# long ago).
#
# Training: the next game in order is the validation game, eight games train; each epoch
# draws 3 random prediction frames per training screen; early stopping on the validation game (every third frame);
# two random starts averaged. Standardisation uses the training screens only. Each player's history is mirrored with
# the prediction frame so that the screener is on the y >= 0 side then.
#
# Writes screen_coverage/02_cache/tf/seqheads_<gameId>.rds: for the test game's rows (in the row order of
# logistic_per_frame.rds) the five joint-call probabilities, the three head probabilities (switch, under | not
# switch, show | not switch), the four screen rows' attention across players (last layer, heads averaged), the
# training curves, the standardisation, and the rules the inputs were built under; and the trained networks,
# tf/seqheads_<gameId>_seed<k>.pt, so that 05_test_past_only.R can rerun a prediction from changed inputs.
# Since 2026-11-12 the inputs are past-only (R/past_only.R) and the defense's calls so far use an even-split prior.
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
cache_dir <- file.path(root, "screen_coverage", "02_cache")
out_path <- file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", FOLD))
if (file.exists(out_path) && !"--force" %in% commandArgs(TRUE)) quit(save = "no")





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Training: random starts averaged, epoch cap, early-stopping patience, batch size, learning rate, weight decay.
N_SEEDS <- 2L
MAX_EPOCHS <- 150L
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
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
if (!identical(L$rules, PAST_ONLY_RULES) || !identical(SQ$rules, PAST_ONLY_RULES) || !identical(SQ$screen_ids, L$P$id)) {
  stop("Inputs were built under other rules or for other screens: rerun 01_logistic_baseline.R and 02_build_sequences.R")
}
X <- L$X
CALLS <- L$calls
base <- SQ$base
NS <- dim(base)[1]
NB <- dim(base)[2]
NF <- dim(base)[4]
flat <- matrix(base, nrow = NS * NB)                      # row (b - 1) * NS + s, columns player-major within feature
y_all <- match(X$call, CALLS)
ctx_all <- SQ$ctx

# Leave one game out: the fold's game is the test set, the next game in order validates, the other eight train.
games <- sort(unique(X$game_id))
val_g <- games[(match(FOLD, games) %% length(games)) + 1L]
tr <- which(!X$game_id %in% c(FOLD, val_g))
va <- which(X$game_id == val_g & X$off %% EVERY == 0L)
te <- which(X$game_id == FOLD)
tr_by_screen <- split(tr, X$idx[tr])

#' Raw history [n, 10, 9, NF] for prediction rows r: steps now, -0.2 s, ..., -1.6 s, mirrored per row
#' (R/past_only.R, seq_history).
history <- function(r) seq_history(flat, NS, X$idx[r], X$off[r], K_STEPS, SQ$base_offs, SQ$step)





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
mu_t <- torch_tensor(mu)
sd_t <- torch_tensor(sdv)
# Model inputs for prediction rows r: standardised histories and context. The validation inputs are built once.
as_x <- function(r) (torch_tensor(history(r)) - mu_t) / sd_t
cmu <- colMeans(ctx_all[tr, ])
csd <- apply(ctx_all[tr, ], 2, sd)
csd[csd < 1e-6] <- 1
as_c <- function(r) torch_tensor(scale(ctx_all[r, , drop = FALSE], cmu, csd))
Xva <- as_x(va)
Cva <- as_c(va)
Yva <- torch_tensor(y_all[va], dtype = torch_long())





## ═════════════════════════════════════════════════════════════════════════════
## 04 - TRAINING ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Loss: mean negative log probability of the true joint call. Each random start's best network is saved here.
nll <- function(logits, yy) -joint_logp(logits)$gather(2, yy$unsqueeze(2))$mean()
net_path <- function(seed) file.path(cache_dir, "tf", sprintf("seqheads_%d_seed%d.pt", FOLD, seed))

t0 <- Sys.time()
# One random start: train with early stopping on the validation game, then predict the test game with the best weights.
fit_seed <- function(seed) {
  torch_manual_seed(seed)
  set.seed(seed)
  net <- seq_heads_transformer(n_feat = NF, n_ctx = ncol(ctx_all), n_steps = K_STEPS)
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
      loss <- nll(net(as_x(b), as_c(b)), torch_tensor(y_all[b], dtype = torch_long()))
      opt$zero_grad()
      loss$backward()
      opt$step()
      tot <- tot + loss$item() * length(b)
    }
    # Validation loss: keep the best epoch's weights and stop after PATIENCE epochs without improvement.
    net$eval()
    vl <- with_no_grad(nll(net(Xva, Cva), Yva)$item())
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
    o <- with_no_grad(net(as_x(r), as_c(r), return_attention = TRUE))
    w <- as_array(o$attention[[length(o$attention)]])
    list(prob = as_array(joint_logp(o$logits)$exp()), heads = as_array(torch_sigmoid(o$logits)),
         att = apply(w[, , 1:4, , drop = FALSE], c(1, 4), mean))
  })
  list(prob = do.call(rbind, lapply(parts, `[[`, "prob")), heads = do.call(rbind, lapply(parts, `[[`, "heads")),
       att = do.call(rbind, lapply(parts, `[[`, "att")), curve = rbindlist(curve), best_ep = best_ep, best_val = best)
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - AVERAGE THE RANDOM STARTS AND SAVE -------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

fits <- lapply(seq_len(N_SEEDS), fit_seed)
avg <- function(k) Reduce(`+`, lapply(fits, `[[`, k)) / N_SEEDS
saveRDS(list(variant = "seqheads", test_game = FOLD, val_game = val_g, rows = te, prob = avg("prob"), heads = avg("heads"),
             att = avg("att"), curves = rbindlist(lapply(fits, `[[`, "curve")),
             best = data.table(seed = seq_len(N_SEEDS), epoch = vapply(fits, `[[`, 0L, "best_ep"), val_logloss = vapply(fits, `[[`, 0, "best_val")),
             seconds = as.numeric(Sys.time() - t0, units = "secs"), nets = vapply(seq_len(N_SEEDS), net_path, ""),
             norm = list(mu = mu, sdv = sdv, cmu = cmu, csd = csd), k_steps = K_STEPS, rules = PAST_ONLY_RULES,
             screen_ids = L$P$id), out_path)
message(sprintf("seqheads fold %d: best epochs %s, val log loss %s, %.0f s", FOLD,
                paste(vapply(fits, `[[`, 0L, "best_ep"), collapse = "/"),
                paste(round(vapply(fits, `[[`, 0, "best_val"), 3), collapse = "/"), as.numeric(Sys.time() - t0, units = "secs")))
