# Screen coverage, step 10: train the time-aware, two-head transformer, leave-one-game-out.
#   Rscript src/screen_coverage/10_train_seq_transformer.R --fold=<gameId> [--force]
#
# Needs 09_build_sequences.R. Like the live "pooled, no timing, + closeness" transformer it is never told when the
# screen comes; it sees each player's last 1.6 s (nine steps, R/seq_transformer.R) and the screen-level context
# (time to act, the defense's earlier calls, closeness, and the memory of contact: the closest the handler has been
# to the screener over the last 2 s, and how long ago).
#
# Training as in 04_train_transformer.R: the next game in order is the validation game, eight games train; each epoch
# draws 3 random prediction frames per training screen; early stopping on the validation game (every third frame);
# two random starts averaged. Standardisation uses the training screens only. Each player's history is mirrored with
# the prediction frame so that the screener is on the y >= 0 side then.
#
# Writes outputs/cache/screen_coverage/tf/seqheads_<gameId>.rds: for the test game's rows (in the row order of
# logistic_per_frame.rds) the five joint-call probabilities, the three head probabilities (switch, under | not
# switch, show | not switch), the four screen rows' attention across players (last layer, heads averaged), and the
# training curves.

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "src", "screen_coverage", "R", "seq_transformer.R"))
torch_set_num_threads(1L)
arg <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), commandArgs(TRUE), value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
FOLD <- as.integer(arg("fold"))
cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
out_path <- file.path(cache_dir, "tf", sprintf("seqheads_%d.rds", FOLD))
if (file.exists(out_path) && !"--force" %in% commandArgs(TRUE)) quit(save = "no")

N_SEEDS <- 2L; MAX_EPOCHS <- 150L; PATIENCE <- 15L; BATCH <- 128L; LR <- 5e-4; WD <- 5e-2
FRAMES_PER_EPOCH <- 3L; EVERY <- 3L; K_STEPS <- 9L

L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
X <- L$X; CALLS <- L$calls
base <- SQ$base; NS <- dim(base)[1]; NB <- dim(base)[2]; NF <- dim(base)[4]
flat <- matrix(base, nrow = NS * NB)                      # row (b - 1) * NS + s, columns player-major within feature
dim_pf <- c(10L, NF)
y_all <- match(X$call, CALLS)
ctx_all <- SQ$ctx
fi <- match(SQ$flip, SQ$feats); yi <- match("y", SQ$feats)

games <- sort(unique(X$game_id))
val_g <- games[(match(FOLD, games) %% length(games)) + 1L]
tr <- which(!X$game_id %in% c(FOLD, val_g)); va <- which(X$game_id == val_g & X$off %% EVERY == 0L); te <- which(X$game_id == FOLD)
tr_by_screen <- split(tr, X$idx[tr])

#' Raw history [n, 10, 9, NF] for prediction rows r: steps now, -0.2 s, ..., -1.6 s, mirrored per row.
history <- function(r) {
  b0 <- match(X$off[r], SQ$base_offs)
  bb <- outer(b0, (seq_len(K_STEPS) - 1L) * SQ$step, `-`)            # [n, 9] base frame index per step
  rows <- (bb - 1L) * NS + X$idx[r]
  a <- flat[as.vector(rows), , drop = FALSE]                           # [n * 9, 10 * NF] (n varies fastest)
  arr <- array(a, c(length(r), K_STEPS, 10L, NF))
  sg <- ifelse(arr[, 1, 2, yi] < 0, -1, 1)
  for (f in fi) arr[, , , f] <- arr[, , , f] * sg
  aperm(arr, c(1, 3, 2, 4))
}

# standardisation from the training screens (present player-frames only)
tr_s <- unique(X$idx[tr])
pres <- base[tr_s, , , "present"] == 1
mu <- vapply(seq_len(NF), function(f) { v <- base[tr_s, , , f]; mean(v[pres]) }, 0)
sdv <- vapply(seq_len(NF), function(f) { v <- base[tr_s, , , f]; sd(v[pres]) }, 0)
mu[SQ$feats %in% SQ$flip] <- 0; sdv[sdv < 1e-6] <- 1
mu[SQ$feats == "present"] <- 0; sdv[SQ$feats == "present"] <- 1
mu_t <- torch_tensor(mu); sd_t <- torch_tensor(sdv)
as_x <- function(r) (torch_tensor(history(r)) - mu_t) / sd_t
cmu <- colMeans(ctx_all[tr, ]); csd <- apply(ctx_all[tr, ], 2, sd); csd[csd < 1e-6] <- 1
as_c <- function(r) torch_tensor(scale(ctx_all[r, , drop = FALSE], cmu, csd))
Xva <- as_x(va); Cva <- as_c(va); Yva <- torch_tensor(y_all[va], dtype = torch_long())

nll <- function(logits, yy) -joint_logp(logits)$gather(2, yy$unsqueeze(2))$mean()

t0 <- Sys.time()
fit_seed <- function(seed) {
  torch_manual_seed(seed); set.seed(seed)
  net <- seq_heads_transformer(n_feat = NF, n_ctx = ncol(ctx_all), n_steps = K_STEPS)
  opt <- optim_adamw(net$parameters, lr = LR, weight_decay = WD)
  best <- Inf; best_state <- NULL; best_ep <- 0L; curve <- list()
  for (ep in seq_len(MAX_EPOCHS)) {
    net$train()
    draw <- unlist(lapply(tr_by_screen, function(rr) rr[sample.int(length(rr), FRAMES_PER_EPOCH)]), use.names = FALSE)
    draw <- sample(draw)
    batches <- split(draw, ceiling(seq_along(draw) / BATCH))
    nb <- length(batches)
    if (nb > 1 && length(batches[[nb]]) == 1) { batches[[nb - 1]] <- c(batches[[nb - 1]], batches[[nb]]); batches[[nb]] <- NULL }
    tot <- 0
    for (b in batches) {
      loss <- nll(net(as_x(b), as_c(b)), torch_tensor(y_all[b], dtype = torch_long()))
      opt$zero_grad(); loss$backward(); opt$step()
      tot <- tot + loss$item() * length(b)
    }
    net$eval()
    vl <- with_no_grad(nll(net(Xva, Cva), Yva)$item())
    curve[[ep]] <- data.table(seed = seed, epoch = ep, train = tot / length(draw), val = vl)
    if (vl < best - 1e-4) { best <- vl; best_ep <- ep; best_state <- lapply(net$state_dict(), function(t) t$clone()) }
    else if (ep - best_ep >= PATIENCE) break
  }
  net$load_state_dict(best_state); net$eval()
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
fits <- lapply(seq_len(N_SEEDS), fit_seed)
avg <- function(k) Reduce(`+`, lapply(fits, `[[`, k)) / N_SEEDS
saveRDS(list(variant = "seqheads", test_game = FOLD, val_game = val_g, rows = te, prob = avg("prob"), heads = avg("heads"),
             att = avg("att"), curves = rbindlist(lapply(fits, `[[`, "curve")),
             best = data.table(seed = seq_len(N_SEEDS), epoch = vapply(fits, `[[`, 0L, "best_ep"), val_logloss = vapply(fits, `[[`, 0, "best_val")),
             seconds = as.numeric(Sys.time() - t0, units = "secs")), out_path)
message(sprintf("seqheads fold %d: best epochs %s, val log loss %s, %.0f s", FOLD,
                paste(vapply(fits, `[[`, 0L, "best_ep"), collapse = "/"),
                paste(round(vapply(fits, `[[`, 0, "best_val"), 3), collapse = "/"), as.numeric(Sys.time() - t0, units = "secs")))
