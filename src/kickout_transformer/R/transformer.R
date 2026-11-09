# A small transformer encoder written out by hand with R torch, so every step of attention is visible.
# Shapes use B = catches in a batch, T = tokens (10 players), d = width of each token's vector,
# h = attention heads, dk = d / h = width of one head.

suppressPackageStartupMessages(library(torch))

#' One transformer layer: every player's row is updated with a weighted average of the other rows (attention),
#' then passed through a small two-layer network on its own (feed-forward). Each part is added back onto its input
#' ("residual"), and rows are normalised before each part ("pre-norm"), which keeps training stable.
attention_layer <- nn_module(
  initialize = function(d_model, n_heads, d_ff, dropout) {
    self$h <- n_heads
    self$dk <- d_model %/% n_heads
    self$wq <- nn_linear(d_model, d_model)   # query: what this row is looking for
    self$wk <- nn_linear(d_model, d_model)   # key: what this row offers to others who look
    self$wv <- nn_linear(d_model, d_model)   # value: what this row hands over when attended to
    self$wo <- nn_linear(d_model, d_model)   # mixes the heads back together
    self$norm1 <- nn_layer_norm(d_model)
    self$norm2 <- nn_layer_norm(d_model)
    self$ff <- nn_sequential(nn_linear(d_model, d_ff), nn_relu(), nn_linear(d_ff, d_model))
    self$drop <- nn_dropout(dropout)
  },
  forward = function(x) {                                     # x: [B, T, d]
    B <- x$size(1); Tn <- x$size(2)
    z <- self$norm1(x)
    heads <- function(t) t$view(c(B, Tn, self$h, self$dk))$transpose(2, 3)    # -> [B, h, T, dk]
    q <- heads(self$wq(z)); k <- heads(self$wk(z)); v <- heads(self$wv(z))
    scores <- torch_matmul(q, k$transpose(3, 4)) / sqrt(self$dk)          # [B, h, T, T]: row i's query vs row j's key
    w <- nnf_softmax(scores, dim = 4)                                      # each row of weights sums to 1
    mixed <- torch_matmul(self$drop(w), v)                                 # [B, h, T, dk]: weighted average of values
    mixed <- mixed$transpose(2, 3)$contiguous()$view(c(B, Tn, -1))         # glue the heads back: [B, T, d]
    x <- x + self$drop(self$wo(mixed))
    x <- x + self$drop(self$ff(self$norm2(x)))
    list(x = x, w = w)
  }
)

#' Tokens in, four class scores out. Token 1 is always the receiver: after the attention layers, his row has
#' gathered what it needs from the other nine players, and the output head reads only that row (plus a few
#' play-level context numbers such as the shot clock).
kickout_transformer <- nn_module(
  initialize = function(n_feat, n_ctx, d_model = 32, n_heads = 4, n_layers = 2, d_ff = 64, dropout = 0.1,
                        n_class = 4) {
    self$embed <- nn_linear(n_feat, d_model)                  # each player's raw numbers -> a d-wide vector
    self$layers <- nn_module_list(lapply(seq_len(n_layers), function(i) attention_layer(d_model, n_heads, d_ff, dropout)))
    self$norm <- nn_layer_norm(d_model)
    self$head <- nn_sequential(nn_linear(d_model + n_ctx, d_model), nn_relu(), nn_dropout(dropout),
                               nn_linear(d_model, n_class))
  },
  forward = function(tokens, ctx, return_attention = FALSE) {
    x <- self$embed(tokens)
    ws <- list()
    for (i in seq_along(self$layers)) {
      o <- self$layers[[i]](x)
      x <- o$x
      ws[[i]] <- o$w
    }
    receiver <- self$norm(x)[, 1, ]                           # [B, d]
    logits <- self$head(torch_cat(list(receiver, ctx), dim = 2))
    if (return_attention) list(logits = logits, attention = ws) else logits
  }
)
