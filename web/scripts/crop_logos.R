## ═════════════════════════════════════════════════════════════════════════════
# Prepares the team logos the site shows (score bar, rosters, midcourt) from the downloaded badges kept in
# web/scripts/logo_sources/ (see web/public/logos/SOURCES.md).
#
# - Three badges carry the club's name as separate text under the crest (BC Barcelona's "BARÇA", Real Madrid's
#   "Realmadrid Baloncesto", UCAM Murcia's "UCAM Universidad Club de Baloncesto"). For these the crest is the ink
#   above the first clear horizontal gap of at least GAP_ROWS rows; the text below is dropped.
# - Every logo is then trimmed to its own ink and centred on a transparent SIZE x SIZE square, so the drawing (not
#   the downloaded canvas, which can carry uneven margins) sits in the middle wherever it is shown.
#
# Writes web/public/logos/trimmed/<team id>.png and web/public/logos/logos.json. The folder name is new on purpose,
# so browsers holding the old images fetch these. Run from the repository root:
#   Rscript web/scripts/crop_logos.R
## ═════════════════════════════════════════════════════════════════════════════

library(magick)
library(jsonlite)

SOURCES   <- "web/scripts/logo_sources"
OUT_DIR   <- "web/public/logos/trimmed"
MANIFEST  <- "web/public/logos/logos.json"
WORDMARK  <- c("1334", "1338", "1340")
GAP_ROWS  <- 6
ALPHA_INK <- 0.1
SIZE      <- 512





## ═════════════════════════════════════════════════════════════════════════════
## 01 - INK BOUNDS -------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The alpha channel as a rows x columns matrix in 0-1 (magick's raster is [channel, x, y]).
alpha_of <- function(img) {
  t(matrix(as.integer(image_data(img, "rgba")[4, , ]), nrow = image_info(img)$width)) / 255
}

# Rows and columns holding ink. With crest_only, the rows stop at the first run of GAP_ROWS rows without ink below
# the first inked row (the crest above a separate wordmark).
ink_bounds <- function(alpha, crest_only) {
  ink_row <- apply(alpha > ALPHA_INK, 1, any)
  first <- which(ink_row)[1]
  last <- max(which(ink_row))
  if (crest_only) {
    run <- 0
    for (r in first:length(ink_row)) {
      run <- if (ink_row[r]) 0 else run + 1
      if (run >= GAP_ROWS) {
        last <- r - run
        break
      }
    }
  }
  cols <- which(apply(alpha[first:last, , drop = FALSE] > ALPHA_INK, 2, any))
  list(top = first, bottom = last, left = min(cols), right = max(cols))
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - CROP, CENTRE AND WRITE -------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

dir.create(OUT_DIR, showWarnings = FALSE)
teams <- sub("\\.png$", "", list.files(SOURCES, "\\.png$"))
manifest <- list()
for (team in teams) {
  img <- image_read(file.path(SOURCES, paste0(team, ".png")))
  b <- ink_bounds(alpha_of(img), team %in% WORDMARK)
  w <- b$right - b$left + 1
  h <- b$bottom - b$top + 1
  ink <- image_crop(img, sprintf("%dx%d+%d+%d", w, h, b$left - 1, b$top - 1))
  side <- max(w, h)
  square <- image_extent(ink, sprintf("%dx%d", side, side), gravity = "center", color = "none")
  image_write(image_resize(square, sprintf("%dx%d", SIZE, SIZE)), file.path(OUT_DIR, paste0(team, ".png")), format = "png")
  manifest[[team]] <- paste0("trimmed/", team, ".png")
  cat(team, ": ink rows", b$top, "-", b$bottom, ", columns", b$left, "-", b$right, "\n")
}
write(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), MANIFEST)
