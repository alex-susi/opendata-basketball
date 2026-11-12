## ═════════════════════════════════════════════════════════════════════════════
# Step 8: WHEN does the receiver act? A timing audit of every catch, and a second target at a fixed horizon.
#   Rscript src/kickout_transformer/08_timing_audit.R
#
# The current label looks at the receiver's whole touch: a drive that starts 3.7 s after the catch, behind a ball
# screen set at 2.4 s, is still a "drive". That mixes two questions: what the catch set up, and what happened later.
# This step records, for every catch (all 1,738, including the "other" ones), the time after the catch of:
#   drive onset        start of the first drives row on the receiver's touch
#   shot release       the first shots row on the touch
#   pass release       the first pass thrown from the touch (complete or not)
#   turnover / foul    a turnover on the touch, or a foul whistled in the chance between the catch and the touch end
#   touch end          the end of the touch
#   first screen       the first on-ball screen (picks row) with the receiver as ball handler on the same touch
# "First action" is the earliest of drive / shot / pass / turnover / foul (ties: drive, then shot, then pass).
#
# Fixed-horizon target. At H seconds after the catch the receiver is in one of five states:
#   shot / drive / pass   his first action happened by H
#   other                 the touch ended by H in a turnover, a foul or a whistle with no shot, drive or pass
#   hold                  still on the ball (or still gathering it) with nothing tagged yet
# Every catch gets a horizon label, so a forecast at H covers all eligible catches. H = 1.25 s is the main one;
# 0.75 s and 2.0 s show how the answer moves with the horizon.
#
# Event times come from the explore bundles (outputs/cache/explore/bundle_<game>.rds, built by
# web/scripts/explore/build.R), which hold the dynamic-event tables in the site's corrected frame.
#
# Writes outputs/kickout_timing/: timing_audit.csv (one row per catch), timing_by_label.csv,
# horizon_vs_label.csv, horizon_shares.csv, film_play_timing.csv, figures/acted_by_time.png,
# and outputs/cache/kickout_transformer/timing.rds for steps 9-10.
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
suppressPackageStartupMessages(library(ggplot2))
out_dir <- file.path(root, "outputs", "kickout_timing")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)

# Horizons in seconds after the catch, H_MAIN the main one. "hold" means no action yet at the horizon.
FPS <- 25
HORIZONS <- c(0.75, 1.25, 2.0)
H_MAIN <- 1.25
H_CLASSES <- c("shot", "drive", "pass", "other", "hold")

m <- readRDS(file.path(paths$base_cache, "catches.rds"))$meta
bundle <- function(g) readRDS(file.path(root, "outputs", "cache", "explore", sprintf("bundle_%d.rds", g)))

# The first event of each touch in an event table: one row per touch, with its frame and any kept columns.
first_by_touch <- function(dt, frame_col, keep = NULL) {
  if (!nrow(dt)) return(data.table(touch = character(), f = integer()))
  cols <- c("touch", frame_col, keep)
  out <- dt[!is.na(touch), ..cols]
  setnames(out, frame_col, "f")
  out[order(f)][, .SD[1], by = touch]
}

# One game's catches with the frame of each event on the receiver's touch: drive, shot, pass, turnover, own screen.
audit_game <- function(g) {
  B <- bundle(g)
  c <- m[game_id == g, .(pass_id, game_id, poss_id, chance_id, catch, receiver, label, t_id)]
  tc <- B$touches[, .(touch, t_f0 = f0, t_f1 = f1, outs)]
  c[tc, on = .(t_id = touch), `:=`(t_f0 = i.t_f0, t_f1 = i.t_f1, outs = i.outs)]
  # First drive, shot, pass, turnover and ball screen on each touch.
  dr <- first_by_touch(B$drives, "f0", c("category", "end"))
  sh <- first_by_touch(B$shots, "f", c("made", "three"))
  ps <- first_by_touch(B$passes, "f0", c("receiver", "complete"))
  to <- first_by_touch(B$to, "f")
  pk <- first_by_touch(B$picks[, .(touch, f0, actor, screener, cov, scov)], "f0", c("actor", "screener", "cov", "scov"))
  c[dr, on = .(t_id = touch), `:=`(f_drive = i.f, drive_category = i.category, drive_end = i.end)]
  c[sh, on = .(t_id = touch), `:=`(f_shot = i.f)]
  c[ps, on = .(t_id = touch), `:=`(f_pass = i.f, pass_to = i.receiver)]
  c[to, on = .(t_id = touch), `:=`(f_tov = i.f)]
  # A ball screen counts only when the receiver is its ball handler.
  c[pk, on = .(t_id = touch), `:=`(f_screen = fifelse(i.actor == receiver, i.f, NA_integer_),
                                   screener = fifelse(i.actor == receiver, i.screener, NA_integer_),
                                   screen_cov = fifelse(i.actor == receiver, paste(i.cov, i.scov, sep = " + "), NA_character_))]
  # a foul whistled in the same chance between the catch and the end of the receiver's touch
  fo <- B$fo[!is.na(f), .(chance, f)]
  c[, f_foul := NA_integer_]
  if (nrow(fo)) c[fo, on = .(chance_id = chance, catch <= f, t_f1 >= f), f_foul := i.f, mult = "first"]
  c
}

# Every game; event times in seconds after the catch.
a <- rbindlist(lapply(sort(unique(m$game_id)), audit_game), fill = TRUE)
sec <- function(f) (f - a$catch) / FPS
a[, `:=`(t_touch_start = sec(t_f0), t_touch_end = sec(t_f1), t_drive = sec(f_drive), t_shot = sec(f_shot),
         t_pass = sec(f_pass), t_tov = sec(f_tov), t_foul = sec(f_foul), t_screen = sec(f_screen))]

# first action: earliest event; ties go to drive, then shot, then pass
ev_cols <- c(drive = "t_drive", shot = "t_shot", pass = "t_pass", turnover = "t_tov", foul = "t_foul")
tm <- as.matrix(a[, ..ev_cols])
tm[is.na(tm)] <- Inf
k <- max.col(-tm, ties.method = "first")
a[, t_first := tm[cbind(seq_len(.N), k)]]
a[, first_action := fifelse(is.finite(t_first), names(ev_cols)[k], NA_character_)]
# no tagged action on the touch (timeouts, held balls): the touch end is when it stopped
a[is.na(first_action), `:=`(first_action = "touch ended", t_first = t_touch_end)]
a[, first_class := fcase(first_action %in% c("shot", "drive", "pass"), first_action, default = "other")]
# time at which the SAME-TOUCH label's action happened (what the current target is about)
a[, t_label := fcase(label == "drive", t_drive, label == "shot", t_shot, label == "pass", t_pass, default = t_first)]
a[, screen_before_label := !is.na(t_screen) & t_screen < t_label]

# The state at each horizon: the first action's class if it has happened by then, otherwise "hold".
for (H in HORIZONS) {
  col <- sprintf("h_%s", gsub("\\.", "_", sprintf("%.2f", H)))
  a[, (col) := fifelse(t_first <= H, first_class, "hold")]
}
H_COL <- sprintf("h_%s", gsub("\\.", "_", sprintf("%.2f", H_MAIN)))
a[, horizon := factor(get(H_COL), levels = H_CLASSES)]

# Write the audit table and cache it for steps 9-10.
setcolorder(a, c("pass_id", "game_id", "poss_id", "catch", "label", "first_action", "t_first", "t_label",
                 "t_drive", "t_shot", "t_pass", "t_tov", "t_foul", "t_touch_start", "t_touch_end", "t_screen",
                 "screener", "screen_cov", "screen_before_label"))
fwrite(a[, !c("outs", "f_drive", "f_shot", "f_pass", "f_tov", "f_foul", "f_screen", "t_f0", "t_f1")],
       file.path(out_dir, "timing_audit.csv"))
saveRDS(a, file.path(paths$base_cache, "timing.rds"))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SUMMARIES --------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Timing of the labelled action by label: quantiles, and the shares that come late or after a screen.
q <- function(v, p) round(unname(quantile(v, p, na.rm = TRUE)), 2)
by_label <- a[, .(catches = .N, median_s = q(t_label, 0.5), p25_s = q(t_label, 0.25), p75_s = q(t_label, 0.75),
                  p90_s = q(t_label, 0.9), share_after_1.25s = round(mean(t_label > 1.25, na.rm = TRUE), 3),
                  share_after_2.5s = round(mean(t_label > 2.5, na.rm = TRUE), 3),
                  share_screen_first = round(mean(screen_before_label), 3),
                  label_is_first_action = round(mean(first_class == label), 3)), by = label][order(label)]
fwrite(by_label, file.path(out_dir, "timing_by_label.csv"))
cat("Seconds from the catch to the labelled action (same-touch label):\n")
print(by_label)

# Same-touch label against the state at the main horizon.
cross <- dcast(a[, .N, by = .(label, horizon)], label ~ horizon, value.var = "N", fill = 0)
fwrite(cross, file.path(out_dir, "horizon_vs_label.csv"))
cat(sprintf("\nSame-touch label (rows) vs state at %.2f s after the catch (columns):\n", H_MAIN))
print(cross)

# Share of catches in each state at each horizon.
shares <- rbindlist(lapply(HORIZONS, function(H) {
  col <- sprintf("h_%s", gsub("\\.", "_", sprintf("%.2f", H)))
  a[, .(horizon_s = H, catches = .N), by = c(state = col)][, share := round(catches / sum(catches), 3)][]
}))
fwrite(shares, file.path(out_dir, "horizon_shares.csv"))
cat("\nState at each horizon:\n")
print(dcast(shares, state ~ horizon_s, value.var = "share"))
cat("\nCatches where a ball screen came before the labelled action:", a[, sum(screen_before_label)],
    sprintf("(%.1f%%)\n", 100 * a[, mean(screen_before_label)]))

# the film-study and attention plays, so their event times can be checked against the cards
film <- unique(rbindlist(lapply(c(file.path(root, "outputs", "kickout_transformer_3class", "film_study_plays.csv")),
                                function(f) if (file.exists(f)) fread(f)[, .(file, pass_id)]), fill = TRUE))
fp <- merge(film, a, by = "pass_id")[order(file)]
fwrite(fp[, .(file, pass_id, poss_id, label, horizon, first_action, t_first, t_screen, screen_cov, t_drive, t_shot,
              t_pass, t_touch_end)], file.path(out_dir, "film_play_timing.csv"))
cat("\nFilm-study plays:\n")
print(fp[, .(file, label, horizon, first = first_action, t_first, t_screen, t_drive, t_shot, t_pass)])





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FIGURE -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Share of catches that have acted, by time after the catch.

# At each time on a 0.04 s grid: the share of catches whose first action has happened, by class.
grid <- seq(0, 6, by = 0.04)
cum <- rbindlist(lapply(grid, function(t) a[, .(t = t, state = fifelse(t_first <= t, first_class, "hold"))][
  , .N, by = .(t, state)]))
cum[, share := N / nrow(a)]
cum[, state := factor(state, levels = rev(H_CLASSES))]
COLS <- c(shot = "#2a78d6", drive = "#eb6834", pass = "#1baf7a", other = "#eda100", hold = "#c9ccd1")
t_lab <- grid[which.min(abs(grid - 5.5))]
# Labels inside the bands at about 5.5 s, for bands above 2%.
lab_at <- cum[t == t_lab][order(state)][, y := cumsum(share) - share / 2][share > 0.02]
pg <- ggplot(cum, aes(t, share, fill = state)) +
  geom_area(colour = "white", linewidth = 0.5) +
  geom_vline(xintercept = HORIZONS, linetype = c("dotted", "dashed", "dotted"), colour = "grey25") +
  annotate("text", x = H_MAIN + 0.05, y = 1.02, label = sprintf("%.2f s horizon", H_MAIN), hjust = 0, size = 3.4) +
  geom_text(data = lab_at, aes(x = t_lab, y = y, label = sprintf("%s %.0f%%", state, 100 * share)), size = 3.3,
            colour = "grey10") +
  scale_fill_manual(values = COLS, breaks = H_CLASSES, name = NULL,
                    labels = c(shot = "shot released", drive = "drive started", pass = "pass thrown",
                               other = "turnover, foul or whistle", hold = "still holding, nothing tagged yet")) +
  scale_y_continuous(labels = function(v) paste0(100 * v, "%"), expand = expansion(c(0, 0.04))) +
  scale_x_continuous(breaks = 0:6, expand = c(0, 0)) +
  labs(title = "What the receiver has done, by time after the catch",
       subtitle = sprintf("All %s perimeter catches in the 10 games. Each catch moves out of grey at its first tagged action.\nDotted lines: the 0.75 s and 2.0 s horizons used as checks.",
                          format(nrow(a), big.mark = ",")),
       x = "Seconds after the catch", y = "Share of catches") +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"))
ggsave(file.path(out_dir, "figures", "acted_by_time.png"), pg, width = 10, height = 6, dpi = 150, bg = "white")
