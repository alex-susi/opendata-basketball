## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, lane experiment: what the roll-lane geometry measured, on real screens (added 2026-11-15).
#   Rscript screen_coverage/01_scripts/09_lane_figures.R
#
# Needs 02_build_sequences.R --variant=B. Uses the fitted folds when they exist (A: live; B: experiment seeds 1-2) to
# print each panel's forecast for the big; draws without them otherwise.
#
# 1. Stills at -0.8 s, -0.4 s and the tag for six screens: the runbook's three clips (Golden for Perez, Fall for
#    Marcos, Hankins for Rousselle), a switch, a screen whose screener is still approaching at -0.8 s, and a
#    re-screen. Each panel shows the ten players, the roll segment from the screener to the rim, each off-ball
#    defender's nearest point on it (dotted) and his path over the last 0.4 s (arrow), labelled with the model inputs
#    (gap in ft, closing speed in ft/s; "n/a" when not valid). The values are recomputed from the tracking bundle and
#    checked against the cached inputs.
# 2. web/public/data/coverage_lanes.json for the viewer's Roll Lanes toggle: per screen, its screener and three
#    off-ball defenders, and at every frame from -2 s to +1 s each defender's gap and closing speed (tenths) and
#    validity. The viewer draws the lane from the positions it already shows.
#
# Writes screen_coverage/03_outputs/experiments/lanes/figures/stills/<nn>_<pick>.png, stills.csv, and the JSON.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
for (f in c("past_only.R", "lane_geometry.R", "lane_variants.R", "predictions.R")) {
  source(file.path(root, "screen_coverage", "01_scripts", "R", f))
}
out_dir <- file.path(lane_out_dir(root), "figures", "stills")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
STILL_OFFS <- c(-20L, -10L, 0L)
PATH_FRAMES <- 10L                 # helper's path drawn over the last 0.4 s





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SCREENS AND CACHED INPUTS ----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
P <- L$P
X <- L$X
SB <- readRDS(file.path(lane_dir(root, "B"), "sequences.rds"))
stopifnot(identical(SB$screen_ids, P$id))
AU <- SB$roll_audit
nvalid <- apply(AU$valid, c(1, 2), sum)
b_of <- function(o) match(o, SB$base_offs)

# The runbook's clips, then a switch, a screener still approaching at -0.8 s, and a re-screen (first in game order).
ids <- c("pick-114243-2-39", "pick-188630-1-12", "pick-114243-3-66")
full_at <- function(k, o) nvalid[k, b_of(o)] == 3L
sw <- P[call == "switch", which = TRUE]
sw <- sw[vapply(sw, function(k) all(sapply(STILL_OFFS, function(o) full_at(k, o))), NA)][1]
d8 <- X[off == -20L, .(idx, d_hs)]
appr <- d8[d_hs >= quantile(d8$d_hs, 0.95)][order(d_hs)]$idx
appr <- appr[vapply(appr, function(k) all(sapply(STILL_OFFS, function(o) full_at(k, o))), NA)][1]
P5 <- readRDS(file.path(root, "screen_coverage", "02_cache", "per_frame_features.rds"))$P[call %in% L$calls]
resc <- which(vapply(seq_len(nrow(P)), function(i) {
  any(P5$game_id == P$game_id[i] & P5$def_team == P$def_team[i] & P5$f0 < P$f0[i] & P5$f0 > P$f0[i] - 50)
}, NA))
resc <- resc[vapply(resc, function(k) all(sapply(STILL_OFFS, function(o) full_at(k, o))), NA)][1]
pick <- data.table(id = c(ids, P$id[c(sw, appr, resc)]),
                   why = c("runbook clip", "runbook clip", "runbook clip", "a switch", "screener still approaching at -0.8 s",
                           "a re-screen (same defense screened within 2 s before)"))
pick <- pick[!duplicated(id)]
stopifnot(all(pick$id %in% P$id))

# Forecasts for the big where both models are fitted (show, drop, switch from the five calls).
fold_prob <- function(dir) {
  paths <- file.path(dir, sprintf("seqheads_%d.rds", sort(unique(X$game_id))))
  if (!all(file.exists(paths))) return(NULL)
  Pm <- matrix(NA_real_, nrow(X), 5)
  for (p in paths) {
    o <- read_fold(p, L)
    Pm[o$rows, ] <- o$prob
  }
  cbind(show = Pm[, 1] + Pm[, 4], drop = Pm[, 2] + Pm[, 3], switch = Pm[, 5])
}
BIG <- list(A = fold_prob(file.path(root, "screen_coverage", "02_cache", "tf")), B = fold_prob(lane_tf_dir(root, "B", 1:2)))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - STILLS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Half-court lines in the site's frame (offense attacking +x): baseline, sideline, key, three-point line, rim.
HALF_L <- 14 * 3.28084
HALF_W <- 7.5 * 3.28084
KEY_X <- (14 - 5.8) * 3.28084
KEY_HW <- 2.45 * 3.28084
THREE_R <- 6.75 * 3.28084
THREE_Y <- 6.6 * 3.28084
# The arc runs between the two corner lines, which meet it sqrt(R^2 - Y^2) ft in front of the rim.
arc_a <- asin(THREE_Y / THREE_R)
arc <- data.table(a = seq(-arc_a, arc_a, length.out = 80))[, .(x = HOOP_X - THREE_R * cos(a), y = THREE_R * sin(a))]
CORNER_X <- HOOP_X - sqrt(THREE_R^2 - THREE_Y^2)
court <- function() {
  list(annotate("rect", xmin = 0, xmax = HALF_L, ymin = -HALF_W, ymax = HALF_W, fill = NA, colour = "grey70"),
       annotate("rect", xmin = KEY_X, xmax = HALF_L, ymin = -KEY_HW, ymax = KEY_HW, fill = NA, colour = "grey80"),
       annotate("segment", x = HALF_L, xend = CORNER_X, y = THREE_Y, yend = THREE_Y, colour = "grey80"),
       annotate("segment", x = HALF_L, xend = CORNER_X, y = -THREE_Y, yend = -THREE_Y, colour = "grey80"),
       geom_path(data = arc, aes(x, y), colour = "grey80", inherit.aes = FALSE),
       annotate("point", x = HOOP_X, y = 0, shape = 21, size = 3, colour = "#d95926", stroke = 1.2))
}
surname <- function(n) sub(".* ", "", n)

rows <- list()
plots <- list()
for (i in seq_len(nrow(pick))) {
  k <- match(pick$id[i], P$id)
  p <- P[k]
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", p$game_id)))
  ro <- SB$roster[k, ]
  pos <- ten_player_positions(B, p, matrix(ro, 1L))
  base <- sequence_base(pos$PX, pos$PY)
  rl <- roll_lane_features(pos$PX, pos$PY, array(base[, , , "present"], dim(base)[1:3]))
  nm <- B$roster$name[match(ro, B$roster$pid)]
  role <- c("H", "S", "BD", "SD", "O", "O", "O", "help 1", "help 2", "help 3")
  panels <- list()
  for (o in STILL_OFFS) {
    b <- b_of(o)
    ko <- match(o, SEQ_POS_OFFS)
    # The recomputed values must equal the cached model inputs.
    for (h in 1:3) {
      j <- ROLL_ROWS[h]
      same <- isTRUE(all.equal(c(rl$distance[1, b, j], rl$closing[1, b, j]), c(AU$distance[k, b, h], AU$closing[k, b, h])))
      if (!(same || (is.na(rl$distance[1, b, j]) && !AU$valid[k, b, h]))) stop("Recomputed lane values differ for ", p$id)
    }
    pl <- data.table(j = 1:10, x = pos$PX[1, ko, ], y = pos$PY[1, ko, ], role = role, name = surname(nm),
                     side = c("O", "O", "D", "D", "O", "O", "O", "D", "D", "D"))
    seg <- data.table(x = pl$x[2], y = pl$y[2], xend = HOOP_X, yend = 0)
    hl <- data.table(h = 1:3, j = ROLL_ROWS, x = pl$x[ROLL_ROWS], y = pl$y[ROLL_ROWS], nx = rl$nearest_x[1, b, ROLL_ROWS],
                     ny = rl$nearest_y[1, b, ROLL_ROWS], d = rl$distance[1, b, ROLL_ROWS], cl = rl$closing[1, b, ROLL_ROWS],
                     u = rl$projection[1, b, ROLL_ROWS], valid = rl$valid[1, b, ROLL_ROWS], name = pl$name[ROLL_ROWS])
    hl[, label := fifelse(valid, sprintf("%s %.1f ft, %+.1f ft/s", name, d, cl), sprintf("%s n/a", name))]
    path <- rbindlist(lapply(ROLL_ROWS, function(j) {
      data.table(j = j, x = pos$PX[1, (ko - PATH_FRAMES):ko, j], y = pos$PY[1, (ko - PATH_FRAMES):ko, j])
    }))[!is.na(x)]
    # Caption: the big's forecast from A and B at this frame, when fitted.
    r <- which(X$idx == k & X$off == o)
    fc <- vapply(names(BIG), function(m) {
      if (is.null(BIG[[m]])) return(NA_character_)
      sprintf("%s: show %.0f%% drop %.0f%% switch %.0f%%", m, 100 * BIG[[m]][r, 1], 100 * BIG[[m]][r, 2], 100 * BIG[[m]][r, 3])
    }, "")
    fc <- paste(fc[!is.na(fc)], collapse = " | ")
    rows[[length(rows) + 1L]] <- hl[, .(id = p$id, why = pick$why[i], call = p$call, t = o / FPS, helper = name, gap_ft = round(d, 2),
                                        closing_fps = round(cl, 2), projection = round(u, 3), valid,
                                        big_forecast = fc)]
    panels[[length(panels) + 1L]] <- ggplot() +
      court() +
      geom_segment(data = seg, aes(x, y, xend = xend, yend = yend), colour = "#c98500", linewidth = 1.4, linetype = "22") +
      geom_segment(data = hl[valid == TRUE], aes(x, y, xend = nx, yend = ny), colour = "#6b6b68", linetype = "dotted") +
      geom_point(data = hl[valid == TRUE], aes(nx, ny), colour = "#c98500", size = 1.6) +
      geom_path(data = path, aes(x, y, group = j), colour = "#1f5fd1", linewidth = 1,
                arrow = arrow(length = unit(0.15, "cm"), type = "closed")) +
      geom_point(data = pl, aes(x, y, fill = side), shape = 21, size = 4, colour = "white") +
      geom_text(data = pl, aes(x, y, label = fifelse(role %in% c("H", "S", "BD", "SD"), role, "")), size = 2.3, colour = "white", fontface = "bold") +
      geom_text(data = hl, aes(x, y, label = label), size = 2.4, vjust = -1.1, colour = "#1f5fd1") +
      scale_fill_manual(values = c(O = "#c7374a", D = "#1f5fd1"), guide = "none") +
      coord_equal(xlim = c(0, HALF_L + 1), ylim = c(-HALF_W - 1, HALF_W + 1)) +
      labs(title = sprintf("%+.1f s", o / FPS), subtitle = fc) +
      theme_void(base_size = 9) +
      theme(plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 7, colour = "grey30"))
  }
  ttl <- sprintf("%s screens for %s (%s); tagged call: %s", surname(nm[2]), surname(nm[1]), pick$why[i], p$call)
  g <- wrap_plots(panels, nrow = 1) +
    plot_annotation(title = ttl,
                    subtitle = paste0("Gold dashes: the roll lane from the screener (S) to the rim. Blue arrows: each off-ball ",
                                      "defender's last 0.4 s. Dotted: his nearest point on the lane.\nLabels: the model's ",
                                      "inputs (gap to the lane; closing speed, + = moving toward it over the last 0.2 s). ",
                                      "Captions: each model's forecast for the screener's defender at that moment."),
                    theme = theme(plot.title = element_text(face = "bold", size = 11), plot.subtitle = element_text(size = 8)))
  ggsave(file.path(out_dir, sprintf("%02d_%s.png", i, p$id)), g, width = 13, height = 5.2, dpi = 150, bg = "white")
}
fwrite(rbindlist(rows), file.path(lane_out_dir(root), "stills.csv"))
cat("Stills drawn for", nrow(pick), "screens in", out_dir, "\n")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - VIEWER FILE FOR THE ROLL LANES TOGGLE ----------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Per screen: screener (s), the three off-ball defenders (r), and at each prediction offset their gap (d) and closing
# speed (c) in tenths, NA -> null when not valid.
offs <- L$offs
bo <- b_of(offs)
tenth <- function(v) ifelse(is.na(v), NA_integer_, as.integer(round(10 * v)))
lanes <- lapply(seq_len(nrow(P)), function(k) {
  list(id = P$id[k], f0 = P$f0[k], s = P$S[k], r = SB$roster[k, ROLL_ROWS],
       d = lapply(1:3, function(h) tenth(AU$distance[k, bo, h])),
       c = lapply(1:3, function(h) tenth(AU$closing[k, bo, h])))
})
jsonlite::write_json(list(experiment = "roll lanes (variant B inputs; not the live model)", offsets = range(offs),
                          generated = format(Sys.time(), "%Y-%m-%d %H:%M"), possessions = split(lanes, P$poss)),
                     file.path(root, "web", "public", "data", "coverage_lanes.json"), auto_unbox = TRUE, na = "null")
cat("Wrote web/public/data/coverage_lanes.json\n")
