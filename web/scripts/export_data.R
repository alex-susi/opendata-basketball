# Export the play viewer's data for the static site in web/.
#   Rscript web/scripts/export_data.R          (from anywhere inside the repository)
#
# Reads the Shiny app's caches through the app's own functions and writes to web/public/data/:
#   meta.json            filter choices and the export's `generated` stamp
#   plays.json           one light record per possession: list text plus the fields the filters need
#   g<game>_p<period>.json   per-play header for one game period: players, events, touches, byte offsets
#   g<game>_p<period>.bin    that period's tracking and EPV prices
#   archetypes.html      the app's Archetypes tab, as the app renders it (needs outputs/archetypes/)
#
# Binary layout, little-endian. Each play is one segment starting on a 4-byte boundary:
#   int32  frames[n], epv.f[m], epv.to[m], epv.holder[m]                      (-1 = null)
#   int16  gc[n]*10, sc[n]*10, ball x[n], y[n], z[n] *100,
#          per player: x[n], y[n] *100,
#          epv v, shot, pass [m] *1000; haz, rop, cum [m] *10000,
#          per priced player: sv[m], pv[m] *1000; tov[m] *10000               (-32768 = null)
#   uint8  stopped[n], per player: detected[n]
# The app already rounds to these precisions, so the integers are exact and the site shows the app's numbers.
#
# After running this, run web/scripts/parity_reference.R too and keep both outputs together.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "load_app.R"))

a <- load_shiny_app()
out_dir <- file.path(a$root, "web", "public", "data")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
unlink(list.files(out_dir, "^g[0-9]+_p[0-9]+[.](bin|json)$", full.names = TRUE))

NULL16 <- -32768L

#' Scale to integers; NA becomes the int16 null marker.
scaled <- function(v, scale) {
  out <- as.integer(round(as.numeric(v) * scale))
  out[is.na(out)] <- NULL16
  stopifnot(all(out >= NULL16 & out <= 32767L))
  out
}

#' Integers with NA mapped to -1.
ids32 <- function(v) {
  out <- as.integer(v)
  out[is.na(out)] <- -1L
  out
}

#' Write one play's segment and return its length in bytes (a multiple of 4).
write_segment <- function(con, p) {
  e <- p$epv
  priced <- e$players
  i32 <- c(ids32(p$frames), ids32(e$f), ids32(e$to), ids32(e$holder))
  i16 <- c(scaled(p$gc, 10), scaled(p$sc, 10), scaled(p$ball$x, 100), scaled(p$ball$y, 100), scaled(p$ball$z, 100),
           unlist(lapply(p$players, function(pl) c(scaled(pl$x, 100), scaled(pl$y, 100)))),
           scaled(e$v, 1000), scaled(e$shot, 1000), scaled(e$pass, 1000),
           scaled(e$haz, 10000), scaled(e$rop, 10000), scaled(e$cum, 10000),
           unlist(lapply(priced, function(o) c(scaled(o$sv, 1000), scaled(o$pv, 1000), scaled(o$tov, 10000)))))
  u8 <- c(as.integer(p$stopped), unlist(lapply(p$players, function(pl) fcoalesce(as.integer(pl$d), 0L))))
  bytes <- 4L * length(i32) + 2L * length(i16) + length(u8)
  pad <- (4L - bytes %% 4L) %% 4L
  writeBin(i32, con, size = 4L, endian = "little")
  writeBin(i16, con, size = 2L, endian = "little")
  writeBin(as.raw(u8), con)
  writeBin(raw(pad), con)
  bytes + pad
}

#' Everything about a play that is not a per-frame series.
play_header <- function(p, offset) {
  list(id = p$id, o = offset, n = length(p$frames), m = length(p$epv$f), game = p$game, period = p$period,
       off = p$off, def = p$def, home = p$home, away = p$away, homeScore = p$homeScore, awayScore = p$awayScore,
       result = p$result, who = p$who, types = I(as.character(p$types)),
       players = lapply(p$players, function(pl) c(pl[c("id", "jersey", "name", "last", "role")], list(arch = pl$arch))),
       priced = I(as.integer(names(p$epv$players))), events = p$events, touches = p$touches)
}

save_json <- function(x, name) {
  write_json(x, file.path(out_dir, name), auto_unbox = TRUE, digits = NA, na = "null", null = "null")
}

# ---- tracking and prices, one pair of files per game period -------------------------------------

plays <- copy(a$app_data$plays)
plays[, file := sprintf("g%d_p%d", game_id, period)]
for (stem in unique(plays$file)) {
  message("Writing ", stem)
  con <- file(file.path(out_dir, paste0(stem, ".bin")), "wb")
  offset <- 0L
  headers <- list()
  for (play_id in plays$id[plays$file == stem]) {
    p <- app_payload(a, play_id)
    headers[[play_id]] <- play_header(p, offset)
    offset <- offset + write_segment(con, p)
  }
  close(con)
  save_json(list(bytes = offset, plays = headers), paste0(stem, ".json"))
}

# ---- the Archetypes tab, rendered by the app's own page function ------------------------------

writeLines(enc2utf8(as.character(a$archetype_page(a$root))), file.path(out_dir, "archetypes.html"), useBytes = TRUE)

# ---- play list with the fields the filters read -------------------------------------------------

shown <- fromJSON(a$plays_json(a$app_data, plays), simplifyDataFrame = TRUE)
stopifnot(identical(shown$id, plays$id))
actors <- split(a$app_data$actors[, .(type, pid)], a$app_data$actors$poss_id)
light <- lapply(seq_len(nrow(plays)), function(i) {
  acted <- actors[[plays$id[i]]]
  list(id = plays$id[i], file = plays$file[i], gameId = plays$game_id[i], game = shown$game[i], q = shown$q[i],
       clock = shown$clock[i], off = shown$off[i], def = shown$def[i], secs = shown$secs[i], result = shown$result[i],
       who = shown$who[i], typeLabels = shown$types[i], types = I(as.character(plays$types[[i]])),
       shotTypes = I(as.character(plays$shot_types[[i]])), offTeam = plays$off_team[i], defTeam = plays$def_team[i],
       offIds = I(as.integer(plays$off_ids[[i]])), defIds = I(as.integer(plays$def_ids[[i]])),
       actors = if (is.null(acted)) list() else lapply(seq_len(nrow(acted)), function(j) list(acted$type[j], acted$pid[j])))
})
save_json(light, "plays.json")

# ---- filter choices, exactly as the Shiny inputs list them -------------------------------------

options_of <- function(named) lapply(seq_along(named), function(i) list(value = as.character(named[[i]]), label = names(named)[i]))
players <- a$choices$player[nzchar(a$choices$player)]
generated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
save_json(list(generated = generated, plays = nrow(plays), files = length(unique(plays$file)),
               game = options_of(a$choices$game), team = options_of(a$choices$team), player = options_of(players),
               period = options_of(a$choices$period), types = options_of(a$choices$types),
               result = options_of(a$choices$result), shotType = options_of(a$choices$shot_type)),
          "meta.json")

sizes <- file.size(list.files(out_dir, full.names = TRUE))
message(sprintf("Exported %d plays in %d files, %.1f MB in total (largest file %.2f MB). Stamp %s.", nrow(plays),
                length(sizes), sum(sizes) / 1e6, max(sizes) / 1e6, generated))
