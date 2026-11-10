# Screen coverage, step 4: train the transformer versions of the four step-2 models, leave-one-game-out.
#   Rscript src/screen_coverage/04_train_transformer.R --variant=timed|arch|pooled|close --fold=<gameId> [--force]
#
# The four variants mirror the logistic models. All see the same ten player tokens (03_build_tokens.R: the four of the
# screen in rows 1-4, the other six in rows 5-10; the logistic models saw only the four) and the same
# context columns as their logistic counterpart:
#   timed    "4 players + so far"     context: shot clock, defense so far, AND the seconds to the screen tag
#   arch     "+ archetypes"           as timed, plus the ball handler's and screener's archetype indicators
#   pooled   "pooled, no timing"      context: shot clock, defense so far; never told when the screen comes
#   close    "pooled, no timing, + closeness"   as pooled, plus the closeness weight 1 / (1 + handler-screener ft / 5)
# The logistic "4 players + so far" and "+ archetypes" are 76 separate models, one per frame. A transformer per frame
# would have only ~1,300 screens to learn ~25,000 weights from, so the timed transformers are one network each that is
# GIVEN the time to the screen as an input: the same knowledge, learned once and shared across frames.
#
# Training. For the held-out (test) game, the next game in order is the validation game and the other eight train.
# Neighbouring frames are near copies, so an epoch does not show every frame: it draws FRAMES_PER_EPOCH random frames
# of each training screen (a different draw each epoch), so every screen counts the same and the network cannot
# memorise a screen within one pass. Validation uses every third frame of the validation game. Training stops when
# the validation log loss has not improved for PATIENCE epochs, keeping the best epoch. N_SEEDS random starts are averaged. The test game's
# screens are then predicted at every frame. Standardisation uses the training rows only.
#
# Writes outputs/cache/screen_coverage/tf/<variant>_<gameId>.rds (probabilities for the test game's rows, in the
# row order of logistic_per_frame.rds, plus training curves).

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "src", "screen_coverage", "R", "transformer.R"))
torch_set_num_threads(1L)

arg <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), commandArgs(TRUE), value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
VARIANT <- arg("variant", "close")
FOLD <- as.integer(arg("fold"))
FORCE <- "--force" %in% commandArgs(TRUE)
cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")
tf_dir <- file.path(cache_dir, "tf")
dir.create(tf_dir, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(tf_dir, sprintf("%s_%d.rds", VARIANT, FOLD))
if (file.exists(out_path) && !FORCE) quit(save = "no")

N_SEEDS <- 2L
MAX_EPOCHS <- 150L
PATIENCE <- 15L
BATCH <- 128L
LR <- 5e-4
WD <- 5e-2
DROPOUT <- 0.2
FRAMES_PER_EPOCH <- 3L
EVERY <- 3L

L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
TK <- readRDS(file.path(cache_dir, "tokens.rds"))
X <- L$X; CALLS <- L$calls
base_ctx <- c("sc_now", paste0("lsf_", 1:5))
CTX <- switch(VARIANT,
              timed = c(base_ctx, "t"),
              arch = c(base_ctx, "t", TK$arch_cols),
              pooled = base_ctx,
              close = c(base_ctx, "closeness"),
              stop("unknown variant ", VARIANT))
ctx_all <- TK$ctx[, CTX, drop = FALSE]
tok_all <- TK$tok
y_all <- match(X$call, CALLS)

games <- sort(unique(X$game_id))
val_g <- games[(match(FOLD, games) %% length(games)) + 1L]
thin <- X$off %% EVERY == 0L
tr <- which(!X$game_id %in% c(FOLD, val_g))                 # all frames of the training screens (drawn from below)
tr_by_screen <- split(tr, X$idx[tr])
va <- which(X$game_id == val_g & thin)
te <- which(X$game_id == FOLD)

nf <- dim(tok_all)[3]
flat <- matrix(tok_all[tr, , ], ncol = nf)
mu <- colMeans(flat); sdv <- apply(flat, 2, sd); sdv[sdv < 1e-6] <- 1
cmu <- colMeans(ctx_all[tr, , drop = FALSE]); csd <- apply(ctx_all[tr, , drop = FALSE], 2, sd); csd[csd < 1e-6] <- 1
mu_t <- torch_tensor(mu); sd_t <- torch_tensor(sdv)
as_x <- function(i) (torch_tensor(tok_all[i, , , drop = FALSE]) - mu_t) / sd_t
as_c <- function(i) torch_tensor(scale(ctx_all[i, , drop = FALSE], cmu, csd))
Xtr <- as_x(tr); Ctr <- as_c(tr); Ytr <- torch_tensor(y_all[tr], dtype = torch_long())
pos_in_tr <- match(seq_len(nrow(X)), tr)                   # row of X -> its position in Xtr
Xva <- as_x(va); Cva <- as_c(va); Yva <- torch_tensor(y_all[va], dtype = torch_long())
Xte <- as_x(te); Cte <- as_c(te)

t0 <- Sys.time()
fit_seed <- function(seed) {
  torch_manual_seed(seed); set.seed(seed)
  net <- coverage_transformer(n_feat = nf, n_ctx = length(CTX), n_class = length(CALLS), dropout = DROPOUT)
  opt <- optim_adamw(net$parameters, lr = LR, weight_decay = WD)
  best <- Inf; best_state <- NULL; best_ep <- 0L; curve <- list()
  for (ep in seq_len(MAX_EPOCHS)) {
    net$train()
    draw <- unlist(lapply(tr_by_screen, function(rr) rr[sample.int(length(rr), FRAMES_PER_EPOCH)]), use.names = FALSE)
    idx <- sample(pos_in_tr[draw])
    batches <- split(idx, ceiling(seq_along(idx) / BATCH))
    nb <- length(batches)
    if (nb > 1 && length(batches[[nb]]) == 1) { batches[[nb - 1]] <- c(batches[[nb - 1]], batches[[nb]]); batches[[nb]] <- NULL }
    tot <- 0
    for (b in batches) {
      loss <- nnf_cross_entropy(net(Xtr[b, , ], Ctr[b, ]), Ytr[b])
      opt$zero_grad(); loss$backward(); opt$step()
      tot <- tot + loss$item() * length(b)
    }
    net$eval()
    vl <- with_no_grad(nnf_cross_entropy(net(Xva, Cva), Yva)$item())
    curve[[ep]] <- data.table(seed = seed, epoch = ep, train = tot / length(idx), val = vl)
    if (vl < best - 1e-4) {
      best <- vl; best_ep <- ep; best_state <- lapply(net$state_dict(), function(t) t$clone())
    } else if (ep - best_ep >= PATIENCE) break
  }
  net$load_state_dict(best_state)
  net$eval()
  prob <- as_array(with_no_grad(nnf_softmax(net(Xte, Cte), dim = 2)))
  list(prob = prob, curve = rbindlist(curve), best_ep = best_ep, best_val = best)
}
fits <- lapply(seq_len(N_SEEDS), fit_seed)
prob <- Reduce(`+`, lapply(fits, `[[`, "prob")) / N_SEEDS
saveRDS(list(variant = VARIANT, test_game = FOLD, val_game = val_g, rows = te, prob = prob, ctx = CTX,
             curves = rbindlist(lapply(fits, `[[`, "curve")),
             best = data.table(seed = seq_len(N_SEEDS), epoch = vapply(fits, `[[`, 0L, "best_ep"),
                               val_logloss = vapply(fits, `[[`, 0, "best_val")),
             seconds = as.numeric(Sys.time() - t0, units = "secs")), out_path)
message(sprintf("%s fold %d: best epochs %s, val log loss %s, %.0f s", VARIANT, FOLD,
                paste(vapply(fits, `[[`, 0L, "best_ep"), collapse = "/"),
                paste(round(vapply(fits, `[[`, 0, "best_val"), 3), collapse = "/"), as.numeric(Sys.time() - t0, units = "secs")))
