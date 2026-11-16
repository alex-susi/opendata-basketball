## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 13: when does a screen become evident, and when does the ball handler act?
#   Rscript screen_coverage/01_scripts/13_window_anchors.R
#
# Measures the two ends of the scoring window from data the coverage models do not predict: tracking positions of the
# handler and screener, and the event timing of the handler's touch, drive, pass and shot. No coverage label, no model
# output. For the 1,463 scored screens (logistic_per_frame.rds), relative to the screen tag (t = 0):
#   start  the handler's touch start (he has the ball); the onset of the final handler-screener approach (their
#          distance closing faster than a threshold, walking back from contact); the screener's own approach (his
#          velocity toward the handler); the last time the pair came within 15 ft and 10 ft before contact
#   end    the drive start on the pick's touch, if any; the end of the touch (pass, shot, turnover or foul)
#
# Writes screen_coverage/03_outputs/window_anchors/: anchors_per_screen.csv, anchor_summary.csv,
# end_by_outcome.csv, and the figure anchors.png.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})
out_dir <- file.path(root, "screen_coverage", "03_outputs", "window_anchors")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Frame rate; closing-speed lag (0.2 s); thresholds for "approaching" in ft/s (the middle one is the main reading);
# dips allowed inside an approach run; the span around the tag searched for contact; distance thresholds.
FPS <- 25
LAG <- 5L
CLOSE_FTS <- c(1, 2, 3)
MAIN_FTS <- 2
MAX_DIP <- 5L
CONTACT_SPAN <- 12L
NEAR_FT <- c(15, 10)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - SCREENS AND POSITIONS --------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The scored screens and the cached ten-player positions, -3.6 s to +1 s around each tag (02_build_sequences.R). Row 1
# is the ball handler, row 2 the screener; an absent player has present = 0.
L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
SQ <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
stopifnot(identical(SQ$screen_ids, L$P$id))
P <- copy(L$P)
offs <- SQ$base_offs
B <- SQ$base
ns <- nrow(P)
pres <- B[, , 1, "present"] == 1 & B[, , 2, "present"] == 1
hx <- B[, , 1, "x"]
hy <- B[, , 1, "y"]
sx <- B[, , 2, "x"]
sy <- B[, , 2, "y"]
hx[!pres] <- NA
hy[!pres] <- NA
sx[!pres] <- NA
sy[!pres] <- NA
# Handler-screener distance per frame, its closing speed over the last 0.2 s, and the screener's own velocity toward
# the handler over the same 0.2 s. All [screens, frames].
D <- sqrt((hx - sx)^2 + (hy - sy)^2)
lag_cols <- function(A) cbind(matrix(NA_real_, ns, LAG), A[, seq_len(ncol(A) - LAG), drop = FALSE])
CLOSE <- (lag_cols(D) - D) * FPS / LAG
svx <- (sx - lag_cols(sx)) * FPS / LAG
svy <- (sy - lag_cols(sy)) * FPS / LAG
SCR_APP <- (svx * (hx - sx) + svy * (hy - sy)) / pmax(D, 1e-6)





## ═════════════════════════════════════════════════════════════════════════════
## 03 - START: WHEN THE SCREEN BECOMES EVIDENT ---------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Contact: the frame of the pair's smallest distance within 0.48 s of the tag.
tag_col <- match(0L, offs)
span <- (tag_col - CONTACT_SPAN):(tag_col + CONTACT_SPAN)
contact_col <- vapply(seq_len(ns), function(i) {
  d <- D[i, span]
  if (all(is.na(d))) NA_integer_ else span[which.min(d)]
}, 0L)

#' Onset of the final run before contact in which speed series v stays above thr, walking back from contact and
#' allowing dips of up to MAX_DIP frames. Returns the onset in seconds from the tag, and whether the walk reached a
#' missing frame or the start of the stored history (censored: the true onset is at least that early).
onset_back <- function(v, from, thr) {
  if (is.na(from)) return(c(NA_real_, NA_real_))
  k <- from
  last_ok <- NA_integer_
  dip <- 0L
  censored <- 0
  while (k >= 1L) {
    if (is.na(v[k])) {
      censored <- 1
      break
    }
    if (v[k] > thr) {
      last_ok <- k
      dip <- 0L
    } else {
      dip <- dip + 1L
      if (dip > MAX_DIP && !is.na(last_ok)) break
      if (dip > MAX_DIP && is.na(last_ok) && from - k > CONTACT_SPAN) break
    }
    k <- k - 1L
  }
  if (k < 1L) censored <- 1
  if (is.na(last_ok)) return(c(NA_real_, censored))
  c(offs[last_ok] / FPS, censored)
}

# The pair's approach and the screener's own approach, at each threshold.
start_rows <- list()
for (thr in CLOSE_FTS) {
  pa <- t(vapply(seq_len(ns), function(i) onset_back(CLOSE[i, ], contact_col[i], thr), numeric(2)))
  sa <- t(vapply(seq_len(ns), function(i) onset_back(SCR_APP[i, ], contact_col[i], thr), numeric(2)))
  start_rows[[length(start_rows) + 1L]] <- data.table(id = P$id, thr = thr, pair_onset = pa[, 1], pair_cens = pa[, 2],
                                                      scr_onset = sa[, 1], scr_cens = sa[, 2])
}
starts <- rbindlist(start_rows)

# Last time the pair came within each distance before contact and stayed within it until contact.
near_since <- function(i, ft) {
  if (is.na(contact_col[i])) return(NA_real_)
  d <- D[i, seq_len(contact_col[i])]
  if (is.na(d[length(d)]) || d[length(d)] > ft) return(NA_real_)
  out <- which(is.na(d) | d > ft)
  if (!length(out)) return(NA_real_)
  offs[max(out) + 1L] / FPS
}
near <- as.data.table(setNames(lapply(NEAR_FT, function(ft) vapply(seq_len(ns), near_since, 0, ft = ft)),
                               paste0("within_", NEAR_FT, "ft")))
P[, `:=`(contact_t = offs[contact_col] / FPS, contact_dist = D[cbind(seq_len(ns), contact_col)])]
P <- cbind(P, near)





## ═════════════════════════════════════════════════════════════════════════════
## 04 - END: WHEN THE HANDLER ACTS ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Each pick's touch (the handler's possession of the ball), its outcome, and any drive on that touch.
games <- sort(unique(P$game_id))
ev <- rbindlist(lapply(games, function(g) {
  e <- jsonlite::fromJSON(file.path(root, "data", "matches", g, paste0(g, "_dynamic_events.json")))
  pk <- as.data.table(e$picks)[, .(id, frame, touchId, ballhandlerId)]
  tc <- as.data.table(e$touches)[, .(touchId = id, t_start = startFrame, t_end = endFrame, t_player = playerId,
                                     outcomes = vapply(outcomes, function(o) paste(sort(o), collapse = "|"), ""))]
  dr <- as.data.table(e$drives)[, .(d_start = min(startFrame)), by = touchId]
  merge(merge(pk, tc, by = "touchId", all.x = TRUE), dr, by = "touchId", all.x = TRUE)
}))
P[, ord := .I]
P <- merge(P, ev, by = "id", all.x = TRUE)
setorder(P, ord)
stopifnot(nrow(P) == ns, identical(P$id, main_ids <- SQ$screen_ids), all(P$f0 == P$frame, na.rm = TRUE))
# Times relative to the tag, and how the touch ended: shot, pass, turnover, foul or other.
P[, `:=`(touch_start_t = (t_start - f0) / FPS, touch_end_t = (t_end - f0) / FPS, drive_start_t = (d_start - f0) / FPS,
         handler_match = t_player == ballhandlerId)]
P[, end_type := fcase(grepl("FG[MX]", outcomes), "shot", grepl("TO", outcomes), "turnover",
                      grepl("FOU", outcomes), "foul", grepl("PASS", outcomes), "pass", default = "other")]





## ═════════════════════════════════════════════════════════════════════════════
## 05 - SUMMARIES AND FIGURE ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One row per anchor: how many screens have it, censored share, and quantiles in seconds from the tag.
qs <- function(v, name, cens = NULL) {
  ok <- !is.na(v)
  q <- quantile(v[ok], c(0.1, 0.25, 0.5, 0.75, 0.9))
  data.table(anchor = name, screens = sum(ok), censored = if (is.null(cens)) NA_real_ else round(mean(cens[ok] == 1), 3),
             p10 = q[1], p25 = q[2], median = q[3], p75 = q[4], p90 = q[5])
}
main <- starts[thr == MAIN_FTS]
summ <- rbind(qs(P$touch_start_t, "handler's touch starts"),
              rbindlist(lapply(CLOSE_FTS, function(k) {
                s <- starts[thr == k]
                rbind(qs(s$pair_onset, sprintf("pair closing > %g ft/s begins", k), s$pair_cens),
                      qs(s$scr_onset, sprintf("screener moving at handler > %g ft/s begins", k), s$scr_cens))
              })),
              qs(P$within_15ft, "pair within 15 ft (until contact)"), qs(P$within_10ft, "pair within 10 ft (until contact)"),
              qs(P$contact_t, "contact (closest within 0.48 s of tag)"), qs(P$drive_start_t, "drive starts (pick's touch)"),
              qs(P$touch_end_t, "handler's touch ends"))
num <- c("p10", "p25", "median", "p75", "p90")
summ[, (num) := lapply(.SD, round, 2), .SDcols = num]
fwrite(summ, file.path(out_dir, "anchor_summary.csv"))
by_end <- P[, .(screens = .N, median_end = round(median(touch_end_t, na.rm = TRUE), 2),
                p25 = round(quantile(touch_end_t, 0.25, na.rm = TRUE), 2), p75 = round(quantile(touch_end_t, 0.75, na.rm = TRUE), 2)),
            by = end_type][order(-screens)]
fwrite(by_end, file.path(out_dir, "end_by_outcome.csv"))
per_screen <- cbind(P[, .(id, game_id, contact_t, contact_dist, touch_start_t, within_15ft, within_10ft, drive_start_t,
                          touch_end_t, end_type, handler_match)],
                    main[, .(pair_onset_2fts = pair_onset, pair_cens = pair_cens, scr_onset_2fts = scr_onset, scr_cens = scr_cens)])
fwrite(per_screen, file.path(out_dir, "anchors_per_screen.csv"))
cat("Screens:", ns, "| touch matched:", sum(!is.na(P$t_end)), "| touch player = handler:", sum(P$handler_match, na.rm = TRUE),
    "| with a drive on the touch:", sum(!is.na(P$d_start)), "\n")
print(summ)
print(by_end)

# Figure: the distribution of each main anchor, seconds from the tag.
fig <- rbind(data.table(anchor = "handler's touch starts", t = P$touch_start_t),
             data.table(anchor = "pair closing > 2 ft/s begins", t = main$pair_onset),
             data.table(anchor = "screener moving at handler > 2 ft/s begins", t = main$scr_onset),
             data.table(anchor = "pair within 10 ft (until contact)", t = P$within_10ft),
             data.table(anchor = "contact (closest within 0.48 s of tag)", t = P$contact_t),
             data.table(anchor = "drive starts (pick's touch)", t = P$drive_start_t),
             data.table(anchor = "handler's touch ends", t = P$touch_end_t))[!is.na(t)]
fig[, anchor := factor(anchor, levels = rev(unique(anchor)))]
g <- ggplot(fig, aes(x = t, y = anchor)) +
  geom_vline(xintercept = 0, linetype = 2, colour = "grey50") +
  geom_boxplot(outlier.size = 0.4, width = 0.5, fill = "grey90") +
  coord_cartesian(xlim = c(-4, 4)) +
  labs(x = "Seconds from the screen tag", y = NULL,
       title = "Screen evident vs handler acts, 1,463 screens") +
  theme_minimal(base_size = 11)
ggsave(file.path(out_dir, "anchors.png"), g, width = 9, height = 4, dpi = 150)
