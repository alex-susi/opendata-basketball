# Season counts per player from the three aggregate files (293 games, offense only).
#
# One row per canonical player. A traded player's all-teams "total" row is used instead of his per-team
# rows, never both; the two ids of an aliased player are added together. Only count columns are kept:
# every rate is recomputed from its numerator and denominator in spec.R.
# Requires src/play_viewer/R/data.R.

AGGREGATE_FILES <- c(shots = "acb_shotsaggregates_20252026.csv", drives = "acb_drivesaggregates_20252026.csv",
                     picks = "acb_picksaggregates_20252026.csv")
IDENTITY_COLS <- c("competition_id", "competition_name", "season_id", "season_name", "player_id", "player_name", "team_id",
                   "team_name")
RATE_PATTERN <- "_rate|_percentage|_pct|_ppp|points_per_|avg_"

#' One aggregate file as counts per canonical player.
#' @param prefix Added to the count columns so the three files do not collide.
season_file <- function(root, file, aliases, prefix = "") {
  d <- fread(file.path(root, "data", "aggregates", file))
  d[, has_total := any(team_name == "total"), by = player_id]
  d <- d[team_name == "total" | !has_total]
  if (anyDuplicated(d$player_id)) stop("More than one season row for a player in ", file)
  counts <- setdiff(names(d)[vapply(d, is.numeric, NA)], IDENTITY_COLS)
  counts <- counts[!grepl(RATE_PATTERN, counts)]
  d[, pid := canon_id(player_id, aliases)]
  out <- d[, lapply(.SD, sum), by = pid, .SDcols = counts]
  setnames(out, counts, paste0(prefix, counts))
  out
}

#' Season counts from all three files; a player missing from a file had no such events.
#' @return data.table keyed by canonical pid, with `possessions` and `games` taken from the shots file
#'   (or the largest value in the other two when a player has no shots row).
season_counts <- function(root, aliases) {
  parts <- list(season_file(root, AGGREGATE_FILES[["shots"]], aliases),
                season_file(root, AGGREGATE_FILES[["drives"]], aliases, "dr_"),
                season_file(root, AGGREGATE_FILES[["picks"]], aliases, "pk_"))
  out <- Reduce(function(a, b) merge(a, b, by = "pid", all = TRUE), parts)
  for (col in setdiff(names(out), "pid")) set(out, which(is.na(out[[col]])), col, 0)
  out[, possessions := pmax(possessions_played, dr_possessions_played, pk_possessions_played)]
  out[, games := pmax(games_played, dr_games_played, pk_games_played)]
  setnames(out, sub("^pk_(handler|screener)_", "\\1_", names(out)))
  out[]
}

#' Display name and teams per canonical player, from the aggregate files and the alias table.
season_people <- function(root, aliases) {
  rows <- rbindlist(lapply(AGGREGATE_FILES, function(f) {
    fread(file.path(root, "data", "aggregates", f), select = c("player_id", "player_name", "team_name"))
  }))
  rows[, pid := canon_id(player_id, aliases)]
  people <- rows[, .(player = player_name[match(pid[1], player_id, nomatch = 1L)],
                     teams = paste(unique(team_name[team_name != "total"]), collapse = " / ")), by = pid]
  alias_name <- aliases$canonical_player_name[match(people$pid, aliases$canonical_player_id)]
  people[, player := fifelse(is.na(alias_name), player, alias_name)]
  people[]
}
