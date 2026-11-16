## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 16: would knowing where or when the screen gets set help the over / under read?
#   Rscript screen_coverage/01_scripts/16_screen_timing_check.R
#
# Prompted by the owner's play review (game 114243, Q3, #35 Hankins screens for #2 Rousselle, #55 Perez went under
# while the card said over). A quick, no-training check on the ball handler's defender, over vs under only (switch
# screens left out), from -1 s to the pick frame (picks.frame) in 0.2 s steps. Simple one-game-out logistic models
# on a few numbers per screen, compared with the live transformer's over-vs-under log loss on the same screens:
#   level now        how much farther from the hoop the guard is than the screener is right now (the main input the
#                    live model leans on)
#   level vs spot    the same, against where the screener will actually stand at the pick frame (uses the future:
#                    an upper bound on what a projected screen spot could add)
#   level vs proj    the same, against a physics guess of where the screener stops (his speed and slowing now)
#   + own motion     the guard's and the screener's speed toward (-) or away from (+) the hoop right now
#   + true time      the same numbers with the true time to the pick frame (uses the future: an upper bound on what
#                    a projected screen time could add)
# Writes screen_coverage/03_outputs/screen_timing_check/: by_time.csv, pooled.csv, this_play.csv, by_group.csv.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "screen_timing_check")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Moments checked (frames from the pick frame), the cap on the physics stopping distance, and the reviewed play.
CHECK_OFFS <- seq(-25L, 0L, 5L)
MAX_STOP_FT <- 15
PLAY <- list(game_id = 114243L, f0 = 69861L)





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PER-SCREEN NUMBERS -----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Rows of the cached movement array: 1 handler, 2 screener, 3 handler's defender (the guard), 4 screener's defender.
L <- load_logistic(root)
X <- L$X
P <- L$P
SQ <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
stopifnot(identical(SQ$screen_ids, P$id))
B <- SQ$base
offs <- SEQ_BASE_OFFS
guard <- ifelse(grepl("^over", P$call), "over", ifelse(grepl("^under", P$call), "under", "switch"))
f <- function(o, j, v) B[, match(o, offs), j, v]

# Speed away from the hoop (+) or toward it (-), ft/s.
radial <- function(o, j) {
  x <- f(o, j, "x")
  y <- f(o, j, "y")
  -((HOOP_X - x) * f(o, j, "vx") - y * f(o, j, "vy")) / pmax(hoop_dist(x, y), 1e-6)
}

# Where the screener stands at the pick frame (the future spot).
sx0 <- f(0L, 2, "x")
sy0 <- f(0L, 2, "y")
rows <- rbindlist(lapply(CHECK_OFFS, function(o) {
  sx <- f(o, 2, "x")
  sy <- f(o, 2, "y")
  sp <- f(o, 2, "speed")
  ac <- f(o, 2, "accel")
  # Physics guess: if he is slowing, he stops v^2 / (2 |a|) ahead along his path (capped); otherwise where he is.
  stop_ft <- ifelse(ac < -1 & sp > 1, pmin(MAX_STOP_FT, sp^2 / (2 * -ac)), 0)
  px <- sx + f(o, 2, "vx") / pmax(sp, 1e-6) * stop_ft
  py <- sy + f(o, 2, "vy") / pmax(sp, 1e-6) * stop_ft
  gd <- hoop_dist(f(o, 3, "x"), f(o, 3, "y"))
  data.table(idx = seq_len(nrow(P)), game_id = P$game_id, t = o / FPS, under = as.integer(guard == "under"),
             keep = guard != "switch" & f(o, 2, "present") == 1 & f(o, 3, "present") == 1 & f(0L, 2, "present") == 1,
             lvl_now = gd - hoop_dist(sx, sy), lvl_spot = gd - hoop_dist(sx0, sy0), lvl_proj = gd - hoop_dist(px, py),
             g_rad = radial(o, 3), s_rad = radial(o, 2), s_speed = sp)
}))
rows <- rows[keep == TRUE]





## ═════════════════════════════════════════════════════════════════════════════
## 03 - COMPARISONS ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' One-game-out logistic log loss for under vs over with formula terms `rhs`.
logo <- function(d, rhs) {
  out <- d[, .(game_id, under)][, p := NA_real_]
  for (g in unique(d$game_id)) {
    fit <- suppressWarnings(glm(as.formula(paste("under ~", rhs)), binomial, d[game_id != g]))
    out[d$game_id == g, p := predict(fit, d[game_id == g], type = "response")]
  }
  out[, mean(-log(ifelse(under == 1, p, 1 - p)))]
}

# The live transformer on the same screens and moments, its over / under share renormalised without switch.
pr <- load_seqheads(root, do.call(file.path, c(list(root), SEQ_FLAT_DIR)))$prob
tf <- data.table(idx = X$idx, t = X$off / FPS, pu = (pr[, 3] + pr[, 4]) / (pr[, 1] + pr[, 2] + pr[, 3] + pr[, 4]))
tf <- tf[rows[, .(idx, t, under)], on = .(idx, t)]
tf_t <- tf[, .(transformer = mean(-log(ifelse(under == 1, pu, 1 - pu)))), by = t]

# Per moment (each fit sees one moment, so it knows the time).
by_time <- rows[, .(screens = .N, under_share = mean(under), level_now = logo(.SD, "lvl_now"),
                    level_vs_spot = logo(.SD, "lvl_spot"), level_vs_proj = logo(.SD, "lvl_proj"),
                    level_now_own_motion = logo(.SD, "lvl_now + g_rad + s_rad")), by = t]
by_time <- tf_t[by_time, on = "t"]
fwrite(by_time[, lapply(.SD, function(v) round(v, 4))], file.path(out_dir, "by_time.csv"))

# Pooled over the six moments: the same numbers without and with the true time to the pick frame.
pooled <- data.table(model = c("level now", "level now + own motion", "level now + own motion + true time",
                               "live transformer"),
                     logloss = c(logo(rows, "lvl_now"), logo(rows, "lvl_now + g_rad + s_rad"),
                                 logo(rows, "(lvl_now + g_rad + s_rad) * factor(t)"), tf_t[, mean(transformer)]))
fwrite(pooled[, .(model, logloss = round(logloss, 4))], file.path(out_dir, "pooled.csv"))

# Over and under screens compared at -0.2 s, and the reviewed play.
by_group <- rows[t == -0.2, .(screens = .N, guard_toward_hoop = median(g_rad), screener_away_from_hoop = median(s_rad),
                              level_now = median(lvl_now)), by = .(call = ifelse(under == 1, "under", "over"))]
fwrite(by_group[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 2) else v)], file.path(out_dir, "by_group.csv"))
k <- P[game_id == PLAY$game_id & f0 == PLAY$f0, which = TRUE]
this_play <- rows[idx == k, .(t, level_now = lvl_now, guard_radial = g_rad, screener_radial = s_rad,
                              screener_speed = s_speed)]
fwrite(this_play[, lapply(.SD, function(v) round(v, 2))], file.path(out_dir, "this_play.csv"))
print(by_time, digits = 3)
print(pooled, digits = 4)
print(by_group, digits = 3)
print(this_play, digits = 3)
