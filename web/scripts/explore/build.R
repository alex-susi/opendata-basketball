# Build the data for the site's seven exploration tabs.
#   Rscript web/scripts/explore/build.R                 every topic (bundles read from cache when present)
#   Rscript web/scripts/explore/build.R paint gravity   only those topics
#   Rscript web/scripts/explore/build.R --rebuild       rebuild the per-game bundles first (after an export change)
#   Rscript web/scripts/explore/build.R --bundles       only (re)build the bundles
#
# Writes web/public/data/explore_<topic>.json. Bundles are cached in outputs/cache/explore/ (git-ignored); each
# takes 20-60 s to build, mostly the site's cuts and rebounding roles (web/scripts/cuts.R, glass.R), which are
# reused unchanged so the tabs agree with the play viewer.

args <- commandArgs(trailingOnly = TRUE)
all_args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", all_args, value = TRUE))
here <- if (length(script)) dirname(script) else "web/scripts/explore"
scripts <- dirname(here)

source(file.path(scripts, "load_app.R"))
a <- load_shiny_app()
source(file.path(scripts, "annotations.R"))
source(file.path(scripts, "cuts.R"))
source(file.path(scripts, "glass.R"))
source(file.path(here, "common.R"))

TOPICS <- c("paint", "chains", "closeouts", "crash", "lanes", "advantage", "gravity")
want <- intersect(args, TOPICS)
if (!length(want)) want <- TOPICS

BL <- lapply(EX_GAMES, game_bundle, rebuild = "--rebuild" %in% args)
names(BL) <- EX_GAMES
if ("--bundles" %in% args) quit(save = "no")

SP <- season_profiles()
for (t in want) {
  message("Topic: ", t)
  source(file.path(here, paste0(t, ".R")))
  t0 <- Sys.time()
  save_doc(get(paste0("topic_", t))(BL))
  message(sprintf("  %.1f s", as.numeric(Sys.time() - t0, units = "secs")))
}
