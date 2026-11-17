## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 27: the README's tracking figure, one still of the Example Play.
#   Rscript screen_coverage/01_scripts/27_readme_figure.R
#
# Fall's screen for Marcos (pick-188630-1-12), from the file 25_example_play.R writes. Left, the half court at -0.4 s
# with the four screen players' last 1.6 s (one dot every 0.2 s) and the screener's level. Right, the live
# transformer's five held-out probabilities from -2 s to +1 s, with the main curve's weight shaded.
#
# Reads  screen_coverage/03_outputs/example_play/example_play.json
# Writes screen_coverage/03_outputs/readme/example_play.png
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(ggplot2)
  library(patchwork)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "readme")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
EX <- fromJSON(file.path(root, "screen_coverage", "03_outputs", "example_play", "example_play.json"),
               simplifyVector = FALSE)
STILL <- -10L
COLS <- c("over + show" = "#2a78d6", "over + drop" = "#eb6834", "under + drop" = "#1baf7a",
          "under + show" = "#c98500", "switch" = "#d55181")
OFFENSE <- "#2a78d6"
DEFENSE <- "#d4512b"
MUTED <- "#5a6577"





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PLAYERS ON THE COURT ----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Positions are in the reads pages' drawing (10 px per ft, hoop at (260, 65.7), baseline at y = 14), one list per
# frame in base_offs, NULL where a player is not tracked.
base_offs <- unlist(EX$base_offs)
pos <- rbindlist(lapply(seq_along(EX$pos), function(o) {
  rbindlist(lapply(1:10, function(j) {
    p <- EX$pos[[o]][[j]]
    if (is.null(p)) {
      return(NULL)
    }
    data.table(off = base_offs[o], j = j, sx = p[[1]], sy = p[[2]])
  }))
}))
pos[, name := unlist(EX$names)[j]]
pos[, side := fifelse(j %in% 1:2, "attack", fifelse(j %in% 3:4, "defense", "other"))]

# The still, and each screen player's trail over the last 1.6 s, one dot every 0.2 s.
now <- pos[off == STILL]
trail <- pos[j <= 4 & off < STILL & off >= STILL - 40L & (STILL - off) %% 5L == 0L]
stopifnot(nrow(now) == 10L, nrow(trail) == 32L)

# The screener's level: a circle around the hoop at his distance from it at the still.
offs <- unlist(EX$offs)
lvl_r <- 10 * EX$inputs$hoop_dist[[match(STILL, offs)]][[2]]
arc <- data.table(a = seq(0, pi, length.out = 181))
arc[, `:=`(sx = 260 + lvl_r * cos(a), sy = 65.7 + lvl_r * sin(a))]
# Name labels set beside each screen player, clear of the trails (drawing px).
roles <- c("handler", "screener", "on the ball", "on the screener")
tags <- now[j <= 4][order(j)]
tags[, `:=`(label = sprintf("%s\n%s", name, roles[j]), tx = sx + c(52, -4, 66, -92), ty = sy + c(16, 32, -6, -4))]





## ═════════════════════════════════════════════════════════════════════════════
## 02 - COURT PANEL -------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# FIBA half court in the same drawing as the reads pages' Example Play. The three-point arc (radius 221.5 around the
# hoop) meets the corner lines at x = 43.5 and 476.5, y = 112.5.
corner <- asin(46.8 / 221.5)
three_arc <- data.table(a = seq(pi - corner, corner, length.out = 181))
three_arc[, `:=`(sx = 260 + 221.5 * cos(a), sy = 65.7 + 221.5 * sin(a))]
three <- rbind(data.table(sx = 43.5, sy = 14),
               three_arc[, .(sx, sy)],
               data.table(sx = 476.5, sy = 14))
circle <- function(cx, cy, r, from = 0, to = 2 * pi) {
  a <- seq(from, to, length.out = 181)
  data.table(sx = cx + r * cos(a), sy = cy + r * sin(a))
}

court <- ggplot() +
  annotate("rect", xmin = 14, xmax = 506, ymin = 14, ymax = 402, fill = "#e9eff9", colour = "#d9dfe8") +
  annotate("rect", xmin = 179.6, xmax = 340.4, ymin = 14, ymax = 204.3, fill = NA, colour = MUTED, alpha = 0.7) +
  geom_path(data = circle(260, 204.3, 59), aes(sx, sy), colour = MUTED, alpha = 0.7) +
  geom_path(data = three, aes(sx, sy), colour = MUTED, alpha = 0.7) +
  geom_path(data = circle(260, 65.7, 41, 0, pi), aes(sx, sy), colour = MUTED, alpha = 0.7) +
  annotate("segment", x = 230.5, xend = 289.5, y = 53.4, yend = 53.4, colour = MUTED, linewidth = 1) +
  geom_path(data = circle(260, 65.7, 7), aes(sx, sy), colour = "#142030", linewidth = 0.8) +
  geom_path(data = arc, aes(sx, sy), colour = MUTED, linetype = "dashed", linewidth = 0.6) +
  geom_text(data = tags, aes(tx, ty, label = label, colour = side), size = 2.9, lineheight = 0.9,
            fontface = "bold") +
  geom_point(data = trail, aes(sx, sy, colour = side), size = 1.4, alpha = 0.5) +
  geom_point(data = now[side == "other"], aes(sx, sy), shape = 21, size = 3, stroke = 1, colour = MUTED,
             fill = "white") +
  geom_point(data = now[side != "other"], aes(sx, sy, colour = side), size = 4) +
  annotate("text", x = 260 + lvl_r * cos(0.2), y = 65.7 + lvl_r * sin(0.2) + 12, label = "screener's level",
           colour = MUTED, size = 2.9, hjust = 0) +
  scale_colour_manual(values = c(attack = OFFENSE, defense = DEFENSE), guide = "none") +
  scale_y_reverse() +
  coord_fixed(xlim = c(14, 506), ylim = c(402, 14), expand = FALSE) +
  labs(title = "On the court at −0.4 s",
       subtitle = "Dots trail each screen player's last 1.6 s") +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(colour = MUTED, margin = margin(2, 0, 6, 0)))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - PROBABILITY PANEL -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The live model's five probabilities (held out, in percent) at every frame from -2 s to +1 s.
calls <- unlist(EX$calls)
live <- rbindlist(lapply(seq_along(offs), function(i) {
  data.table(off = offs[i], call = calls, p = unlist(EX$probs$live[[i]]))
}))
live[, `:=`(t = off / WINDOW_FPS, call = factor(call, levels = calls))]
band <- data.table(off = offs, w = window_weight(offs, "main"))
band[, t := off / WINDOW_FPS]

probs <- ggplot(live, aes(t, p, colour = call)) +
  geom_area(data = band, aes(t, 100 * w), inherit.aes = FALSE, fill = "#1f5fd1", alpha = 0.08) +
  geom_vline(xintercept = 0, colour = "#142030", linetype = "dashed", linewidth = 0.4) +
  geom_vline(xintercept = STILL / WINDOW_FPS, colour = MUTED, linetype = "dotted", linewidth = 0.5) +
  geom_line(linewidth = 1) +
  annotate("text", x = 0.03, y = 98, label = "pick frame", hjust = 0, size = 3, colour = "#142030") +
  annotate("text", x = STILL / WINDOW_FPS - 0.03, y = 98, label = "court view", hjust = 1, size = 3, colour = MUTED) +
  annotate("text", x = -1.35, y = 92, label = "shaded = main-curve weight", hjust = 0, size = 3, colour = "#1f5fd1") +
  scale_colour_manual(values = COLS, name = NULL) +
  scale_x_continuous(breaks = seq(-2, 1, 0.5), labels = function(x) sprintf("%+.1f s", x)) +
  scale_y_continuous(limits = c(0, 100), breaks = seq(0, 100, 25), labels = function(y) paste0(y, "%")) +
  labs(title = "What the live model said",
       subtitle = sprintf("Held-out probabilities. Recorded coverage %s", EX$call),
       x = "Time from the pick frame", y = NULL) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(colour = MUTED, margin = margin(2, 0, 6, 0)),
        legend.position = "bottom",
        panel.grid.minor = element_blank())

fig <- court + probs +
  plot_layout(widths = c(1, 1.15)) +
  plot_annotation(title = "Fall's screen for Marcos, Barcelona vs Gran Canaria",
                  caption = "SkillCorner tracking, Liga ACB 2025-26, game 188630. Hoop at the top.",
                  theme = theme(plot.title = element_text(face = "bold", size = 14),
                                plot.caption = element_text(colour = MUTED)))
ggsave(file.path(out_dir, "example_play.png"), fig, width = 11, height = 5.2, dpi = 160, bg = "white")
at <- live[off == STILL]
cat("README figure written | at -0.4 s:", paste(sprintf("%s %.0f%%", at$call, at$p), collapse = ", "), "\n")
