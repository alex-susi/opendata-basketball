# Data layer for the play viewer: event index, tracking cache and per-play payloads.
# Files under data/ are only read. Derived files go to outputs/cache/play_viewer/.

suppressPackageStartupMessages(library(data.table))

CACHE_VERSION <- 1L          # tracking cache
INDEX_VERSION <- 3L          # play index (viewing windows and re-homed action markings since 3)
MIN_LIVE_FRAMES <- 25L
MAX_GAMES_IN_MEMORY <- 3L

PLAY_TYPES <- c(pick = "Pick", handoff = "Handoff", off_ball_screen = "Off-ball screen", drive = "Drive",
                isolation = "Isolation", post = "Post-up", closeout = "Closeout", transition = "Transition")

# Roster tag for each playstyle archetype: the label shown beside a name and its colour slot (--arch-* in
# www/style.css). A defensive role takes the colour of the offensive archetype most of its players have, so a
# player usually keeps his colour at both ends. An archetype missing here is shown by its full name in grey.
ARCHETYPE_TAGS <- list("Primary Ball Handler" = c("Primary BH", "primary"), "Secondary Ball Handler" = c("Secondary BH", "secondary"),
                       "Slasher" = c("Slasher", "slasher"), "Off Screen Shooter" = c("Off Screen Shooter", "offscreen"),
                       "Movement Shooter" = c("Movement Shooter", "movement"), "Stationary Shooter" = c("Stationary Shooter", "stationary"),
                       "Athletic Finisher" = c("Athletic Finisher", "finisher"), "Versatile Big" = c("Versatile Big", "versatile"),
                       "Post Scorer" = c("Post Scorer", "post"), "Roll & Cut Big" = c("R&C Big", "big"),
                       "Point of Attack" = c("Point of Attack", "primary"), "Chaser" = c("Chaser", "secondary"),
                       "Helper" = c("Helper", "movement"), "Anchor Big" = c("Anchor Big", "big"))

# Club colours by SkillCorner team id: primary, then secondary. Entered by hand from the clubs' kits and crests.
# They only style the viewer and are no part of any analysis.
TEAM_COLORS <- list("1330" = c("#E30613", "#FFFFFF"),    # BAXI Manresa: red, white
                    "1340" = c("#004D98", "#A50044"),    # Barcelona: blue, garnet
                    "1332" = c("#0A3A9A", "#FFD100"),    # MoraBanc Andorra: blue, yellow
                    "1315" = c("#D0202E", "#FFFFFF"),    # Basquet Girona: red, white
                    "1335" = c("#111111", "#FFFFFF"),    # Bilbao Basket: black, white
                    "1326" = c("#9D2235", "#13294B"),    # Baskonia: maroon, navy
                    "1334" = c("#D2232A", "#0C2340"),    # UCAM Murcia: red, navy
                    "1331" = c("#E2001A", "#FFFFFF"),    # Casademont Zaragoza: red, white
                    "1336" = c("#00843D", "#111111"),    # Joventut Badalona: green, black
                    "1319" = c("#D8232A", "#111111"),    # Coviran Granada: red, black
                    "1328" = c("#FFD100", "#00338D"),    # Gran Canaria: yellow, blue
                    "1322" = c("#6CACE4", "#FFFFFF"),    # Rio Breogan: sky blue, white
                    "1333" = c("#FFD100", "#111111"),    # Lenovo Tenerife: yellow, black
                    "1339" = c("#00A651", "#5C2D91"),    # Unicaja Malaga: green, purple
                    "1338" = c("#FFFFFF", "#00529F"),    # Real Madrid: white, blue
                    "1316" = c("#1D4F9C", "#FFFFFF"),    # San Pablo Burgos: blue, white
                    "1325" = c("#F58220", "#111111"))    # Valencia Basket: orange, black
SPARE_COLORS <- list(home = c("#1F6FE5", "#FFFFFF"), away = c("#F26A36", "#FFFFFF"))   # a team missing above
FLOOR_COLOR <- "#F6CFA3"     # the court, as drawn by the front ends
PANEL_COLOR <- "#1B2334"     # the dark surface team names are written on
CLASH_DISTANCE <- 110        # RGB distance under which two primaries read as the same colour

RESULT_LABELS <- c(FGM = "Made 2", FGM3 = "Made 3", FGX = "Missed 2", FGX3 = "Missed 3", TO = "Turnover",
                   FOU = "Foul", VIO = "Violation", JMP = "Jump ball", EPD = "End of period")

# Event families that mark a play type or a shot: where the frame lives and who the actors are.
ACTIONS <- list(pick = list(table = "picks", frame = "frame", off = c("ballhandlerId", "screenerId"),
                            def = c("ballhandlerDefId", "screenerDefId")),
                handoff = list(table = "handoffs", frame = "frame", off = c("setterId", "receiverId"),
                               def = c("setterDefId", "receiverDefId")),
                off_ball_screen = list(table = "off_ball_screens", frame = "frame",
                                       off = c("cutterId", "screenerId"), def = c("cutterDefId", "screenerDefId")),
                drive = list(table = "drives", frame = "startFrame", off = "ballhandlerId", def = "ballhandlerDefId"),
                isolation = list(table = "isolations", frame = "startFrame", off = "ballhandlerId",
                                 def = "ballhandlerDefId"),
                post = list(table = "posts", frame = "startFrame", off = "ballhandlerId", def = "ballhandlerDefId"),
                closeout = list(table = "closeouts", frame = "startFrame", off = "ballhandlerId",
                                def = "ballhandlerDefId"),
                shot = list(table = "shots", frame = "startFrame", off = "shooterId",
                            def = c("closestDefId", "blockerId")))

# ---- paths ---------------------------------------------------------------------------------------

#' Locate the repository root: the nearest parent folder that holds data/matches.json.
#' @param start Folder to start from.
#' @return Absolute path of the repository root.
find_repo_root <- function(start = getwd()) {
  dir <- normalizePath(start, winslash = "/")
  while (!file.exists(file.path(dir, "data", "matches.json"))) {
    parent <- dirname(dir)
    if (identical(parent, dir)) stop("Could not find data/matches.json above ", start)
    dir <- parent
  }
  dir
}

cache_dir <- function(root) file.path(root, "outputs", "cache", "play_viewer")
match_file <- function(root, game_id, suffix) file.path(root, "data", "matches", game_id, paste0(game_id, suffix))
tracking_cache_path <- function(root, game_id) file.path(cache_dir(root), paste0("tracking_", game_id, ".rds"))
index_cache_path <- function(root) file.path(cache_dir(root), "index.rds")

#' Find a game's tracking file, accepting both the delivered .jsonl.gz and an unpacked .jsonl.
#' @return Path to a materialised tracking file.
tracking_source <- function(root, game_id) {
  candidates <- match_file(root, game_id, c("_tracking_data.jsonl", "_tracking_data.jsonl.gz"))
  found <- candidates[file.exists(candidates)]
  if (!length(found)) stop("No tracking file for game ", game_id)
  if (file.size(found[1]) < 1e5) stop(found[1], " looks like a Git LFS pointer, not tracking data")
  found[1]
}

# ---- record helpers ------------------------------------------------------------------------------

read_json_file <- function(path) jsonlite::fromJSON(path, simplifyVector = FALSE)

#' Pull one scalar field from a list of records, mapping NULL to NA.
num_field <- function(recs, name) {
  vapply(recs, function(r) if (is.null(r[[name]])) NA_real_ else as.numeric(r[[name]])[1], 0)
}
int_field <- function(recs, name) as.integer(num_field(recs, name))
chr_field <- function(recs, name) {
  vapply(recs, function(r) if (is.null(r[[name]])) NA_character_ else as.character(r[[name]])[1], "")
}
lgl_field <- function(recs, name) vapply(recs, function(r) isTRUE(as.logical(r[[name]])), NA)

#' Map raw player ids to canonical ids with the supplied alias table (idempotent).
canon_id <- function(ids, aliases) {
  hit <- match(ids, aliases$player_id)
  ifelse(is.na(hit), ids, aliases$canonical_player_id[hit])
}

camel_to_words <- function(x) tolower(gsub("([a-z])([A-Z])", "\\1 \\2", x))

# ---- team colours --------------------------------------------------------------------------------

#' Relative luminance of a colour (WCAG), 0 for black to 1 for white.
luminance <- function(hex) {
  v <- grDevices::col2rgb(hex)[, 1] / 255
  sum(c(0.2126, 0.7152, 0.0722) * ifelse(v <= 0.03928, v / 12.92, ((v + 0.055) / 1.055)^2.4))
}

#' Contrast ratio between two colours (WCAG), from 1 to 21.
contrast <- function(a, b) {
  l <- sort(c(luminance(a), luminance(b)))
  (l[2] + 0.05) / (l[1] + 0.05)
}

#' The option that stands out most against a background.
clearest <- function(options, background) options[which.max(vapply(options, contrast, 0, b = background))]

#' A colour mixed with white until it can be read on the dark panel.
lightened <- function(hex) {
  rgb <- grDevices::col2rgb(hex)[, 1]
  for (share in seq(0, 0.9, 0.1)) {
    out <- grDevices::rgb(t(round(rgb + (255 - rgb) * share)), maxColorValue = 255)
    if (contrast(out, PANEL_COLOR) >= 3) break
  }
  out
}

#' How one team is drawn from its two colours: `fill` and `edge` for player dots and hulls, `ink` for the
#' number on a dot, `text` for the team's name on the dark panel, `mark` for outlines drawn on the floor.
team_kit <- function(pair) {
  fill <- pair[1]
  edge <- pair[2]
  readable <- function(hex) contrast(hex, PANEL_COLOR) >= 3
  list(fill = fill, edge = edge,
       ink = if (contrast(fill, edge) >= 4.5) edge else clearest(c("#FFFFFF", "#0B0E14"), fill),
       text = if (readable(fill)) fill else if (luminance(fill) < 0.02 && readable(edge)) edge else lightened(fill),
       mark = clearest(c(fill, edge), FLOOR_COLOR))
}

#' Both teams' colours for one possession. A team keeps its colours whichever end it is playing; when the two
#' primaries are too alike, the away team wears its secondary colour, as it would change kit.
side_colors <- function(row) {
  pair <- function(id, spare) if (is.null(TEAM_COLORS[[as.character(id)]])) spare else TEAM_COLORS[[as.character(id)]]
  home <- pair(row$home_team, SPARE_COLORS$home)
  away <- pair(row$away_team, SPARE_COLORS$away)
  apart <- sqrt(sum((grDevices::col2rgb(home[1]) - grDevices::col2rgb(away[1]))^2))
  if (apart < CLASH_DISTANCE) away <- rev(away)
  kits <- list(home = team_kit(home), away = team_kit(away))
  home_is_off <- row$off_team == row$home_team
  list(off = kits[[if (home_is_off) "home" else "away"]], def = kits[[if (home_is_off) "away" else "home"]])
}

# ---- tracking cache ------------------------------------------------------------------------------

#' Flatten one side's player objects for a chunk of parsed frames.
side_rows <- function(fr, key, home) {
  per_frame <- lapply(fr, `[[`, key)
  pl <- unlist(per_frame, recursive = FALSE)
  if (!length(pl)) return(NULL)
  xyz <- lapply(pl, `[[`, "xyz")
  data.table(frame = rep(int_field(fr, "frameIdx"), lengths(per_frame)),
             pid = int_field(pl, "playerId"),
             x = round(vapply(xyz, function(v) as.numeric(v[[1]]), 0), 2),
             y = round(vapply(xyz, function(v) as.numeric(v[[2]]), 0), 2),
             det = int_field(pl, "isDetected"),
             home = home,
             jersey = chr_field(pl, "jersey"))
}

#' Parse a chunk of JSON Lines into frame rows and player rows, dropping dead frames.
parse_tracking_chunk <- function(lines) {
  lines <- lines[nzchar(lines)]
  if (!length(lines)) return(NULL)
  fr <- jsonlite::fromJSON(paste0("[", paste(lines, collapse = ","), "]"), simplifyVector = FALSE)
  live <- lengths(lapply(fr, `[[`, "homePlayers")) + lengths(lapply(fr, `[[`, "awayPlayers")) > 0L
  fr <- fr[live]
  if (!length(fr)) return(NULL)
  ball <- lapply(fr, function(f) if (length(f$ball$xyz) == 3L) as.numeric(unlist(f$ball$xyz)) else rep(NA_real_, 3))
  frames <- data.table(frame = int_field(fr, "frameIdx"),
                       period = int_field(fr, "period"),
                       gc = num_field(fr, "gameClock"),
                       sc = num_field(fr, "shotClock"),
                       stopped = lgl_field(fr, "gameClockStopped"),
                       bx = round(vapply(ball, `[`, 0, 1L), 2),
                       by = round(vapply(ball, `[`, 0, 2L), 2),
                       bz = round(vapply(ball, `[`, 0, 3L), 2))
  list(frames = frames, players = rbind(side_rows(fr, "homePlayers", TRUE), side_rows(fr, "awayPlayers", FALSE)))
}

#' Stream one game's tracking file and keep the live frames in a compact form.
#' @return list(frames, players, jerseys, source_size, version).
build_tracking_cache <- function(root, game_id, chunk_lines = 4000L) {
  src <- tracking_source(root, game_id)
  con <- if (grepl("\\.gz$", src)) gzfile(src, "r") else file(src, "r")
  on.exit(close(con))
  parts <- list()
  repeat {
    lines <- readLines(con, n = chunk_lines, warn = FALSE)
    if (!length(lines)) break
    parts[[length(parts) + 1L]] <- parse_tracking_chunk(lines)
  }
  frames <- rbindlist(lapply(parts, `[[`, "frames"))
  players <- rbindlist(lapply(parts, `[[`, "players"))
  if (is.unsorted(frames$frame, strictly = TRUE)) stop("Tracking frames are not strictly increasing in game ", game_id)
  jerseys <- unique(players[, .(pid, jersey)], by = "pid")
  players[, jersey := NULL]
  out <- list(frames = frames, players = players, jerseys = jerseys, source_size = file.size(src),
              version = CACHE_VERSION)
  dir.create(cache_dir(root), recursive = TRUE, showWarnings = FALSE)
  saveRDS(out, tracking_cache_path(root, game_id))
  out
}

tracking_cache_is_current <- function(root, game_id) {
  path <- tracking_cache_path(root, game_id)
  if (!file.exists(path)) return(FALSE)
  cached <- readRDS(path)
  identical(cached$version, CACHE_VERSION) && identical(cached$source_size, file.size(tracking_source(root, game_id)))
}

# ---- event index ---------------------------------------------------------------------------------

#' Both rosters of one game as a table, with canonical ids.
game_roster <- function(root, game_id, aliases) {
  meta <- read_json_file(match_file(root, game_id, "_game_data.json"))
  team_rows <- function(team, home) {
    data.table(game_id = game_id, pid = int_field(team$players, "playerId"),
               first = chr_field(team$players, "firstName"), last = chr_field(team$players, "lastName"),
               jersey = chr_field(team$players, "jersey"), team_id = as.integer(team$teamId),
               team_name = team$teamName, home = home)
  }
  roster <- rbind(team_rows(meta$homeTeam, TRUE), team_rows(meta$awayTeam, FALSE))
  roster[, name := trimws(paste(first, last))]
  roster[, canon := canon_id(pid, aliases)]
  roster
}

#' Timeline labels for one action family.
action_labels <- function(type, recs, nm) {
  who <- function(field) nm(int_field(recs, field))
  made <- lgl_field(recs, "outcome")
  switch(type,
         pick = sprintf("Pick: %s screens for %s", who("screenerId"), who("ballhandlerId")),
         handoff = sprintf("Handoff: %s to %s", who("setterId"), who("receiverId")),
         off_ball_screen = sprintf("Off-ball screen: %s for %s", who("screenerId"), who("cutterId")),
         drive = sprintf("Drive: %s", who("ballhandlerId")),
         isolation = sprintf("Isolation: %s", who("ballhandlerId")),
         post = sprintf("Post-up: %s", who("ballhandlerId")),
         closeout = sprintf("Closeout: %s on %s", who("ballhandlerDefId"), who("ballhandlerId")),
         shot = sprintf("%s %s: %s (%s)", ifelse(made, "Made", "Missed"),
                        ifelse(lgl_field(recs, "three"), "3", "2"), who("shooterId"),
                        camel_to_words(chr_field(recs, "complexShotType"))))
}

# Which player a timeline tick is credited to, per action family.
TICK_PLAYER <- c(pick = "ballhandlerId", handoff = "receiverId", off_ball_screen = "cutterId", drive = "ballhandlerId",
                 isolation = "ballhandlerId", post = "ballhandlerId", closeout = "ballhandlerDefId", shot = "shooterId")

#' Short caption for a timeline tick: the play type, or "Made 3" / "Missed 2" for shots.
action_short <- function(type, recs) {
  if (type != "shot") return(rep(unname(PLAY_TYPES[type]), length(recs)))
  paste(ifelse(lgl_field(recs, "outcome"), "Made", "Missed"), ifelse(lgl_field(recs, "three"), 3, 2))
}

#' Timeline rows (possession, frame, kind, label, short caption, player) for one action family.
action_events <- function(type, ev, nm) {
  recs <- ev[[ACTIONS[[type]]$table]]
  if (!length(recs)) return(NULL)
  kind <- if (type == "shot") ifelse(lgl_field(recs, "outcome"), "made", "missed") else type
  data.table(poss_id = chr_field(recs, "possessionId"), type = type,
             frame = int_field(recs, ACTIONS[[type]]$frame), kind = kind, label = action_labels(type, recs, nm),
             short = action_short(type, recs), who = nm(int_field(recs, TICK_PLAYER[[type]])))
}

#' Players named in one action family, one row per (possession, type, player, side), with the action's frame.
action_actors <- function(type, ev) {
  spec <- ACTIONS[[type]]
  recs <- ev[[spec$table]]
  if (!length(recs)) return(NULL)
  side_actors <- function(fields, side) {
    rbindlist(lapply(fields, function(f) data.table(poss_id = chr_field(recs, "possessionId"), type = type,
                                                    frame = int_field(recs, spec$frame), pid = int_field(recs, f),
                                                    side = side)))
  }
  rbind(side_actors(spec$off, "off"), side_actors(spec$def, "def"))[!is.na(pid)]
}

#' Timeline rows for whistles, rebounds and free throws.
other_events <- function(ev, nm) {
  to <- ev$turnovers
  fo <- ev$fouls
  rb <- ev$rebounds
  ft <- ev$free_throws
  steal <- ifelse(is.na(int_field(to, "stealerId")), "", paste0(", steal ", nm(int_field(to, "stealerId"))))
  reb_who <- ifelse(lgl_field(rb, "rebounded"), nm(int_field(rb, "rebounderId")), "team")
  rbind(data.table(poss_id = chr_field(to, "possessionId"), type = "turnover", frame = int_field(to, "frame"),
                   kind = "turnover", label = sprintf("Turnover: %s%s", nm(int_field(to, "turnedOverId")), steal),
                   short = "Turnover", who = nm(int_field(to, "turnedOverId"))),
        data.table(poss_id = chr_field(fo, "possessionId"), type = "foul", frame = int_field(fo, "frame"),
                   kind = "foul",
                   label = sprintf("Foul: %s on %s", nm(int_field(fo, "foulerId")), nm(int_field(fo, "fouledId"))),
                   short = "Foul", who = nm(int_field(fo, "foulerId"))),
        data.table(poss_id = chr_field(rb, "possessionId"), type = "rebound", frame = int_field(rb, "frame"),
                   kind = "rebound",
                   label = sprintf("%s rebound: %s", ifelse(lgl_field(rb, "defensive"), "Defensive", "Offensive"),
                                   reb_who),
                   short = ifelse(lgl_field(rb, "defensive"), "Def. rebound", "Off. rebound"), who = reb_who),
        data.table(poss_id = chr_field(ft, "possessionId"), type = "free_throw", frame = int_field(ft, "frame"),
                   kind = ifelse(lgl_field(ft, "outcome"), "made", "missed"),
                   label = sprintf("Free throw %s: %s", ifelse(lgl_field(ft, "outcome"), "made", "missed"),
                                   nm(int_field(ft, "shooterId"))),
                   short = ifelse(lgl_field(ft, "outcome"), "FT made", "FT missed"), who = nm(int_field(ft, "shooterId"))))
}

#' Who to name next to a possession's result: the last shooter, the player who lost the ball, or the fouled player.
result_names <- function(plays, events) {
  last_label <- function(kinds) {
    last <- events[kind %in% kinds][order(frame), .SD[.N], by = poss_id]
    sub("^[^:]*: ", "", sub(" \\(.*$", "", last$label))[match(plays$id, last$poss_id)]
  }
  who <- fifelse(plays$outcome %in% c("FGM", "FGM3", "FGX", "FGX3"), last_label(c("made", "missed")),
                 fifelse(plays$outcome == "TO", sub(", steal.*$", "", last_label("turnover")),
                         fifelse(plays$outcome == "FOU", sub("^.* on ", "", last_label("foul")), NA_character_)))
  fifelse(is.na(who), "", who)
}

#' Last frame worth showing for each possession. The delivered endFrame can stop short: at a shot's release, at
#' the start of the possession's last chance, or (the last possession of a period) on its own first frame. The
#' window is stretched to the end of the possession's last chance and of its last shot. A chance whose frames
#' are reversed counts by its later frame.
view_end_frames <- function(plays, ev) {
  latest <- function(recs) {
    data.table(id = chr_field(recs, "possessionId"),
               f = pmax(int_field(recs, "startFrame"), int_field(recs, "endFrame"), na.rm = TRUE))
  }
  ends <- rbind(latest(ev$chances), latest(ev$shots))[!is.na(f), .(f = max(f)), by = id]
  pmax(plays$end_frame, ends$f[match(plays$id, ends$id)], na.rm = TRUE)
}

#' Move action markings to the possession they happened in. A few carry the id of their period's last
#' possession although their frame lies in an earlier one; left alone they would tag the wrong play.
#' @param dt Rows with `poss_id` and `frame`.
#' @return `dt` with `poss_id` corrected where another possession's window holds the frame.
rehome <- function(dt, plays) {
  own <- match(dt$poss_id, plays$id)
  inside <- dt$frame >= plays$start_frame[own] & dt$frame <= plays$view_end[own]
  for (i in which(!is.na(dt$frame) & !(inside %in% TRUE))) {
    holds <- which(plays$start_frame <= dt$frame[i] & plays$view_end >= dt$frame[i])
    if (length(holds)) set(dt, i, "poss_id", plays$id[holds[which.max(plays$start_frame[holds])]])
  }
  dt
}

#' Keep each possession's viewing window inside the tracking frames of its own period (one possession is
#' delivered with a start frame in the period before its own).
#' @return list(view_start, view_end).
clip_to_period <- function(plays, frames) {
  span <- frames[, .(lo = min(frame), hi = max(frame)), by = period]
  at <- match(plays$period, span$period)
  list(pmax(plays$start_frame, span$lo[at], na.rm = TRUE), pmin(plays$view_end, span$hi[at], na.rm = TRUE))
}

#' Count live frames and running-clock frames inside each possession's viewing window.
live_counts <- function(plays, frames) {
  hi <- findInterval(plays$view_end, frames$frame)
  lo <- findInterval(plays$view_start - 1L, frames$frame)
  running <- c(0L, cumsum(!frames$stopped))
  list(n_live = pmax(hi - lo, 0L), n_run = pmax(running[hi + 1L] - running[lo + 1L], 0L))
}

#' Index one game: possessions with filter fields, timeline events, touches and rosters.
game_index <- function(root, game_id, aliases, match_row) {
  ev <- read_json_file(match_file(root, game_id, "_dynamic_events.json"))
  roster <- game_roster(root, game_id, aliases)
  nm <- function(ids) fifelse(is.na(match(ids, roster$pid)), "unknown", roster$last[match(ids, roster$pid)])
  po <- ev$possessions
  if (any(vapply(po, function(p) is.null(p$leftHoop), NA))) warning("Missing leftHoop in game ", game_id)
  plays <- data.table(id = chr_field(po, "id"), game_id = game_id, period = int_field(po, "period"),
                      start_frame = int_field(po, "startFrame"), end_frame = int_field(po, "endFrame"),
                      start_gc = num_field(po, "startGameClock"), end_gc = num_field(po, "endGameClock"),
                      off_team = int_field(po, "offTeamId"), def_team = int_field(po, "defTeamId"),
                      left_hoop = lgl_field(po, "leftHoop"), start_type = chr_field(po, "startType"),
                      outcome = vapply(po, function(p) paste(unlist(p$outcome), collapse = "|"), ""),
                      home_score = int_field(po, "homeStartScore"), away_score = int_field(po, "awayStartScore"),
                      home_team = match_row$home_id, away_team = match_row$away_id)
  plays[, off_ids := lapply(po, function(p) canon_id(as.integer(unlist(p$offPlayerIds)), aliases))]
  plays[, def_ids := lapply(po, function(p) canon_id(as.integer(unlist(p$defPlayerIds)), aliases))]
  plays[, view_end := view_end_frames(plays, ev)]

  actions <- rehome(rbindlist(lapply(names(ACTIONS), action_events, ev = ev, nm = nm)), plays)
  actors <- rehome(rbindlist(lapply(names(ACTIONS), action_actors, ev = ev)), plays)[, frame := NULL]
  actors[, pid := canon_id(pid, aliases)]
  events <- rbind(actions, other_events(ev, nm))[!is.na(frame)]
  orphan <- mean(!events$poss_id %in% plays$id)

  transition <- unique(chr_field(ev$chances, "possessionId")[lgl_field(ev$chances, "transition")])
  type_rows <- rbind(unique(actions[type != "shot", .(poss_id, type)]),
                     data.table(poss_id = transition, type = rep("transition", length(transition))))
  types <- split(type_rows$type, type_rows$poss_id)
  shot_types <- split(chr_field(ev$shots, "complexShotType"), chr_field(ev$shots, "possessionId"))
  plays[, types := lapply(id, function(i) intersect(names(PLAY_TYPES), types[[i]]))]
  plays[, shot_types := lapply(id, function(i) unique(stats::na.omit(shot_types[[i]])))]
  plays[, result := fifelse(outcome %in% names(RESULT_LABELS), RESULT_LABELS[outcome], outcome)]
  plays[, result_who := result_names(plays, events)]

  touches <- data.table(game_id = game_id, pid = int_field(ev$touches, "playerId"),
                        f0 = int_field(ev$touches, "startFrame"), f1 = int_field(ev$touches, "endFrame"))
  list(plays = plays, actors = unique(actors), events = events[, game_id := game_id],
       touches = touches[!is.na(f0) & !is.na(f1) & f1 >= f0], roster = roster, orphan = orphan)
}

#' The ten sample games with display labels.
load_matches <- function(root) {
  m <- read_json_file(file.path(root, "data", "matches.json"))
  out <- data.table(game_id = int_field(m, "id"), date = as.Date(substr(chr_field(m, "date_time"), 1, 10)),
                    home_id = vapply(m, function(g) as.integer(g$home_team$id), 0L),
                    away_id = vapply(m, function(g) as.integer(g$away_team$id), 0L),
                    home_name = vapply(m, function(g) g$home_team$name, ""),
                    away_name = vapply(m, function(g) g$away_team$name, ""),
                    home_score = int_field(m, "home_score"), away_score = int_field(m, "away_score"))
  out[, label := sprintf("%s %d-%d %s (%s)", home_name, home_score, away_score, away_name,
                         format(date, "%d %b %Y"))]
  out[order(date)]
}

#' Build the cross-game play index from the event files and the tracking caches.
build_index <- function(root) {
  matches <- load_matches(root)
  aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
  games <- lapply(seq_len(nrow(matches)), function(i) game_index(root, matches$game_id[i], aliases, matches[i]))
  plays <- rbindlist(lapply(games, `[[`, "plays"))
  for (g in matches$game_id) {
    frames <- readRDS(tracking_cache_path(root, g))$frames
    plays[game_id == g, c("view_start", "view_end") := clip_to_period(plays[game_id == g], frames)]
    plays[game_id == g, c("n_live", "n_run") := live_counts(plays[game_id == g], frames)]
  }
  dropped <- plays[n_live < MIN_LIVE_FRAMES, .N]
  plays <- plays[n_live >= MIN_LIVE_FRAMES]
  plays[, game_date := matches$date[match(game_id, matches$game_id)]]
  setorder(plays, game_date, start_frame)
  roster <- rbindlist(lapply(games, `[[`, "roster"))
  teams <- unique(roster[, .(team_id, team_name)])[order(team_name)]
  plays[, off_name := teams$team_name[match(off_team, teams$team_id)]]
  plays[, def_name := teams$team_name[match(def_team, teams$team_id)]]
  people <- roster[canon %in% unlist(c(plays$off_ids, plays$def_ids)),
                   .(name = name[1], teams = paste(unique(team_name), collapse = " / ")), by = canon]
  alias_name <- aliases$canonical_player_name[match(people$canon, aliases$canonical_player_id)]
  people[, name := fifelse(is.na(alias_name), name, alias_name)]
  out <- list(version = INDEX_VERSION, matches = matches, plays = plays, people = people[order(name)], teams = teams,
              roster = roster, actors = rbindlist(lapply(games, `[[`, "actors")),
              events = rbindlist(lapply(games, `[[`, "events")), touches = rbindlist(lapply(games, `[[`, "touches")),
              dropped_short = dropped, orphan_events = vapply(games, `[[`, 0, "orphan"))
  saveRDS(out, index_cache_path(root))
  out
}

#' Build whatever part of the cache is missing or stale. Safe to call on every start.
#' @return Invisibly, the game ids whose tracking cache was rebuilt.
ensure_cache <- function(root, force = FALSE) {
  games <- load_matches(root)$game_id
  stale <- games[force | !vapply(games, tracking_cache_is_current, NA, root = root)]
  for (g in stale) {
    message(sprintf("Reading tracking for game %d (one-time, %d of %d)...", g, match(g, stale), length(stale)))
    build_tracking_cache(root, g)
  }
  index_ok <- file.exists(index_cache_path(root)) && identical(readRDS(index_cache_path(root))$version, INDEX_VERSION)
  if (length(stale) || !index_ok) {
    message("Indexing possessions...")
    build_index(root)
  }
  invisible(stale)
}

# ---- app-facing API ------------------------------------------------------------------------------

#' Each player's most likely playstyle archetype on each side of the ball (built by src/archetypes/), or an
#' empty table if the archetypes have not been built.
#' @return data.table(pid = canonical id, side = "off" or "def", archetype, probability).
load_archetypes <- function(root) {
  read_side <- function(file, side) {
    path <- file.path(root, "outputs", "archetypes", file)
    if (!file.exists(path)) return(NULL)
    fread(path, select = c("pid", "archetype", "probability"))[, side := side]
  }
  out <- rbind(read_side("offense_membership.csv", "off"), read_side("defense_membership.csv", "def"))
  if (is.null(out)) data.table(pid = integer(), archetype = character(), probability = numeric(), side = character()) else out
}

#' Load everything the app needs. Tracking is read per game on demand.
load_app_data <- function(root = find_repo_root()) {
  ensure_cache(root)
  app <- readRDS(index_cache_path(root))
  app$root <- root
  app$archetypes <- load_archetypes(root)
  app$tracking <- new.env()
  app
}

#' Tracking for one game, keeping only the most recently used games in memory.
get_tracking <- function(app, game_id) {
  key <- as.character(game_id)
  if (is.null(app$tracking[[key]])) {
    loaded <- grep("^[0-9]", ls(app$tracking), value = TRUE)
    if (length(loaded) >= MAX_GAMES_IN_MEMORY) rm(list = loaded[1], envir = app$tracking)
    app$tracking[[key]] <- readRDS(tracking_cache_path(app$root, game_id))
  }
  app$tracking[[key]]
}

#' Apply the sidebar filters to the play index.
#' @param f Named list of filter values (Shiny `input` works).
#' @return The matching rows of `app$plays`, in chronological order.
filter_plays <- function(app, f) {
  plays <- app$plays
  keep <- rep(TRUE, nrow(plays))
  has_any <- function(col, values) vapply(col, function(v) any(v %in% values), NA)
  has_all <- function(col, values) vapply(col, function(v) all(values %in% v), NA)
  if (length(f[["game"]])) keep <- keep & plays$game_id %in% as.integer(f[["game"]])
  if (length(f[["period"]])) keep <- keep & plays$period %in% as.integer(f[["period"]])
  if (length(f[["result"]])) keep <- keep & plays$result %in% f[["result"]]
  if (length(f[["shot_type"]])) keep <- keep & has_any(plays$shot_types, f[["shot_type"]])
  if (length(f[["types"]])) {
    keep <- keep & (if (identical(f[["types_mode"]], "all")) has_all else has_any)(plays$types, f[["types"]])
  }
  if (length(f[["team"]])) {
    team <- as.integer(f[["team"]])
    keep <- keep & switch(f[["team_side"]], off = plays$off_team %in% team, def = plays$def_team %in% team,
                          plays$off_team %in% team | plays$def_team %in% team)
  }
  if (length(f[["player"]]) && nzchar(f[["player"]])) {
    p <- as.integer(f[["player"]])
    acted <- app$actors[pid == p & (!length(f[["types"]]) | type %in% f[["types"]]), unique(poss_id)]
    keep <- keep & switch(f[["player_role"]], off = has_any(plays$off_ids, p), def = has_any(plays$def_ids, p),
                          actor = plays$id %in% acted, has_any(plays$off_ids, p) | has_any(plays$def_ids, p))
  }
  plays[keep]
}

format_clock <- function(seconds) sprintf("%d:%02d", as.integer(seconds) %/% 60L, as.integer(seconds) %% 60L)

#' JSON for the play list (one object per play).
plays_json <- function(app, plays) {
  rows <- plays[, .(id, game = app$matches$label[match(game_id, app$matches$game_id)], q = period,
                    clock = format_clock(start_gc), off = off_name, def = def_name,
                    types = vapply(types, function(v) paste(PLAY_TYPES[v], collapse = "|"), ""),
                    result, who = result_who, secs = round(n_run / 25))]
  jsonlite::toJSON(rows, dataframe = "rows", na = "null")
}

#' One player's track aligned to the possession's frames, rotated so the offense attacks +x.
#' `arch` is his archetype on the side of the ball he is on in this possession (NULL if he has none).
player_track <- function(p, pl, frames, flip, info, home_is_off, archetypes) {
  rows <- pl[pid == p]
  at <- match(frames, rows$frame)
  role <- if (rows$home[1] == home_is_off) "off" else "def"
  arch <- archetypes[pid == info$canon & side == role]
  tag <- if (nrow(arch)) ARCHETYPE_TAGS[[arch$archetype[1]]]
  if (is.null(tag)) tag <- c(arch$archetype[1], "none")
  list(id = p, jersey = info$jersey, name = info$name, last = info$last, role = role,
       arch = if (nrow(arch)) list(name = arch$archetype[1], short = tag[1], slot = tag[2], p = arch$probability[1]),
       x = I(flip * rows$x[at]), y = I(flip * rows$y[at]), d = I(rows$det[at]))
}

epv_cache_path <- function(root, game_id) file.path(root, "outputs", "cache", "epv", paste0("epv_", game_id, ".rds"))

#' EPV prices for one game (built by src/epv/build_epv.R), or NULL if they have not been built.
get_epv <- function(app, game_id) {
  key <- paste0("epv_", game_id)
  path <- epv_cache_path(app$root, game_id)
  if (is.null(app$tracking[[key]]) && file.exists(path)) app$tracking[[key]] <- readRDS(path)
  app$tracking[[key]]
}

#' Three-sample centred mean (about a third of a second) to steady the on-screen numbers.
steady <- function(v) fcoalesce(frollmean(v, 3L, align = "center"), v)

#' EPV prices for one possession, on the pricing grid: holder state plus each offensive player's options.
epv_payload <- function(app, play) {
  epv <- get_epv(app, play$game_id)
  if (is.null(epv)) return(NULL)
  fr <- epv$frames[poss_id == play$id][order(frame)]
  if (!nrow(fr)) return(NULL)
  pl <- epv$players[frame %in% fr$frame]
  option <- function(p) {
    at <- match(fr$frame, pl[pid == p]$frame)
    list(sv = I(round(pl[pid == p]$sv[at], 3)), pv = I(round(steady(pl[pid == p]$pv[at]), 3)),
         tov = I(round(steady(pl[pid == p]$ptov[at]), 4)))
  }
  pids <- unique(pl$pid)
  list(f = I(fr$frame), v = I(round(steady(fr$epv), 3)), haz = I(round(steady(fr$haz), 4)),
       rop = I(round(steady(fr$rop), 4)), cum = I(round(fr$cum, 4)), shot = I(round(steady(fr$sv), 3)),
       pass = I(round(steady(fr$pass_best), 3)), to = I(fr$pass_pid), holder = I(fr$holder),
       players = setNames(lapply(pids, option), pids))
}

# Inputs of the xFG context model in the order the viewer lists them (XFG_FEATURES in src/epv/R/models.R),
# with the decimals each is sent at.
SHOT_FEATURES <- c(loc_xfg = 4, def1 = 1, def2 = 1, n6 = 0, between = 0, rim_def = 1, closing = 1, speed = 1, sc = 1,
                   held = 1, drib = 0)

#' The steps behind xFG for each tracked shot of one possession, in order of release: the baseline for the
#' shot's kind (`zone`: rim, mid or three), each context feature's value at release (`v`) and what it adds to
#' xFG (`e`), and the result. Only the inputs of the shot's context model (`model`: rim or jump) are listed.
#' `fixed` flags the features whose effect includes one set from the season aggregates, not fitted.
#' Empty when the possession has no priced shot or the prices were built before shots were saved.
shot_payload <- function(app, play) {
  shots <- get_epv(app, play$game_id)$shots
  if (is.null(shots)) return(list())
  sh <- shots[poss_id == play$id][order(frame)]
  lapply(seq_len(nrow(sh)), function(i) {
    s <- sh[i]
    keys <- Filter(function(k) !is.na(s[[paste0("eff_", k)]]), names(SHOT_FEATURES))
    list(f = s$frame, pid = s$pid, made = s$made, fouled = s$fouled, three = s$three == 1L, zone = s$area, model = s$zone,
         dist = round(s$dist, 1), rounds = s$rounds, base = round(s$base, 4), xfg = round(s$xfg, 4),
         fixed = if (nzchar(s$fixed)) lapply(setNames(nm = strsplit(s$fixed, ",")[[1]]), function(k) TRUE),
         v = lapply(setNames(keys, keys), function(k) round(s[[k]], SHOT_FEATURES[[k]])),
         e = lapply(setNames(keys, keys), function(k) round(s[[paste0("eff_", k)]], 4)))
  })
}

#' Everything the browser needs to animate one possession, as a JSON string.
#' Tracking is in camera view; possessions.leftHoop says which way the offense attacks. A 180 degree
#' rotation (not a mirror) puts every offense on the right-hand hoop and keeps left/right handedness.
#' Frames run over the viewing window (view_start to view_end), which can outlast the delivered possession;
#' EPV prices exist only inside the delivered one.
play_payload <- function(app, play_id) {
  row <- app$plays[id == play_id]
  if (nrow(row) != 1L) return(NULL)
  trk <- get_tracking(app, row$game_id)
  fr <- trk$frames[frame >= row$view_start & frame <= row$view_end]
  pl <- trk$players[frame >= row$view_start & frame <= row$view_end]
  flip <- if (row$left_hoop) -1 else 1
  roster <- app$roster[game_id == row$game_id]
  info <- merge(trk$jerseys[pid %in% pl$pid], roster[, .(pid, name, last, canon)], by = "pid", all.x = TRUE)
  info[is.na(name), c("name", "last", "canon") := .(paste("Player", pid), paste("Player", pid), pid)]
  info <- info[order(suppressWarnings(as.integer(jersey)))]
  players <- lapply(seq_len(nrow(info)), function(i) player_track(info$pid[i], pl, fr$frame, flip, info[i],
                                                                  row$off_team == row$home_team, app$archetypes))
  in_window <- function(dt, col) dt[game_id == row$game_id & get(col) >= row$view_start & get(col) <= row$view_end]
  events <- in_window(app$events, "frame")[order(frame), .(f = frame, kind, label, short, who)]
  touches <- app$touches[game_id == row$game_id & f1 >= row$view_start & f0 <= row$view_end, .(pid, f0, f1)]
  game <- app$matches[game_id == row$game_id]
  payload <- list(id = row$id, game = game$label, period = row$period, off = row$off_name, def = row$def_name,
                  home = game$home_name, away = game$away_name, homeScore = row$home_score,
                  awayScore = row$away_score, result = row$result, who = row$result_who,
                  types = I(unname(PLAY_TYPES[row$types[[1]]])), colors = side_colors(row),
                  frames = I(fr$frame), gc = I(round(fr$gc, 1)), sc = I(round(fr$sc, 1)),
                  stopped = I(as.integer(fr$stopped)),
                  ball = list(x = I(flip * fr$bx), y = I(flip * fr$by), z = I(fr$bz)),
                  players = players, events = events, touches = touches, epv = epv_payload(app, row),
                  shots = shot_payload(app, row))
  jsonlite::toJSON(payload, auto_unbox = TRUE, digits = NA, na = "null", null = "null", dataframe = "rows")
}
