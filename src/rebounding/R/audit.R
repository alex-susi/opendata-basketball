# Audit of rebound episodes and of the ball track around them (framework section 2, 5 and step 1 of 15).
#
# Everything is computed from the raw windows of extract.R. Coordinates are rotated so the offense attacks
# +x. Ball positions are vendor reconstructions (isDetected is 0 on every frame of every game), so contact,
# touch and control below are automated proxies from geometry, not reviewed annotations.
# Requires geometry.R.

CONTACT_PAD <- 0.6       # ft added to the rim/board zones when looking for the first contact
CONTROL_DIST <- 3        # ft: ball this close to a player (horizontally) counts toward control
CONTROL_SPEED <- 10      # ft/s: ball slower than this counts toward control
CONTROL_Z <- 8.5         # ft: ball lower than this counts toward control
REACH_Z <- 11            # ft: pooled reach, used for the "touch possible" proxy
TOUCH_DIST <- 2.5        # ft
FLOOR_LOOK <- 1.6        # ft: a local minimum of ball height below this is a floor bounce candidate

#' Rotate camera coordinates to offense-attacks-+x (a 180 degree turn when flip is -1).
rot <- function(v, flip) v * flip

#' Ball track of one shot's window, rotated, with finite-difference velocity over two frames (centred) and
#' a flag for frames that are exactly the midpoint of their neighbours (interpolated by the vendor).
ball_track <- function(frames, s, from, to) {
  w <- frames[frame >= from & frame <= to][order(frame)]
  w[, c("x", "y", "z") := .(rot(bx, s$flip), rot(by, s$flip), bz)]
  w[, gap := c(1L, diff(frame))]
  w[, c("vx", "vy", "vz") := .((shift(x, -1L) - shift(x, 1L)) * FPS / 2, (shift(y, -1L) - shift(y, 1L)) * FPS / 2,
                               (shift(z, -1L) - shift(z, 1L)) * FPS / 2)]
  w[, interp := abs(x - (shift(x) + shift(x, -1L)) / 2) < 0.015 & abs(z - (shift(z) + shift(z, -1L)) / 2) < 0.015]
  w[]
}

#' Where made shots cross rim height on the way down, per game and end: the ball-frame hoop centre.
#' Ends are named by possessions.leftHoop (TRUE: the camera's left basket).
hoop_calibration <- function(raws) {
  cr <- rbindlist(lapply(raws, function(raw) {
    sh <- raw$shots[made == TRUE & !is.na(f0) & !is.na(f1)]
    rbindlist(lapply(seq_len(nrow(sh)), function(k) {
      s <- sh[k]
      w <- ball_track(raw$frames, s, s$f0, s$f1 + MADE_AFTER)
      if (nrow(w) < 5L) return(NULL)
      i <- which(w$z[-1] < RIM_Z & w$z[-nrow(w)] >= RIM_Z & hoop_dist(w$x[-1], w$y[-1]) < 4)
      if (!length(i)) return(NULL)
      i <- i[1]
      a <- (w$z[i] - RIM_Z) / (w$z[i] - w$z[i + 1])
      data.table(game_id = s$game_id, left_hoop = s$left_hoop, x = w$x[i] + a * (w$x[i + 1] - w$x[i]),
                 y = w$y[i] + a * (w$y[i + 1] - w$y[i]), lag = w$frame[i] - s$f1)
    }))
  }))
  cr[, .(n = .N, hx = median(x), hy = median(y), sd_x = sd(x), sd_y = sd(y), dx = median(x) - RIM_X,
         lag_frames = as.numeric(median(lag))), by = .(game_id, left_hoop)]
}

#' Ball offset from the nearest player while someone holds it (slow, chest height), per game, in the
#' rotated frame: shows whether ball and player coordinates agree on the ground plane.
held_offset <- function(raw) {
  fr <- raw$frames[!is.na(bx) & bz > 2.5 & bz < 5 & bspeed < 3]
  pl <- raw$players[frame %in% fr$frame]
  j <- merge(pl, fr[, .(frame, bx, by)], by = "frame")
  j[, d := sqrt((x - bx)^2 + (y - by)^2)]
  near <- j[j[, .I[which.min(d)], by = frame]$V1][d < 4]
  near[, .(game_id = raw$shots$game_id[1], n = .N, dx_cam = median(bx - x), dy_cam = median(by - y),
           d_med = median(d), d_p90 = quantile(d, 0.9))]
}

#' Players on court at chosen frames of a window, rotated, with side relative to the shooting team.
window_players <- function(raw, s, frames) {
  pl <- raw$players[frame %in% frames]
  home_off <- raw$home_team == s$off_team
  pl[, c("px", "py", "off") := .(rot(x, s$flip), rot(y, s$flip), home == home_off)]
  pl[]
}

#' One missed shot's automated timeline: contact with rim or board, first frame a touch is possible, the
#' control proxy, the first floor bounce, and tracking coverage between release and rebound.
#' @param hoop Calibrated ball-frame hoop centre for this shot's end: list(hx, hy).
miss_timeline <- function(raw, s, rb, hoop) {
  end <- if (nrow(rb) && !is.na(rb$rf[1])) max(rb$rf[1], s$f1) else s$f1
  w <- ball_track(raw$frames, s, s$f0, min(s$f0 + WINDOW_MAX, end + WINDOW_AFTER))
  out <- list(n_frames = nrow(w), span_frames = end - s$f0 + 1L)
  seen <- w[frame <= end]
  out$ball_cover <- if (out$span_frames > 0) sum(!is.na(seen$x)) / out$span_frames else NA_real_
  out$max_gap <- if (nrow(seen)) max(diff(c(s$f0 - 1L, seen$frame[!is.na(seen$x)], end + 1L))) - 1L else NA_integer_
  out$berr_mean <- mean(seen$berr, na.rm = TRUE)
  out$interp_share <- mean(seen$interp, na.rm = TRUE)
  if (sum(!is.na(w$x)) < 10L) return(c(out, list(tracked = FALSE)))
  w <- w[!is.na(x)]
  dx <- w$x - hoop$hx
  dy <- w$y - hoop$hy
  dh <- sqrt(dx^2 + dy^2)
  board <- dx >= (BOARD_X - RIM_X) - BALL_R - CONTACT_PAD & abs(dy) <= BOARD_HALF_W + CONTACT_PAD &
    w$z >= BOARD_Z0 - CONTACT_PAD & w$z <= BOARD_Z1 + CONTACT_PAD
  rim <- dh <= RIM_R + BALL_R + CONTACT_PAD + 0.6 & w$z >= RIM_Z - 1.2 & w$z <= RIM_Z + 1.5
  after_apex <- seq_len(nrow(w)) >= which.max(w$z[seq_len(min(nrow(w), 60L))])
  hit <- which((rim | board) & after_apex)
  low <- which(w$z < 6 & after_apex)
  out$contact_frame <- if (length(hit) && (!length(low) || hit[1] < low[1])) w$frame[hit[1]] else NA_integer_
  out$contact_kind <- if (is.na(out$contact_frame)) "none" else if (board[hit[1]] && !rim[hit[1]]) "board" else "rim"
  out$apex_z <- max(w$z[seq_len(min(nrow(w), 60L))])
  # direction change across the contact: angle between mean velocity 3 frames before and 3 after
  if (!is.na(out$contact_frame)) {
    i <- hit[1]
    pre <- w[max(1L, i - 4L):max(1L, i - 1L)]
    post <- w[min(nrow(w), i + 1L):min(nrow(w), i + 4L)]
    v1 <- c(mean(pre$vx, na.rm = TRUE), mean(pre$vy, na.rm = TRUE), mean(pre$vz, na.rm = TRUE))
    v2 <- c(mean(post$vx, na.rm = TRUE), mean(post$vy, na.rm = TRUE), mean(post$vz, na.rm = TRUE))
    out$deflect_deg <- acos(pmin(1, pmax(-1, sum(v1 * v2) / sqrt(sum(v1^2) * sum(v2^2))))) * 180 / pi
    out$speed_in <- sqrt(sum(v1^2))
    out$speed_out <- sqrt(sum(v2^2))
  }
  # players after release: touch possible, control proxy, nearest player at each ball frame
  start <- if (is.na(out$contact_frame)) s$f0 + 10L else out$contact_frame
  pl <- window_players(raw, s, w$frame[w$frame >= start])
  if (nrow(pl)) {
    j <- merge(pl[, !c("x", "y")], w[, .(frame, x, y, z, vx, vy, vz)], by = "frame")
    j[, d := sqrt((px - x)^2 + (py - y)^2)]
    near <- j[j[, .I[which.min(d)], by = frame]$V1][order(frame)]
    near[, bsp := sqrt(vx^2 + vy^2 + vz^2)]
    touch <- near[d <= TOUCH_DIST & z <= REACH_Z]
    out$touch_frame <- if (nrow(touch)) touch$frame[1] else NA_integer_
    out$touch_pid <- if (nrow(touch)) touch$pid[1] else NA_integer_
    ctl <- near[, ok := d <= CONTROL_DIST & z <= CONTROL_Z & !is.na(bsp) & bsp <= CONTROL_SPEED]
    run <- frollsum(as.integer(ctl$ok), 6L, align = "left")
    k <- which(ctl$ok & run >= 4L)
    out$control_frame <- if (length(k)) ctl$frame[k[1]] else NA_integer_
    out$control_pid <- if (length(k)) ctl$pid[k[1]] else NA_integer_
    out$control_off <- if (length(k)) ctl$off[k[1]] else NA
    # floor bounce: local minimum of height below FLOOR_LOOK after falling fast
    fb <- which(w$z < FLOOR_LOOK & shift(w$vz, 2L) < -5 & shift(w$z, -1L) >= w$z & shift(w$z, 1L) >= w$z & w$frame >= start)
    if (length(fb)) {
      f <- fb[1]
      out$bounce_frame <- w$frame[f]
      out$bounce_x <- w$x[f]
      out$bounce_y <- w$y[f]
      out$bounce_z <- w$z[f]
      nd <- near[frame == w$frame[f]]$d
      out$bounce_near <- if (length(nd)) nd else NA_real_
    }
  }
  c(out, list(tracked = TRUE))
}

#' Every shot of one game with its rebound, audit flags and automated timeline (misses only).
episode_audit <- function(raw, hoops) {
  sh <- raw$shots
  rb <- raw$rebounds[fg == TRUE & !is.na(shot_id)]
  rb_first <- rb[order(rf)][, .SD[1], by = shot_id]
  ep <- merge(sh, rb_first[, .(shot_id, reb_id, rf, grabbed, defensive, rpid, rcanon, rteam, next_chance,
                               rx_cam, ry_cam)], by = "shot_id", all.x = TRUE, sort = FALSE)
  ep[, n_reb := rb[, .N, by = shot_id][match(ep$shot_id, shot_id), N]]
  ep[is.na(n_reb), n_reb := 0L]
  # The delivered defensive flag is wrong on 14 team awards (Gate 0): the side comes from the rebound's teamId,
  # which the next chance's offence confirms in every disagreement. The flag is kept as defensive_flag.
  ep[, defensive_flag := defensive]
  ep[!is.na(rteam), defensive := rteam == def_team]
  # tracked shooter at release against the event location (event frame = ours turned 180 degrees)
  rel <- raw$players[.(ep$f0, ep$pid), on = .(frame, pid), .(x, y)]
  ep[, c("shooter_x", "shooter_y") := .(rot(rel$x, flip), rot(rel$y, flip))]
  ep[, c("loc_x", "loc_y") := .(-sx_cam, -sy_cam)]
  ep[, loc_gap := sqrt((shooter_x - loc_x)^2 + (shooter_y - loc_y)^2)]
  ep[, sx := fcoalesce(shooter_x, loc_x)]
  ep[, sy := fcoalesce(shooter_y, loc_y)]
  ep[, shot_dist := hoop_dist(sx, sy)]
  # putback: the offense shoots again within a second of the rebound
  nxt <- sh[, .(f_next = f0, team_next = off_team)]
  ep[, putback := vapply(seq_len(.N), function(i) {
    if (is.na(rf[i]) || defensive[i] %in% TRUE) return(FALSE)
    any(nxt$team_next == off_team[i] & nxt$f_next > rf[i] - 5L & nxt$f_next <= rf[i] + 25L)
  }, NA)]
  miss <- ep[made == FALSE & fouled == FALSE & !is.na(f0) & !is.na(f1)]
  tl <- rbindlist(lapply(seq_len(nrow(miss)), function(k) {
    s <- miss[k]
    h <- hoops[game_id == s$game_id & left_hoop == s$left_hoop]
    hoop <- if (nrow(h)) list(hx = h$hx, hy = h$hy) else list(hx = RIM_X, hy = 0)
    as.data.table(miss_timeline(raw, s, raw$rebounds[shot_id == s$shot_id & fg == TRUE], hoop))
  }), fill = TRUE)
  miss <- cbind(miss, tl)
  ep <- merge(ep, miss[, c("shot_id", setdiff(names(tl), names(ep))), with = FALSE], by = "shot_id", all.x = TRUE, sort = FALSE)
  ep[]
}

#' The episode population and why each shot is in or out of the rebound models.
classify_episodes <- function(ep) {
  ep[, status := fcase(
    made == TRUE, "made",
    fouled == TRUE, "fouled miss",
    n_reb == 0L, "miss without rebound row",
    !(tracked %in% TRUE), "miss, ball not tracked",
    ball_cover < 0.8 | max_gap > 12L, "miss, poor ball coverage",
    default = "eligible")]
  ep[, outcome := fcase(
    status != "eligible" & status != "miss, poor ball coverage", NA_character_,
    grabbed == TRUE & defensive == FALSE, "off player",
    grabbed == TRUE & defensive == TRUE, "def player",
    grabbed == FALSE & defensive == FALSE, "off team award",
    grabbed == FALSE & defensive == TRUE, "def team award")]
  ep[, kind := fcase(
    blocked == TRUE, "blocked",
    putback == TRUE, "putback or tip",
    contact_kind == "none", "airball or no contact",
    contact_kind == "board", "backboard first",
    default = "rim first")]
  ep[, range := cut(shot_dist, c(-Inf, 10, 22, Inf), labels = c("short (<10 ft)", "mid (10-22 ft)", "long (22+ ft)"))]
  ep[]
}

#' The shot ranges used to describe the data (EDA and the site): at the rim (under 5 ft), midrange (every other
#' two) and three. The models use these too (density benchmark) or continuous shot distance (skill GAMs);
#' `range` above remains only to stratify the review sample.
SHOT_RANGES <- c("rim (<5 ft)", "midrange (other 2s)", "three")
shot_range <- function(dist, three) {
  factor(fifelse(three %in% TRUE, SHOT_RANGES[3], fifelse(dist < 5, SHOT_RANGES[1], SHOT_RANGES[2])), levels = SHOT_RANGES)
}

#' Counts the framework reports in its section 2, recomputed from the delivered event files.
audit_counts <- function(ep, chance_players) {
  m <- ep[made == FALSE]
  r <- ep[n_reb > 0L]
  cp <- unique(chance_players[, .(game_id, canon)])
  games_per <- cp[, .N, by = canon]
  data.table(
    quantity = c("Shot records, including fouled misses", "Made shot records", "Missed records including fouled attempts",
                 "Fouled misses", "Non-fouled misses", "Linked field-goal rebound records", "Player-secured field-goal rebounds",
                 "Offensive player rebounds", "Defensive player rebounds", "Team field-goal rebounds",
                 "Offensive team rebounds (delivered flag)", "Defensive team rebounds (delivered flag)",
                 "Non-fouled misses without a rebound row",
                 "Blocked, non-fouled misses", "Canonical players appearing in chance_players",
                 "Players appearing in one game", "Players appearing in two games",
                 "Rebound rows pointing to a made or fouled shot", "Shots with more than one rebound row",
                 "Offensive team rebounds (side by teamId)", "Defensive team rebounds (side by teamId)"),
    count = c(nrow(ep), sum(ep$made), nrow(m), sum(m$fouled), sum(!m$fouled), sum(ep$n_reb),
              sum(r$grabbed %in% TRUE), sum(r$grabbed %in% TRUE & r$defensive %in% FALSE),
              sum(r$grabbed %in% TRUE & r$defensive %in% TRUE), sum(r$grabbed %in% FALSE),
              sum(r$grabbed %in% FALSE & r$defensive_flag %in% FALSE), sum(r$grabbed %in% FALSE & r$defensive_flag %in% TRUE),
              sum(!m$fouled & m$n_reb == 0L), sum(!m$fouled & m$blocked), nrow(games_per),
              sum(games_per$N == 1L), sum(games_per$N == 2L),
              sum(r$made | r$fouled), sum(ep$n_reb > 1L),
              sum(r$grabbed %in% FALSE & r$defensive %in% FALSE), sum(r$grabbed %in% FALSE & r$defensive %in% TRUE)),
    framework = c(1459, 606, 853, 111, 742, 713, 635, 177, 458, 78, 54, 24, 29, 51, 205, 180, 25, NA, NA, NA, NA))
}

#' A stratified sample of episodes for review against the play viewer (framework section 5): every kind and
#' shot range, every game, plus random picks. Reviewers fill the label columns using the guide in
#' docs/project/rebounding.md.
review_sample <- function(ep, n_total = 60L, seed = 20261027L) {
  set.seed(seed)
  pool <- ep[made == FALSE & fouled == FALSE]
  pool[, stratum := paste(kind, range, sep = " | ")]
  strat <- pool[, .SD[sample(.N, min(.N, 3L))], by = stratum]
  extra <- pool[status != "eligible"][sample(.N, min(.N, 8L))]
  rnd <- pool[!shot_id %in% c(strat$shot_id, extra$shot_id)][sample(.N, max(0L, n_total - nrow(strat) - nrow(extra)))]
  out <- unique(rbind(strat, extra, rnd, fill = TRUE), by = "shot_id")[seq_len(min(n_total, .N))]
  out[, .(game_id, shot_id, period, release_frame = f0, end_frame = f1, rebound_frame = rf, status, kind, range,
          outcome, contact_frame, contact_kind, control_frame, bounce_frame,
          label_contact = "", label_first_touch = "", label_control = "", label_dead_ball = "", label_boxout = "",
          reviewer_note = "")]
}
