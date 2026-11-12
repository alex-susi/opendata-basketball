## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 6: the play viewer's live probabilities.
#   Rscript screen_coverage/01_scripts/06_export_live.R
#
# Writes web/public/data/coverage_frames.json, read by the viewer's Coverage Read card
# (web/src/components/Annotations.svelte, web/src/lib/coverage.ts). Per possession: every scored screen with its tag
# frame, its four players, the tagged call, and the held-out probability of each call (whole percent) at every frame
# from -2 s to +1 s, raw (the card smooths them over the last 0.2 s itself and sums them to each defender's call).
#
# The live model is the time-aware transformer with two linked heads (03_train_transformer.R), built under the
# past-only rules (R/past_only.R): each player's last 1.6 s, never told when the screen comes. Each game's screens come
# from the network trained without that game. Also writes web/public/data/coverage_attention.json for the Model
# Attention toggle. (Until 2026-11-12 --model= could export the archived token transformers instead.)
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
LIVE <- SEQ_MODEL
SMOOTH <- 5L





## ═════════════════════════════════════════════════════════════════════════════
## 01 - LIVE PROBABILITIES -----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
SQH <- load_seqheads(root)
P <- L$P
X <- L$X
PW <- SQH$prob
# Each screen's frame rows in time order, and its record with whole-percent probabilities per call.
rows <- lapply(split(seq_len(nrow(X)), X$idx), function(r) r[order(X$off[r])])
screens <- lapply(seq_len(nrow(P)), function(k) {
  r <- rows[[as.character(k)]]
  list(id = P$id[k], f0 = P$f0[k], h = P$H[k], s = P$S[k], bd = P$BD[k], sd = P$SD[k], call = P$call[k],
       p = lapply(seq_along(L$calls), function(j) as.integer(round(100 * PW[r, j]))))
})
by_poss <- split(screens, P$poss)
jsonlite::write_json(list(model = LIVE, rules = L$rules, smooth_frames = SMOOTH, offsets = range(L$offs), calls = L$calls,
                          generated = format(Sys.time(), "%Y-%m-%d %H:%M"), possessions = by_poss),
                     file.path(root, "web", "public", "data", "coverage_frames.json"), auto_unbox = TRUE)
cat("Wrote web/public/data/coverage_frames.json with", LIVE, ":", length(screens), "screens in", length(by_poss), "possessions\n")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - ATTENTION FOR THE MODEL ATTENTION TOGGLE -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# web/public/data/coverage_attention.json: per screen, its players (roster: the four of the screen first) and, at
# every frame, which roster player sits in token rows 5-10 (k, 0-based) and the whole-percent share of the four screen
# players' attention going to each of the ten rows (w). Loaded by the site only when the toggle is on. The roster is
# fixed per screen (02_build_sequences.R: the other six as of -2 s).
roster <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))$roster
att_screens <- lapply(seq_len(nrow(P)), function(k) {
  r <- rows[[as.character(k)]]
  list(id = P$id[k], f0 = P$f0[k], r = roster[k, ], k = rep(list(4:9), length(r)),
       w = lapply(r, function(i) as.integer(round(100 * SQH$att[i, ]))))
})
jsonlite::write_json(list(model = LIVE, offsets = range(L$offs), generated = format(Sys.time(), "%Y-%m-%d %H:%M"),
                          possessions = split(att_screens, P$poss)),
                     file.path(root, "web", "public", "data", "coverage_attention.json"), auto_unbox = TRUE)
cat("Wrote web/public/data/coverage_attention.json\n")
