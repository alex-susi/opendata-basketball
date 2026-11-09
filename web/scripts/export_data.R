# Export the play viewer's data for the static site in web/.
#   Rscript web/scripts/export_data.R          (from anywhere inside the repository)
#   Rscript web/scripts/export_data.R --page   (only archetypes.html, after editing the Archetypes tab's wording)
#   Rscript web/scripts/export_data.R --figures   (only season.json, sample.json and playstyle.json)
#
# Reads the Shiny app's caches through the app's own functions and writes to web/public/data/:
#   meta.json            filter choices and the export's `generated` stamp
#   plays.json           one light record per possession: list text plus the fields the filters need
#   g<game>_p<period>.json   per-play header for one game period: players, events, touches, byte offsets
#   g<game>_p<period>.bin    that period's tracking
#   archetypes.html      the app's Archetypes tab, as the app renders it (needs outputs/archetypes/)
#   season.json          season counts per person and team from data/aggregates/ (annotations.R)
#   sample.json          per person and team over the ten tracked games: box score, ratings, shot quality,
#                        tracking and points per action (sample_stats.R)
#   playstyle.json       archetype probabilities and component scores per player (playstyle.R)
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
source(file.path(if (length(script)) dirname(script) else "web/scripts", "cuts.R"))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "glass.R"))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "sample_stats.R"))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "playstyle.R"))
out_dir <- file.path(a$root, "web", "public", "data")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# ---- the Archetypes tab, rendered by the app's own page function ------------------------------

writeLines(enc2utf8(as.character(a$archetype_page(a$root))), file.path(out_dir, "archetypes.html"), useBytes = TRUE)
if ("--page" %in% args) {
  message("Wrote archetypes.html only.")
  quit(save = "no")
}

save_json <- function(x, name) {
  write_json(x, file.path(out_dir, name), auto_unbox = TRUE, digits = NA, na = "null", null = "null")
}
# The player card's figures; they do not touch the plays, so the export stamp and parity reference stay valid.
save_figures <- function() {
  save_json(season_figures(), "season.json")
  save_json(sample_figures(), "sample.json")
  save_json(playstyle_figures(), "playstyle.json")
}
if ("--figures" %in% args) {
  save_figures()
  message("Wrote season.json, sample.json and playstyle.json only.")
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
# Cuts (cuts.R; the site only, not the Shiny app): a play has the cuts that start inside its viewing window. They
# join its actions for the Action filter, its chips in the play list (in the order they happen) and its actors.
CUT_TYPES <- c(cut_basket = "Basket Cut", cut_in = "Off-Ball Screen Cut (In)", cut_out = "Off-Ball Screen Cut (Out)", cut_pop = "Pick and Pop")
CUT_CHIPS <- c(cut_basket = "Basket Cut", cut_in = "Screen Cut In", cut_out = "Screen Cut Out", cut_pop = "Pick and Pop")
# Each action's first frame and how many times it happens in the possession (the chips show "×n" for more than one).
first_at <- a$app_data$events[, .(frame = min(frame), n = .N), by = .(poss_id, type)]
play_actions <- function(i) {
  id <- plays$id[i]
  types <- as.character(plays$types[[i]])
  mine <- first_at[poss_id == id][match(types, type)]
  at <- mine$frame
  counts <- fcoalesce(mine$n, 1L)
  at[types == "transition"] <- -Inf
  counts[types == "transition"] <- 1L
  cuts <- game_ann[[as.character(plays$game_id[i])]]$cuts
  cuts <- if (is.null(cuts)) cuts else cuts[f >= plays$view_start[i] & f <= plays$view_end[i]]
  # Only this possession's offense: a cut near the window's edge can belong to the neighbouring possession.
  if (!is.null(cuts) && nrow(cuts)) {
    team <- a$app_data$roster[game_id == plays$game_id[i]][match(cuts$pid, pid), team_id]
    cuts <- cuts[team %in% plays$off_team[i]]
  }
  if (!is.null(cuts) && nrow(cuts)) {
    cut_first <- cuts[, .(f = min(f), n = .N), by = .(code = paste0("cut_", kind))]
    types <- c(types, cut_first$code)
    at <- c(at, cut_first$f)
    counts <- c(counts, cut_first$n)
  }
  at[is.na(at)] <- Inf
  o <- order(at)
  types <- types[o]
  list(types = types, counts = counts[o], labels = paste(c(a$PLAY_TYPES, CUT_CHIPS)[types], collapse = "|"),
       actors = if (is.null(cuts) || !nrow(cuts)) list() else lapply(seq_len(nrow(cuts)), function(j) list(paste0("cut_", cuts$kind[j]), cuts$pid[j])))
}
light <- lapply(seq_len(nrow(plays)), function(i) {
  acted <- actors[[plays$id[i]]]
  acts <- play_actions(i)
  list(id = plays$id[i], file = plays$file[i], gameId = plays$game_id[i], game = shown$game[i], q = shown$q[i],
       clock = shown$clock[i], off = shown$off[i], def = shown$def[i], secs = shown$secs[i], result = shown$result[i], and1 = isTRUE(plays$and1[i]),
       who = shown$who[i], typeLabels = acts$labels, types = I(acts$types), typeCounts = I(as.integer(acts$counts)),
       shotTypes = I(as.character(plays$shot_types[[i]])), offTeam = plays$off_team[i], defTeam = plays$def_team[i],
       oreb = plays$n_oreb[i], offIds = I(as.integer(plays$off_ids[[i]])), defIds = I(as.integer(plays$def_ids[[i]])),
       actors = c(if (is.null(acted)) list() else lapply(seq_len(nrow(acted)), function(j) list(acted$type[j], acted$pid[j])), acts$actors))
})
save_json(light, "plays.json")
save_figures()

# ---- filter choices, exactly as the Shiny inputs list them -------------------------------------

options_of <- function(named) lapply(seq_along(named), function(i) list(value = as.character(named[[i]]), label = names(named)[i]))
players <- a$choices$player[nzchar(a$choices$player)]
generated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
save_json(list(generated = generated, plays = nrow(plays), files = length(unique(plays$file)),
               game = options_of(a$choices$game), team = options_of(a$choices$team), player = options_of(players),
               period = options_of(a$choices$period), types = c(options_of(a$choices$types), options_of(setNames(names(CUT_TYPES), CUT_TYPES))),
               result = options_of(a$choices$result), shotType = options_of(a$choices$shot_type),
               teamColors = lapply(a$TEAM_COLORS, function(pair) I(unname(pair)))),
          "meta.json")

sizes <- file.size(list.files(out_dir, full.names = TRUE))
message(sprintf("Exported %d plays in %d files, %.1f MB in total (largest file %.2f MB). Stamp %s.", nrow(plays),
                length(sizes), sum(sizes) / 1e6, max(sizes) / 1e6, generated))
