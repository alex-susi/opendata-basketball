## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 35: the play-review sample (coverage product plan, Phase 3, 2026-11-21).
#   Rscript screen_coverage/01_scripts/35_review_sample.R
#
# Picks about 50 on-ball screens for the owner to review in the play viewer's review panel, BEFORE anyone looks at how
# the model did on them: this script never reads a prediction. The sample is stratified so every coverage and every
# hard case the plan asks for is there, which makes it a sample for diagnosis, never an estimate of how common
# anything is.
#
# Strata (counts in STRATA below):
#   - switches, split by when the matchups table first hands the handler to the screener's defender (from 1 s before
#     to 3 s after the pick frame, the EDA's one-sided hand-over): early (by +0.4 s), late (after +0.4 s), none by +3 s
#   - the four other coverages, each with some screens where that hand-over shows up anyway (a temporary show or help:
#     the pressure-and-return controls)
#   - screens outside the five coverages (ice, blitz, no coverage called): denied or avoided screens
#   - five-coverage screens left out of the model for incomplete tracking
# Inside a stratum, screens with a hard-case flag are drawn more often: a re-screen (another pick in the possession
# within 3 s), a closest approach at the edge of the ±0.48 s search (13_window_anchors.R), a low tracking quality
# chance (quality index below 3), or a screener moving fast or standing still at the pick frame. At most MAX_PER_GAME
# screens per game. A seeded subset of REPEAT_N is marked for the owner's second, blind pass.
#
# Writes:
#   - web/public/data/coverage_review_sample.json · the review queue in a shuffled order, with no coverage, stratum or
#     flag (the panel must not give the answer away)
#   - screen_coverage/03_outputs/product_review/review_sample_strata.csv · every case with its coverage, stratum and
#     flags (for analysis after the review; do not open it before reviewing)
#   - screen_coverage/03_outputs/product_review/review_sample_summary.csv · achieved counts per stratum and flag
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "product_review")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
FPS <- 25L





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

SEED <- 20261121L
STRATA <- c(switch_early = 5L, switch_late = 5L, switch_none = 5L,
            over_show = 8L, over_drop = 7L, under_drop = 6L, under_show = 6L,
            outside_five = 5L, left_out_tracking = 3L)
# Of each non-switch coverage, at least this many where the one-sided hand-over shows up anyway (pressure-and-return
# and help controls).
CONTROLS <- c(over_show = 2L, under_show = 2L, over_drop = 1L, under_drop = 1L)
MAX_PER_GAME <- 7L
REPEAT_N <- 12L
# Extra draw weight per hard-case flag.
FLAG_WEIGHT <- 2





## ═════════════════════════════════════════════════════════════════════════════
## 02 - EVERY PICK WITH ITS FLAGS ----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The scored cohort (01_logistic_baseline.R) and its screener's speed at the pick frame (02_build_sequences.R).
L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
SQ <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
stopifnot(identical(SQ$screen_ids, L$P$id))
scr_speed <- SQ$base[, match(0L, SQ$base_offs), 2L, match("speed", SQ$feats)]
anchors <- fread(file.path(root, "screen_coverage", "03_outputs", "window_anchors", "anchors_per_screen.csv"))

# All picks of the ten games from the site's per-game bundles: players, coverage, possession, chance quality, and the
# first one-sided hand-over in the matchups table.
games <- sort(unique(L$P$game_id))
picks <- rbindlist(lapply(games, function(g) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  p <- merge(B$picks[, .(id, chance, f0, H = actor, BD = adef, S = screener, SD = sdef, cov, scov)],
             B$ch[, .(chance, poss, q)], by = "chance", all.x = TRUE)
  mu <- merge(B$mu, B$ch[, .(chance, poss)], by = "chance")
  p[, t_hand := vapply(seq_len(.N), function(i) {
    m <- mu[poss == p$poss[i] & off == p$H[i] & def == p$SD[i] & f1 >= p$f0[i] - FPS & f0 <= p$f0[i] + 3L * FPS][order(f0)]
    if (nrow(m)) (max(m$f0[1], p$f0[i] - FPS) - p$f0[i]) / FPS else NA_real_
  }, 0)]
  # A re-screen: another pick in the same possession within 3 s either side.
  p[, rescreen := vapply(seq_len(.N), function(i) any(p$poss == p$poss[i] & p$id != p$id[i] & abs(p$f0 - p$f0[i]) <= 3L * FPS), TRUE)]
  p[, game_id := g]
  p
}))
picks[scov == "soft", scov := "drop"]
picks[, call := fifelse(cov == "switch" | scov == "switch", "switch",
                        fifelse(cov %in% c("over", "under") & scov %in% c("show", "drop"), paste(cov, "+", scov), NA_character_))]
picks[, in_cohort := id %in% L$P$id]
picks[, speed := scr_speed[match(id, L$P$id)]]
picks <- merge(picks, anchors[, .(id, contact_t)], by = "id", all.x = TRUE)
spd_q <- quantile(picks$speed, c(1 / 3, 2 / 3), na.rm = TRUE)
picks[, `:=`(low_quality = !is.na(q) & q < 3, boundary = !is.na(contact_t) & abs(contact_t) >= 0.48 - 1e-9,
             screener_moving = !is.na(speed) & speed >= spd_q[2], screener_still = !is.na(speed) & speed <= spd_q[1])]

# Each pick's stratum (NA: not eligible). The cohort's call matches the event fields for every cohort screen.
stopifnot(all(picks[in_cohort == TRUE]$call == L$P$call[match(picks[in_cohort == TRUE]$id, L$P$id)]))
picks[, stratum := fcase(
  in_cohort & call == "switch" & !is.na(t_hand) & t_hand <= 0.4, "switch_early",
  in_cohort & call == "switch" & !is.na(t_hand), "switch_late",
  in_cohort & call == "switch", "switch_none",
  in_cohort, sub(" + ", "_", call, fixed = TRUE),
  !in_cohort & is.na(call), "outside_five",
  !in_cohort & !is.na(call), "left_out_tracking",
  default = NA_character_)]
picks[, flags := rescreen + boundary + low_quality + screener_moving + screener_still]





## ═════════════════════════════════════════════════════════════════════════════
## 03 - DRAW THE SAMPLE --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One stratum at a time, rarest first so the game cap bites on the common ones. Within a stratum, the hand-over
# controls first (non-switch coverages), then the rest, each drawn with weight 1 + FLAG_WEIGHT per flag.
set.seed(SEED)
taken <- character(0)
draw <- function(pool, n) {
  out <- character(0)
  while (length(out) < n) {
    per_game <- table(factor(picks[id %in% c(taken, out)]$game_id, levels = games))
    ok <- pool[!id %in% c(taken, out) & per_game[as.character(game_id)] < MAX_PER_GAME]
    if (!nrow(ok)) break
    out <- c(out, ok$id[sample.int(nrow(ok), 1L, prob = 1 + FLAG_WEIGHT * ok$flags)])
  }
  out
}
order_strata <- names(sort(table(picks$stratum)[names(STRATA)]))
for (s in order_strata) {
  pool <- picks[stratum == s]
  n_ctrl <- if (s %in% names(CONTROLS)) CONTROLS[[s]] else 0L
  got <- draw(pool[!is.na(t_hand)], n_ctrl)
  taken <- c(taken, got)
  taken <- c(taken, draw(pool, STRATA[[s]] - length(got)))
}
S <- picks[id %in% taken]
S[, control := stratum %in% names(CONTROLS) & !is.na(t_hand)]

# The second-pass subset: per stratum group, a seeded draw.
rep_plan <- list(switch = 4L, over_show = 2L, over_drop = 2L, under_drop = 1L, under_show = 1L, outside_five = 1L, left_out_tracking = 1L)
S[, group := fifelse(startsWith(stratum, "switch"), "switch", stratum)]
S[, repeat_pass := FALSE]
for (g in names(rep_plan)) {
  ids <- S[group == g]$id
  S[id %in% ids[sample.int(length(ids), min(rep_plan[[g]], length(ids)))], repeat_pass := TRUE]
}
stopifnot(sum(S$repeat_pass) == REPEAT_N)

# The review order: shuffled, so the queue says nothing about the coverage.
S <- S[sample.int(.N)]
S[, case := seq_len(.N)]





## ═════════════════════════════════════════════════════════════════════════════
## 04 - WRITE ------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

queue <- lapply(seq_len(nrow(S)), function(i) {
  r <- S[i]
  list(case = r$case, id = r$id, game = r$game_id, poss = r$poss, f0 = r$f0, h = r$H, s = r$S, bd = r$BD, sd = r$SD,
       repeat_pass = r$repeat_pass)
})
jsonlite::write_json(list(version = 1L, seed = SEED, made = format(Sys.time(), "%Y-%m-%d"), n = nrow(S), cases = queue),
                     file.path(root, "web", "public", "data", "coverage_review_sample.json"), auto_unbox = TRUE)
fwrite(S[, .(case, id, game_id, poss, f0, call, cov, scov, stratum, control, repeat_pass, in_cohort, t_hand, rescreen,
             boundary, low_quality, screener_moving, screener_still, q, contact_t, speed = round(speed, 2))],
       file.path(out_dir, "review_sample_strata.csv"))
flag_cols <- c("control", "rescreen", "boundary", "low_quality", "screener_moving", "screener_still", "repeat_pass")
summary_tab <- rbind(S[, .(n = .N), by = .(what = stratum)][order(what)],
                     data.table(what = flag_cols, n = vapply(flag_cols, function(f) sum(S[[f]]), 0L)),
                     data.table(what = paste0("game_", games), n = as.integer(table(factor(S$game_id, levels = games)))))
fwrite(summary_tab, file.path(out_dir, "review_sample_summary.csv"))
print(summary_tab)
cat("Wrote", nrow(S), "review cases\n")
