# Screen coverage, step 7: the play viewer's live probabilities.
#   Rscript src/screen_coverage/07_export_live.R [--model="transformer: pooled, no timing, + closeness"]
#
# Writes web/public/data/coverage_frames.json, read by the viewer's Coverage Read card
# (web/src/components/Annotations.svelte, web/src/lib/coverage.ts). Per possession: every scored screen with its tag
# frame, its four players, the tagged call, and the held-out probability of each call (whole percent) at every frame
# from -2 s to +1 s, raw (the card smooths them over the last 0.2 s itself).
#
# The live model is the transformer that is never told when the screen comes ("pooled, no timing, + closeness": all
# ten players as tokens, the shot clock, the defense's earlier calls and the closeness weight). It is the best of the
# models a live system could actually run, because the timing-aware models need to know the moment of the screen in
# advance. Each game's screens come from the network trained without that game.

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
source(file.path(root, "src", "screen_coverage", "R", "predictions.R"))
hit <- grep("^--model=", commandArgs(TRUE), value = TRUE)
LIVE <- if (length(hit)) sub("^--model=", "", hit) else "transformer: pooled, no timing, + closeness"
SMOOTH <- 5L

L <- load_coverage_predictions(root)
if (!LIVE %in% names(L$prob)) stop("Unknown model: ", LIVE, ". One of: ", paste(names(L$prob), collapse = "; "))
P <- L$P; X <- L$X; PW <- L$prob[[LIVE]]
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

# ---- attention, for the viewer's Model Attention toggle (transformer live models only) ----------------------
# web/public/data/coverage_attention.json: per screen, its players (roster: the four of the screen first) and, at
# every frame, which roster player sits in token rows 5-10 (k, 0-based) and the whole-percent share of the four screen
# players' attention going to each of the ten rows (w). Loaded by the site only when the toggle is on.
if (startsWith(LIVE, "transformer: ")) {
  A <- load_tf_attention(root, TF_VARIANT[[sub("^transformer: ", "", LIVE)]])
  ids <- readRDS(file.path(root, "outputs", "cache", "screen_coverage", "tokens.rds"))$ids
  att_screens <- lapply(seq_len(nrow(P)), function(k) {
    r <- rows[[as.character(k)]]
    roster <- unique(c(ids[r[1], 1:4], as.vector(ids[r, 5:10])))
    list(id = P$id[k], f0 = P$f0[k], r = roster,
         k = lapply(r, function(i) match(ids[i, 5:10], roster) - 1L),
         w = lapply(r, function(i) as.integer(round(100 * A[i, ]))))
  })
  jsonlite::write_json(list(model = LIVE, offsets = range(L$offs), generated = format(Sys.time(), "%Y-%m-%d %H:%M"),
                            possessions = split(att_screens, P$poss)),
                       file.path(root, "web", "public", "data", "coverage_attention.json"), auto_unbox = TRUE)
  cat("Wrote web/public/data/coverage_attention.json\n")
}
