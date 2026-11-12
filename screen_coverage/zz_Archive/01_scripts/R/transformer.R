# The screen-coverage transformer: ten player tokens and a few screen-level numbers in, five call scores out.
#
# It reuses the attention layer written out by hand for the kickout exercise (kickout_transformer/01_scripts/R/transformer.R):
# every player's row is updated with a weighted average of all ten rows, then a small feed-forward network. Rows 1-4
# are always the players of the screen (ball handler, screener, handler's defender, screener's defender); rows 5-10
# are the other six, who matter only through what the four rows take from them in attention. After the attention
# layers the four screen rows are read side by side and joined to the context vector (shot clock, the defense's
# earlier calls, and per variant the time to the screen, the closeness, the archetypes) before the output head. Like
# the kickout model, the context changes the final call, not the attention.

suppressPackageStartupMessages(library(torch))
source(file.path(root, "kickout_transformer", "01_scripts", "R", "transformer.R"))     # attention_layer(); needs `root`

# initialize: token embedding, attention layers, and an output head over the four screen rows plus the context.
coverage_transformer <- nn_module(initialize = function(n_feat, n_ctx, n_read = 4L, d_model = 32, n_heads = 4, n_layers = 2, d_ff = 64,
                                                        dropout = 0.1, n_class = 5) {
                                    self$n_read <- n_read
                                    self$embed <- nn_linear(n_feat, d_model)
                                    self$layers <- nn_module_list(lapply(seq_len(n_layers), function(i) attention_layer(d_model, n_heads, d_ff, dropout)))
                                    self$norm <- nn_layer_norm(d_model)
                                    self$head <- nn_sequential(nn_linear(n_read * d_model + n_ctx, 64), nn_relu(), nn_dropout(dropout),
                                                               nn_linear(64, n_class))
                                  },
                                  forward = function(tokens, ctx, return_attention = FALSE) {      # tokens: [B, 10, n_feat]; ctx: [B, n_ctx]
                                    # Embed the tokens and run the attention layers, keeping each layer's attention
                                    # weights.
                                    x <- self$embed(tokens)
                                    ws <- list()
                                    for (i in seq_along(self$layers)) {
                                      o <- self$layers[[i]](x)
                                      x <- o$x
                                      ws[[i]] <- o$w
                                    }
                                    rows <- self$norm(x)[, 1:self$n_read, ]$flatten(start_dim = 2)  # the four screen rows side by side: [B, 4 * d]
                                    logits <- self$head(torch_cat(list(rows, ctx), dim = 2))
                                    if (return_attention) list(logits = logits, attention = ws) else logits
                                  })
