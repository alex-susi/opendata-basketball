# Step 11 of the rebounding manual: what the obstruction proxy is worth and how it could be checked. The contribution
# split separates a player's own collection probability, his side's chance of securing the ball, and the share of
# that chance the model ties to his obstruction (predictions minus predictions with his blocking removed); the idea
# of crediting help to a teammate's rebound comes from ReboundingImpact (Rebound Impact Modeling.R; read for the
# concept only, no licence, its NBA data not read). Also the stratified review sample and its scoring. Settings:
# config/experiment.yaml (step11). Requires pairwise_obstruction.R.

#' Features of one episode with player `p`'s blocking removed (his row of O set to 0): his blocking_opp becomes 0 and
#' each opponent's blocked_by_opp loses his part.
features_without_blocker <- function(O, p) {
  O2 <- O
  O2[as.character(p), ] <- 0
  obstruction_features(O2)
}

#' Counterfactual episodes for the contribution split: for each episode and each of its players, a copy of the
#' episode's feature rows with that player's blocking removed, under the id "<episode>#<pid>".
#' @param sf Step 04 player features merged with obstruction features (episode_id, pid, ...).
counterfactual_rows <- function(sf, O_list, ids) {
  rbindlist(lapply(ids, function(id) {
    O <- O_list[[id]]
    base <- sf[episode_id == id]
    rbindlist(lapply(as.integer(rownames(O)), function(p) {
      f <- features_without_blocker(O, p)
      d <- merge(base[, !OBSTRUCTION_FEATURES, with = FALSE], f, by = "pid")
      d[, episode_id := paste0(id, "#", p)]
      d[order(match(pid, base$pid))]
    }))
  }))
}

#' The contribution split from actual and counterfactual predictions (long: episode_id, outcome_id, probability) and
#' the choice sets (outcome side). One row per episode and player.
contribution_split <- function(pred, pred_cf, choice) {
  side <- choice[, .(episode_id, outcome_id, side)]
  a <- merge(pred[, .(episode_id, outcome_id, probability)], side, by = c("episode_id", "outcome_id"))
  cf <- copy(pred_cf)[, c("episode_id", "removed") := tstrsplit(episode_id, "#", fixed = TRUE)]
  cf <- merge(cf[, .(episode_id, removed, outcome_id, probability)], side, by = c("episode_id", "outcome_id"))
  me <- merge(unique(cf[, .(episode_id, removed)]), side[, .(episode_id, removed = outcome_id, my_side = side)],
              by = c("episode_id", "removed"))
  agg <- function(d) d[, .(own = sum(probability[outcome_id == removed]),
                           mates = sum(probability[side == my_side & outcome_id != removed]),
                           team = sum(probability[side == my_side])), by = .(episode_id, removed)]
  act <- agg(merge(a, me, by = "episode_id", allow.cartesian = TRUE))
  rem <- agg(merge(cf, me, by = c("episode_id", "removed")))
  r <- merge(act, rem, by = c("episode_id", "removed"), suffixes = c("", "_removed"))
  r[, `:=`(contrib_own = own - own_removed, contrib_mates = mates - mates_removed, contrib_team = team - team_removed)]
  setnames(r, c("removed", "own", "team"), c("pid", "collection", "team_secures"))
  r[, pid := as.integer(pid)]
  r[, .(episode_id, pid, collection, team_secures, contrib_own, contrib_mates, contrib_team)]
}

#' Candidate pairs (blocker, runner) of every episode at one time with the descriptors the strata need.
#' @param O_list pair matrices; `st` positions and velocities at t (episode_id, pid, off, x, y, vx, vy); `rel`
#'   positions at release (episode_id, pid, x, y).
candidate_pairs <- function(O_list, st, rel, pairings) {
  # Per episode: every attacker-defender pair with its obstruction and the positions at release.
  rbindlist(lapply(names(O_list), function(id) {
    O <- O_list[[id]]
    s <- st[episode_id == id]
    r0 <- rel[episode_id == id]
    if (nrow(s) != 10L) return(NULL)
    d <- CJ(b = as.integer(rownames(O)), r = as.integer(rownames(O)))
    d <- d[s$off[match(b, s$pid)] != s$off[match(r, s$pid)]]
    ib <- match(d$b, s$pid)
    ir <- match(d$r, s$pid)
    d[, `:=`(episode_id = id, o_br = O[cbind(as.character(b), as.character(r))], o_rb = O[cbind(as.character(r), as.character(b))],
             dist = sqrt((s$x[ib] - s$x[ir])^2 + (s$y[ib] - s$y[ir])^2),
             closing = closing_speed(s$x[ib], s$y[ib], s$vx[ib], s$vy[ib], s$x[ir], s$y[ir], s$vx[ir], s$vy[ir]),
             to_hoop_b = -radial(s, ib), to_hoop_r = -radial(s, ir),
             runner_hoop_release = hoop_dist(r0$x[match(r, r0$pid)], r0$y[match(r, r0$pid)]))]
    pg <- pairings[episode_id == id]
    d[, blocker_pairing := pg$pairing[match(b, pg$pid)]][, blocker_target := pg$runner[match(b, pg$pid)]]
    d[]
  }))
}

#' Velocity component away from the hoop of player rows `i` of a state table.
radial <- function(s, i) {
  dx <- s$x[i] - RIM_X
  dy <- s$y[i]
  r <- pmax(sqrt(dx^2 + dy^2), 1e-6)
  (dx * s$vx[i] + dy * s$vy[i]) / r
}

#' The held-aside review sample: per_stratum pairs from each stratum, at most one pair per episode overall, drawn in
#' stratum order with a fixed seed. Strata (config step11$labels): strong, ambiguous, close_not_blocking, post,
#' converging. Each item's two players are shown as A and B in a random order, so the page does not say who blocks.
review_sample <- function(cp, lb, pc) {
  strata <- list(strong = cp[o_br >= 0.5],
                 ambiguous = cp[blocker_pairing == "ambiguous" & r == blocker_target],
                 close_not_blocking = cp[dist < 4 & o_br < 0.15 & o_rb < 0.15],
                 post = cp[runner_hoop_release <= 8 & dist < 6],
                 converging = cp[to_hoop_b >= 4 & to_hoop_r >= 4 & dist < 6 & o_br < pc$pair_min & o_rb < pc$pair_min])
  set.seed(lb$seed)
  used <- character()
  out <- list()
  for (nm in names(strata)) {
    pool <- strata[[nm]][!episode_id %in% used]
    pool <- pool[sample(.N)][!duplicated(episode_id)]
    take <- pool[seq_len(min(lb$per_stratum, .N))]
    used <- c(used, take$episode_id)
    out[[nm]] <- cbind(stratum = nm, take)
  }
  s <- rbindlist(out)
  flip <- runif(nrow(s)) < 0.5
  s[, `:=`(player_a = fifelse(flip, r, b), player_b = fifelse(flip, b, r))]
  s <- s[sample(.N)]
  s[, item := seq_len(.N)]
  s[]
}

#' Precision and recall of the proxy (max of the pair's two obstruction values >= pair_min) against a reviewer's
#' "box-out" labels (either direction); unclear labels are left out and counted.
score_review <- function(sheet, smp, pc) {
  d <- merge(smp[, .(item, o_max = pmax(o_br, o_rb))], sheet[, .(item, label)], by = "item")
  d <- d[nzchar(label)]
  unclear <- d[label == "unclear", .N]
  d <- d[label != "unclear"]
  d[, `:=`(truth = label %in% c("boxout_by_A", "boxout_by_B"), flag = o_max >= pc$pair_min)]
  data.table(labelled = nrow(d) + unclear, unclear = unclear, boxouts = sum(d$truth), flagged = sum(d$flag),
             true_pos = sum(d$truth & d$flag), precision = sum(d$truth & d$flag) / max(1, sum(d$flag)),
             recall = sum(d$truth & d$flag) / max(1, sum(d$truth)))
}
