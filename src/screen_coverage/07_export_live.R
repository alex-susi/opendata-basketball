## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 7: the play viewer's live probabilities.
#   Rscript src/screen_coverage/07_export_live.R [--model="time-aware transformer, two heads"]
#
# Writes web/public/data/coverage_frames.json, read by the viewer's Coverage Read card
# (web/src/components/Annotations.svelte, web/src/lib/coverage.ts). Per possession: every scored screen with its tag
# frame, its four players, the tagged call, and the held-out probability of each call (whole percent) at every frame
# from -2 s to +1 s, raw (the card smooths them over the last 0.2 s itself and sums them to each defender's call).
#
# The live model is the time-aware transformer with two linked heads (10_train_seq_transformer.R): each player's last
# 1.6 s, never told when the screen comes. It is the best of the models a live system could run. Each game's screens
# come from the network trained without that game. --model= picks another (any name from load_coverage_predictions(),
# e.g. "transformer: pooled, no timing, + closeness").
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
source(file.path(root, "src", "screen_coverage", "R", "predictions.R"))
hit <- grep("^--model=", commandArgs(TRUE), value = TRUE)
LIVE <- if (length(hit)) sub("^--model=", "", hit) else SEQ_MODEL
SMOOTH <- 5L





## ═════════════════════════════════════════════════════════════════════════════
## 01 - LIVE PROBABILITIES -----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_coverage_predictions(root)
SQH <- if (LIVE == SEQ_MODEL) load_seqheads(root) else NULL
if (LIVE != SEQ_MODEL && !LIVE %in% names(L$prob)) stop("Unknown model: ", LIVE, ". One of: ", paste(c(SEQ_MODEL, names(L$prob)), collapse = "; "))
P <- L$P
X <- L$X
PW <- if (LIVE == SEQ_MODEL) SQH$prob else L$prob[[LIVE]]
# Each screen's frame rows in time order, and its record with whole-percent probabilities per call.
rows <- lapply(split(seq_len(nrow(X)), X$idx), function(r) r[order(X$off[r])])
screens <- lapply(seq_len(nrow(P)), function(k) {
  r <- rows[[as.character(k)]]
  list(id = P$id[k], f0 = P$f0[k], h = P$H[k], s = P$S[k], bd = P$BD[k], sd = P$SD[k], call = P$call[k],
       p = lapply(seq_along(L$calls), function(j) as.integer(round(100 * PW[r, j]))))
})
by_poss <- split(screens, P$poss)
jsonlite::write_json(list(model = LIVE, smooth_frames = SMOOTH, offsets = range(L$offs), calls = L$calls,
                          generated = format(Sys.time(), "%Y-%m-%d %H:%M"), possessions = by_poss),
                     file.path(root, "web", "public", "data", "coverage_frames.json"), auto_unbox = TRUE)
cat("Wrote web/public/data/coverage_frames.json with", LIVE, ":", length(screens), "screens in", length(by_poss), "possessions\n")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - ATTENTION FOR THE MODEL ATTENTION TOGGLE -------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Transformer live models only.
# web/public/data/coverage_attention.json: per screen, its players (roster: the four of the screen first) and, at
# every frame, which roster player sits in token rows 5-10 (k, 0-based) and the whole-percent share of the four screen
# players' attention going to each of the ten rows (w). Loaded by the site only when the toggle is on.
write_attention <- function(A, roster_at) {
  att_screens <- lapply(seq_len(nrow(P)), function(k) {
    r <- rows[[as.character(k)]]
    ro <- roster_at(k, r)
    list(id = P$id[k], f0 = P$f0[k], r = ro$roster, k = ro$k, w = lapply(r, function(i) as.integer(round(100 * A[i, ]))))
  })
  jsonlite::write_json(list(model = LIVE, offsets = range(L$offs), generated = format(Sys.time(), "%Y-%m-%d %H:%M"),
                            possessions = split(att_screens, P$poss)),
                       file.path(root, "web", "public", "data", "coverage_attention.json"), auto_unbox = TRUE)
  cat("Wrote web/public/data/coverage_attention.json\n")
}
# The sequence model's roster is fixed per screen; the token model's other six can change from frame to frame.
if (LIVE == SEQ_MODEL) {
  roster <- readRDS(file.path(root, "outputs", "cache", "screen_coverage", "sequences.rds"))$roster   # fixed per screen
  write_attention(SQH$att, function(k, r) list(roster = roster[k, ], k = rep(list(4:9), length(r))))
} else if (startsWith(LIVE, "transformer: ")) {
  ids <- readRDS(file.path(root, "outputs", "cache", "screen_coverage", "tokens.rds"))$ids          # per frame
  write_attention(load_tf_attention(root, TF_VARIANT[[sub("^transformer: ", "", LIVE)]]), function(k, r) {
    roster <- unique(c(ids[r[1], 1:4], as.vector(ids[r, 5:10])))
    list(roster = roster, k = lapply(r, function(i) match(ids[i, 5:10], roster) - 1L))
  })
}
