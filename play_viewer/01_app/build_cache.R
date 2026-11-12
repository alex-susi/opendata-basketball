# Pre-build the play viewer cache (the app also does this on first start).
# Run from anywhere inside the repository:
#   Rscript play_viewer/01_app/build_cache.R [--force]

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
source(file.path(if (length(script)) dirname(script) else "play_viewer/01_app", "R", "data.R"))

root <- find_repo_root()
started <- Sys.time()
rebuilt <- ensure_cache(root, force = "--force" %in% args)
app <- readRDS(index_cache_path(root))

message(sprintf("Cache ready in %s: %d tracking files rebuilt, %.0f s.", cache_dir(root), length(rebuilt),
                as.numeric(difftime(Sys.time(), started, units = "secs"))))
message(sprintf("%d possessions indexed; %d with under %d live frames left out.", nrow(app$plays),
                app$dropped_short, MIN_LIVE_FRAMES))
print(app$plays[, .(plays = .N, live_minutes = round(sum(n_live) / 1500, 1)), by = game_id])
