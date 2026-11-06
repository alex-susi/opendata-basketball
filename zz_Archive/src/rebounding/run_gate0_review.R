# Gate 0 review sample: at least 30 rebounds or 10% of them, every game, unusual cases oversampled, each drawn as
# a ball-height timeline and a top-down view at the rebound frame for review against the event labels.
#   Rscript src/rebounding/run_gate0_review.R
# Needs outputs/cache/rebounding/gate0.rds (run_gate0.R). Writes outputs/rebounding/gate0/review/sample.csv and
# page_*.png. The labels go in outputs/rebounding/gate0/review/review_log.csv (filled by hand, not by this script).

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "gate0.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "gate0", "review")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
g0 <- readRDS(file.path(cache, "gate0.rds"))
hoops <- readRDS(file.path(cache, "episodes.rds"))$hoops
ep <- g0$episodes
PER_PAGE <- 3L

# ---- the sample: unusual strata first, then ordinary rebounds spread over games ----------------------------
set.seed(20261028L)
pool <- ep[!is.na(reb_id)]
take <- function(rows, n, why) {
  rows <- rows[!shot_id %in% picked$shot_id]
  if (!nrow(rows)) return(invisible())
  s <- rows[sample(.N, min(.N, n))]
  picked <<- rbind(picked, data.table(shot_id = s$shot_id, reason = why))
}
picked <- data.table(shot_id = character(), reason = character())
take(pool[rf <= f0], 4L, "rebound at or before release")
take(pool[side_by_flag != side], 5L, "defensive flag disagrees with teamId")
take(pool[terminal == "team rebound: other / unclear"], 7L, "team award, no out-of-bounds or foul seen")
take(pool[terminal %in% c("team rebound: foul", "player rebound, foul in the scramble")], 5L, "foul in the scramble")
take(pool[status != "eligible"], 3L, "excluded for ball coverage")
take(pool[rf > f0 & rf < f1], 4L, "rebound before endFrame")
take(pool[grabbed %in% TRUE & (reb_ball_dist > 6 | !(nearest_pid %in% rpid))], 6L, "rebounder not nearest / far from ball")
take(pool[kind == "blocked"], 4L, "blocked")
take(pool[kind == "airball or no contact"], 4L, "airball or no contact")
take(pool[putback_attempt %in% TRUE | cst %in% "tip"], 4L, "put-back or tip")
take(pool[kind == "backboard first"], 3L, "backboard first")
take(pool[terminal == "team rebound: out of bounds (ball seen out)"], 3L, "team award out of bounds")
n_total <- g0$review_n
for (g in matches$id) take(pool[game_id == g & retained == TRUE], 1L, "ordinary")
take(pool[retained == TRUE], n_total - nrow(picked), "ordinary")
extra <- ep[terminal == "no rebound row: unexplained"]
picked <- rbind(picked, data.table(shot_id = extra[sample(.N, 4L)]$shot_id, reason = "no rebound row (extra, not counted)"))
smp <- merge(picked, ep, by = "shot_id", sort = FALSE)
smp[, page := (seq_len(.N) - 1L) %/% PER_PAGE + 1L]
fwrite(smp[, .(page, shot_id, game_id, reason, period, f0, f1, rf, kind, terminal, outcome12, side_by_flag, rpid,
               nearest_pid, reb_ball_dist, z_reb, contact_frame, touch_frame, control_frame, retained)],
       file.path(out, "sample.csv"))

# ---- drawing -------------------------------------------------------------------------------------------------
court <- function(hoop) {
  rect(-COURT_HALF_L, -COURT_HALF_W, COURT_HALF_L, COURT_HALF_W, border = "grey40")
  lines(c(0, 0), c(-COURT_HALF_W, COURT_HALF_W), col = "grey60")
  rect(COURT_HALF_L - 5.8 * FT_PER_M, -2.45 * FT_PER_M, COURT_HALF_L, 2.45 * FT_PER_M, border = "grey60")
  a <- seq(-pi / 2, pi / 2, length.out = 60)
  r3 <- 6.75 * FT_PER_M
  lines(RIM_X - r3 * cos(a), r3 * sin(a), col = "grey60")
  symbols(hoop$hx, hoop$hy, circles = RIM_R, inches = FALSE, add = TRUE, fg = "orange", lwd = 2)
}
draw_episode <- function(raw, s, hoop) {
  last <- if (!is.na(s$rf)) max(s$rf, s$f1) else s$f1
  w <- ball_track(raw$frames, s, s$f0 - 5L, last + 30L)
  t <- (w$frame - s$f0) / FPS
  ts <- function(f) (f - s$f0) / FPS
  pl <- window_players(raw, s, w$frame)
  rb <- if (!is.na(s$rpid)) merge(pl[pid == s$rpid, .(frame, px, py)], w[, .(frame, x, y)], by = "frame") else NULL
  par(mar = c(4, 4, 3, 1))
  plot(t, w$z, type = "n", ylim = c(0, max(16, max(w$z, na.rm = TRUE))), xlab = "seconds from release", ylab = "ft",
       main = sprintf("%s  [%s]", s$shot_id, s$reason), cex.main = 1)
  abline(h = RIM_Z, col = "orange", lty = 3)
  lines(t, sqrt((w$x - hoop$hx)^2 + (w$y - hoop$hy)^2), col = "grey55", lty = 2)
  if (!is.null(rb) && nrow(rb)) lines(ts(rb$frame), sqrt((rb$px - rb$x)^2 + (rb$py - rb$y)^2), col = "darkgreen", lwd = 2)
  lines(t, w$z, lwd = 1.5)
  points(t[!(w$interp %in% TRUE)], w$z[!(w$interp %in% TRUE)], pch = 16, cex = 0.5)
  mark <- function(f, col, lab) if (!is.na(f)) { abline(v = ts(f), col = col, lwd = 2); mtext(lab, 3, 0, at = ts(f), col = col, cex = 0.7) }
  mark(s$f1, "blue", "end"); mark(s$contact_frame, "purple", "c"); mark(s$touch_frame, "orange", "t")
  mark(s$rf, "red", "REB"); mark(s$control_frame, "darkgreen", "ctl")
  legend("topright", c("ball z", "ball-hoop xy", "rebounder-ball xy"), col = c("black", "grey55", "darkgreen"),
         lty = c(1, 2, 1), bty = "n", cex = 0.8)
  # top-down at the rebound frame (or the end of the window when there is none)
  f_at <- if (!is.na(s$rf)) s$rf else last
  par(mar = c(4, 1, 3, 1))
  plot(NA, xlim = c(8, 50), ylim = c(-COURT_HALF_W - 2, COURT_HALF_W + 2), asp = 1, axes = FALSE, xlab = "", ylab = "",
       main = sprintf("%s | %s | flag side %s | %s", s$kind, fcoalesce(s$outcome12, "no rebound row"),
                      fcoalesce(s$side_by_flag, "-"), s$terminal), cex.main = 0.85)
  court(hoop)
  path <- w[frame >= fcoalesce(s$contact_frame, s$f1) & frame <= f_at + 12L & !is.na(x)]
  points(path$x, path$y, pch = 16, cex = 0.45, col = grey(seq(0.75, 0, length.out = max(1, nrow(path)))))
  at <- pl[frame == f_at]
  if (nrow(at)) {
    points(at$px, at$py, pch = 21, cex = 2.2, bg = fifelse(at$off, "tomato", "steelblue"), col = "black")
    text(at$px, at$py, at$pid %% 1000, cex = 0.5, col = "white")
  } else text(28, 0, "no players tracked at this frame (dead time)", cex = 0.9)
  if (!is.na(s$rpid) && s$rpid %in% at$pid) points(at[pid == s$rpid]$px, at[pid == s$rpid]$py, cex = 3.6, lwd = 2.5, col = "darkgreen")
  bxy <- w[frame == f_at]
  if (nrow(bxy) && !is.na(bxy$x)) points(bxy$x, bxy$y, pch = 4, cex = 2.2, lwd = 3, col = "black")
  if (!is.na(s$rev_x)) points(-s$rev_x, -s$rev_y, pch = 3, cex = 2, lwd = 2, col = "darkgreen")
  mtext(sprintf("ball z at REB %.1f ft | rebounder-ball %.1f ft | nearest %s (%s) | red = offense", fcoalesce(s$z_reb, NA_real_),
                fcoalesce(s$reb_ball_dist, NA_real_), fcoalesce(as.character(s$nearest_pid %% 1000), "-"),
                fifelse(s$nearest_off %in% TRUE, "off", "def")), 1, 1, cex = 0.7)
}

raws <- list()
for (p in unique(smp$page)) {
  png(file.path(out, sprintf("page_%02d.png", p)), width = 1500, height = 420 * PER_PAGE, res = 100)
  layout(matrix(seq_len(2L * PER_PAGE), ncol = 2, byrow = TRUE), widths = c(1.1, 1))
  for (k in which(smp$page == p)) {
    s <- smp[k]
    key <- as.character(s$game_id)
    if (is.null(raws[[key]])) {
      raws[[key]] <- readRDS(file.path(cache, sprintf("raw_%s.rds", s$game_id)))
      raws[[key]]$home_team <- matches$home_team$id[matches$id == s$game_id]
    }
    h <- hoops[game_id == s$game_id & left_hoop == s$left_hoop]
    draw_episode(raws[[key]], s, if (nrow(h)) list(hx = h$hx, hy = h$hy) else list(hx = RIM_X, hy = 0))
  }
  dev.off()
}
message(nrow(smp), " episodes on ", max(smp$page), " pages")
