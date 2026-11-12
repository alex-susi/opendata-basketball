## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 2: movement histories for the live time-aware transformer.
#   Rscript screen_coverage/01_scripts/02_build_sequences.R
#
# Needs 01_logistic_baseline.R first (same screens and frame rows).
#
# For every scored screen, each of its ten players is described at every frame from 3.6 s before the screen tag to
# 1 s after it. The model (03_train_transformer.R) then reads, for a prediction at frame t, each player's values at
# t, t-0.2 s, ..., t-1.6 s (nine steps): his last 1.6 s. Nothing after t is ever used.
#
# The ten players: rows 1-4 are the ball handler, screener, handler's defender and screener's defender; rows 5-7 the
# other attackers and 8-10 the other defenders in the screen's possession at -2 s, the earliest frame ever predicted,
# so the roster is known at every prediction frame (their order does not matter to the model). Until 2026-11-12 the
# roster was read at the screen tag.
#
# Per player and frame (positions in the site's frame, offense attacking the hoop at +40.8 ft):
#   x, y               court position (ft). y, rel_y, rel_h_y and vy are mirrored at training time so that the
#                      screener is on the y >= 0 side at the prediction frame
#   rel_x, rel_y       position relative to the screener at the same frame
#   rel_h_x, rel_h_y   position relative to the ball handler (the screener's row traces the path of his approach)
#   hoop_dist, lvl     distance from the hoop; that minus the screener's (+ = above the screen, - = below)
#   vx, vy, speed      velocity over the last 0.2 s (ft/s)
#   accel              change in speed over the last 0.2 s (ft/s per s): speeding up (+) or slowing down (-)
#   turn               change of direction over the last 0.2 s (degrees; 0 when he is nearly still)
#   lvl_v              how fast his level is changing (ft/s)
#   lvl_hold           seconds he has stayed on the same side of the screener's level (above, level within 0.5 ft,
#                      or below), capped at 1.6 s: "Jefferson was high, then started sliding"
#   present            1 if tracked in the screen's possession at that frame and the two 0.2 s steps before it
#                      (missing players get zeros: this is the missingness flag)
# Screen-level context per prediction frame (memory of contact, all visible on the court):
#   hs_min             the closest the ball handler has been to the screener over the last 2 s (ft)
#   since_hs_min       seconds since that closest moment (0 = they are closest now)
#   plus time to act, the defense's calls so far at that frame (logs, 01_logistic_baseline.R) and closeness
#
# Past-only (2026-11-12): every position comes from R/past_only.R (pos_past): the exact frame, else at most two frames
# earlier, never later. The features themselves are built there too (sequence_base, contact_memory) so that
# 05_test_past_only.R checks exactly this code.
#
# Writes screen_coverage/02_cache/sequences.rds.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages(library(data.table))
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
cache_dir <- file.path(root, "screen_coverage", "02_cache")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The roster is read at the earliest prediction frame (-2 s). Step, stored frames and features: R/past_only.R.
ROSTER_OFF <- -50L





## ═════════════════════════════════════════════════════════════════════════════
## 02 - SCREENS AND THEIR TEN PLAYERS ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Step-2 screens and rows, built under the same rules.
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
if (!identical(L$rules, PAST_ONLY_RULES)) stop("logistic_per_frame.rds was built under other rules: rerun 01_logistic_baseline.R")
P <- L$P
X <- L$X
NS <- nrow(P)
stopifnot(min(X$off) >= ROSTER_OFF)
# Roster per screen: the four of the screen, then the other six in the possession at -2 s; positions at every offset.
roster <- matrix(NA_integer_, NS, 10L)
roster[, 1:4] <- as.matrix(P[, .(H, S, BD, SD)])
NP <- length(SEQ_POS_OFFS)
PX <- PY <- array(NA_real_, c(NS, NP, 10L))
for (g in unique(P$game_id)) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  s <- which(P$game_id == g)
  roster[s, 5:10] <- other_six(B, P[s], P$f0[s] + ROSTER_OFF)
  pos <- ten_player_positions(B, P[s], roster[s, , drop = FALSE])
  PX[s, , ] <- pos$PX
  PY[s, , ] <- pos$PY
}
cat("Screens whose other six were not all found at -2 s:", sum(rowSums(is.na(roster[, 5:10])) > 0), "\n")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - PER-FRAME PLAYER FEATURES AND CONTEXT ----------------------------------
## ═════════════════════════════════════════════════════════════════════════════

base <- sequence_base(PX, PY)
cat(sprintf("Players present over the stored frames: screen four %.1f%%, other six %.1f%%\n",
            100 * mean(base[, , 1:4, "present"]), 100 * mean(base[, , 5:10, "present"])))
# Memory of contact per prediction row; a missing memory falls back to the current distance.
mem <- contact_memory(PX, PY, X$idx, X$off)
ctx <- cbind(as.matrix(X[, c("tta_now", paste0("lsf_", 1:5)), with = FALSE]), closeness = X$closeness,
             hs_min = mem[, 1], since_hs_min = mem[, 2])
ctx[is.na(ctx[, "hs_min"]), "hs_min"] <- X$d_hs[is.na(ctx[, "hs_min"])]
ctx[is.na(ctx[, "since_hs_min"]), "since_hs_min"] <- 0
stopifnot(!anyNA(ctx), !anyNA(base))
saveRDS(list(base = base, base_offs = SEQ_BASE_OFFS, step = SEQ_STEP, feats = SEQ_FEATS, flip = SEQ_FLIP, ctx = ctx,
             roster = roster, screen_ids = P$id, rules = PAST_ONLY_RULES),
        file.path(cache_dir, "sequences.rds"))
cat("Sequences:", paste(dim(base), collapse = " x "), "(screens x frames x players x features); context:",
    paste(colnames(ctx), collapse = ", "), "\n")
