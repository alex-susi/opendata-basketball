# Screen coverage, step 3: player tokens for the transformer, at every frame of every scored screen.
#   Rscript src/screen_coverage/03_build_tokens.R
#
# Needs 02_per_frame.R first: it uses the same screens and the same frame rows (outputs/cache/screen_coverage/
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
# Context columns per row (each variant picks some): sc_now, lsf_1..5 (defense so far), t (seconds to the tag),
# closeness (1 / (1 + handler-screener distance / 5)), and the archetype indicators.
#
# Writes outputs/cache/screen_coverage/tokens.rds.

suppressPackageStartupMessages(library(data.table))
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
cache_dir <- file.path(root, "outputs", "cache", "screen_coverage")

FPS <- 25
VLAG <- 6L
HOOP_X <- (14 - 1.575) * 3.28084
hoop_dist <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)
ROLES <- c("H", "S", "BD", "SD", "O", "X")
SLOT_ROLE <- c("H", "S", "BD", "SD", "O", "O", "O", "X", "X", "X")
TOKEN_FEATS <- c("x", "y", "rel_x", "rel_y", "hoop_dist", "lvl", "vx", "vy", "speed", "present", paste0("role_", ROLES))

L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
P <- L$P; X <- L$X
N <- nrow(X)

pos_at <- function(B, frames, ids) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    hit <- B$P[.(frames[miss] + d, ids[miss]), .(x, y), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y)]
  }
  out
}

# player ids per row and slot: the four of the screen, then the other six found in the tracking at that frame
ids <- matrix(NA_integer_, N, 10L)
ids[, 1:4] <- as.matrix(P[X$idx, .(H, S, BD, SD)])
tok <- array(0, c(N, 10L, length(TOKEN_FEATS)), dimnames = list(NULL, NULL, TOKEN_FEATS))
for (g in unique(X$game_id)) {
  B <- readRDS(file.path(root, "outputs", "cache", "explore", sprintf("bundle_%d.rds", g)))
  r <- which(X$game_id == g)
  poss <- P$poss[X$idx[r]]
  S0 <- pos_at(B, X$frame[r], ids[r, 2])
  # the other six: everyone tracked in the screen's possession at the nearest frame within 2 that has them
  found <- data.table()
  left <- seq_along(r)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    if (!length(left)) break
    q <- data.table(i = left, frame = X$frame[r][left] + d, q_poss = poss[left],
                    e1 = ids[r[left], 1], e2 = ids[r[left], 2], e3 = ids[r[left], 3], e4 = ids[r[left], 4])
    h <- B$P[q, on = "frame", nomatch = 0L, allow.cartesian = TRUE]
    h <- h[poss == q_poss & pid != e1 & pid != e2 & pid != e3 & pid != e4]
    ok <- h[, .(n_off = sum(off), n_def = sum(!off)), by = i][n_off == 3L & n_def == 3L]$i
    found <- rbind(found, h[i %in% ok, .(i, pid, off, x, y)])
    left <- setdiff(left, ok)
  }
  if (nrow(found)) {
    found[, ds := sqrt((x - S0$x[i])^2 + (y - S0$y[i])^2)]
    found[, slot := fifelse(off, 4L, 7L) + frank(ds, ties.method = "first"), by = .(i, off)]
    ids[cbind(r[found$i], found$slot)] <- found$pid
  }
  flip <- ifelse(S0$y < 0, -1, 1)
  for (j in 1:10) {
    has <- !is.na(ids[r, j])
    n <- pos_at(B, X$frame[r], ids[r, j]); b <- pos_at(B, X$frame[r] - VLAG, ids[r, j])
    ok <- has & !is.na(n$x) & !is.na(b$x)
    y <- flip * n$y; vx <- (n$x - b$x) / (VLAG / FPS); vy <- flip * (n$y - b$y) / (VLAG / FPS)
    vals <- cbind(x = n$x, y = y, rel_x = n$x - S0$x, rel_y = y - flip * S0$y, hoop_dist = hoop_dist(n$x, n$y),
                  lvl = hoop_dist(n$x, n$y) - hoop_dist(S0$x, S0$y), vx = vx, vy = vy, speed = sqrt(vx^2 + vy^2))
    vals[!ok, ] <- 0
    tok[r, j, colnames(vals)] <- vals
    tok[r, j, "present"] <- as.numeric(ok)
    tok[r, j, paste0("role_", SLOT_ROLE[j])] <- 1
  }
}
stopifnot(all(tok[, 1:4, "present"] == 1))
miss <- 1 - tok[, 5:10, "present"]
cat(sprintf("Other six players: %.2f%% of slots missing (rows with any missing: %.2f%%)\n",
            100 * mean(miss), 100 * mean(rowSums(miss) > 0)))

ARCH <- grep("^[hs]_([A-Z]|other$)", names(X), value = TRUE)      # archetype indicators only (not h_lvl, s_hoop, ...)
ctx <- cbind(as.matrix(X[, c("sc_now", paste0("lsf_", 1:5)), with = FALSE]),
             t = X$off / FPS, closeness = 1 / (1 + X$d_hs / 5), as.matrix(X[, ..ARCH]))
stopifnot(!anyNA(ctx), !anyNA(tok))
saveRDS(list(tok = tok, ctx = ctx, arch_cols = ARCH, token_feats = TOKEN_FEATS, ids = ids),
        file.path(cache_dir, "tokens.rds"))
cat("Tokens:", paste(dim(tok), collapse = " x "), "(frame rows x players x features); context columns:",
    paste(colnames(ctx), collapse = ", "), "\n")
