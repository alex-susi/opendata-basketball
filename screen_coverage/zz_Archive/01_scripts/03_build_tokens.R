## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 3: player tokens for the transformer, at every frame of every scored screen.
#   Rscript screen_coverage/zz_Archive/01_scripts/03_build_tokens.R
#
# Needs 02_per_frame.R first: it uses the same screens and the same frame rows (screen_coverage/zz_Archive/02_cache/
# logistic_per_frame.rds), so the transformer and the logistic models are scored on identical rows.
#
# Ten tokens, one per player on the floor. Rows 1-4 are always the players of the screen: ball handler, screener,
# handler's defender, screener's defender. Rows 5-7 are the other three attackers and rows 8-10 the other three
# defenders, each group ordered by distance to the screener at that frame. Each token, from the frame and 0.24 s
# before it (nothing later):
#   x, y            court position (ft; offense attacks the hoop at +40.8), mirrored so the screener is at y >= 0
#   rel_x, rel_y    position relative to the screener
#   hoop_dist, lvl  distance from the hoop, and that minus the screener's (the "level" of the logistic model)
#   vx, vy, speed   velocity over the last 0.24 s (ft/s; vy mirrored with y)
#   present         1 if the player is tracked at the frame; a missing other player gets 0 and zeros elsewhere
#   role_*          ball handler, screener, handler's defender, screener's defender, other attacker, other defender
# Context columns per row (each variant picks some): tta_now (time to act), lsf_1..5 (defense so far), t (seconds to the tag),
# closeness (1 / (1 + handler-screener distance / 5)), and the archetype indicators.
#
# Past-only (2026-11-12): positions and the other six come from R/past_only.R (pos_past, other_six): the exact frame,
# else at most two frames earlier, never later.
#
# Writes screen_coverage/zz_Archive/02_cache/tokens.rds.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages(library(data.table))
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
cache_dir <- file.path(root, "screen_coverage", "zz_Archive", "02_cache")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

VLAG <- 6L
ROLES <- c("H", "S", "BD", "SD", "O", "X")
SLOT_ROLE <- c("H", "S", "BD", "SD", "O", "O", "O", "X", "X", "X")
TOKEN_FEATS <- c("x", "y", "rel_x", "rel_y", "hoop_dist", "lvl", "vx", "vy", "speed", "present", paste0("role_", ROLES))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FRAME ROWS AND PLAYERS -------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The step-2 screens and frame rows; the token array follows X's row order.
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
if (!identical(L$rules, PAST_ONLY_RULES)) stop("logistic_per_frame.rds was built under other rules: rerun 02_per_frame.R")
P <- L$P
X <- L$X
N <- nrow(X)
# Positions come from pos_past() (R/past_only.R): the exact frame or up to two frames earlier.
pos_at <- function(B, frames, ids) pos_past(B, frames, ids)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - TOKENS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# player ids per row and slot: the four of the screen, then the other six found in the tracking at that frame
ids <- matrix(NA_integer_, N, 10L)
ids[, 1:4] <- as.matrix(P[X$idx, .(H, S, BD, SD)])
tok <- array(0, c(N, 10L, length(TOKEN_FEATS)), dimnames = list(NULL, NULL, TOKEN_FEATS))
# One game at a time: find the other six players, then fill each slot's token values.
for (g in unique(X$game_id)) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  r <- which(X$game_id == g)
  S0 <- pos_at(B, X$frame[r], ids[r, 2])
  # The other six in the screen's possession at the row's frame or up to two frames before (R/past_only.R); slots
  # 5-7 are attackers and 8-10 defenders, each group ordered by distance to the screener.
  ids[r, 5:10] <- other_six(B, P[X$idx[r]], X$frame[r])
  # Mirror y so the screener is at y >= 0. A slot's values stay zero unless both positions are tracked.
  flip <- ifelse(S0$y < 0, -1, 1)
  for (j in 1:10) {
    has <- !is.na(ids[r, j])
    n <- pos_at(B, X$frame[r], ids[r, j])
    b <- pos_at(B, X$frame[r] - VLAG, ids[r, j])
    ok <- has & !is.na(n$x) & !is.na(b$x)
    y <- flip * n$y
    vx <- (n$x - b$x) / (VLAG / FPS)
    vy <- flip * (n$y - b$y) / (VLAG / FPS)
    vals <- cbind(x = n$x, y = y, rel_x = n$x - S0$x, rel_y = y - flip * S0$y, hoop_dist = hoop_dist(n$x, n$y),
                  lvl = hoop_dist(n$x, n$y) - hoop_dist(S0$x, S0$y), vx = vx, vy = vy, speed = sqrt(vx^2 + vy^2))
    vals[!ok, ] <- 0
    tok[r, j, colnames(vals)] <- vals
    tok[r, j, "present"] <- as.numeric(ok)
    tok[r, j, paste0("role_", SLOT_ROLE[j])] <- 1
  }
}
# The four screen players must be present in every row; report how often the other six are missing.
stopifnot(all(tok[, 1:4, "present"] == 1))
miss <- 1 - tok[, 5:10, "present"]
cat(sprintf("Other six players: %.2f%% of slots missing (rows with any missing: %.2f%%)\n",
            100 * mean(miss), 100 * mean(rowSums(miss) > 0)))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - CONTEXT AND SAVE -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ARCH <- grep("^[hs]_([A-Z]|other$)", names(X), value = TRUE)      # archetype indicators only (not h_lvl, s_hoop, ...)
ctx <- cbind(as.matrix(X[, c("tta_now", paste0("lsf_", 1:5)), with = FALSE]),
             t = X$off / FPS, closeness = 1 / (1 + X$d_hs / 5), as.matrix(X[, ..ARCH]))
stopifnot(!anyNA(ctx), !anyNA(tok))
saveRDS(list(tok = tok, ctx = ctx, arch_cols = ARCH, token_feats = TOKEN_FEATS, ids = ids, screen_ids = P$id,
             rules = PAST_ONLY_RULES),
        file.path(cache_dir, "tokens.rds"))
cat("Tokens:", paste(dim(tok), collapse = " x "), "(frame rows x players x features); context columns:",
    paste(colnames(ctx), collapse = ", "), "\n")
