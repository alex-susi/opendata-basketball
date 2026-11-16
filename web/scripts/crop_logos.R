## ═════════════════════════════════════════════════════════════════════════════
# Crops the wordmark off the team logos that carry their name as separate text under the crest (BC Barcelona's
# "BARÇA", Real Madrid's "Realmadrid Baloncesto", UCAM Murcia's "UCAM Universidad Club de Baloncesto"), so only the
# crest shows on the site (score bar, rosters, midcourt).
#
# Reads the downloaded badges kept in web/scripts/logo_sources/ (see web/public/logos/SOURCES.md) and writes
# web/public/logos/<team id>.png: the crest is the ink above the first clear horizontal gap of at least GAP_ROWS rows,
# trimmed to its own bounds and centred on a transparent 512 x 512 square. Run from the repository root:
#   Rscript web/scripts/crop_logos.R
## ═════════════════════════════════════════════════════════════════════════════

library(magick)

SOURCES   <- "web/scripts/logo_sources"
OUT       <- "web/public/logos"
TEAMS     <- c("1334", "1338", "1340")
GAP_ROWS  <- 6
ALPHA_INK <- 0.1
SIZE      <- 512





## ═════════════════════════════════════════════════════════════════════════════
## 01 - CREST BOUNDS -----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Rows and columns of the crest: from the first row with ink down to the first run of GAP_ROWS rows without ink.
crest_bounds <- function(alpha) {
  ink_row <- apply(alpha > ALPHA_INK, 1, any)
  first <- which(ink_row)[1]
  last <- length(ink_row)
  run <- 0
  for (r in first:length(ink_row)) {
    run <- if (ink_row[r]) 0 else run + 1
    if (run >= GAP_ROWS) {
      last <- r - run
      break
    }
  }
  cols <- which(apply(alpha[first:last, , drop = FALSE] > ALPHA_INK, 2, any))
  list(top = first, bottom = last, left = min(cols), right = max(cols))
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - CROP AND WRITE ---------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

for (team in TEAMS) {
  img <- image_read(file.path(SOURCES, paste0(team, ".png")))
  # magick's raster is [channel, x, y]; the alpha channel as a rows x columns matrix in 0-1.
  alpha <- t(matrix(as.integer(image_data(img, "rgba")[4, , ]), nrow = image_info(img)$width)) / 255
  b <- crest_bounds(alpha)
  w <- b$right - b$left + 1
  h <- b$bottom - b$top + 1
  crest <- image_crop(img, sprintf("%dx%d+%d+%d", w, h, b$left - 1, b$top - 1))
  side <- max(w, h)
  square <- image_extent(crest, sprintf("%dx%d", side, side), gravity = "center", color = "none")
  image_write(image_resize(square, sprintf("%dx%d", SIZE, SIZE)), file.path(OUT, paste0(team, ".png")), format = "png")
  cat(team, ": crest rows", b$top, "-", b$bottom, ", columns", b$left, "-", b$right, "\n")
}
