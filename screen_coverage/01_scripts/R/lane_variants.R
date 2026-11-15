## ═════════════════════════════════════════════════════════════════════════════
# The lane-feature experiment's variants and where each keeps its files (added 2026-11-15).
#
# Variants differ only in the channels appended to each player token after the 16 movement features (SEQ_FEATS):
#   A   none: the live v2 transformer's inputs, rebuilt into its own folder (checked identical to the live cache)
#   B   roll_distance_ft, roll_closing_fps, roll_lane_valid (R/lane_geometry.R)
#   C   roll_distance_ft, roll_lane_valid (closing speed left out)
# Every variant keeps the live screens, frame rows, context, folds, settings and two-head output.
#
# Files: screen_coverage/02_cache/experiments/lanes/<variant>/sequences.rds and tf_s<seeds>/seqheads_<game>.rds
# (plus networks); results in screen_coverage/03_outputs/experiments/lanes/.
## ═════════════════════════════════════════════════════════════════════════════

LANE_VARIANTS <- list(A = character(0),
                      B = c("roll_distance_ft", "roll_closing_fps", "roll_lane_valid"),
                      C = c("roll_distance_ft", "roll_lane_valid"))

# Continuous lane channels, each with the flag that marks it valid: in standardised space an invalid entry is 0.
LANE_MASKED <- c(roll_distance_ft = "roll_lane_valid", roll_closing_fps = "roll_lane_valid")

#' Folder of a variant's cache, and of one set of its fitted folds (seeds such as 1:2 -> "tf_s1-2").
lane_dir <- function(root, variant) file.path(root, "screen_coverage", "02_cache", "experiments", "lanes", variant)
lane_tf_dir <- function(root, variant, seeds) file.path(lane_dir(root, variant), paste0("tf_s", paste(range(seeds), collapse = "-")))
lane_out_dir <- function(root) file.path(root, "screen_coverage", "03_outputs", "experiments", "lanes")

#' The feature axis a variant's sequences must have.
lane_feats <- function(variant) c(SEQ_FEATS, LANE_VARIANTS[[variant]])
