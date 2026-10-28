# Shared start for the rebounding stage scripts: sources the modules, compiles the C++ simulator and loads
# the audited episodes and their bundles (building the bundles on first use).
# Expects `here` (the src/rebounding directory) to be set by the calling script.

suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "flight.R", "opportunity.R", "late.R", "skills.R"))
  if (file.exists(file.path(here, "R", f))) source(file.path(here, "R", f))

root <- find_repo_root()
cache <- file.path(root, "outputs", "cache", "rebounding")
report <- file.path(root, "outputs", "rebounding")
dir.create(report, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
games <- matches$id
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
load_ball_cpp(here, cache)

audited <- readRDS(file.path(cache, "episodes.rds"))
episodes <- audited$episodes
hoops <- audited$hoops

read_raw <- function(g) {
  raw <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
  raw$home_team <- matches$home_team$id[matches$id == g]
  raw
}

bundles_path <- file.path(cache, "bundles.rds")
if (file.exists(bundles_path)) {
  bundles <- readRDS(bundles_path)
} else {
  bundles <- unlist(lapply(games, function(g) game_bundles(read_raw(g), episodes, hoops, aliases)), recursive = FALSE)
  saveRDS(bundles, bundles_path)
}
bundle_game <- vapply(bundles, function(b) b$game_id, 0L)

#' Launch library: every tracked attempt of the given games, made or missed (framework section 12: fit launch
#' and flight priors on all usable attempts, then condition simulations on a miss).
launch_path <- file.path(cache, "launch_rows.rds")
if (file.exists(launch_path)) {
  launch_rows_all <- readRDS(launch_path)
} else {
  launch_rows_all <- rbindlist(lapply(games, function(g) {
    raw <- read_raw(g)
    sh <- episodes[game_id == g & !is.na(f0) & !is.na(f1)]
    rbindlist(lapply(seq_len(nrow(sh)), function(k) {
      s <- sh[k]
      h <- hoops[game_id == g & left_hoop == s$left_hoop]
      tr <- ball_track(raw$frames, s, s$f0, s$f1 + 15L)[!is.na(x)]
      tr <- tr[, .(t = (frame - s$f0) / FPS, x = x - h$hx, y = y - h$hy, z, key = !(interp %in% TRUE))][key | t == 0]
      r <- launch_row(tr)
      if (is.null(r)) NULL else r[, c("game_id", "shot_id", "made") := .(g, s$shot_id, s$made)]
    }))
  }))
  saveRDS(launch_rows_all, launch_path)
}
