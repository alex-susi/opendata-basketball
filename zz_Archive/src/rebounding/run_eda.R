# Exploratory tables behind every modelling decision in the rebounding framework, for the Rebounding tab.
#   Rscript src/rebounding/run_eda.R
# Needs run_audit.R, run_flight.R, run_opportunity.R (scenes_all from run_skills.R) and run_skills.R.
# Writes outputs/rebounding/eda/*.csv; run_export.R puts them in web/public/data/rebounding.json.
# Everything here is description of the ten games: no model is fitted except where a table says so.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
out_dir <- file.path(report, "eda")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
w <- function(dt, name) fwrite(dt, file.path(out_dir, paste0(name, ".csv")))

#' Wilson interval for a proportion.
wilson <- function(k, n, z = 1.645) {
  p <- k / n
  c0 <- (p + z^2 / (2 * n)) / (1 + z^2 / n)
  h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)
  list(lo = pmax(0, c0 - h), hi = pmin(1, c0 + h))
}
rate_table <- function(dt, by) {
  out <- dt[, .(n = .N, k = sum(off_ball)), by = by]
  ci <- wilson(out$k, out$n)
  out[, `:=`(rate = k / n, lo = ci$lo, hi = ci$hi)]
  setorderv(out, by)
  out
}

el <- episodes[status == "eligible"]
el[, off_ball := outcome %in% c("off player", "off team award")]
el[, shot_range := shot_range(shot_dist, three)]

# ---- 1. outcomes: what is being predicted ------------------------------------------------------------------
w(el[, .N, by = outcome][, share := N / sum(N)][order(-N)], "outcomes")
w(rate_table(el, "shot_range"), "oreb_by_distance")
w(rate_table(el, "kind"), "oreb_by_kind")

# ---- 2. where rebounds are secured -------------------------------------------------------------------------
spots <- rbindlist(lapply(bundles, function(b) {
  s <- b$shot
  if (!(s$grabbed %in% TRUE)) return(NULL)
  p <- b$players[frame == s$rf & canon == s$rcanon]
  if (!nrow(p)) return(NULL)
  sx <- s$sx - RIM_X; sy <- s$sy
  rx <- p$x[1] - RIM_X; ry <- p$y[1]
  ang <- atan2(ry, rx) - atan2(sy, sx)
  ang <- (ang + pi) %% (2 * pi) - pi
  data.table(shot_id = b$id, sx = round(sx, 1), sy = round(sy, 1), rx = round(rx, 1), ry = round(ry, 1), r = round(sqrt(rx^2 + ry^2), 2),
             shot_dist = round(s$shot_dist, 1), range = shot_range(s$shot_dist, s$three), off = !(s$defensive %in% TRUE),
             angle = round(abs(ang) * 180 / pi), sy_sign = sign(sy), kind = s$kind)
}))
w(spots, "rebound_spots")
w(spots[, .(n = .N, median_r = median(r), q25 = quantile(r, 0.25), q75 = quantile(r, 0.75), long_share = mean(r > 12)),
        by = .(range)][order(range)], "rebound_distance_by_range")
w(spots[, .(n = .N), by = .(angle_bin = cut(angle, seq(0, 180, 30), include.lowest = TRUE), range)][order(range, angle_bin)],
  "rebound_angle")
w(spots[, .(n = .N, median_r = median(r)), by = off], "rebound_distance_by_side")

# ---- 3. timing ---------------------------------------------------------------------------------------------
timing <- el[, .(shot_id, shot_dist = round(shot_dist, 1), kind,
                 t_contact = round((contact_frame - f0) / FPS, 2), t_end = round((f1 - f0) / FPS, 2),
                 t_rebound_after_contact = round((rf - fcoalesce(contact_frame, f1)) / FPS, 2),
                 touch_vs_rebound = round((touch_frame - rf) / FPS, 2), control_vs_rebound = round((control_frame - rf) / FPS, 2))]
w(timing, "timing")
fit <- lm(t_contact ~ shot_dist, timing[!is.na(t_contact)])
w(data.table(term = c("intercept", "per_ft", "r2", "n"), value = c(coef(fit), summary(fit)$r.squared, nobs(fit))), "flight_time_fit")

# ---- 4. the ball track -------------------------------------------------------------------------------------
raws <- lapply(games, read_raw)
minima <- rbindlist(lapply(raws, function(raw) {
  fr <- raw$frames[order(frame)]
  fr[, vz := (bz - shift(bz, 3L)) * FPS / 3]
  fr[!is.na(bz) & bz < shift(bz) & bz <= shift(bz, -1L) & vz < -8 & shift(bz, -3L) - bz > 0.3 & bz < 6, .(z = bz)]
}))
w(minima[, .(n = .N), by = .(z = floor(z * 5) / 5)][order(z)], "bounce_minima")
crossings <- rbindlist(lapply(raws, function(raw) {
  sh <- episodes[game_id == raw$shots$game_id[1] & made == TRUE & !is.na(f0) & !is.na(f1)]
  rbindlist(lapply(seq_len(nrow(sh)), function(k) {
    s <- sh[k]
    tr <- ball_track(raw$frames, s, s$f0, s$f1 + 15L)
    i <- which(tr$z[-1] < RIM_Z & tr$z[-nrow(tr)] >= RIM_Z & hoop_dist(tr$x[-1], tr$y[-1]) < 4)
    if (!length(i)) return(NULL)
    i <- i[1]
    a <- (tr$z[i] - RIM_Z) / (tr$z[i] - tr$z[i + 1])
    data.table(game_id = s$game_id, end = fifelse(s$left_hoop, "camera left", "camera right"),
               dx = round(tr$x[i] + a * (tr$x[i + 1] - tr$x[i]) - RIM_X, 2), dy = round(tr$y[i] + a * (tr$y[i + 1] - tr$y[i]), 2))
  }))
}))
w(crossings, "hoop_crossings")
w(rbindlist(lapply(raws, `[[`, "index_gaps")), "frame_gaps")
# one clear rim-first miss for the worked example: every frame, whether it is a keyframe, and the event times
ex <- Filter(function(b) b$shot$kind == "rim first" && b$shot$range == "mid (10-22 ft)" && !is.na(b$shot$bounce_frame), bundles)[[3]]
w(ex$ball[t >= 0 & t <= bundle_times(ex)$rebound + 0.6, .(t = round(t, 2), x = round(x, 2), y = round(y, 2), z = round(z, 2), key)],
  "example_track")
tm <- bundle_times(ex)
w(data.table(event = c("release", "contact", "first possible touch", "rebound frame", "floor bounce"),
             t = round(c(0, tm$contact, tm$touch, tm$rebound, tm$bounce), 2), shot_id = ex$id), "example_events")

# ---- 5. who gets the ball: position at release -------------------------------------------------------------
scenes_all <- readRDS(file.path(cache, "scenes_all.rds"))
rank_rows <- rbindlist(lapply(names(scenes_all), function(cp) rbindlist(lapply(seq_along(bundles), function(i) {
  sc <- scenes_all[[cp]][[i]]
  if (!length(sc) || sc$y > 10) return(NULL)
  sp <- spots[shot_id == sc$id]
  dh <- sqrt((sc$pl$x - RIM_X)^2 + sc$pl$y^2)
  ds <- if (nrow(sp)) sqrt((sc$pl$x - RIM_X - sp$rx)^2 + (sc$pl$y - sp$ry)^2) else rep(NA_real_, 10)
  data.table(checkpoint = cp, shot_id = sc$id, rank_hoop = rank(dh, ties.method = "first")[sc$y],
             rank_spot = if (nrow(sp)) rank(ds, ties.method = "first")[sc$y] else NA_integer_,
             nearest_spot_off = if (nrow(sp)) sc$pl$off[which.min(ds)] else NA, winner_off = sc$pl$off[sc$y])
}))))
w(rank_rows[, .N, by = .(checkpoint, rank = rank_hoop)][, share := N / sum(N), by = checkpoint][order(checkpoint, rank)], "rank_by_hoop")
w(rank_rows[!is.na(rank_spot), .N, by = .(checkpoint, rank = rank_spot)][, share := N / sum(N), by = checkpoint][order(checkpoint, rank)],
  "rank_by_spot")
w(rank_rows[!is.na(nearest_spot_off), .(n = .N, nearest_team_wins = mean(nearest_spot_off == winner_off)), by = checkpoint], "nearest_team_wins")
inside <- rbindlist(lapply(seq_along(bundles), function(i) {
  sc <- scenes_all$release[[i]]
  if (!length(sc)) return(NULL)
  dh <- sqrt((sc$pl$x - RIM_X)^2 + sc$pl$y^2)
  data.table(shot_id = sc$id, off_in = sum(sc$pl$off & dh <= 12), def_in = sum(!sc$pl$off & dh <= 12),
             off_ball = sc$y %in% c(1:5, 11L))
}))
inside[, diff := pmin(2, pmax(-4, off_in - def_in))]
w(rate_table(inside, "diff"), "oreb_by_inside_difference")
w(rate_table(inside[, off_in := pmin(off_in, 3L)], "off_in"), "oreb_by_offense_inside")

# ---- 6. obstruction at the rim -----------------------------------------------------------------------------
obs <- rbindlist(lapply(seq_along(bundles), function(i) {
  sc <- scenes_all$rim[[i]]
  if (!length(sc)) return(NULL)
  rec <- apply(sc$O, 2, max)
  dh <- sqrt((sc$pl$x - RIM_X)^2 + sc$pl$y^2)
  near <- dh <= 15
  data.table(shot_id = sc$id, off_blocked = sum(rec[sc$pl$off & near] >= 0.35), def_blocked = sum(rec[!sc$pl$off & near] >= 0.35),
             off_ball = sc$y %in% c(1:5, 11L))
}))
obs[, net := pmin(2, pmax(-2, def_blocked - off_blocked))]
w(rate_table(obs, "net"), "oreb_by_net_boxouts")
w(rate_table(obs[, off_blocked := pmin(off_blocked, 2L)], "off_blocked"), "oreb_by_offense_boxed_out")

# ---- 7. movement in the first 0.48 s -----------------------------------------------------------------------
mv <- readRDS(file.path(cache, "movement_rows.rds"))
h <- ANT_FRAMES / FPS
mv[, `:=`(proj = sqrt((vx0 * h)^2 + (vy0 * h)^2), moved = sqrt((x1 - x0)^2 + (y1 - y0)^2))]
set.seed(4)
w(mv[sample(.N, min(.N, 1500L)), .(proj = round(proj, 2), moved = round(moved, 2), off)], "movement_sample")
damp <- fit_damping(mv)
w(data.table(term = c("position_factor", "velocity_factor"), value = c(damp$pos, damp$vel)), "damping")
w(mv[, .(n = .N, toward_hoop_ft = mean(dr), moved_ft = mean(moved)), by = role][order(role)], "movement_by_role")

# ---- 8. players: how much evidence each one has ------------------------------------------------------------
pl <- rbindlist(lapply(seq_along(bundles), function(i) {
  sc <- scenes_all$rim[[i]]
  if (!length(sc)) return(NULL)
  data.table(canon = sc$pl$canon, off = sc$pl$off, won = seq_len(10) == sc$y, game_id = sc$game_id)
}))
players <- pl[, .(scenes = .N, rebounds = sum(won), games = uniqueN(game_id), def_share = mean(!off)), by = canon]
w(players, "player_evidence")
w(data.table(league_rate = mean(pl$won)), "player_league_rate")

message("EDA tables: ", paste(sub("\\.csv$", "", list.files(out_dir)), collapse = ", "))
