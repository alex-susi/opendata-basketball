## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 25: frame-by-frame data for the Example Play on the reads pages.
#   Rscript screen_coverage/01_scripts/25_example_play.R
#
# One screen (Fall for Marcos, Barcelona vs Gran Canaria, pick-188630-1-12) at every frame from -2 s to +1 s around
# the pick frame. Everything comes from the same caches the live model was scored on, so a page can replay what the
# model saw and said:
#   players   court positions of all ten at every stored frame from -3.6 s (for the 1.6 s trails), in the pages' half
#             court drawing (10 px per ft, hoop at the top)
#   inputs    the four screen players' level, level change, time held at a level, speed, speed change and turn
#             (sequences.rds), and the screen-wide numbers (logistic_per_frame.rds and the context matrix)
#   probs     the live transformer's five probabilities (held out, 4 random starts averaged) and the logistic
#             baseline's, both in percent
#
# Writes screen_coverage/03_outputs/example_play/example_play.json. The reads pages embed a copy of it.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "example_play")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
SCREEN <- "pick-188630-1-12"





## ═════════════════════════════════════════════════════════════════════════════
## 01 - THE SCREEN IN EACH CACHE ------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
SQ <- load_seqheads(root)
S <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
stopifnot(identical(S$screen_ids, L$P$id), identical(S$rules, L$rules), nrow(S$ctx) == nrow(L$X))
k <- match(SCREEN, S$screen_ids)
rows <- which(L$X$id == SCREEN)
X <- L$X[rows]
stopifnot(!is.na(k), length(rows) == 76L, identical(X$off, -50:25))

# Names from the game's rosters, in the sequence roster order (handler, screener, their defenders, the other six).
gd <- fromJSON(file.path(root, "data", "matches", "188630", "188630_game_data.json"))
ros <- rbind(data.table(pid = gd$homeTeam$players$playerId, last = gd$homeTeam$players$lastName),
             data.table(pid = gd$awayTeam$players$playerId, last = gd$awayTeam$players$lastName))
ids <- S$roster[k, ]
names_10 <- ros$last[match(ids, ros$pid)]





## ═════════════════════════════════════════════════════════════════════════════
## 02 - POSITIONS, INPUTS AND PROBABILITIES -------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Court feet to the pages' drawing: 10 px per ft, hoop at (260, 65.7), baseline at y = 14.
to_svg <- function(x, y) list(sx = round(260 + 10 * y, 1), sy = round(14 + 10 * (45.93 - x), 1))
B <- S$base[k, , , ]
present <- B[, , "present"] == 1
pos <- lapply(seq_along(S$base_offs), function(o) {
  p <- to_svg(B[o, , "x"], B[o, , "y"])
  lapply(1:10, function(j) if (present[o, j]) c(p$sx[j], p$sy[j]) else NULL)
})

# The four screen players' movement inputs at each predicted frame.
four <- function(f, digits = 1) {
  m <- B[match(X$off, S$base_offs), 1:4, f]
  round(m, digits)
}
inputs <- list(lvl = four("lvl"), lvl_v = four("lvl_v"), lvl_hold = four("lvl_hold", 2), speed = four("speed"),
               accel = four("accel"), turn = four("turn", 0))
ctx <- S$ctx[rows, ]
screen <- list(tta = round(X$tta_now, 1), d_hs = round(X$d_hs, 1), closeness = round(X$closeness, 2),
               hs_min = round(ctx[, "hs_min"], 1), since_hs_min = round(ctx[, "since_hs_min"], 2),
               n_so_far = as.integer(X$n_so_far))
probs <- list(live = round(100 * SQ$prob[rows, ], 1), baseline = round(100 * L$prob[["no timing, + closeness"]][rows, ], 1))
stopifnot(!anyNA(probs$live), !anyNA(probs$baseline))

out <- list(screen = SCREEN, game = 188630, call = X$call[1], calls = L$calls, offs = X$off,
            base_offs = S$base_offs, names = names_10, ids = ids, pos = pos, inputs = inputs, screen_wide = screen,
            probs = probs, generated = format(Sys.Date()))
write_json(out, file.path(out_dir, "example_play.json"), auto_unbox = TRUE, null = "null", digits = NA)
cat("Example play written:", SCREEN, "|", names_10[1:4], "| call", X$call[1], "\n")
cat("At -0.4 s:", paste(sprintf("%s %.0f%%", L$calls, probs$live[X$off == -10L, ]), collapse = ", "), "\n")
