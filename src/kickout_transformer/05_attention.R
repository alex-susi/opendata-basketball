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

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
suppressPackageStartupMessages({ library(ggplot2); library(patchwork) })
hit <- grep("^--model=", commandArgs(TRUE), value = TRUE)
MODEL <- if (length(hit)) sub("^--model=", "", hit) else "hist"

FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M

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
  for (a in parts) { out[at + seq_len(dim(a)[1]), , , ] <- a; at <- at + dim(a)[1] }
  out
}
att <- stack_first(lapply(tf, `[[`, "attention"))            # [catch, layer, head, token]
pred <- rbindlist(lapply(tf, `[[`, "pred"))
n_layers <- dim(att)[2]; n_heads <- dim(att)[3]

# ---- attention by role ---------------------------------------------------------------------------

role_of <- function(r) {
  passer <- d$freeze[r, , "is_passer"] == 1
  c("receiver (himself)", ifelse(passer[2:5], "passer", "other teammate"),
    "nearest defender", "2nd-nearest defender", rep("other defender", 3))
}
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

# ---- two kickouts with a similar gap -------------------------------------------------------------

base <- readRDS(file.path(paths$cache, "pred_baselines.rds"))[model == "logistic"]
k <- m[kickout == TRUE & def1_dist >= 5 & def1_dist <= 8, .(row, label, def1_dist, def1_closing, game_id)]
k <- pred[, c("row", PROB_COLS), with = FALSE][k, on = "row"]
k <- k[!is.na(p_shot)]
pair <- c(k[which.max(p_shot), row], k[which.min(p_shot), row])

court_layer <- function() {
  arc <- seq(-pi / 2 - 0.3, pi / 2 + 0.3, length.out = 120)
  three <- data.table(x = HOOP_X - 6.75 * FT_PER_M * cos(arc), y = 6.75 * FT_PER_M * sin(arc))
  three <- three[abs(y) <= 6.6 * FT_PER_M]
  base_x <- 14 * FT_PER_M; side <- 7.5 * FT_PER_M; lane <- 4.9 / 2 * FT_PER_M; ft <- base_x - 5.8 * FT_PER_M
  list(annotate("rect", xmin = 0, xmax = base_x, ymin = -side, ymax = side, fill = "#f6e7d3", colour = "grey40"),
       annotate("rect", xmin = ft, xmax = base_x, ymin = -lane, ymax = lane, fill = NA, colour = "grey40"),
       geom_path(data = three, aes(x, y), colour = "grey40", inherit.aes = FALSE),
       annotate("segment", x = max(three$x), xend = base_x, y = c(-1, 1) * 6.6 * FT_PER_M,
                yend = c(-1, 1) * 6.6 * FT_PER_M, colour = "grey40"),
       annotate("point", x = HOOP_X, y = 0, shape = 21, size = 3, colour = "orange3", stroke = 1.2),
       coord_equal(xlim = c(0, base_x), ylim = c(-side, side), expand = FALSE))
}

#' Game clock (m:ss left in the period) when the pass was caught, from the supplied passes table.
catch_clock <- function(game, pass_id) {
  ev <- jsonlite::fromJSON(file.path(root, "data", "matches", game, sprintf("%s_dynamic_events.json", game)))$passes
  s <- ev$endGameClock[ev$id == pass_id]
  if (!length(s) || is.na(s[1])) return("clock n/a")
  sprintf("%d:%02d", floor(s[1] / 60), floor(s[1] %% 60))
}

draw_play <- function(r) {
  i <- match(r, rows)
  tok <- as.data.table(d$freeze[r, , c("hoop_dx", "y", "vx", "vy", "is_offense", "is_passer")])
  tok[, `:=`(X = HOOP_X - hoop_dx, token = .I)]
  tok[, w := colMeans(matrix(att[i, n_layers, , ], nrow = n_heads))]   # last layer, heads averaged
  rx <- tok$X[1]; ry <- tok$y[1]
  tok[, side := fifelse(is_offense == 1, "offense", "defense")]
  links <- tok[token > 1]
  links[, label_y := y + fifelse(y > 7.5 * FT_PER_M - 3, -2.4, 2.4)]   # labels near the top edge go below the dot
  pr <- pred[row == r]; lg <- base[row == r]; meta <- m[row == r]
  fmt <- function(p) paste(sprintf("%s %.0f%%", CLASSES, 100 * unlist(p[, ..PROB_COLS])), collapse = "  ")
  clk <- catch_clock(meta$game_id, meta$pass_id)
  ggplot() + court_layer() +
    geom_segment(data = links, aes(x = rx, y = ry, xend = X, yend = y, linewidth = w), colour = "#7b2cbf", alpha = 0.55) +
    geom_segment(data = tok, aes(x = X, y = y, xend = X + 0.5 * vx, yend = y + 0.5 * vy),
                 arrow = arrow(length = unit(0.12, "cm")), colour = "grey25") +
    geom_point(data = tok, aes(X, y, fill = side), shape = 21, size = 4.5) +
    geom_point(data = tok[1], aes(X, y), shape = 21, size = 7, stroke = 1.4, colour = "black", fill = NA) +
    geom_text(data = links, aes(X, label_y, label = sprintf("%.0f%%", 100 * w)), size = 3, colour = "#5a189a") +
    geom_text(data = tok[is_passer == 1], aes(X, y, label = "passer"), nudge_y = -2.6, size = 2.8) +
    scale_fill_manual(values = c(offense = "#2a6f97", defense = "#d1495b"), name = NULL) +
    scale_linewidth(range = c(0.2, 3), guide = "none") +
    labs(title = sprintf("Game %s, Q%d %s. Nearest defender %.1f ft, closing %.1f ft/s. Actual: %s",
                         meta$game_id, meta$period, clk, meta$def1_dist, meta$def1_closing, toupper(meta$label)),
         subtitle = paste0("Dashboard: #/play/", meta$poss_id, "   (", meta$pass_id, ", catch frame ", meta$catch, ")",
                           "\nTransformer: ", fmt(pr), "\nLogistic:      ", fmt(lg)),
         x = NULL, y = NULL) +
    theme_void(base_size = 10) + theme(legend.position = "bottom", plot.title = element_text(face = "bold", size = 10))
}

fig_dir <- file.path(paths$out, "figures")
dir.create(fig_dir, showWarnings = FALSE)
g <- draw_play(pair[1]) / draw_play(pair[2]) +
  plot_annotation(title = sprintf("Two kickouts, similar defender gap, different predictions\n%s transformer, %s",
                                  if (MODEL == "hist") "History" else "Freeze-frame", CLASS_TAG),
                  caption = paste("Receiver ringed. Arrows: where each player is heading over the next 0.5 s.",
                                  "Purple lines: the receiver's last-layer attention to each player (heads averaged).",
                                  "Attention is a mixing weight, not a causal effect.", sep = "\n"))
ggsave(file.path(fig_dir, sprintf("attention_two_kickouts_%s.png", MODEL)), g, width = 7.5, height = 10, dpi = 150, bg = "white")
cat("\nExample plays (rows):", pair, "\n")
print(m[row %in% pair, .(row, poss_id, pass_id, period, catch, label, def1_dist, def1_closing, defs_in_paint, recv_hoop_dist)])
