# Step 04 of the rebounding manual: static geometry of the ten players at one information time, for the grouped
# conditional logit (one row per player) and the binary offensive-rebound model (one row per episode). Inputs are
# the Step 03 features (positions at t, attack frame, offence at +x) and shot facts known at release. Feature list and
# definitions: config/experiment.yaml (step04$features). Relative-position ideas from ReboundingPrediction
# data/derived.py and box-out matchups from the ShotQuality notebook (both read for ideas only, no licence).
#
# Every length is computed from x, y and the hoop, and every length constant is given in feet times `ft` (the length
# of one foot in the data's units), so the features are the same in metres as in feet up to that scale.

PLAYER_FEATURES <- c("dist_hoop", "dist_minus_mean", "nearest_opp_dist", "inside_gap", "opp_inside", "mates_inside",
                     "abs_rel_bearing", "is_offense", "is_shooter", "dist_x_shot", "shooter_x_rim", "n_within_6",
                     "closeness_share")
EPISODE_FEATURES <- c("shot_dist", "three", "off_d1", "off_d2", "def_d1", "def_d2", "off_minus_def_mean",
                      "n_off_inside_matchup")
CROWD_RADIUS_FT <- 6
CLOSENESS_SCALE_FT <- 6
SHOT_SCALE_FT <- 25

#' Player features of every episode at one time point.
#' @param pl ten rows per episode: episode_id, pid, off, x, y (and source_frame, kept).
#' @param shot one row per episode: episode_id, shooter_id, shot_dist, rim (logical), sx, sy (shooter at release).
#' @param hoop hoop centre c(x, y) in the data's units; `ft` the length of one foot in those units.
static_features <- function(pl, shot, hoop = c(RIM_X, 0), ft = 1) {
  d <- merge(pl, shot, by = "episode_id")
  if (d[, .N, by = episode_id][, any(N != 10L)]) stop("every episode needs exactly ten players")
  d[, `:=`(dist_hoop = sqrt((x - hoop[1])^2 + (y - hoop[2])^2), is_offense = as.numeric(off),
           is_shooter = as.numeric(pid == shooter_id))]
  d[, c("nearest_opp_dist", "inside_gap", "opp_inside", "mates_inside", "n_within_6") := {
    dm <- as.matrix(dist(cbind(x, y)))
    opp <- outer(off, off, `!=`)
    do <- dm
    do[!opp] <- Inf
    j <- max.col(-do, ties.method = "first")
    nearer <- outer(dist_hoop, dist_hoop, `>`)            # [i, k]: k is nearer the hoop than i
    mate <- !opp
    diag(mate) <- FALSE
    .(do[cbind(seq_len(.N), j)], dist_hoop[j] - dist_hoop, rowSums(nearer & opp), rowSums(nearer & mate),
      rowSums(dm < CROWD_RADIUS_FT * ft) - 1)
  }, by = episode_id]
  d[, `:=`(dist_minus_mean = dist_hoop - mean(dist_hoop),
           closeness_share = exp(-dist_hoop / (CLOSENESS_SCALE_FT * ft)) / sum(exp(-dist_hoop / (CLOSENESS_SCALE_FT * ft)))),
    by = episode_id]
  rel <- atan2(d$y - hoop[2], d$x - hoop[1]) - atan2(d$sy - hoop[2], d$sx - hoop[1])
  d[, `:=`(abs_rel_bearing = abs(atan2(sin(rel), cos(rel))), dist_x_shot = dist_hoop * shot_dist / (SHOT_SCALE_FT * ft),
           shooter_x_rim = is_shooter * as.numeric(rim))]
  keep <- c("episode_id", "pid", "off", intersect("source_frame", names(d)), PLAYER_FEATURES)
  d[, ..keep][order(episode_id, -off, pid)]
}

#' All orderings of 1..n (rows), for the five-against-five assignment.
permutations <- function(n) {
  if (n == 1L) return(matrix(1L))
  p <- permutations(n - 1L)
  do.call(rbind, lapply(seq_len(n), function(i) cbind(i, p + (p >= i))))
}
PERM5 <- permutations(5L)

#' Box-out matchups: the pairing of the five defenders with the five attackers that minimises the total distance,
#' found over all 120 pairings. Returns, for each attacker in input order, the index of his defender.
matchup_assignment <- function(ax, ay, dx, dy) {
  cost <- sqrt(outer(ax, dx, `-`)^2 + outer(ay, dy, `-`)^2)
  tot <- vapply(seq_len(nrow(PERM5)), function(r) sum(cost[cbind(1:5, PERM5[r, ])]), 0)
  unname(PERM5[which.min(tot), ])
}

#' Episode features for the binary offensive-rebound model: shot distance and three, the two nearest offensive and
#' defensive hoop distances, offence minus defence mean distance, and how many attackers are nearer the hoop than
#' their assigned defender.
episode_features <- function(pl, shot, hoop = c(RIM_X, 0)) {
  d <- merge(pl, shot, by = "episode_id")
  d[, dist_hoop := sqrt((x - hoop[1])^2 + (y - hoop[2])^2)]
  d[, {
    o <- which(off)
    df <- which(!off)
    if (length(o) != 5L || length(df) != 5L) stop("episode ", episode_id[1], " is not five against five")
    so <- sort(dist_hoop[o])
    sd <- sort(dist_hoop[df])
    m <- matchup_assignment(x[o], y[o], x[df], y[df])
    .(shot_dist = shot_dist[1], three = as.numeric(three[1]), off_d1 = so[1], off_d2 = so[2], def_d1 = sd[1], def_d2 = sd[2],
      off_minus_def_mean = mean(dist_hoop[o]) - mean(dist_hoop[df]),
      n_off_inside_matchup = sum(dist_hoop[o] < dist_hoop[df][m]))
  }, by = episode_id][order(episode_id)]
}
