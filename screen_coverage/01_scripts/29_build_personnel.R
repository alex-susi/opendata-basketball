## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 29: the personnel experiment's inputs (positions and the possession's memory).
#   Rscript screen_coverage/01_scripts/29_build_personnel.R
#
# Needs 01_logistic_baseline.R, 02_build_sequences.R and 28_fold_positions.R. Prompted by the Screen Coverage EDA
# (2026-11-18): the screener's defender switches 12% of the time as a big and 30% as a guard, and an earlier switch
# or a cross-match in the possession doubles the switch rate. The live model sees neither.
#
# Positions (per held-out game, from 28_fold_positions.R, so the graded game's tracking never shaped them): each of
# the ten players' probability of being a guard, a wing or a big (pos), and his most likely group as 0/1 indicators
# (pos_hard, the owner's preferred form since 2026-11-19). The transformer gets the three as movement
# channels (the same at every step, 0 when the player is absent). The logistic baseline gets the four screen
# players' guard and big probabilities (wing is the reference) and "same size": the chance both defenders are in the
# same group, sum over groups of p(handler's defender) x p(screener's defender).
#
# The possession's memory at each prediction frame t, all read only once readable (1 s after, R/past_only.R
# KNOWN_AFTER), never from after t:
#   sw_before   an off-ball screen, handoff or pick earlier in the screen's possession was switched (its frame + 1 s
#               <= t; the screen itself never counts)
#   re_pick     an earlier pick in the possession (frame + 1 s <= t, before this screen)
#   cross       cross-matched: a matchups row of the handler (screener) in the possession, ended at least 1 s before
#               t and before the pick frame, had someone other than his defender at the pick. Rows still running
#               are never read, so the pick's own hand-over (median +0.9 s) cannot enter
# Check: every input is recomputed with everything after its readable time scrambled (later events' frames and
# coverages, later matchups rows' defenders and ends) on 300 random rows; they must not change.
#
# Writes screen_coverage/02_cache/experiments/personnel/inputs.rds.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages(library(data.table))
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
cache_dir <- file.path(root, "screen_coverage", "02_cache")
exp_dir <- file.path(cache_dir, "experiments", "personnel")
L <- readRDS(file.path(cache_dir, "logistic_per_frame.rds"))
SQ <- readRDS(file.path(cache_dir, "sequences.rds"))
POS <- readRDS(file.path(exp_dir, "positions_by_fold.rds"))
if (!identical(L$rules, PAST_ONLY_RULES) || !identical(SQ$screen_ids, L$P$id)) stop("Rerun 01_logistic_baseline.R and 02_build_sequences.R")
P <- L$P
X <- L$X
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
canon <- function(id) {
  m <- aliases$canonical_player_id[match(id, aliases$player_id)]
  fifelse(is.na(m), id, m)
}
POS_COLS <- c("p_guard", "p_wing", "p_big")
MEM_COLS <- c("sw_before", "re_pick", "cross")





## ═════════════════════════════════════════════════════════════════════════════
## 01 - POSITIONS PER FOLD -----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# For every held-out game: the ten roster slots' group probabilities [screens x 10 x 3]. A player without an
# offensive archetype (none expected) gets an even split.
roster_c <- matrix(canon(SQ$roster), nrow(SQ$roster))
pos_arrays <- lapply(POS$folds, function(f) {
  m <- match(roster_c, f$pid)
  a <- array(1 / 3, c(dim(roster_c), 3L), dimnames = list(NULL, NULL, POS_COLS))
  for (k in seq_along(POS_COLS)) {
    v <- f[[POS_COLS[k]]][m]
    v[is.na(v)] <- 1 / 3
    a[, , k] <- v
  }
  attr(a, "missing") <- sum(is.na(m) & !is.na(roster_c))
  a
})
# Hard groups (owner, 2026-11-19): each player in his most likely group only, as 0/1 indicators in the same layout.
pos_hard <- lapply(pos_arrays, function(a) {
  top <- apply(a, c(1, 2), which.max)
  h <- array(0, dim(a), dimnames = dimnames(a))
  for (k in seq_along(POS_COLS)) h[, , k] <- (top == k) * 1
  h
})
cat("Hard groups in the roster slots (first fold): guard / wing / big =",
    paste(apply(pos_hard[[1]], 3, sum), collapse = " / "), "\n")
cat("Roster slots without a position (any fold):", max(vapply(pos_arrays, attr, 0L, "missing")), "of", sum(!is.na(roster_c)), "\n")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - THE POSSESSION'S MEMORY ------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Per game: earlier actions (frame, switched?, is it a pick, its id) and matchups rows, by possession.
events <- list()
mups <- list()
for (g in unique(P$game_id)) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  cp <- B$ch[, .(chance, poss)]
  one <- function(dt, pick) if (nrow(dt)) merge(dt[, .(id, chance, f = f0, sw = cov %in% "switch", pick = pick)], cp, by = "chance") else NULL
  events[[as.character(g)]] <- rbindlist(list(one(B$obs, FALSE), one(B$handoffs, FALSE), one(B$picks, TRUE)))[, game_id := g]
  mups[[as.character(g)]] <- merge(B$mu, cp, by = "chance")[, .(poss, f0, f1, def, off)][, game_id := g]
}
EV <- rbindlist(events)
MU <- rbindlist(mups)

#' The three memory flags for screen i at prediction frames tt, from event table ev and matchups table mu.
memory_of <- function(i, tt, ev, mu) {
  s <- P[i]
  e <- ev[game_id == s$game_id & poss == s$poss & id != s$id]
  m <- mu[game_id == s$game_id & poss == s$poss & ((off == s$H & def != s$BD) | (off == s$S & def != s$SD))]
  known <- e$f + KNOWN_AFTER
  ended <- m$f1 + KNOWN_AFTER
  cbind(sw_before = vapply(tt, function(t) any(e$sw & known <= t & e$f < s$f0), 0),
        re_pick = vapply(tt, function(t) any(e$pick & known <= t & e$f < s$f0), 0),
        cross = vapply(tt, function(t) any(ended <= min(t, s$f0)), 0))
}
MEM <- matrix(0, nrow(X), length(MEM_COLS), dimnames = list(NULL, MEM_COLS))
rows_of <- split(seq_len(nrow(X)), X$idx)
for (i in seq_len(nrow(P))) {
  r <- rows_of[[as.character(i)]]
  MEM[r, ] <- memory_of(i, X$frame[r], EV, MU)
}
cat("Memory flags, share of rows at the pick frame:\n")
print(round(colMeans(MEM[X$off == 0, ]), 3))
cat("Switch rate at the pick frame with each flag on:\n")
print(round(sapply(MEM_COLS, function(k) mean(X$call[X$off == 0 & MEM[, k] == 1] == "switch")), 3))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - PAST-ONLY CHECK --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# For random rows: scramble every event and matchups row not yet readable at the row's frame, recompute, compare.
set.seed(20261119)
check <- sample(nrow(X), 300L)
changed <- 0L
for (r in check) {
  i <- X$idx[r]
  t <- X$frame[r]
  ev <- copy(EV[game_id == P$game_id[i]])
  late <- ev$f + KNOWN_AFTER > t
  ev[late, `:=`(f = f + sample(-200:200, .N, TRUE), sw = sample(c(TRUE, FALSE), .N, TRUE), pick = sample(c(TRUE, FALSE), .N, TRUE))]
  ev[late & f + KNOWN_AFTER <= t, f := t]
  mu <- copy(MU[game_id == P$game_id[i]])
  open <- mu$f1 + KNOWN_AFTER > t
  mu[open, `:=`(def = sample(unique(MU$def), .N, TRUE), f1 = pmax(f1 + sample(-200:200, .N, TRUE), t - KNOWN_AFTER + 1L))]
  if (!identical(memory_of(i, t, ev, mu)[1, ], MEM[r, ])) changed <- changed + 1L
}
cat(sprintf("Past-only check: %d of %d rows changed when everything after their readable time was scrambled\n", changed, length(check)))
if (changed) stop("The memory inputs read the future")

saveRDS(list(pos = pos_arrays, pos_hard = pos_hard, mem = MEM, pos_cols = POS_COLS, mem_cols = MEM_COLS, screen_ids = P$id,
             rules = PAST_ONLY_RULES, past_only_check = c(rows = length(check), changed = changed)),
        file.path(exp_dir, "inputs.rds"))
cat("Wrote", file.path(exp_dir, "inputs.rds"), "\n")
