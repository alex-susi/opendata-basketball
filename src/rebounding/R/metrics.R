# Step 03 of the rebounding manual: the scoring harness. Every model hands in one long table of probabilities
# (episode x time point x outcome); it is validated against the episode's choice set, scored once per episode (never
# per player row), and compared with another model on the same episodes and time point. Thresholds and the
# uncertainty settings are config/experiment.yaml (step03).
#
# Per-episode top-1 with pessimistic ties and the warning against per-row accuracy come from ReboundingPrediction's
# eval/metrics.py and README (ideas only, no licence); the code is written independently.

PRED_COLS <- c("model", "time_point", "episode_id", "outcome_id", "probability")

#' The choice set of every episode: its ten players at release and the two team awards, with each outcome's side.
#' @param el eligible episodes (release_off_ids, release_def_ids as "id;id;...").
choice_sets <- function(el) {
  rbindlist(lapply(seq_len(nrow(el)), function(i) {
    e <- el[i]
    off <- strsplit(e$release_off_ids, ";", fixed = TRUE)[[1]]
    def <- strsplit(e$release_def_ids, ";", fixed = TRUE)[[1]]
    data.table(episode_id = e$episode_id, outcome_id = c(off, def, "team_off", "team_def"),
               kind = c(rep("player", 10L), "team", "team"), side = c(rep("off", 5L), rep("def", 5L), "off", "def"))
  }))
}

#' The credited outcome of every episode in the choice-set vocabulary, and whether the offence secured it.
episode_labels <- function(el) {
  el[, .(episode_id, game_id,
         outcome_id = fifelse(credited_outcome == "off team award", "team_off",
                              fifelse(credited_outcome == "def team award", "team_def", as.character(rebounder_id))),
         y_off = side == "off")]
}

#' Validity of a prediction table: one row per outcome of each (model, time point, episode)'s choice set, no
#' duplicates, finite, non-negative and summing to one. Returns one row per (model, time point) with counts of
#' failures; `ok` is TRUE when there are none.
check_predictions <- function(pred, choice, tol = 1e-9) {
  stopifnot(all(PRED_COLS %in% names(pred)))
  key <- c("model", "time_point", "episode_id")
  per <- pred[, .(n = .N, dup = anyDuplicated(outcome_id) > 0, sum_p = sum(probability),
                  bad = sum(!is.finite(probability) | probability < 0)), by = key]
  have <- unique(pred[, .(model, time_point, episode_id, outcome_id)])
  want <- merge(unique(pred[, ..key]), choice[, .(episode_id, outcome_id)], by = "episode_id", allow.cartesian = TRUE)
  missing <- fsetdiff(want[, .(model, time_point, episode_id, outcome_id)], have)
  extra <- fsetdiff(have, want[, .(model, time_point, episode_id, outcome_id)])
  out <- per[, .(episodes = .N, wrong_size = sum(n != 12L), duplicated = sum(dup), not_finite_or_negative = sum(bad),
                 not_normalised = sum(abs(sum_p - 1) > tol), max_sum_error = max(abs(sum_p - 1))),
             by = .(model, time_point)]
  out <- merge(out, missing[, .(missing_outcomes = .N), by = .(model, time_point)], by = c("model", "time_point"), all.x = TRUE)
  out <- merge(out, extra[, .(extra_outcomes = .N), by = .(model, time_point)], by = c("model", "time_point"), all.x = TRUE)
  out[is.na(missing_outcomes), missing_outcomes := 0L][is.na(extra_outcomes), extra_outcomes := 0L]
  out[, ok := wrong_size == 0 & duplicated == 0 & not_finite_or_negative == 0 & not_normalised == 0 &
          missing_outcomes == 0 & extra_outcomes == 0][]
}

#' Per-episode scores of a validated prediction table: multiclass log loss (floored probability, flagged), Brier
#' over all outcomes, rank of the credited outcome with ties counted against the model, top-1/top-3, reciprocal
#' rank, and the binary OREB scores of P(OREB) = offensive players + offensive team award.
score_episodes <- function(pred, choice, labels, floor = 1e-12) {
  p <- merge(pred, choice[, .(episode_id, outcome_id, side)], by = c("episode_id", "outcome_id"))
  p <- merge(p, labels[, .(episode_id, game_id, truth = outcome_id, y_off)], by = "episode_id")
  p[, hit := outcome_id == truth]
  if (p[, sum(hit), by = .(model, time_point, episode_id)][, any(V1 != 1L)])
    stop("every episode needs exactly one credited outcome in its choice set")
  p[, {
    pt <- probability[hit]
    p_off <- sum(probability[side == "off"])
    yo <- y_off[1]
    pc <- min(max(p_off, floor), 1 - floor)
    rank <- sum(probability > pt) + sum(probability == pt)
    .(game_id = game_id[1], p_true = pt, floored = pt < floor, ll = -log(max(pt, floor)),
      brier = sum((probability - hit)^2), rank = rank, top1 = rank == 1L, top3 = rank <= 3L, rr = 1 / rank,
      p_off = p_off, y_off = yo, team_ll = -(yo * log(pc) + (1 - yo) * log(1 - pc)), team_brier = (p_off - yo)^2)
  }, by = .(model, time_point, episode_id)]
}

#' Means of the per-episode scores by model and time point (and any extra grouping columns).
summarise_scores <- function(sc, by = c("model", "time_point")) {
  sc[, .(episodes = .N, games = uniqueN(game_id), log_loss = mean(ll), brier = mean(brier), top1 = mean(top1),
         top3 = mean(top3), mrr = mean(rr), team_log_loss = mean(team_ll), team_brier = mean(team_brier),
         mean_p_off = mean(p_off), oreb_rate = mean(y_off), floored = sum(floored)), by = by]
}

#' Class-wise reliability: every (episode, outcome) probability pooled, binned at fixed breaks; observed frequency
#' against mean prediction per bin, and the expected calibration error (bin-weighted absolute gap) per model/time.
calibration_classwise <- function(pred, labels, breaks) {
  p <- merge(pred, labels[, .(episode_id, truth = outcome_id)], by = "episode_id")
  p[, y := outcome_id == truth]
  p[, bin := cut(probability, breaks, include.lowest = TRUE)]
  bins <- p[, .(n = .N, mean_p = mean(probability), observed = mean(y)), by = .(model, time_point, bin)]
  bins[, ece_part := n / sum(n) * abs(mean_p - observed), by = .(model, time_point)]
  list(bins = bins[order(model, time_point, bin)],
       ece = bins[, .(ece = sum(ece_part)), by = .(model, time_point)])
}

#' Calibration in the large by outcome group: mean predicted probability and observed frequency of offensive
#' players, defensive players and each team award.
calibration_groups <- function(pred, choice, labels) {
  p <- merge(pred, choice[, .(episode_id, outcome_id, kind, side)], by = c("episode_id", "outcome_id"))
  p <- merge(p, labels[, .(episode_id, truth = outcome_id)], by = "episode_id")
  p[, group := paste(side, kind)]
  p[, .(predicted = sum(probability) / uniqueN(episode_id), observed = sum(outcome_id == truth) / uniqueN(episode_id)),
    by = .(model, time_point, group)][order(model, time_point, group)]
}

#' Binary OREB reliability at fixed breaks, with calibration in the large.
calibration_team <- function(sc, breaks) {
  sc <- copy(sc)[, bin := cut(p_off, breaks, include.lowest = TRUE)]
  list(bins = sc[, .(n = .N, mean_p = mean(p_off), observed = mean(y_off)), by = .(model, time_point, bin)][
         order(model, time_point, bin)],
       large = sc[, .(mean_p_off = mean(p_off), oreb_rate = mean(y_off), gap = mean(p_off) - mean(y_off)),
                  by = .(model, time_point)])
}

#' Paired comparison of two models on the same episodes and time point: difference = candidate - reference per
#' episode (`metric` is a column of score_episodes()), its pooled mean, per-game means, a game bootstrap interval,
#' a t interval on the per-game means, the conservative (wider) interval, and the mean with each game dropped.
paired_comparison <- function(sc, candidate, reference, time, metric = "ll", reps = 2000L, seed = 1L, level = 0.95) {
  a <- sc[model == candidate & time_point == time, .(episode_id, game_id, a = get(metric))]
  b <- sc[model == reference & time_point == time, .(episode_id, b = get(metric))]
  d <- merge(a, b, by = "episode_id")
  if (nrow(d) != nrow(a) || nrow(d) != nrow(b)) stop("models were not scored on the same episodes: ", candidate, " / ", reference)
  d[, diff := a - b]
  pg <- d[, .(n = .N, s = sum(diff), mean_diff = mean(diff)), by = game_id][order(game_id)]
  set.seed(seed)
  boot <- replicate(reps, { i <- sample.int(nrow(pg), replace = TRUE); sum(pg$s[i]) / sum(pg$n[i]) })
  alpha <- (1 - level) / 2
  bq <- unname(quantile(boot, c(alpha, 1 - alpha)))
  m <- mean(pg$mean_diff)
  tq <- m + c(-1, 1) * qt(1 - alpha, nrow(pg) - 1L) * sd(pg$mean_diff) / sqrt(nrow(pg))
  drop1 <- vapply(seq_len(nrow(pg)), function(i) sum(pg$s[-i]) / sum(pg$n[-i]), 0)
  list(summary = data.table(candidate = candidate, reference = reference, time_point = time, metric = metric,
                            episodes = nrow(d), games = nrow(pg), mean_diff = mean(d$diff),
                            episodes_better = mean(d$diff < 0), games_better = sum(pg$mean_diff < 0),
                            boot_lo = bq[1], boot_hi = bq[2], game_t_lo = tq[1], game_t_hi = tq[2],
                            lo = min(bq[1], tq[1]), hi = max(bq[2], tq[2]),
                            drop_one_min = min(drop1), drop_one_max = max(drop1),
                            worst_game = pg$game_id[which.max(pg$mean_diff)], worst_game_diff = max(pg$mean_diff)),
       by_game = cbind(candidate = candidate, reference = reference, time_point = time, metric = metric,
                       pg[, .(game_id, episodes = n, mean_diff)]))
}

#' The prespecified decision on a paired comparison (config step03$decision): superiority or non-inferiority.
decide <- function(cmp, rule, margin) {
  switch(rule,
         superiority = cmp$hi < 0 && cmp$drop_one_max < 0,
         non_inferiority = cmp$hi < margin,
         stop("unknown rule ", rule))
}

#' A candidate against several references, each compared and decided on its own (C1 since config v3: superiority
#' over every baseline). One row per reference with its decision; `pass` is TRUE only when every one passes.
decide_against <- function(sc, candidate, references, time, rule, margin, metric = "ll", reps = 2000L, seed = 1L,
                           level = 0.95) {
  rows <- rbindlist(lapply(references, function(r) {
    cmp <- paired_comparison(sc, candidate, r, time, metric, reps, seed, level)$summary
    cmp[, pass := decide(cmp, rule, margin)]
  }))
  list(by_reference = rows, pass = nrow(rows) == length(references) && all(rows$pass))
}
