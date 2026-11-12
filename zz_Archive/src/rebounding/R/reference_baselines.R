# Step 03 of the rebounding manual: same-information-time prediction points, the release-or-later player geometry
# they allow, the reference baselines, and the leakage checks. Settings: config/experiment.yaml (step03).
#
# Information rule: a forecast at frame t reads tracking frames <= t only. A ball frame is "measured" when it is not
# the exact midpoint of its neighbours (the vendor fills single frames that way), which needs the next frame, so ball
# frame f becomes usable at f + 1. The hoop is the nominal one: the calibrated hoops of audit.R come from each game's
# own made shots, later ones included. Delivered player positions may already be smoothed by the vendor using later
# frames; that is outside this project's control and is stated as a limitation.
# Requires geometry.R (RIM_X, FPS).

#' Ball observations and the release ten's floor positions for one episode, in the attack frame (offence at +x).
#' @param raw cached raw window of the game (extract.R); `home_off`: TRUE when the home team is on offence.
#' @return list(ball = (frame, x, y, z, measured, usable_from), players = (frame, pid, off, x, y, det)).
episode_tracking <- function(raw, s, home_off, tol, delay, carry, to = s$rebound_frame) {
  ids <- as.integer(c(strsplit(s$release_off_ids, ";", fixed = TRUE)[[1]], strsplit(s$release_def_ids, ";", fixed = TRUE)[[1]]))
  w <- raw$frames[frame >= s$release_frame - 2L & frame <= to + 1L & !is.na(bx)][order(frame)]
  x <- w$bx * s$flip
  y <- w$by * s$flip
  z <- w$bz
  mid <- abs(x - (shift(x) + shift(x, -1L)) / 2) < tol & abs(z - (shift(z) + shift(z, -1L)) / 2) < tol &
    shift(w$frame) == w$frame - 1L & shift(w$frame, -1L) == w$frame + 1L
  ball <- data.table(frame = w$frame, x = x, y = y, z = z, measured = !(mid %in% TRUE), usable_from = w$frame + delay)
  pl <- raw$players[frame >= s$release_frame - carry & frame <= to & pid %in% ids,
                    .(frame, pid, off = home == home_off, x = x * s$flip, y = y * s$flip, det)]
  list(ball = ball[frame >= s$release_frame - 1L & frame <= to], players = pl[order(frame, pid)])
}

#' The causal rim-arrival trigger (config step03$times$rim_arrival): the first measured ball frame, guard frames
#' after release, near the nominal hoop at rim height and below an earlier measured high point; known at
#' f + delay. Uses only measured frames up to f, so frames after the trigger cannot move it. NA if it never fires.
rim_arrival_frame <- function(ball, release, th, delay) {
  m <- ball[measured == TRUE & frame >= release]
  if (!nrow(m)) return(NA_integer_)
  m[, peak := cummax(z)]
  hit <- m[frame >= release + th$guard_frames & sqrt((x - RIM_X)^2 + y^2) <= th$hoop_radius_ft &
             z >= th$z_min_ft & z <= th$z_max_ft & z <= peak - th$below_peak_ft]
  if (!nrow(hit)) NA_integer_ else hit$frame[1] + as.integer(delay)
}

#' Prediction points of one episode: release, the rim-arrival trigger and fixed times after it. A point is defined
#' only while the ball is loose (t < credited rebound frame) and when all ten players have a row within `carry`
#' frames up to t.
prediction_points <- function(tr, s, th) {
  ti <- th$times
  t_rim <- rim_arrival_frame(tr$ball, s$release_frame, ti$rim_arrival, th$information$ball_delay_frames)
  pts <- data.table(time_point = c("release", paste0("rim+", ti$post_rim_s)),
                    anchor = c("release", rep("rim_arrival", length(ti$post_rim_s))),
                    offset_s = c(0, unlist(ti$post_rim_s)))
  pts[, frame_idx := fifelse(anchor == "release", s$release_frame, t_rim + as.integer(round(offset_s * FPS)))]
  carry <- th$information$player_carry_frames
  pts[, players_ok := vapply(frame_idx, function(t) !is.na(t) &&
                               uniqueN(tr$players[frame <= t & frame >= t - carry]$pid) == 10L, NA)]
  pts[, reason := fifelse(is.na(frame_idx), "no rim arrival",
                          fifelse(ti$loose_only & frame_idx >= s$rebound_frame, "rebound at or before t",
                                  fifelse(!players_ok, "fewer than ten players", "")))]
  pts[, `:=`(episode_id = s$episode_id, defined = reason == "", rim_arrival_frame = t_rim)]
  pts[, .(episode_id, time_point, anchor, offset_s, frame_idx, rim_arrival_frame, defined, reason)]
}

#' Floor geometry of the ten players at frame t, from rows at or before t only: each player's last row within
#' `carry` frames. source_frame records the frame each value came from (assert_information_time() checks it).
features_at <- function(players, t, carry) {
  p <- players[frame <= t & frame >= t - carry]
  p <- p[p[, .I[which.max(frame)], by = pid]$V1]
  if (nrow(p) != 10L) return(NULL)
  p[, source_frame := frame][, frame := NULL]
  p[, dist_hoop := sqrt((x - RIM_X)^2 + y^2)]
  d <- as.matrix(dist(p[, .(x, y)]))
  opp <- outer(p$off, p$off, `!=`)
  d[!opp] <- Inf
  j <- max.col(-d, ties.method = "first")
  p[, `:=`(nearest_opp_dist = d[cbind(seq_len(.N), j)], inside_gap = dist_hoop[j] - dist_hoop)]
  p[, rank_all := frank(list(dist_hoop, pid), ties.method = "first")]
  p[, rank_side := frank(list(dist_hoop, pid), ties.method = "first"), by = off]
  p[, rank_inside := frank(list(-inside_gap, pid), ties.method = "first")]
  p[, role := paste0(fifelse(off, "off", "def"), rank_side)]
  p[order(-off, rank_side)]
}

#' Error if any feature value comes from a frame after its information time (a planted future feature fails here).
assert_information_time <- function(feat) {
  bad <- feat[source_frame > frame_idx]
  if (nrow(bad)) stop(sprintf("%d feature rows use frames after their information time (first: %s at %s)",
                              nrow(bad), bad$episode_id[1], bad$time_point[1]))
  invisible(TRUE)
}

BASELINES <- c("uniform", "side_prior", "role_prior", "nearest_hoop", "inside_rule", "role_prior_by_range",
               "nearest_hoop_by_range")
RANK_TABLES <- c(role_prior = "role", nearest_hoop = "rank_all", inside_rule = "rank_inside")
BY_RANGE <- c(role_prior_by_range = "role_prior", nearest_hoop_by_range = "nearest_hoop")   # config v2

#' Smoothed share of the training player rebounds won by each role / hoop-distance rank / inside rank.
rank_tables <- function(feat, lab, a) {
  player_lab <- lab[!outcome_id %in% c("team_off", "team_def")]
  win <- merge(feat[episode_id %in% player_lab$episode_id], player_lab[, .(episode_id, truth = outcome_id)],
               by = "episode_id")[as.character(pid) == truth]
  if (nrow(win) != nrow(player_lab)) stop("a credited player is missing from the training features")
  levels <- list(role = c(paste0("off", 1:5), paste0("def", 1:5)), rank_all = 1:10, rank_inside = 1:10)
  lapply(RANK_TABLES, function(col) {
    cnt <- table(factor(win[[col]], levels = levels[[col]]))
    setNames(as.numeric((cnt + a) / (sum(cnt) + length(cnt) * a)), names(cnt))
  })
}

#' Rank tables and smoothed outcome-type shares (offensive player, defensive player, team_off, team_def) of a
#' subset of training episodes: the per-range fits of the *_by_range baselines.
smoothed_fit <- function(feat, lab, a) {
  n_type <- c(sum(lab$y_off & !lab$outcome_id %in% c("team_off", "team_def")),
              sum(!lab$y_off & !lab$outcome_id %in% c("team_off", "team_def")),
              sum(lab$outcome_id == "team_off"), sum(lab$outcome_id == "team_def"))
  sh <- (n_type + a) / (nrow(lab) + 4 * a)
  list(rates = c(team_off = sh[3], team_def = sh[4]), tabs = rank_tables(feat, lab, a), n = nrow(lab))
}

#' Fit every reference baseline on the training episodes of one time point: team-award rates per side, player
#' shares per side, the smoothed rank tables, and (when `feat` has a shot_range column) the same tables and
#' smoothed outcome-type shares per shot range, with a pooled smoothed fit for a range absent from training.
#' @param feat features of one time point (episode_id, pid, role, rank_all, rank_inside, shot_range, ...).
fit_baselines <- function(feat, labels, train_ids, a) {
  lab <- labels[episode_id %in% train_ids]
  if (!nrow(lab)) stop("no training episodes")
  n <- nrow(lab)
  rates <- c(team_off = sum(lab$outcome_id == "team_off") / n, team_def = sum(lab$outcome_id == "team_def") / n)
  player_lab <- lab[!outcome_id %in% c("team_off", "team_def")]
  side <- c(off = sum(player_lab$y_off) / n, def = sum(!player_lab$y_off) / n)
  fit <- list(rates = rates, side = side, tabs = rank_tables(feat, lab, a), train_ids = sort(train_ids), n_train = n)
  if ("shot_range" %in% names(feat)) {
    rng <- unique(feat[, .(episode_id, shot_range)])
    fit$by_range <- sapply(sort(unique(rng$shot_range)), function(r) {
      l <- lab[episode_id %in% rng[shot_range == r]$episode_id]
      if (nrow(l)) smoothed_fit(feat, l, a) else NULL
    }, simplify = FALSE)
    fit$pooled_smoothed <- smoothed_fit(feat, lab, a)
  }
  fit
}

#' Long predictions (model, episode_id, outcome_id, probability) of every baseline for the given episodes.
predict_baselines <- function(fit, feat, ids, models = BASELINES) {
  f <- feat[episode_id %in% ids]
  if (is.null(fit$by_range)) models <- setdiff(models, names(BY_RANGE))
  players_mass <- 1 - sum(fit$rates)
  team <- data.table(outcome_id = c("team_off", "team_def"), probability = unname(fit$rates))
  rank_rows <- function(fr, tab, col, mass) fr[, .(episode_id, outcome_id = as.character(pid), probability = mass * tab[as.character(get(col))])]
  team_rows <- function(eps, rates) data.table(episode_id = rep(eps, each = 2L), outcome_id = c("team_off", "team_def"),
                                               probability = rep(unname(rates), length(eps)))
  # Each model's predictions: rank tables by shot range, or pooled tables with the team-rebound rows.
  rbindlist(lapply(models, function(m) {
    if (m %in% names(BY_RANGE)) {
      col <- RANK_TABLES[[BY_RANGE[[m]]]]
      return(cbind(model = m, rbindlist(lapply(split(f, by = "shot_range"), function(fr) {
        r <- fit$by_range[[fr$shot_range[1]]]
        if (is.null(r)) r <- fit$pooled_smoothed
        rbind(rank_rows(fr, r$tabs[[BY_RANGE[[m]]]], col, 1 - sum(r$rates)), team_rows(unique(fr$episode_id), r$rates))
      }))))
    }
    pl <- switch(m,
                 uniform = f[, .(episode_id, outcome_id = as.character(pid), probability = players_mass / 10)],
                 side_prior = f[, .(episode_id, outcome_id = as.character(pid),
                                    probability = fifelse(off, fit$side[["off"]], fit$side[["def"]]) / 5)],
                 rank_rows(f, fit$tabs[[m]], RANK_TABLES[[m]], players_mass))
    cbind(model = m, rbind(pl, team_rows(unique(f$episode_id), fit$rates)))
  }))
}

#' Outer-fold predictions of every baseline at one time point, plus the selected reference: per outer fold, the
#' baseline with the lowest inner leave-one-game-out log loss on the nine training games.
#' @return list(pred, selection) with fold and provenance columns.
fold_predictions <- function(feat, labels, fa, choice, a, floor) {
  ids <- unique(feat$episode_id)
  fa <- fa[episode_id %in% ids]
  out <- list()
  sel <- list()
  # Per outer fold: fit the baselines on the training games, predict the test game, and score the inner folds.
  for (k in sort(unique(fa$outer_fold))) {
    s <- fold_split(fa, k)
    fit <- fit_baselines(feat, labels, s$train, a)
    pr <- predict_baselines(fit, feat, s$test)
    inner <- rbindlist(lapply(s$inner, function(f) {
      fi <- fit_baselines(feat, labels, f$train, a)
      cbind(inner_game = f$game_id, predict_baselines(fi, feat, f$test))
    }))
    inner[, time_point := "inner"]
    isc <- score_episodes(inner[, !"inner_game"], choice, labels, floor)
    ill <- isc[, .(inner_log_loss = mean(ll)), by = model][match(intersect(BASELINES, model), model)]
    best <- ill$model[which.min(ill$inner_log_loss)]
    sel[[length(sel) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, ill, selected = ill$model == best)
    pr <- rbind(pr, pr[model == best][, model := "selected_reference"])
    out[[length(out) + 1L]] <- cbind(outer_fold = k, test_game = s$test_game, n_train = fit$n_train, pr)
  }
  list(pred = rbindlist(out), selection = rbindlist(sel))
}

#' Label-invariance check of a fit-and-predict function on one outer fold: predictions for the test game must not
#' change when the test game's labels are altered (every credited outcome moved to another outcome of its choice
#' set). TRUE when they are identical. A model that reads test labels fails it.
label_invariance <- function(fit_predict, feat, labels, choice, split) {
  alt <- copy(labels)
  test <- alt$episode_id %in% split$test
  ch <- merge(choice[episode_id %in% split$test], alt[, .(episode_id, truth = outcome_id)], by = "episode_id")
  moved <- ch[outcome_id != truth, .SD[1], by = episode_id]
  i <- match(moved$episode_id, alt$episode_id)
  alt[i, `:=`(outcome_id = moved$outcome_id, y_off = moved$side == "off")]
  stopifnot(all(alt$outcome_id[test] != labels$outcome_id[test]))
  a <- fit_predict(feat, labels, split)
  b <- fit_predict(feat, alt, split)
  setkeyv(a, c("model", "episode_id", "outcome_id"))
  setkeyv(b, c("model", "episode_id", "outcome_id"))
  isTRUE(all.equal(a, b, tolerance = 0))
}

#' Future-frame poisoning check of one episode: for each defined point, every raw tracking frame after its t is
#' corrupted (players moved, the ball parked bouncing at the hoop, where it would fire the trigger), the episode's
#' tracking rebuilt from the corrupted raw frames, and the trigger and features recomputed. TRUE when nothing known
#' at t changes.
poisoning_invariance <- function(raw, s, home_off, th, pts) {
  inf <- th$information
  ok <- TRUE
  clean <- episode_tracking(raw, s, home_off, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
  # At each defined time point, corrupt the tracking after it and check that the features do not change.
  for (i in which(pts$defined)) {
    t <- pts$frame_idx[i]
    bad <- list(frames = copy(raw$frames), players = copy(raw$players))
    bad$frames[frame > t, `:=`(bx = RIM_X * s$flip, by = 0, bz = 9 + 0.7 * (frame %% 3))]
    bad$players[frame > t, `:=`(x = x + 37, y = -y)]
    tr <- episode_tracking(bad, s, home_off, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
    if (pts$anchor[i] == "rim_arrival") {
      t_rim <- rim_arrival_frame(tr$ball, s$release_frame, th$times$rim_arrival, inf$ball_delay_frames)
      ok <- ok && identical(t_rim, pts$rim_arrival_frame[i])
    }
    ok <- ok && isTRUE(all.equal(features_at(clean$players, t, inf$player_carry_frames),
                                 features_at(tr$players, t, inf$player_carry_frames), tolerance = 0))
  }
  ok
}
