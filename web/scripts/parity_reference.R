# Writes web/tests/parity_reference.json, the reference the Vitest parity test compares against.
#   Rscript web/scripts/parity_reference.R     (after web/scripts/export_data.R; keep both outputs together)
#
# 1. Filter cases are run through the real Shiny server (shiny::testServer on app.R's server function),
#    one per branch of filter_plays(); the reference stores the play ids the server's `matching()` returns.
# 2. A few plays' payloads, exactly as the app sends them, are reduced to sums the test recomputes from
#    the exported binary files.
# The export's `generated` stamp is stored too, so a stale reference fails the first test.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
source(file.path(if (length(script)) dirname(script) else "web/scripts", "load_app.R"))

a <- load_shiny_app()
meta <- fromJSON(file.path(a$root, "web", "public", "data", "meta.json"), simplifyVector = FALSE)
plays <- a$app_data$plays

# ---- filter cases ---------------------------------------------------------------------------------

#' The inputs a browser sends: every filter present, the unused ones empty.
inputs <- function(...) {
  base <- list(game = character(0), period = character(0), result = character(0), shot_type = character(0),
               types = character(0), types_mode = "any", team = character(0), team_side = "any", player = "",
               player_role = "any")
  utils::modifyList(base, list(...))
}

games <- as.character(a$app_data$matches$game_id)
team <- as.character(plays[, .N, by = off_team][order(-N), off_team][1])
teams <- as.character(a$app_data$teams$team_id[1:2])
busiest <- a$app_data$actors[type == "pick", .N, by = pid][order(-N), pid][1]
player <- as.character(busiest)

cases <- list(none = inputs(),
              one_game = inputs(game = games[1]),
              games_and_periods = inputs(game = games[c(2, 7)], period = c("2", "4")),
              results = inputs(result = c("Made 3", "Turnover")),
              shot_types = inputs(shot_type = c("dunk", "stepback")),
              types_any = inputs(types = c("pick", "drive")),
              types_all = inputs(types = c("pick", "drive"), types_mode = "all"),
              transition = inputs(types = "transition"),
              team_offense = inputs(team = team, team_side = "off"),
              team_defense = inputs(team = team, team_side = "def"),
              teams_either = inputs(team = teams),
              player_on_court = inputs(player = player),
              player_offense = inputs(player = player, player_role = "off"),
              player_defense = inputs(player = player, player_role = "def"),
              player_in_action = inputs(player = player, player_role = "actor"),
              player_in_pick = inputs(player = player, player_role = "actor", types = "pick"),
              combined = inputs(game = games[1:5], team = team, team_side = "off", types = c("pick", "closeout"),
                                types_mode = "all", result = c("Made 2", "Made 3", "Missed 2", "Missed 3")),
              nothing = inputs(game = games[1], period = "4", shot_type = "heave", result = "Made 2"))

matched <- new.env()
shiny::testServer(a$server, {
  for (name in names(cases)) {
    do.call(session$setInputs, cases[[name]])
    matched[[name]] <- matching()$id
  }
})

arrays <- c("game", "period", "result", "shot_type", "types", "team")
filter_cases <- lapply(names(cases), function(name) {
  sent <- cases[[name]]
  sent[arrays] <- lapply(sent[arrays], I)
  list(name = name, inputs = sent, ids = I(matched[[name]]))
})

# ---- payload sums ---------------------------------------------------------------------------------

total <- function(v) sum(as.numeric(v), na.rm = TRUE)
present <- function(v) sum(!is.na(v))

#' Sums of every series in one play's payload.
payload_sums <- function(play_id) {
  p <- app_payload(a, play_id)
  e <- p$epv
  list(id = play_id, n = length(p$frames), m = length(e$f), frames = total(p$frames), gc = total(p$gc),
       sc = total(p$sc), scPresent = present(p$sc), stopped = total(p$stopped),
       ball = I(c(total(p$ball$x), total(p$ball$y), total(p$ball$z))),
       players = lapply(p$players, function(pl) list(id = pl$id, role = pl$role, x = total(pl$x), y = total(pl$y),
                                                     present = present(pl$x), detected = total(pl$d))),
       epv = list(f = total(e$f), to = total(e$to), holder = total(e$holder), v = total(e$v), shot = total(e$shot),
                  pass = total(e$pass), haz = total(e$haz), rop = total(e$rop), cum = total(e$cum),
                  players = lapply(names(e$players), function(k) list(id = as.integer(k), sv = total(e$players[[k]]$sv),
                                                                      pv = total(e$players[[k]]$pv),
                                                                      tov = total(e$players[[k]]$tov),
                                                                      present = present(e$players[[k]]$pv)))))
}

roster_size <- vapply(plays$id, function(i) length(unique(c(plays[id == i]$off_ids[[1]], plays[id == i]$def_ids[[1]]))), 0L)
sample_ids <- unique(c(plays$id[1], plays$id[which.max(plays$n_live)], plays$id[which.max(roster_size)],
                       plays[game_id == as.integer(games[6])]$id[40], plays[period == max(period)]$id[1],
                       plays$id[nrow(plays)]))

reference <- list(export_generated = meta$generated, filters = filter_cases, payloads = lapply(sample_ids, payload_sums))
out <- file.path(a$root, "web", "tests", "parity_reference.json")
write_json(reference, out, auto_unbox = TRUE, digits = NA, na = "null", null = "null")

counts <- vapply(names(cases), function(name) length(matched[[name]]), 0L)
message("Plays matched per filter case (they should differ, or the inputs were ignored):")
print(counts)
message(sprintf("Wrote %s: %d filter cases, %d payloads, export stamp %s.", out, length(cases), length(sample_ids),
                meta$generated))
