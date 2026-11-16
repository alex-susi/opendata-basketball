## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 15: are the live model's percentages honest?
#   Rscript screen_coverage/01_scripts/15_calibration.R
#
# Calibration check of the held-out probabilities (each game predicted by the folds that never saw it). A model is
# well calibrated when, of all the times it says "70% over", over is the actual call about 70% of the time. Checked
# for the full call (five calls), the ball handler's defender alone (over / under / switch) and the screener's
# defender alone (show / soft / switch), for the live transformer and the logistic baseline.
#
# Frames are weighted with the fixed "main" time-weight curve (R/window_weights.R: 0 before -1.8 s, up to full weight
# at -0.9 s, full through +0.24 s, down to 0 at +0.5 s from the pick frame), the moments a ball handler would use the
# read. The by-time check uses every scored frame from -2 s to +1 s, unweighted.
#
#   reliability   per call: predictions grouped in 10-point bins (0-10%, ..., 90-100%) against how often that call
#                 happened; the gap averaged over bins by their share of frames (calibration error, in points)
#   top call      the card's leading call: its stated probability against how often it was right, overall and at each
#                 moment from -2 s to +1 s (positive gap = overconfident)
#   confident     frames where a call is stated at 60% or more, by time from the pick frame: how often it happened
#   temperature   one number summarising the direction: the single softening (T > 1, the model is overconfident) or
#                 sharpening (T < 1, underconfident) of all held-out probabilities that would best fit the outcomes;
#                 fitted on the same held-out games, so a diagnostic only, not a fix
# 95% intervals resample whole games (1,000 draws).
#
# Writes screen_coverage/03_outputs/calibration/: calibration_error.csv, reliability_bins.csv, top_call_by_time.csv,
# confident_reads_by_time.csv, temperature.csv, card_flicker.csv, reliability.png, top_call_by_time.png.
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
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "calibration")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Bin width, game resamples, the logistic baseline used (as in 04_evaluate.R) and the time-weight curve.
BINS <- seq(0, 1, 0.1)
N_BOOT <- 1000L
SEED <- 20261115L
LOGISTIC <- "no timing, + closeness"
CURVE <- "main"

# A "confident read": a call stated at 60% or more; the time bands (seconds from the pick frame) it is checked in.
CONF_MIN <- 0.6
CONF_BANDS <- c(-2, -1, -0.5, 0, 0.25, 0.5, 1)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PREDICTIONS PER CALL ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- L$X
calls <- L$calls
models <- list(transformer = load_seqheads(root)$prob, logistic = L$prob[[LOGISTIC]])

# Each score's call probabilities: the five joint calls, or a defender's three, summed from the joint calls.
score_probs <- function(P) {
  def <- function(groups) sapply(groups, function(m) rowSums(P[, match(m, calls), drop = FALSE]))
  list(joint = setNames(as.data.frame(P), calls), guard = as.data.frame(def(GUARD_CALLS)),
       big = as.data.frame(def(BIG_CALLS)))
}
truth <- list(joint = X$call,
              guard = names(GUARD_CALLS)[vapply(X$call, function(cc) which(vapply(GUARD_CALLS, function(m) cc %in% m, TRUE)), 1L)],
              big = names(BIG_CALLS)[vapply(X$call, function(cc) which(vapply(BIG_CALLS, function(m) cc %in% m, TRUE)), 1L)])

# Long table: one row per frame and call, with the stated probability, whether it happened and the frame's weight.
w_main <- window_weight(X$off, CURVE)
long <- rbindlist(lapply(names(models), function(m) {
  sp <- score_probs(models[[m]])
  rbindlist(lapply(names(sp), function(s) {
    rbindlist(lapply(names(sp[[s]]), function(k) {
      data.table(model = m, score = s, call = k, game_id = X$game_id, off = X$off, w = w_main, p = sp[[s]][[k]],
                 y = as.numeric(truth[[s]] == k))
    }))
  }))
}))
long[, bin := cut(p, BINS, include.lowest = TRUE, labels = FALSE)]
stopifnot(!anyNA(long$p), !anyNA(long$bin))

# The leading call per frame (the top bar on the card): its stated probability and whether it was the actual call.
top <- rbindlist(lapply(names(models), function(m) {
  sp <- score_probs(models[[m]])
  rbindlist(lapply(names(sp), function(s) {
    P <- as.matrix(sp[[s]])
    k <- max.col(P, ties.method = "first")
    data.table(model = m, score = s, idx = X$idx, game_id = X$game_id, off = X$off, w = w_main,
               conf = P[cbind(seq_along(k), k)], right = as.numeric(colnames(P)[k] == truth[[s]]))
  }))
}))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - GAME RESAMPLING --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Sums per game are added up with each draw's game counts, so a statistic is recomputed per draw without the rows.
set.seed(SEED)
games <- sort(unique(X$game_id))
draw_counts <- vapply(seq_len(N_BOOT), function(i) tabulate(match(sample(games, replace = TRUE), games), length(games)),
                      numeric(length(games)))

#' Point estimate and 95% interval of `stat` applied to sums of `cols` within groups `by`, games resampled.
#' `d` holds one row per game and group; `stat` takes a data.table of summed cols per group and returns one number.
boot_stat <- function(d, by, cols, stat) {
  arr <- lapply(cols, function(cc) {
    m <- dcast(d, as.formula(paste(paste(by, collapse = " + "), "~ game_id")), value.var = cc, fill = 0)
    as.matrix(m[, as.character(games), with = FALSE])
  })
  names(arr) <- cols
  # The keys come out of dcast in the same sorted order for every column.
  key_dt <- dcast(d, as.formula(paste(paste(by, collapse = " + "), "~ game_id")), value.var = cols[1], fill = 0)[, ..by]
  at <- function(cnt) {
    s <- key_dt[, ..by]
    for (cc in cols) set(s, j = cc, value = as.numeric(arr[[cc]] %*% cnt))
    stat(s)
  }
  est <- at(rep(1, length(games)))
  v <- apply(draw_counts, 2, at)
  c(est = est, lo = quantile(v, 0.025, names = FALSE), hi = quantile(v, 0.975, names = FALSE))
}





## ═════════════════════════════════════════════════════════════════════════════
## 04 - RELIABILITY ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Weighted sums per game, model, score, call and bin.
g <- long[w > 0, .(sw = sum(w), swp = sum(w * p), swy = sum(w * y), n = .N), by = .(model, score, call, bin, game_id)]
bins_out <- g[, .(stated = sum(swp) / sum(sw), happened = sum(swy) / sum(sw), frames = sum(n), weight = sum(sw)),
              by = .(model, score, call, bin)]
setorder(bins_out, model, score, call, bin)
fwrite(bins_out[, .(model, score, call, bin = sprintf("%d-%d%%", (bin - 1) * 10, bin * 10), stated = round(stated, 3),
                    happened = round(happened, 3), frames, weight = round(weight, 1))],
       file.path(out_dir, "reliability_bins.csv"))

# Calibration error per model and score, plus the same for each call alone. No interval: resampling games thins the
# bins and so inflates this measure (every resample scores worse than the data), which makes a percentile interval
# misleading. The top-call gap below is a plain average and does get one.
pool <- g[, .(sw = sum(sw), swp = sum(swp), swy = sum(swy)), by = .(model, score, call, bin)]
err_call <- pool[sw > 0, .(est = sum(sw * abs(swy / sw - swp / sw)) / sum(sw)), by = .(model, score, call)]
err <- err_call[, .(call = "all calls (mean)", est = mean(est)), by = .(model, score)]
err_call[, c("lo", "hi") := NA_real_]
err[, c("lo", "hi") := NA_real_]





## ═════════════════════════════════════════════════════════════════════════════
## 05 - TOP CALL ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Overall (main curve): mean stated minus share right, in points (positive = overconfident).
tg <- top[w > 0, .(sw = sum(w), swc = sum(w * conf), swr = sum(w * right)), by = .(model, score, game_id)]
top_gap <- rbindlist(lapply(split(tg, by = c("model", "score")), function(d) {
  d[, one := 1L]
  r <- boot_stat(d, "one", c("sw", "swc", "swr"), function(s) s[, (swc - swr) / sw])
  data.table(model = d$model[1], score = d$score[1], call = "top call: stated minus right", t(r))
}))

# By moment, every scored frame, unweighted.
tt <- top[, .(n = .N, sc = sum(conf), sr = sum(right)), by = .(model, score, off, game_id)]
by_time <- rbindlist(lapply(split(tt, by = c("model", "score", "off")), function(d) {
  d[, one := 1L]
  r <- boot_stat(d, "one", c("n", "sc", "sr"), function(s) s[, (sc - sr) / n])
  data.table(model = d$model[1], score = d$score[1], t = d$off[1] / WINDOW_FPS, stated = sum(d$sc) / sum(d$n),
             right = sum(d$sr) / sum(d$n), gap = r[["est"]], lo = r[["lo"]], hi = r[["hi"]])
}))
fwrite(by_time[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "top_call_by_time.csv"))

# Confident reads by moment: frames where a call is stated at 60% or more, grouped by time from the pick frame, with
# how often that call happened. Screens counts the distinct screens behind the frames (a screen gives many frames).
long[, idx := X$idx[rowid(model, score, call)]]
long[, band := cut(off / WINDOW_FPS, CONF_BANDS, include.lowest = TRUE)]
conf_t <- long[p >= CONF_MIN, .(frames = .N, screens = uniqueN(idx), stated = mean(p), happened = mean(y)),
               by = .(model, score, call, band)]
setorder(conf_t, model, score, call, band)
fwrite(conf_t[, .(model, score, call, seconds = band, frames, screens, stated = round(stated, 3),
                  happened = round(happened, 3))], file.path(out_dir, "confident_reads_by_time.csv"))
print(conf_t[model == "transformer" & score == "joint" & call == "switch"], digits = 3)





## ═════════════════════════════════════════════════════════════════════════════
## 06 - TEMPERATURE ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The single power on the probabilities (p^(1/T), renormalised) that minimises the main-curve-weighted log loss of
# the held-out frames. Diagnostic only: fitted on the same games it describes.
fit_temp <- function(P, y, w) {
  lp <- log(pmax(P, 1e-12))
  loss <- function(Tm) {
    z <- lp / Tm
    z <- z - apply(z, 1, max)
    lq <- z - log(rowSums(exp(z)))
    -sum(w * lq[cbind(seq_along(y), y)]) / sum(w)
  }
  o <- optimize(loss, c(0.25, 4))
  data.table(temperature = o$minimum, loss_before = loss(1), loss_after = o$objective)
}
temps <- rbindlist(lapply(names(models), function(m) {
  sp <- score_probs(models[[m]])
  rbindlist(lapply(names(sp), function(s) {
    P <- as.matrix(sp[[s]])
    keep <- w_main > 0
    cbind(data.table(model = m, score = s),
          fit_temp(P[keep, ], match(truth[[s]][keep], colnames(P)), w_main[keep]))
  }))
}))
fwrite(temps[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "temperature.csv"))

calib <- rbind(err, err_call, top_gap)
setnames(calib, c("est", "lo", "hi"), c("points", "lo", "hi"))
calib[, c("points", "lo", "hi") := lapply(.SD, function(v) round(100 * v, 2)), .SDcols = c("points", "lo", "hi")]
fwrite(calib, file.path(out_dir, "calibration_error.csv"))
print(calib[call %in% c("all calls (mean)", "top call: stated minus right")])
print(temps, digits = 4)

# Card stability (added 2026-11-15, for the Display panel's Raw / 0.08 s switch): how many times per screen the
# live model's leading call changes over the -2 s to +1 s window, from whole-percent values as the card shows them,
# raw or averaged over the last 2 or 5 frames (never a later one).
# Rows are put in screen, then frame order first (X itself is sorted by frame offset).
ord <- order(X$idx, X$off)
sid <- X$idx[ord]
P100 <- round(100 * models$transformer[ord, ])
# Average of the last k frames of the same screen, or of what there is so far at a screen's first frames.
trail_mean <- function(v, k) {
  out <- v
  for (lag in seq_len(k - 1L)) {
    prev <- shift(v, lag)
    ok <- shift(sid, lag) == sid & !is.na(prev)
    out <- out + fifelse(ok %in% TRUE, prev, 0)
  }
  n <- 1 + Reduce(`+`, lapply(seq_len(k - 1L), function(lag) as.numeric((shift(sid, lag) == sid) %in% TRUE)), 0)
  out / n
}
flicker <- rbindlist(lapply(c(1L, 2L, 5L), function(k) {
  m <- if (k > 1) apply(P100, 2, trail_mean, k = k) else P100
  guard_m <- cbind(m[, 1] + m[, 2], m[, 3] + m[, 4], m[, 5])
  big_m <- cbind(m[, 1] + m[, 4], m[, 2] + m[, 3], m[, 5])
  d <- data.table(idx = sid, j = max.col(m, "first"), g = max.col(guard_m, "first"), b = max.col(big_m, "first"))
  d[, .(joint = sum(diff(j) != 0), guard = sum(diff(g) != 0), big = sum(diff(b) != 0)), by = idx][,
    .(card = c("raw", "", "", "", "0.2 s (5 frames)")[k], joint = mean(joint), guard = mean(guard), big = mean(big),
      screens_3plus_joint_changes = mean(joint >= 3))]
}))
flicker[card == "", card := "0.08 s (2 frames)"]
fwrite(flicker[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], file.path(out_dir, "card_flicker.csv"))
print(flicker, digits = 3)





## ═════════════════════════════════════════════════════════════════════════════
## 07 - FIGURES ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Reliability of the live transformer: each call's bins, point size by frames; on the diagonal = honest.
score_lab <- c(joint = "Full call", guard = "Ball handler's defender", big = "Screener's defender")
rb <- bins_out[model == "transformer" & frames >= 30]
rb[, score := factor(score_lab[score], score_lab)]
p1 <- ggplot(rb, aes(stated, happened, colour = call)) +
  geom_abline(slope = 1, intercept = 0, colour = "grey70", linetype = "dashed") +
  geom_line() +
  geom_point(aes(size = weight)) +
  facet_wrap(~score, nrow = 1) +
  scale_x_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_size_area(max_size = 3.5, guide = "none") +
  coord_equal() +
  labs(x = "Model's stated probability (10-point bins)", y = "How often that call happened", colour = NULL,
       title = "Live model: stated probability vs how often the call happened",
       subtitle = "Held-out games; frames weighted by the main time curve (-1.8 s to +0.5 s from the pick frame); bins with 30+ frames") +
  theme_minimal(base_size = 10) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank())
ggsave(file.path(out_dir, "reliability.png"), p1, width = 11, height = 4.8, dpi = 150, bg = "white")

# Top call by moment: stated minus right, with the game-resampled interval.
bt <- by_time[, .(model, score = factor(score_lab[score], score_lab), t, gap, lo, hi)]
p2 <- ggplot(bt, aes(t, 100 * gap, colour = model, fill = model)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_vline(xintercept = 0, colour = "grey80", linetype = "dashed") +
  geom_ribbon(aes(ymin = 100 * lo, ymax = 100 * hi), alpha = 0.15, colour = NA) +
  geom_line(linewidth = 0.8) +
  facet_wrap(~score, nrow = 1) +
  scale_colour_manual(values = c(transformer = "#1f6fd1", logistic = "#d1691f")) +
  scale_fill_manual(values = c(transformer = "#1f6fd1", logistic = "#d1691f")) +
  labs(x = "Seconds from the pick frame", y = "Stated minus right (points)", colour = NULL, fill = NULL,
       title = "Leading call: stated probability minus how often it was right",
       subtitle = "Above 0 = overconfident, below 0 = underconfident; 95% interval from resampling games") +
  theme_minimal(base_size = 10) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank())
ggsave(file.path(out_dir, "top_call_by_time.png"), p2, width = 11, height = 4, dpi = 150, bg = "white")
cat("Wrote", out_dir, "\n")
