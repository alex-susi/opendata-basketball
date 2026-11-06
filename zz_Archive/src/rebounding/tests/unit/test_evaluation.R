# Step 03: folds, scoring harness, causal triggers, features and leakage checks on synthetic data.

source(file.path(here, "R", "folds.R"))
source(file.path(here, "R", "metrics.R"))
source(file.path(here, "R", "reference_baselines.R"))
th <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))$step03

# Synthetic eligible episodes: `n_games` games of `per_game` episodes, ten players each, credited outcomes drawn
# with a fixed seed (players near the hoop more likely), and floor positions at release in the attack frame.
synthetic <- function(n_games = 3L, per_game = 8L, seed = 7L) {
  set.seed(seed)
  el <- rbindlist(lapply(seq_len(n_games), function(g) rbindlist(lapply(seq_len(per_game), function(i) {
    ids <- (g * 1000L + i * 20L) + 1:10
    data.table(episode_id = sprintf("shot-%d-%d", g, i), game_id = 100L + g,
               release_off_ids = paste(ids[1:5], collapse = ";"), release_def_ids = paste(ids[6:10], collapse = ";"))
  }))))
  feat <- rbindlist(lapply(seq_len(nrow(el)), function(k) {
    ids <- as.integer(c(strsplit(el$release_off_ids[k], ";")[[1]], strsplit(el$release_def_ids[k], ";")[[1]]))
    pl <- data.table(frame = 100L, pid = ids, off = rep(c(TRUE, FALSE), each = 5), x = RIM_X - runif(10, 2, 25),
                     y = runif(10, -15, 15), det = 1L)
    cbind(episode_id = el$episode_id[k], time_point = "release", frame_idx = 100L, features_at(pl, 100L, 5L))
  }))
  feat <- merge(feat, data.table(episode_id = el$episode_id, shot_range = sample(c("rim", "mid", "three"), nrow(el), TRUE)),
                by = "episode_id")
  win <- feat[, .(pid = sample(pid, 1, prob = 1 / dist_hoop)), by = episode_id]
  el <- merge(el, win, by = "episode_id")
  team <- runif(nrow(el)) < 0.12
  win_off <- feat$off[match(paste(el$episode_id, el$pid), paste(feat$episode_id, feat$pid))]
  el[, credited_outcome := fifelse(team, fifelse(runif(.N) < 0.5, "off team award", "def team award"),
                                   fifelse(win_off, "off player", "def player"))]
  el[, `:=`(rebounder_id = fifelse(team, NA_integer_, pid), side = fifelse(grepl("^off", credited_outcome), "off", "def"))]
  list(el = el, feat = feat, labels = episode_labels(el), choice = choice_sets(el),
       fa = fold_assignment(el, data.table(game_id = unique(el$game_id), date = sprintf("2026-0%d-01", seq_len(n_games)))))
}

test_that("log loss, Brier, pessimistic ranks and the OREB score match hand calculations", {
  el <- data.table(episode_id = c("e1", "e2"), game_id = 1L, release_off_ids = "1;2;3;4;5", release_def_ids = "6;7;8;9;10",
                   credited_outcome = c("def player", "off team award"), rebounder_id = c(6L, NA), side = c("def", "off"))
  choice <- choice_sets(el); labels <- episode_labels(el)
  expect_equal(labels$outcome_id, c("6", "team_off"))
  uni <- choice[, .(model = "u", time_point = "t", episode_id, outcome_id, probability = 1 / 12)]
  tie <- copy(uni)[, model := "tie"][episode_id == "e1", probability := fifelse(outcome_id %in% c("6", "7"), 0.2, 0.06)]
  expect_true(all(check_predictions(rbind(uni, tie), choice)$ok))
  sc <- score_episodes(rbind(uni, tie), choice, labels)
  u1 <- sc[model == "u" & episode_id == "e1"]
  expect_equal(u1$ll, log(12)); expect_equal(u1$brier, 132 / 144); expect_equal(u1$rank, 12)
  expect_false(u1$top3); expect_equal(u1$p_off, 0.5); expect_equal(u1$team_ll, log(2)); expect_false(u1$y_off)
  t1 <- sc[model == "tie" & episode_id == "e1"]
  expect_equal(t1$rank, 2); expect_false(t1$top1); expect_true(t1$top3); expect_equal(t1$ll, -log(0.2))
  expect_true(sc[model == "u" & episode_id == "e2"]$y_off)
})

test_that("invalid prediction tables are caught", {
  s <- synthetic(1L, 2L)
  p <- s$choice[, .(model = "m", time_point = "t", episode_id, outcome_id, probability = 1 / 12)]
  bad <- list(missing = p[-1], extra = rbind(p, p[1][, outcome_id := "999"]), dup = rbind(p[-2], p[1]),
              negative = copy(p)[1:2, probability := c(-0.01, 1 / 12 + 0.01)],
              unnormalised = copy(p)[1, probability := 0.2], nan = copy(p)[1, probability := NaN])
  for (b in names(bad)) expect_false(all(check_predictions(bad[[b]], s$choice)$ok), info = b)
  expect_true(all(check_predictions(p, s$choice)$ok))
})

test_that("leave-one-game-out folds keep each episode in one test fold and its game out of training", {
  s <- synthetic(4L, 5L)
  expect_true(all(check_folds(s$fa)$pass))
  for (k in 1:4) {
    f <- fold_split(s$fa, k)
    expect_false(f$test_game %in% s$fa[episode_id %in% f$train]$game_id)
    expect_length(f$inner, 3L)
    expect_false(any(vapply(f$inner, function(i) f$test_game %in% s$fa[episode_id %in% c(i$train, i$test)]$game_id, NA)))
  }
  expect_equal(s$fa[order(outer_fold)]$game_id[1], 101L)   # fold 1 is the earliest game
  broken <- copy(s$fa)[1, outer_fold := 2L]
  expect_false(all(check_folds(broken)$pass))
})

test_that("baselines are valid, use training games only, and ignore candidate order", {
  s <- synthetic()
  r <- fold_predictions(s$feat, s$labels, s$fa, s$choice, 0.5, 1e-12)
  r$pred[, time_point := "release"]
  expect_true(all(check_predictions(r$pred, s$choice)$ok))
  expect_setequal(unique(r$pred$model), c(BASELINES, "selected_reference"))
  expect_equal(r$selection[, sum(selected), by = outer_fold]$V1, rep(1L, 3))
  shuffled <- s$feat[sample(.N)]
  r2 <- fold_predictions(shuffled, s$labels, s$fa, s$choice, 0.5, 1e-12)
  r2$pred[, time_point := "release"]
  key <- c("model", "episode_id", "outcome_id")
  expect_equal(setkeyv(r2$pred, key)$probability, setkeyv(r$pred, key)$probability)
  fp <- function(f, lab, split) predict_baselines(fit_baselines(f, lab, split$train, 0.5), f, split$test)
  expect_true(label_invariance(fp, s$feat, s$labels, s$choice, fold_split(s$fa, 2L)))
  leaky <- function(f, lab, split) {
    p <- merge(fp(f, lab, split), lab[, .(episode_id, truth = outcome_id)], by = "episode_id")
    p[, probability := 0.5 * probability + 0.5 * (outcome_id == truth)][, truth := NULL][]
  }
  expect_false(label_invariance(leaky, s$feat, s$labels, s$choice, fold_split(s$fa, 2L)))
  fit <- fit_baselines(s$feat, s$labels, fold_split(s$fa, 1L)$train, 0.5)
  expect_equal(sum(fit$rates) + sum(fit$side), 1)
  expect_true(all(vapply(fit$tabs, function(t) abs(sum(t) - 1) < 1e-12, NA)))
})

test_that("by-range baselines learn each shot range's own table and fall back to the pooled fit", {
  s <- synthetic(3L, 30L, seed = 3L)
  # rim misses: the closest player always gets it; threes: the fifth closest; no team awards on rim misses
  f <- s$feat
  rk <- f[, .(episode_id, pid = as.character(pid), rank_all, shot_range)]
  want <- rk[(shot_range == "rim" & rank_all == 1L) | (shot_range != "rim" & rank_all == 5L)]
  lab <- copy(s$labels)
  lab[, outcome_id := as.character(want$pid[match(episode_id, want$episode_id)])]
  lab[, y_off := f$off[match(paste(episode_id, outcome_id), paste(f$episode_id, f$pid))]]
  train <- fold_split(s$fa, 1L)$train
  fit <- fit_baselines(f, lab, train, 0.5)
  expect_equal(unname(which.max(fit$by_range$rim$tabs$nearest_hoop)), 1L)
  expect_equal(unname(which.max(fit$by_range$three$tabs$nearest_hoop)), 5L)
  expect_true(all(fit$by_range$rim$rates > 0))                      # smoothed: no zero team mass
  p <- predict_baselines(fit, f, fold_split(s$fa, 1L)$test)
  expect_true(all(abs(p[, sum(probability), by = .(model, episode_id)]$V1 - 1) < 1e-12))
  top <- p[model == "nearest_hoop_by_range"][order(-probability)][, .SD[1], by = episode_id]
  top <- merge(top, rk, by.x = c("episode_id", "outcome_id"), by.y = c("episode_id", "pid"))
  top[, outcome_id := NULL]
  expect_true(all(top[shot_range == "rim"]$rank_all == 1L) && all(top[shot_range == "three"]$rank_all == 5L))
  # a range absent from training uses the pooled smoothed fit
  no_mid <- fit_baselines(f, lab, setdiff(train, f[shot_range == "mid"]$episode_id), 0.5)
  expect_null(no_mid$by_range$mid)
  pm <- predict_baselines(no_mid, f, f[shot_range == "mid"]$episode_id[1:10], "nearest_hoop_by_range")
  expect_true(all(abs(pm[, sum(probability), by = episode_id]$V1 - 1) < 1e-12))
  expect_equal(pm[outcome_id == "team_off"]$probability[1], unname(no_mid$pooled_smoothed$rates["team_off"]))
  # without a shot_range column the by-range baselines are simply not fitted
  plain <- fit_baselines(f[, !"shot_range"], lab, train, 0.5)
  expect_setequal(unique(predict_baselines(plain, f[, !"shot_range"], train[1:3])$model), setdiff(BASELINES, names(BY_RANGE)))
})

test_that("a feature read after its information time is rejected", {
  s <- synthetic(1L, 2L)
  expect_true(assert_information_time(s$feat))
  planted <- copy(s$feat)[1, source_frame := frame_idx + 1L]
  expect_error(assert_information_time(planted), "after their information time")
})

# A camera-frame raw window for one episode: a shot released at frame 100 from (20, 3) toward the attacked hoop,
# rising to about 14 ft and coming down at the rim at about frame 125, then bouncing out; ten players standing still.
synthetic_raw <- function(flip, fill_midpoints = FALSE) {
  f <- 90:180
  t <- pmax(0, (f - 100) / FPS)
  g <- 28.3
  x <- 20 + (RIM_X - 1 - 20) * t; y <- 3 - 3 * t; z <- 7 + (10.3 - 7 + 0.5 * g) * t - 0.5 * g * t^2
  out <- f > 125
  t2 <- (f[out] - 125) / FPS
  x[out] <- RIM_X - 1 - 9 * t2; y[out] <- 2 * t2; z[out] <- 10.3 + 5 * t2 - 0.5 * g * t2^2
  if (fill_midpoints) { odd <- which(f %% 2 == 1 & f > 90 & f < 180); x[odd] <- (x[odd - 1] + x[odd + 1]) / 2
                        y[odd] <- (y[odd - 1] + y[odd + 1]) / 2; z[odd] <- (z[odd - 1] + z[odd + 1]) / 2 }
  frames <- data.table(frame = f, bx = flip * x, by = flip * y, bz = z)
  px <- c(RIM_X - 3, RIM_X - 10, RIM_X - 22, RIM_X - 6, RIM_X - 15, RIM_X - 2, RIM_X - 8, RIM_X - 20, RIM_X - 5, RIM_X - 12)
  py <- c(2, -8, 0, 12, -14, -1, -6, 3, 9, -10)
  players <- CJ(frame = f, k = 1:10)[, `:=`(pid = 500L + k, home = k <= 5, x = flip * px[k], y = flip * py[k], det = 1L)]
  s <- data.table(episode_id = "e", release_frame = 100L, rebound_frame = 140L, flip = flip,
                  release_off_ids = paste(501:505, collapse = ";"), release_def_ids = paste(506:510, collapse = ";"))
  list(raw = list(frames = frames, players = players), s = s)
}

test_that("the rim-arrival trigger is causal, fires where the rule says, and skips filled-in frames", {
  inf <- th$information
  r <- synthetic_raw(1)
  tr <- episode_tracking(r$raw, r$s, TRUE, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
  ra <- th$times$rim_arrival
  b <- tr$ball[frame >= 100]
  b[, peak := cummax(z)]
  first <- b[frame >= 100 + ra$guard_frames & sqrt((x - RIM_X)^2 + y^2) <= ra$hoop_radius_ft & z >= ra$z_min_ft &
               z <= ra$z_max_ft & z <= peak - ra$below_peak_ft]$frame[1]
  t_rim <- rim_arrival_frame(tr$ball, 100L, ra, inf$ball_delay_frames)
  expect_equal(t_rim, first + 1L)
  expect_true(t_rim > 110L && t_rim <= 127L)
  pts <- prediction_points(tr, r$s, th)
  expect_equal(pts[time_point == "rim+0.2"]$frame_idx, t_rim + 5L)
  expect_true(nrow(pts[frame_idx >= 140L]) > 0 && all(pts[frame_idx >= 140L]$reason == "rebound at or before t"))
  expect_true(all(pts[frame_idx < 140L]$defined))
  expect_true(poisoning_invariance(r$raw, r$s, TRUE, th, pts))
  # filled-in (midpoint) frames are not measurements and never fire the trigger
  rf <- synthetic_raw(1, fill_midpoints = TRUE)
  trf <- episode_tracking(rf$raw, rf$s, TRUE, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
  expect_true(all(!trf$ball[frame > 100 & frame < 179 & frame %% 2 == 1]$measured))
  t_f <- rim_arrival_frame(trf$ball, 100L, ra, inf$ball_delay_frames)
  expect_equal((t_f - 1L) %% 2, 0)
})

test_that("triggers and features are the same in both attack directions", {
  inf <- th$information
  a <- synthetic_raw(1); b <- synthetic_raw(-1)
  ta <- episode_tracking(a$raw, a$s, TRUE, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
  tb <- episode_tracking(b$raw, b$s, TRUE, inf$keyframe_tol_ft, inf$ball_delay_frames, inf$player_carry_frames)
  expect_equal(prediction_points(ta, a$s, th), prediction_points(tb, b$s, th))
  fa <- features_at(ta$players, 120L, 5L); fb <- features_at(tb$players, 120L, 5L)
  expect_equal(fa, fb)
  expect_equal(fa[pid == 506]$rank_all, 1L)               # the defender 2 ft from the hoop is nearest
  expect_true(fa[pid == 506]$inside_gap > 0)
})

test_that("a player missing at t uses his last row within the carry window, else the point is undefined", {
  r <- synthetic_raw(1)
  r$raw$players <- r$raw$players[!(pid == 503L & frame > 115L)]
  expect_equal(features_at(r$raw$players[, .(frame, pid, off = home, x, y, det)], 118L, 5L)[pid == 503L]$source_frame, 115L)
  expect_null(features_at(r$raw$players[, .(frame, pid, off = home, x, y, det)], 121L, 5L))
})

test_that("paired comparisons are reproducible with a seed and the decision rules apply as written", {
  s <- synthetic(5L, 10L)
  r <- fold_predictions(s$feat, s$labels, s$fa, s$choice, 0.5, 1e-12)
  r$pred[, time_point := "release"]
  sc <- score_episodes(r$pred[, .(model, time_point, episode_id, outcome_id, probability)], s$choice, s$labels)
  a <- paired_comparison(sc, "nearest_hoop", "uniform", "release", "ll", 200L, 11L)
  b <- paired_comparison(sc, "nearest_hoop", "uniform", "release", "ll", 200L, 11L)
  expect_identical(a, b)
  expect_equal(a$summary$games, 5L)
  expect_equal(a$summary$mean_diff, weighted.mean(a$by_game$mean_diff, a$by_game$episodes))
  expect_true(a$summary$lo <= a$summary$boot_lo && a$summary$hi >= a$summary$game_t_hi)
  self <- paired_comparison(sc, "uniform", "uniform", "release", "ll", 50L, 1L)$summary
  expect_equal(self$mean_diff, 0)
  expect_false(decide(self, "superiority", 0.02))
  expect_true(decide(self, "non_inferiority", 0.02))
  expect_error(paired_comparison(sc[!(model == "uniform" & episode_id == sc$episode_id[1])], "nearest_hoop", "uniform",
                                 "release", "ll", 10L, 1L), "same episodes")
  # a candidate that puts 60% on the credited outcome beats every baseline; it cannot beat itself
  strong <- merge(r$pred[model == "uniform"], s$labels[, .(episode_id, truth = outcome_id)], by = "episode_id")
  strong[, `:=`(model = "strong", probability = 0.4 * probability + 0.6 * (outcome_id == truth))]
  sc2 <- rbind(sc, score_episodes(strong[, .(model, time_point, episode_id, outcome_id, probability)], s$choice, s$labels))
  all_refs <- decide_against(sc2, "strong", c(BASELINES, "selected_reference"), "release", "superiority", 0.02, reps = 200L)
  expect_true(all_refs$pass)
  expect_equal(nrow(all_refs$by_reference), length(BASELINES) + 1L)
  with_self <- decide_against(sc2, "strong", c("uniform", "strong"), "release", "superiority", 0.02, reps = 200L)
  expect_false(with_self$pass)
  expect_equal(with_self$by_reference$pass, c(TRUE, FALSE))
})
