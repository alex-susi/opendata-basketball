# Shared by export_data.R and parity_reference.R.
# Loads the Shiny play viewer's own objects and functions without launching it, so everything the static
# site ships is produced by the app's code. src/play_viewer/ is read, never modified.

suppressPackageStartupMessages({
  library(shiny)
  library(jsonlite)
  library(data.table)
})

#' Find the repository root from wherever Rscript was started.
repo_root <- function() {
  dir <- normalizePath(getwd(), winslash = "/")
  while (!file.exists(file.path(dir, "data", "matches.json"))) {
    if (identical(dirname(dir), dir)) stop("Run this from inside the repository")
    dir <- dirname(dir)
  }
  dir
}

#' Source the app's data layer and app.R into a private environment.
#' app.R's final shinyApp() call only returns an object; nothing is started.
#' @return Environment holding app_data, choices, server and the data-layer functions.
load_shiny_app <- function(root = repo_root()) {
  app_dir <- file.path(root, "src", "play_viewer")
  a <- new.env()
  sys.source(file.path(app_dir, "R", "data.R"), envir = a)
  old <- setwd(app_dir)
  on.exit(setwd(old))
  suppressMessages(sys.source("app.R", envir = a))
  a$root <- root
  a
}

#' One possession exactly as the Shiny app sends it to the browser, parsed back into R.
#' Numeric arrays come back as vectors with NA for null; arrays of objects as lists.
app_payload <- function(a, play_id) {
  fromJSON(a$play_payload(a$app_data, play_id), simplifyVector = TRUE, simplifyDataFrame = FALSE, simplifyMatrix = FALSE)
}
