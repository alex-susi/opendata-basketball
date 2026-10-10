# Play viewer: animate any possession from the 10 tracked ACB games.
#
# Start it from R with the repository as working directory:
#   shiny::runApp("src/play_viewer")
#
# The first start reads the ten tracking files once (about two minutes) and caches the live frames
# under outputs/cache/play_viewer/. Rscript src/play_viewer/build_cache.R does the same ahead of time.
# R/data.R holds the data layer; www/player.js draws the animation in the browser.

library(shiny)

app_data <- load_app_data()

# ---- filter choices ------------------------------------------------------------------------------

period_label <- function(p) ifelse(p <= 4L, paste0("Q", p), paste0("OT", p - 4L))
periods <- sort(unique(app_data$plays$period))
results <- intersect(c(RESULT_LABELS, sort(unique(app_data$plays$result))), app_data$plays$result)
shot_types <- sort(unique(unlist(app_data$plays$shot_types)))

choices <- list(game = setNames(app_data$matches$game_id, app_data$matches$label),
                team = setNames(app_data$teams$team_id, app_data$teams$team_name),
                player = c("Any player" = "",
                           setNames(app_data$people$canon, sprintf("%s (%s)", app_data$people$name,
                                                                   app_data$people$teams))),
                period = setNames(periods, period_label(periods)),
                types = setNames(names(PLAY_TYPES), PLAY_TYPES),
                result = setNames(results, results),
                shot_type = setNames(shot_types, tools::toTitleCase(camel_to_words(shot_types))))

# ---- UI ------------------------------------------------------------------------------------------

#' A multi-select filter; empty means "no restriction".
pick_many <- function(id, label, placeholder) {
  selectizeInput(id, label, choices = choices[[id]], multiple = TRUE,
                 options = list(placeholder = placeholder, plugins = list("remove_button")))
}

#' A compact native dropdown that qualifies the filter next to it.
pick_mode <- function(id, label, options) selectInput(id, label, choices = options, selectize = FALSE)

filters_panel <- tags$details(class = "panel filters", open = NA,
                              tags$summary(span("Filters"), actionLink("reset", "Reset")),
                              pick_many("game", "Game", "All games"),
                              div(class = "pair",
                                  pick_many("team", "Team", "All teams"),
                                  pick_mode("team_side", "Team is",
                                            c("Either side" = "any", "On offense" = "off", "On defense" = "def"))),
                              div(class = "pair",
                                  selectizeInput("player", "Player", choices = choices$player),
                                  pick_mode("player_role", "Player is",
                                            c("On court" = "any", "On offense" = "off", "On defense" = "def",
                                              "In the action" = "actor"))),
                              div(class = "pair",
                                  pick_many("types", "Play type", "Any play type"),
                                  pick_mode("types_mode", "Match", c("Any selected" = "any", "All selected" = "all"))),
                              div(class = "pair even",
                                  pick_many("period", "Quarter", "All"),
                                  pick_many("result", "Result", "Any result")),
                              pick_many("shot_type", "Shot type", "Any shot type"))

list_panel <- div(class = "panel plays",
                  div(class = "plays-head", span("Possessions"), span(id = "play-count", class = "count")),
                  div(id = "play-list", class = "play-list"))

ui <- bootstrapPage(tags$head(tags$title("ACB play viewer"),
                              tags$link(rel = "stylesheet", href = "style.css")),
                    div(class = "app",
                        tags$aside(class = "left", filters_panel, list_panel),
                        includeHTML(file.path("www", "viewer.html"))),
                    tags$script(src = "player.js"))

# ---- server --------------------------------------------------------------------------------------

#' Clear every filter back to "no restriction".
reset_filters <- function(session) {
  for (id in c("game", "team", "types", "period", "result", "shot_type")) {
    updateSelectizeInput(session, id, selected = character(0))
  }
  updateSelectizeInput(session, "player", selected = "")
  for (id in c("team_side", "player_role", "types_mode")) updateSelectInput(session, id, selected = "any")
}

server <- function(input, output, session) {
  matching <- reactive(filter_plays(app_data, input))
  observe(session$sendCustomMessage("plays", plays_json(app_data, matching())))
  observeEvent(input$play_id, session$sendCustomMessage("play", play_payload(app_data, input$play_id)))
  observeEvent(input$reset, reset_filters(session))
}

shinyApp(ui, server)
