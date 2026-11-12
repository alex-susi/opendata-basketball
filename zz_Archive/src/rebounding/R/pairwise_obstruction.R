# Step 11 of the rebounding manual: pairwise geometric obstruction. obstruction_score(i, j, k, t) says how much player
# i's body stands on player j's route to target k at frame t, from floor positions only; it is a geometric proxy, not
# body contact (no orientation, no contact evidence in the data). Relative-position ideas (inside gap, "opponent
# boxes me" as the projection of the opponent onto the line to the basket) from ReboundingPrediction data/derived.py,
# and box-out matchups from the ShotQuality offensive-rebounding notebook; both read for ideas only (no licence),
# written independently. Settings: config/experiment.yaml (step11). Requires geometry.R (RIM_X, COURT_HALF_L, FPS).

OBSTRUCTION_FEATURES <- c("blocked_by_opp", "blocking_opp")

#' The fixed target points routes lead to: the hoop and rings around it (angles from the hoop-to-centre-court
#' direction, so 0 is straight out from the hoop), points past the baseline dropped. `hoop` c(x, y).
obstruction_targets <- function(tg, hoop = c(RIM_X, 0)) {
  a <- unlist(tg$angles_deg) * pi / 180
  ring <- CJ(r = unlist(tg$radii_ft), a = a)
  pts <- data.table(tx = hoop[1] - ring$r * cos(ring$a), ty = hoop[2] + ring$r * sin(ring$a))
  if (isTRUE(tg$hoop)) pts <- rbind(data.table(tx = hoop[1], ty = hoop[2]), pts)
  pts[tx <= COURT_HALF_L + 1e-9]
}

#' obstruction_score of blocker positions (bx, by) on runner positions (rx, ry) heading to target (tx, ty);
#' vectorised over equal-length inputs. `p` = config step11$score.
obstruction_score <- function(bx, by, rx, ry, tx, ty, p) {
  L <- sqrt((tx - rx)^2 + (ty - ry)^2)
  ux <- (tx - rx) / pmax(L, 1e-9)
  uy <- (ty - ry) / pmax(L, 1e-9)
  dx <- bx - rx
  dy <- by - ry
  s <- dx * ux + dy * uy
  e <- abs(dx * uy - dy * ux)
  cl <- function(v) pmin(1, pmax(0, v))
  exp(-e^2 / (2 * p$lateral_sd_ft^2)) * cl(s / p$ramp_ft) * exp(-pmax(0, s - p$near_ft) / p$decay_ft) *
    cl((L + p$body_ft - s) / p$ramp_ft) * cl(L / p$min_route_ft)
}

#' Pair obstruction matrix of one frame: O[i, j] = mean over targets of player i's obstruction of player j's route.
#' Teammates and the diagonal are 0. `off` logical; dimnames are the player ids.
pair_obstruction <- function(pid, off, x, y, targets, p) {
  n <- length(x)
  O <- matrix(0, n, n, dimnames = list(pid, pid))
  bx <- matrix(x, n, n)
  by <- matrix(y, n, n)                       # [i, j]: blocker i
  rx <- matrix(x, n, n, byrow = TRUE)
  ry <- matrix(y, n, n, byrow = TRUE)  # [i, j]: runner j
  for (k in seq_len(nrow(targets))) O <- O + obstruction_score(bx, by, rx, ry, targets$tx[k], targets$ty[k], p)
  O <- O / nrow(targets)
  O[!outer(off, off, `!=`)] <- 0
  O
}

#' Player features from a pair matrix: how much each player's routes are blocked by opponents, and how much he
#' blocks theirs (1 - product of the complements, so one strong block counts nearly fully).
obstruction_features <- function(O) {
  data.table(pid = as.integer(rownames(O)), blocked_by_opp = 1 - apply(1 - O, 2, prod), blocking_opp = 1 - apply(1 - O, 1, prod))
}

#' Each player's main obstruction target: the opponent he obstructs most, "none" below pair_min (help, rotation or no
#' block; no pair is forced) and "ambiguous" when a second opponent is within ambiguity_margin and also >= pair_min.
pairing_of <- function(O, pc) {
  pid <- as.integer(rownames(O))
  rbindlist(lapply(seq_along(pid), function(i) {
    o <- O[i, ]
    ord <- order(-o, as.integer(names(o)))
    best <- o[ord[1]]
    second <- o[ord[2]]
    cls <- if (best < pc$pair_min) "none" else if (second >= pc$pair_min && best - second <= pc$ambiguity_margin) "ambiguous" else "pair"
    data.table(pid = pid[i], runner = as.integer(names(o)[ord[1]]), o_best = unname(best), o_second = unname(second),
               runner_second = as.integer(names(o)[ord[2]]), pairing = cls)
  }))
}

#' Pair matrices, player features and pairings of every episode at one time. `pl`: episode_id, pid, off, x, y (ten
#' rows per episode, any order). Returns list(O = named list of matrices, features, pairings).
episode_obstruction <- function(pl, targets, p, pc) {
  sp <- split(pl[order(episode_id, -off, pid)], by = "episode_id")
  O <- lapply(sp, function(d) pair_obstruction(d$pid, d$off, d$x, d$y, targets, p))
  list(O = O,
       features = rbindlist(lapply(names(O), function(id) cbind(episode_id = id, obstruction_features(O[[id]])))),
       pairings = rbindlist(lapply(names(O), function(id) cbind(episode_id = id, pairing_of(O[[id]], pc)))))
}

#' Persistence of pairs before t: for each blocker b[m] and runner r[m], the share of frames in [t - n, t] (each
#' player's last row within `carry` frames, frames <= t only) at which b's obstruction of r is at least pair_min.
#' Frames without all ten players are skipped; NA when none is left.
pair_persistence <- function(players, t, n, b, r, targets, p, pc, carry = 5L) {
  hits <- numeric(length(b))
  seen <- 0L
  for (f in (t - n):t) {
    q <- players[frame <= f & frame >= f - carry]
    q <- q[q[, .I[which.max(frame)], by = pid]$V1]
    if (nrow(q) != 10L || !all(c(b, r) %in% q$pid)) next
    O <- pair_obstruction(q$pid, q$off, q$x, q$y, targets, p)
    seen <- seen + 1L
    hits <- hits + (O[cbind(as.character(b), as.character(r))] >= pc$pair_min)
  }
  if (seen == 0L) rep(NA_real_, length(b)) else hits / seen
}

#' Rate of change of the distance between two players (ft/s; negative = closing), from positions and velocities.
closing_speed <- function(x1, y1, vx1, vy1, x2, y2, vx2, vy2) {
  dx <- x1 - x2
  dy <- y1 - y2
  (dx * (vx1 - vx2) + dy * (vy1 - vy2)) / pmax(sqrt(dx^2 + dy^2), 1e-6)
}
