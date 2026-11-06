# Read the rebound episodes and the raw tracking windows around every shot of the ten games.
#   Rscript src/rebounding/extract_windows.R [--force]
# Writes outputs/cache/rebounding/raw_{gameId}.rds (git-ignored). About a minute per game.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "extract.R"))

root <- find_repo_root()
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
cache <- file.path(root, "outputs", "cache", "rebounding")
dir.create(cache, recursive = TRUE, showWarnings = FALSE)
for (g in matches$id) {
  t0 <- Sys.time()
  raw <- game_raw(root, g, aliases, cache, force = "--force" %in% args)
  message(sprintf("%s: %d shots, %d frames, %.0f s", g, nrow(raw$shots), nrow(raw$frames),
                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}
