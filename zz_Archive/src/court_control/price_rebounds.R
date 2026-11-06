# Price the offensive-rebound chance for every potential shooter EPV prices, for src/epv/build_epv.R.
#   Rscript src/court_control/price_rebounds.R [--force]
#
# Needs outputs/cache/epv/tables.rds (from build_epv.R) and the per-fold rebound parameters
# outputs/cache/court_control/params_{gameId}.rds (from build_control.R). Each game is priced with the
# parameters fitted without it, so EPV's leave-one-game-out validation never sees a game's own rebounds.
# Writes outputs/cache/court_control/poreb_{gameId}.rds: (frame, pid, poreb) for every offensive player on
# every frame EPV prices, if he is within POREB_RANGE of the hoop. Finished games are kept unless --force.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/court_control"
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "..", "epv", "R", "features.R"))
source(file.path(here, "R", "data.R"))
source(file.path(here, "R", "control.R"))

POREB_RANGE <- 35   # ft: EPV gives no shot value beyond 30 ft; a little more covers receivers moving inward

app <- load_app_data()
games <- app$matches$game_id
cache <- file.path(app$root, "outputs", "cache", "court_control")
epv_tabs <- readRDS(file.path(app$root, "outputs", "cache", "epv", "tables.rds"))
grid <- court_grid(REBOUND_CELL, half = TRUE, reach = REBOUND_REACH)

for (k in seq_along(games)) {
  g <- games[k]
  out_path <- file.path(cache, paste0("poreb_", g, ".rds"))
  if (file.exists(out_path) && !"--force" %in% args) next
  par <- readRDS(file.path(cache, paste0("params_", g, ".rds")))
  started <- Sys.time()
  # The same state EPV built its tables from (game_tables() in src/epv/R/features.R), matched by frame.
  ev <- game_events(app$root, g)
  S <- game_state(app, g, extra_frames = c(ev$shots$frame, ev$passes$frame))
  tab <- epv_tabs[[k]]
  stopifnot(tab$rows$game_id[1] == g)
  sl <- unique(tab$slots[, .(row, pid)])
  sl[, frame := tab$rows$frame[match(row, tab$rows$row)]]
  sl[, srow := match(frame, S$fr$frame)]
  hit <- S$off$pid[sl$srow, , drop = FALSE] == sl$pid
  sl <- sl[rowSums(hit) == 1L]
  slot <- max.col(S$off$pid[sl$srow, , drop = FALSE] == sl$pid, ties.method = "first")
  sl[, c("sx", "sy") := .(pick(S$off$x[srow, , drop = FALSE], slot), pick(S$off$y[srow, , drop = FALSE], slot))]
  sl <- sl[sqrt((sx - HOOP_X)^2 + sy^2) <= POREB_RANGE]
  sl[, poreb := rebound_chance_many(ten(S, srow), sx, sy, grid, par)]
  saveRDS(unique(sl[, .(frame, pid, poreb)], by = c("frame", "pid")), out_path)
  message(sprintf("Game %d: %d shooter-frames in %.1f min, mean P(OREB) %.3f", g, nrow(sl),
                  as.numeric(difftime(Sys.time(), started, units = "mins")), mean(sl$poreb)))
}
