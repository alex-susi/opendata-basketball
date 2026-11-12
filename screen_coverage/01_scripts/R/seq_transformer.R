# The time-aware screen-coverage transformer with two linked heads.
#
# Input: for each of the ten players, nine steps of history (now, 0.2 s ago, ..., 1.6 s ago), each step a row of
# movement features (02_build_sequences.R). Two kinds of attention, both the hand-written layer from the kickout
# exercise (kickout_transformer/01_scripts/R/transformer.R):
#   1. along time, within each player: his "now" row looks back over his own last 1.6 s (speeding up, turning,
#      sliding below the screener, how long he has held a level)
#   2. across players: the ten "now" rows, each already carrying its player's recent past, attend to each other
# The four screen players' rows are then read side by side with the context (time to act, the defense's earlier
# calls, closeness, and the memory of contact) and turned into three numbers:
#   switch        is it a switch?
#   under         if not a switch: did the ball defender go under (vs over)?
#   show          if not a switch: did the big show (vs soft)?
# The five joint calls follow: over + show = (1 - p_switch) x (1 - p_under) x p_show, and so on; switch = p_switch.
# So the two defenders' calls share the switch decision and "under + show" borrows from every under and every show.

suppressPackageStartupMessages(library(torch))
source(file.path(root, "kickout_transformer", "01_scripts", "R", "transformer.R"))     # attention_layer(); needs `root`

ROLE_OF_ROW <- c(1L, 2L, 3L, 4L, 5L, 5L, 5L, 6L, 6L, 6L)   # handler, screener, their defenders, other O, other D

# initialize: embeddings for features, history step and role; attention along time and across players; the head.
seq_heads_transformer <- nn_module(initialize = function(n_feat, n_ctx, n_steps = 9L, d_model = 32, n_heads = 4, n_time_layers = 1L,
                                                         n_player_layers = 2L, d_ff = 64, dropout = 0.2) {
                                     self$embed <- nn_linear(n_feat, d_model)
                                     self$step_emb <- nn_embedding(n_steps, d_model)
                                     self$role_emb <- nn_embedding(6L, d_model)
                                     self$time_layers <- nn_module_list(lapply(seq_len(n_time_layers), function(i) attention_layer(d_model, n_heads, d_ff, dropout)))
                                     self$player_layers <- nn_module_list(lapply(seq_len(n_player_layers), function(i) attention_layer(d_model, n_heads, d_ff, dropout)))
                                     self$norm <- nn_layer_norm(d_model)
                                     self$head <- nn_sequential(nn_linear(4 * d_model + n_ctx, 64), nn_relu(), nn_dropout(dropout), nn_linear(64, 3))
                                     self$steps <- n_steps
                                   },
                                   # x: [B, 10 players, 9 steps, n_feat] (step 1 = now); ctx: [B, n_ctx]
                                   forward = function(x, ctx, return_attention = FALSE) {
                                     B <- x$size(1)
                                     Pn <- x$size(2)
                                     Tn <- x$size(3)
                                     # Each (player, step) row: its features plus embeddings of the step and of the
                                     # player's role.
                                     h <- self$embed(x) + self$step_emb(torch_tensor(seq_len(Tn), dtype = torch_long()))$view(c(1, 1, Tn, -1))
                                     h <- h + self$role_emb(torch_tensor(ROLE_OF_ROW, dtype = torch_long()))$view(c(1, Pn, 1, -1))
                                     # Attention along time, one player at a time.
                                     h <- h$reshape(c(B * Pn, Tn, -1))
                                     for (i in seq_along(self$time_layers)) h <- self$time_layers[[i]](h)$x
                                     h <- h[, 1, ]$reshape(c(B, Pn, -1))                       # each player's "now" row, after looking back
                                     ws <- list()
                                     # Attention across the ten players.
                                     for (i in seq_along(self$player_layers)) {
                                       o <- self$player_layers[[i]](h)
                                       h <- o$x
                                       ws[[i]] <- o$w
                                     }
                                     rows <- self$norm(h)[, 1:4, ]$flatten(start_dim = 2)
                                     logits <- self$head(torch_cat(list(rows, ctx), dim = 2))   # [B, 3]: switch, under, show
                                     if (return_attention) list(logits = logits, attention = ws) else logits
                                   })

#' Log probability of each of the five joint calls (over + show, over + soft, under + soft, under + show, switch).
joint_logp <- function(logits) {
  ls <- nnf_logsigmoid(logits[, 1])
  lns <- nnf_logsigmoid(-logits[, 1])
  lu <- nnf_logsigmoid(logits[, 2])
  lo <- nnf_logsigmoid(-logits[, 2])
  lsh <- nnf_logsigmoid(logits[, 3])
  lsf <- nnf_logsigmoid(-logits[, 3])
  torch_stack(list(lns + lo + lsh, lns + lo + lsf, lns + lu + lsf, lns + lu + lsh, ls), dim = 2)
}
