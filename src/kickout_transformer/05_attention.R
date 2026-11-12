## ═════════════════════════════════════════════════════════════════════════════
# Step 5: look inside the transformer. Where does the receiver's row put its attention?
#   Rscript src/kickout_transformer/05_attention.R [--model=hist]
#
# The attention weights saved by step 3 are the receiver's row of each layer's weight matrix: ten numbers per head
# that sum to 1, one per player (including himself). If attention were spread evenly, every player would get 10%.
# These are weights in an average of vectors, not causal effects: a high weight means "this row's information
# was mixed in", not "this player caused the decision".
#
# Outputs (outputs/kickout_transformer/):
#   attention_by_role.csv      mean weight by player role, layer and head, on held-out catches
#   figures/attention_two_kickouts.png   two strict kickouts with a similar defender gap but different predictions
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)

hit <- grep("^--model=", commandArgs(TRUE), value = TRUE)
MODEL <- if (length(hit)) sub("^--model=", "", hit) else "hist"

FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M

# The chosen model's held-out folds: predictions and the receiver's attention for every catch.
d <- kt_load_catches(paths)
m <- d$meta
files <- list.files(paths$cache, sprintf("^tf_%s_[0-9]+\\.rds$", MODEL), full.names = TRUE)
tf <- lapply(files, readRDS)
rows <- unlist(lapply(tf, function(o) o$pred$row))
#' Stack 4-d arrays along their first dimension.
stack_first <- function(parts) {
  n <- vapply(parts, function(a) dim(a)[1], 0L)
  out <- array(NA_real_, c(sum(n), dim(parts[[1]])[-1]))
  at <- 0L
  for (a in parts) {
    out[at + seq_len(dim(a)[1]), , , ] <- a
    at <- at + dim(a)[1]
  }
  out
}
att <- stack_first(lapply(tf, `[[`, "attention"))            # [catch, layer, head, token]
pred <- rbindlist(lapply(tf, `[[`, "pred"))
n_layers <- dim(att)[2]
n_heads <- dim(att)[3]





## ═════════════════════════════════════════════════════════════════════════════
## 01 - ATTENTION BY ROLE ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Role of each of the ten tokens: the receiver, his four teammates (the passer marked), then defenders by distance.
role_of <- function(r) {
  passer <- d$freeze[r, , "is_passer"] == 1
  c("receiver (himself)", ifelse(passer[2:5], "passer", "other teammate"),
    "nearest defender", "2nd-nearest defender", rep("other defender", 3))
}
# One row per catch, layer, head and token with its attention weight.
role_tab <- rbindlist(lapply(seq_along(rows), function(i) {
  roles <- role_of(rows[i])
  rbindlist(lapply(seq_len(n_layers), function(l) rbindlist(lapply(seq_len(n_heads), function(h)
    data.table(layer = l, head = h, role = roles, w = att[i, l, h, ])))))
}))
# weight per player in the role (so "other defender" is per defender, comparable with the 10% even split)
by_role <- role_tab[, .(mean_weight_per_player = mean(w)), by = .(layer, head, role)]
by_role_heads <- role_tab[, .(mean_weight_per_player = mean(w)), by = .(layer, role)]
fwrite(rbind(by_role, by_role_heads[, head := 0L]), file.path(paths$out, sprintf("attention_by_role_%s.csv", MODEL)))
cat("Mean attention weight per player, by role (heads averaged; an even split would give 0.10):\n")
print(dcast(by_role_heads, role ~ paste0("layer_", layer), value.var = "mean_weight_per_player")[
  , lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])
cat("\nLast layer, by head:\n")
print(dcast(by_role[layer == n_layers], role ~ paste0("head_", head), value.var = "mean_weight_per_player")[
  , lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])





## ═════════════════════════════════════════════════════════════════════════════
## 02 - TWO KICKOUTS WITH A SIMILAR GAP ----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Kickouts with the nearest defender 5-8 ft away: the transformer's most and least likely shots.
base <- readRDS(file.path(paths$cache, "pred_baselines.rds"))[model == "logistic"]
k <- m[kickout == TRUE & def1_dist >= 5 & def1_dist <= 8, .(row, label, def1_dist, def1_closing, game_id)]
k <- pred[, c("row", PROB_COLS), with = FALSE][k, on = "row"]
k <- k[!is.na(p_shot)]
pair <- c(k[which.max(p_shot), row], k[which.min(p_shot), row])

source(file.path(root, "src", "kickout_transformer", "R", "draw_play.R"))
roster <- load_rosters(root, unique(m[row %in% pair, game_id]))
tf_label <- if (MODEL == "hist") "Transformer (+ last 1 s)" else "Transformer (freeze frame)"
# A play card for one catch: last-layer attention (heads averaged) and both models' probabilities.
card_for <- function(r) {
  i <- match(r, rows)
  meta <- m[row == r]
  w <- colMeans(matrix(att[i, n_layers, , ], nrow = n_heads))       # last layer, heads averaged
  probs <- setNames(list(setNames(unlist(pred[row == r, ..PROB_COLS]), CLASSES),
                         setNames(unlist(base[row == r, ..PROB_COLS]), CLASSES)),
                    c(tf_label, "Logistic (10 hand features)"))
  p_tf <- probs[[1]][["shot"]]
  headline <- sprintf("Actually a %s. Transformer gave a shot %.0f%%, closest defender %.1f ft away.",
                      toupper(meta$label), 100 * p_tf, meta$def1_dist)
  play_card(root, meta, d$freeze[r, , ], d$token_pid[r, ], roster, w, probs, headline)
}

# The two cards stacked in one figure.
fig_dir <- file.path(paths$out, "figures")
dir.create(fig_dir, showWarnings = FALSE)
g <- wrap_elements(full = card_for(pair[1])) / wrap_elements(full = card_for(pair[2])) +
  plot_annotation(title = sprintf("Two kickouts with a similar defender gap (5-8 ft): the transformer's most and least likely shots\n%s, %s",
                                  tf_label, CLASS_TAG),
                  caption = CARD_CAPTION,
                  theme = theme(plot.title = element_text(face = "bold", size = 14),
                                plot.caption = element_text(hjust = 0, size = 8.5, colour = "grey35")))
ggsave(file.path(fig_dir, sprintf("attention_two_kickouts_%s.png", MODEL)), g, width = 11, height = 14.5, dpi = 150, bg = "white")
cat("\nExample plays (rows):", pair, "\n")
print(m[row %in% pair, .(row, poss_id, pass_id, period, catch, label, def1_dist, def1_closing, defs_in_paint, recv_hoop_dist)])
