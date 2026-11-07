# Export the play viewer's data for the static site in web/.
#   Rscript web/scripts/export_data.R          (from anywhere inside the repository)
#   Rscript web/scripts/export_data.R --page   (only archetypes.html, after editing the Archetypes tab's wording)
#
# Reads the Shiny app's caches through the app's own functions and writes to web/public/data/:
#   meta.json            filter choices and the export's `generated` stamp
#   plays.json           one light record per possession: list text plus the fields the filters need
#   g<game>_p<period>.json   per-play header for one game period: players, events, touches, byte offsets
#   g<game>_p<period>.bin    that period's tracking
#   archetypes.html      the app's Archetypes tab, as the app renders it (needs outputs/archetypes/)
#   season.json          season counts per person and team from data/aggregates/ (annotations.R)
#
# Each play header also carries `ann`: the event locations and context the site draws over the court
# (annotations.R). The Shiny app does not draw these.
#
# Binary layout, little-endian. Each play is one segment starting on a 4-byte boundary:
#   int32  frames[n]                                                          (-1 = null)
#   int16  gc[n]*10, sc[n]*10, ball x[n], y[n], z[n] *100,
#          per player: x[n], y[n] *100                                       (-32768 = null)
#   uint8  stopped[n], per player: detected[n], then per player: predError[n]*10 (255 = null; kept within 0-25.4 ft)
# The app already rounds to these precisions, so the integers are exact and the site shows the app's numbers.
#
# After a full run, run web/scripts/parity_reference.R too and keep both outputs together. A --page run leaves
# the data and its stamp alone, so the reference stays valid.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "load_app.R"))

a <- load_shiny_app()
source(file.path(if (length(script)) dirname(script) else "web/scripts", "annotations.R"))
out_dir <- file.path(a$root, "web", "public", "data")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# ---- the Archetypes tab, rendered by the app's own page function ------------------------------

writeLines(enc2utf8(as.character(a$archetype_page(a$root))), file.path(out_dir, "archetypes.html"), useBytes = TRUE)
if ("--page" %in% args) {
  message("Wrote archetypes.html only.")
  quit(save = "no")
}

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
  i32 <- ids32(p$frames)
  i16 <- c(scaled(p$gc, 10), scaled(p$sc, 10), scaled(p$ball$x, 100), scaled(p$ball$y, 100), scaled(p$ball$z, 100),
           unlist(lapply(p$players, function(pl) c(scaled(pl$x, 100), scaled(pl$y, 100)))))
  err <- function(v) {
    out <- pmin(pmax(as.integer(round(as.numeric(v) * 10)), 0L), 254L)   # a few predErrors are slightly negative
    out[is.na(out)] <- 255L
    out
  }
  u8 <- c(as.integer(p$stopped), unlist(lapply(p$players, function(pl) fcoalesce(as.integer(pl$d), 0L))),
          unlist(lapply(p$players, function(pl) err(pl$e))))
  bytes <- 4L * length(i32) + 2L * length(i16) + length(u8)
  pad <- (4L - bytes %% 4L) %% 4L
  writeBin(i32, con, size = 4L, endian = "little")
  writeBin(i16, con, size = 2L, endian = "little")
  writeBin(as.raw(u8), con)
  writeBin(raw(pad), con)
  bytes + pad
}

#' Everything about a play that is not a per-frame series.
play_header <- function(p, offset, ann) {
  row <- a$app_data$plays[id == p$id]
  roster <- a$app_data$roster[game_id == row$game_id]
  team_of <- function(pid) roster$team_id[match(pid, roster$pid)]
  canon_of <- function(pid) fcoalesce(roster$canon[match(pid, roster$pid)], as.integer(pid))
  list(id = p$id, o = offset, n = length(p$frames), game = p$game, period = p$period,
       off = p$off, def = p$def, home = p$home, away = p$away, homeScore = p$homeScore, awayScore = p$awayScore,
       result = p$result, who = p$who, and1 = isTRUE(p$and1), types = I(as.character(p$types)), colors = p$colors,
       leftHoop = row$left_hoop, startType = row$start_type, offTeam = row$off_team, defTeam = row$def_team,
       homeTeam = row$home_team,
       players = lapply(p$players, function(pl) c(pl[c("id", "jersey", "name", "last", "role")], list(arch = pl$arch),
                                                  list(canon = canon_of(pl$id), team = team_of(pl$id)))),
       events = p$events, touches = p$touches, ann = ann)
}

save_json <- function(x, name) {
  write_json(x, file.path(out_dir, name), auto_unbox = TRUE, digits = NA, na = "null", null = "null")
}

# ---- tracking, one pair of files per game period -------------------------------------

plays <- copy(a$app_data$plays)
plays[, file := sprintf("g%d_p%d", game_id, period)]
game_ann <- list()
for (stem in unique(plays$file)) {
  message("Writing ", stem)
  con <- file(file.path(out_dir, paste0(stem, ".bin")), "wb")
  offset <- 0L
  headers <- list()
  for (play_id in plays$id[plays$file == stem]) {
    row <- plays[id == play_id]
    key <- as.character(row$game_id)
    if (is.null(game_ann[[key]])) game_ann[[key]] <- game_annotations(row$game_id)
    p <- app_payload(a, play_id)
    headers[[play_id]] <- play_header(p, offset, play_annotations(game_ann[[key]], row$view_start, row$view_end))
    offset <- offset + write_segment(con, p)
  }
  close(con)
  save_json(list(bytes = offset, plays = headers), paste0(stem, ".json"))
}

# ---- play list with the fields the filters read -------------------------------------------------

shown <- fromJSON(a$plays_json(a$app_data, plays), simplifyDataFrame = TRUE)
stopifnot(identical(shown$id, plays$id))
actors <- split(a$app_data$actors[, .(type, pid)], a$app_data$actors$poss_id)
light <- lapply(seq_len(nrow(plays)), function(i) {
  acted <- actors[[plays$id[i]]]
  list(id = plays$id[i], file = plays$file[i], gameId = plays$game_id[i], game = shown$game[i], q = shown$q[i],
       clock = shown$clock[i], off = shown$off[i], def = shown$def[i], secs = shown$secs[i], result = shown$result[i], and1 = isTRUE(plays$and1[i]),
       who = shown$who[i], typeLabels = shown$types[i], types = I(as.character(plays$types[[i]])),
       shotTypes = I(as.character(plays$shot_types[[i]])), offTeam = plays$off_team[i], defTeam = plays$def_team[i],
       oreb = plays$n_oreb[i], offIds = I(as.integer(plays$off_ids[[i]])), defIds = I(as.integer(plays$def_ids[[i]])),
       actors = if (is.null(acted)) list() else lapply(seq_len(nrow(acted)), function(j) list(acted$type[j], acted$pid[j])))
})
save_json(light, "plays.json")
save_json(season_figures(), "season.json")

# ---- filter choices, exactly as the Shiny inputs list them -------------------------------------

options_of <- function(named) lapply(seq_along(named), function(i) list(value = as.character(named[[i]]), label = names(named)[i]))
players <- a$choices$player[nzchar(a$choices$player)]
generated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
save_json(list(generated = generated, plays = nrow(plays), files = length(unique(plays$file)),
               game = options_of(a$choices$game), team = options_of(a$choices$team), player = options_of(players),
               period = options_of(a$choices$period), types = options_of(a$choices$types),
               result = options_of(a$choices$result), shotType = options_of(a$choices$shot_type),
               teamColors = lapply(a$TEAM_COLORS, function(pair) I(unname(pair)))),
          "meta.json")

sizes <- file.size(list.files(out_dir, full.names = TRUE))
message(sprintf("Exported %d plays in %d files, %.1f MB in total (largest file %.2f MB). Stamp %s.", nrow(plays),
                length(sizes), sum(sizes) / 1e6, max(sizes) / 1e6, generated))
