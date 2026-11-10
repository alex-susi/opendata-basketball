# Step 3: train the transformer, leave-one-game-out, exactly like the baselines.
#   Rscript src/kickout_transformer/03_train_transformer.R --model=freeze [--fold=114243] [--force]
#   Rscript src/kickout_transformer/03_train_transformer.R --model=hist   [--fold=114243] [--force]
#
#   freeze  tokens describe the ten players at the catch only (13 numbers each)
#   hist    the same plus each player's displacement over the last second (21 numbers each)
#
# For each held-out (test) game: one other game is set aside as a validation game, the model trains on the
# remaining eight, and training stops when the validation log loss has not improved for PATIENCE epochs (the
# weights from the best epoch are kept). This is repeated with N_SEEDS random starts and the probabilities are
# averaged. The test game is never seen until the final prediction.
#
# Left/right mirroring: a play and its mirror image (y -> -y) should lead to the same decision, so each training
# batch flips a random half of its plays. That doubles the variety of plays the model sees.
#
# Writes one file per test game: outputs/cache/kickout_transformer/tf_{model}_{game}.rds with the predictions,
# the receiver's attention weights, the training curves, and the seed-1 model (tf_{model}_{game}.pt).

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
source(file.path(root, "src", "kickout_transformer", "R", "transformer.R"))
torch_set_num_threads(1L)

arg <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), commandArgs(TRUE), value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
MODEL <- arg("model", "freeze")
FOLD <- arg("fold")
FORCE <- "--force" %in% commandArgs(TRUE)

N_SEEDS <- 3L
MAX_EPOCHS <- 200L
PATIENCE <- 25L
BATCH <- 64L
LR <- 1e-3
WD <- 1e-2
CTX_FEATS <- c("time_to_act", "kickout", "from_paint")   # play-level facts, joined to the receiver row before the head

d <- kt_load_catches(paths)
m <- d$meta
tokens <- if (MODEL == "freeze") d$freeze else d$hist
feats <- dimnames(tokens)[[3]]
y_feats <- which(feats %in% c("y", "vy", "rel_y") | grepl("^dy_", feats))      # change sign under a mirror
ctx_all <- as.matrix(m[, ..CTX_FEATS]) * 1
y_all <- match(m$label, CLASSES)
games <- sort(unique(m$game_id))

run_fold <- function(g) {
  out_path <- file.path(paths$cache, sprintf("tf_%s_%s.rds", MODEL, g))
  if (file.exists(out_path) && !FORCE) return(invisible(readRDS(out_path)))
  t0 <- Sys.time()
  val_g <- games[(match(g, games) %% length(games)) + 1L]
  tr <- which(!m$game_id %in% c(g, val_g)); va <- which(m$game_id == val_g); te <- which(m$game_id == g)

  # standardise with training rows only; mirrored features keep a centre of 0 so a flip stays a flip
  flat <- matrix(tokens[tr, , ], ncol = length(feats))
  mu <- colMeans(flat); sdv <- apply(flat, 2, sd); sdv[sdv < 1e-6] <- 1; mu[y_feats] <- 0
  cmu <- colMeans(ctx_all[tr, , drop = FALSE]); csd <- apply(ctx_all[tr, , drop = FALSE], 2, sd); csd[csd < 1e-6] <- 1
  mu_t <- torch_tensor(mu); sd_t <- torch_tensor(sdv)
  as_x <- function(i) (torch_tensor(tokens[i, , , drop = FALSE]) - mu_t) / sd_t
  as_c <- function(i) torch_tensor(scale(ctx_all[i, , drop = FALSE], cmu, csd))
  Xva <- as_x(va); Cva <- as_c(va); Yva <- torch_tensor(y_all[va], dtype = torch_long())
  Xte <- as_x(te); Cte <- as_c(te)
  raw_tr <- torch_tensor(tokens[tr, , , drop = FALSE]); Ctr <- as_c(tr); Ytr <- torch_tensor(y_all[tr], dtype = torch_long())

  fit_seed <- function(seed) {
    torch_manual_seed(seed); set.seed(seed)
    net <- kickout_transformer(n_feat = length(feats), n_ctx = length(CTX_FEATS), n_class = length(CLASSES))
    opt <- optim_adamw(net$parameters, lr = LR, weight_decay = WD)
    best <- Inf; best_state <- NULL; best_ep <- 0L; curve <- list()
    for (ep in seq_len(MAX_EPOCHS)) {
      net$train()
      idx <- sample(length(tr))
      tot <- 0
      batches <- split(idx, ceiling(seq_along(idx) / BATCH))
      nb <- length(batches)
      if (nb > 1 && length(batches[[nb]]) == 1) {          # a one-catch batch loses a dimension in torch: merge it
        batches[[nb - 1]] <- c(batches[[nb - 1]], batches[[nb]]); batches[[nb]] <- NULL
      }
      for (b in batches) {
        sgn <- matrix(1, length(b), length(feats))
        sgn[runif(length(b)) < 0.5, y_feats] <- -1
        xb <- (raw_tr[b, , ] * torch_tensor(sgn)$unsqueeze(2) - mu_t) / sd_t
        loss <- nnf_cross_entropy(net(xb, Ctr[b, ]), Ytr[b])
        opt$zero_grad(); loss$backward(); opt$step()
        tot <- tot + loss$item() * length(b)
      }
      net$eval()
      vl <- with_no_grad(nnf_cross_entropy(net(Xva, Cva), Yva)$item())
      curve[[ep]] <- data.table(seed = seed, epoch = ep, train = tot / length(tr), val = vl)
      if (vl < best - 1e-4) {
        best <- vl; best_ep <- ep
        best_state <- lapply(net$state_dict(), function(t) t$clone())
      } else if (ep - best_ep >= PATIENCE) break
    }
    net$load_state_dict(best_state)
    net$eval()
    o <- with_no_grad(net(Xte, Cte, return_attention = TRUE))
    prob <- as_array(nnf_softmax(o$logits, dim = 2))
    # receiver's attention row in every layer: [test catches, layer, head, 10 tokens]
    att <- simplify2array(lapply(o$attention, function(w) as_array(w[, , 1, ])))      # [n, h, 10, L]
    att <- aperm(att, c(1, 4, 2, 3))
    if (seed == 1L) torch_save(net, file.path(paths$cache, sprintf("tf_%s_%s.pt", MODEL, g)))
    list(prob = prob, att = att, curve = rbindlist(curve), best_ep = best_ep, best_val = best)
  }

  fits <- lapply(seq_len(N_SEEDS), fit_seed)
  prob <- Reduce(`+`, lapply(fits, `[[`, "prob")) / N_SEEDS
  att <- Reduce(`+`, lapply(fits, `[[`, "att")) / N_SEEDS
  out <- list(model = MODEL, test_game = g, val_game = val_g,
              pred = pred_table(m$row[te], paste0("transformer_", MODEL), prob),
              attention = att, curves = rbindlist(lapply(fits, `[[`, "curve")),
              best = data.table(seed = seq_len(N_SEEDS), epoch = vapply(fits, `[[`, 0L, "best_ep"),
                                val_logloss = vapply(fits, `[[`, 0, "best_val")),
              n_params = sum(vapply(kickout_transformer(length(feats), length(CTX_FEATS), n_class = length(CLASSES))$parameters, function(p) p$numel(), 0)),
              mu = mu, sd = sdv, ctx_mu = cmu, ctx_sd = csd, feats = feats, seconds = as.numeric(Sys.time() - t0, units = "secs"))
  saveRDS(out, out_path)
  message(sprintf("%s fold %s: best epochs %s, val log loss %s, %.0f s", MODEL, g,
                  paste(out$best$epoch, collapse = "/"), paste(round(out$best$val_logloss, 3), collapse = "/"),
                  out$seconds))
  invisible(out)
}

for (g in if (is.null(FOLD)) games else as.integer(FOLD)) run_fold(g)
