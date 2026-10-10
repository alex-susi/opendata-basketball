# Two-stage component models for EPV: a GAM carries the smooth structural part (court location,
# shot clock, passing-lane geometry) and gradient boosting adds the remaining features on top of the
# GAM's linear predictor. The number of boosting rounds is chosen by game-grouped inner validation and
# may come out as zero, in which case the component is the GAM alone.

BOOST_ROUNDS <- c(40L, 120L, 300L)

#' Split a set of games into k groups for inner validation.
inner_folds <- function(games, k = 3L) {
  games <- sort(unique(games))
  split(games, rep_len(seq_len(k), length(games)))
}

log_loss <- function(p, y) -mean(y * log(pmax(p, 1e-9)) + (1 - y) * log(pmax(1 - p, 1e-9)))
mse <- function(p, y) mean((p - y)^2)

#' Area under the ROC curve from ranks.
auc <- function(p, y) {
  r <- rank(p)
  (sum(r[y == 1]) - sum(y == 1) * (sum(y == 1) + 1) / 2) / (sum(y == 1) * sum(y == 0))
}

#' An xgboost matrix whose starting point is the GAM's linear predictor.
boost_matrix <- function(dt, features, margin, label = NULL) {
  x <- as.matrix(dt[, lapply(.SD, as.numeric), .SDcols = features])
  d <- xgboost::xgb.DMatrix(x, missing = NA)
  xgboost::setinfo(d, "base_margin", margin)
  if (!is.null(label)) xgboost::setinfo(d, "label", as.numeric(label))
  d
}

#' Fit one component.
#' @param dt Training rows; must hold `y`, `game_id`, the GAM terms and `features`.
#' @param formula One-sided GAM formula for the structural part.
#' @param family binomial() or gaussian().
#' @param features Columns given to the boosting stage.
#' @param monotone Named vector of +1/-1 constraints for some of `features`.
#' @return list(gam, bst, features, rounds, binary).
fit_two_stage <- function(dt, y, formula, family, features, monotone = c()) {
  dt <- copy(dt)
  set(dt, j = "y__", value = as.numeric(dt[[y]]))
  full <- update(formula, y__ ~ .)
  gam <- if (nrow(dt) > 20000L) mgcv::bam(full, family = family, data = dt, discrete = TRUE) else
    mgcv::gam(full, family = family, data = dt, method = "REML")
  margin <- as.numeric(predict(gam, dt, type = "link"))
  binary <- family$family == "binomial"
  loss <- if (binary) log_loss else mse
  signs <- ifelse(features %in% names(monotone), monotone[features], 0)
  params <- list(objective = if (binary) "binary:logistic" else "reg:squarederror", eta = 0.08, max_depth = 3,
                 min_child_weight = if (binary) 10 else 200, subsample = 0.8, colsample_bytree = 0.8, lambda = 5,
                 monotone_constraints = paste0("(", paste(signs, collapse = ","), ")"), nthread = 4)
  grow <- function(rows, rounds, from = NULL) {
    xgboost::xgb.train(params = params, data = boost_matrix(dt[rows], features, margin[rows], dt$y__[rows]),
                       nrounds = rounds, xgb_model = from, verbose = 0)
  }
  # held-out loss for the GAM alone and for each candidate number of rounds
  curve <- vapply(inner_folds(dt$game_id), function(held) {
    tr <- which(!dt$game_id %in% held)
    te <- which(dt$game_id %in% held)
    test <- boost_matrix(dt[te], features, margin[te])
    out <- loss(family$linkinv(margin[te]), dt$y__[te])
    bst <- NULL
    for (i in seq_along(BOOST_ROUNDS)) {
      bst <- grow(tr, BOOST_ROUNDS[i] - c(0L, BOOST_ROUNDS)[i], bst)
      out <- c(out, loss(predict(bst, test), dt$y__[te]))
    }
    out
  }, numeric(length(BOOST_ROUNDS) + 1L))
  rounds <- c(0L, BOOST_ROUNDS)[which.min(rowMeans(curve))]
  list(gam = gam, bst = if (rounds > 0L) grow(seq_len(nrow(dt)), rounds), features = features, rounds = rounds,
       binary = binary, linkinv = family$linkinv)
}

#' Predict a component: probability for binary components, mean for the value model.
#' @param stage "full" for GAM plus boosting, "gam" for the structural part alone.
predict_two_stage <- function(model, dt, stage = "full") {
  margin <- as.numeric(predict(model$gam, dt, type = "link"))
  if (stage == "gam" || is.null(model$bst)) return(model$linkinv(margin))
  predict(model$bst, boost_matrix(dt, model$features, margin))
}

# ---- component definitions -----------------------------------------------------------------------

SHOT_FEATURES <- c("dist", "three", "def1", "def2", "n6", "between", "rim_def", "closing", "speed", "sc", "held", "drib")
HOLDER_FEATURES <- c("dist", "x", "bound", "def1", "def2", "n6", "closing", "speed", "sc", "held", "drib", "in_air",
                     "ball_dist", "ahead", "def_spread")
VALUE_FEATURES <- c("dist", "x", "bound", "def1", "def2", "n6", "sv", "sv_other", "sc", "held", "drib", "ahead",
                    "def_spread")
PASS_FEATURES <- c("lane_margin", "lane_margin2", "len", "recv_def", "pass_def", "recv_hoop", "backcourt")

#' Fit the shot-side components on a set of training shots, plus the constants the shot value needs.
fit_shot_models <- function(shots, ft, orb) {
  list(xfg = fit_two_stage(shots[fouled == FALSE], "made", ~ s(dist, k = 8) + s(angle, k = 5), binomial(), SHOT_FEATURES,
                           c(def1 = 1, def2 = 1, n6 = -1, between = -1)),
       foul = fit_two_stage(shots, "fouled", ~ s(dist, k = 6), binomial(), setdiff(SHOT_FEATURES, c("three", "rim_def")),
                            c(def1 = -1)),
       oreb = oreb_rates(shots), ft = mean(ft$made), and1 = shots[fouled == TRUE, mean(made)], orb_value = mean(orb$pts))
}

#' Offensive-rebound rate after an unfouled miss, for twos and for threes.
#' A fitted rebound model (shot distance, bodies near the rim) did not beat the base rate on held-out games
#' (docs/project/decision_log.md), so the shot value uses these two rates until a model earns its place.
oreb_rates <- function(shots) {
  misses <- shots[fouled == FALSE & made == FALSE & !is.na(oreb)]
  c(two = misses[three == 0, mean(oreb)], three = misses[three == 1, mean(oreb)])
}

#' Expected points if this player shot now: unfouled make, second chance after a miss, and free throws.
#' @return data.table(sv, xfg, pfoul, poreb).
shot_value <- function(m, dt) {
  dt <- copy(dt)[, dist := pmin(dist, 60)]
  xfg <- predict_two_stage(m$xfg, dt)
  pfoul <- predict_two_stage(m$foul, dt)
  poreb <- unname(m$oreb[dt$three + 1L])
  pts <- 2 + dt$three
  data.table(sv = (1 - pfoul) * (xfg * pts + (1 - xfg) * poreb * m$orb_value) +
               pfoul * (m$and1 * (pts + m$ft) + (1 - m$and1) * pts * m$ft),
             xfg = xfg, pfoul = pfoul, poreb = poreb)
}

fit_pass_model <- function(passes) {
  fit_two_stage(passes, "turnover", ~ s(lane_margin, k = 4) + s(len, k = 4), binomial(), PASS_FEATURES,
                c(lane_margin = -1, lane_margin2 = -1, recv_def = -1, pass_def = -1))
}

#' Fit the three state models on holder rows: 2-second turnover hazard, turnover before the possession
#' ends, and points scored in the rest of the possession.
fit_state_models <- function(holders) {
  list(haz = fit_two_stage(holders, "haz_y", ~ s(x, ay, k = 25) + s(sc, k = 6), binomial(), HOLDER_FEATURES,
                           c(def1 = -1, def2 = -1)),
       rop = fit_two_stage(holders, "rop_y", ~ s(x, ay, k = 25) + s(sc, k = 6), binomial(), HOLDER_FEATURES,
                           c(def1 = -1, def2 = -1)),
       value = fit_two_stage(holders, "pts_y", ~ s(dist, k = 6) + s(sc, k = 6) + s(sv, k = 6) + s(sv_other, k = 6) +
                               s(ahead, k = 4), gaussian(), VALUE_FEATURES, c(sv = 1, sv_other = 1)))
}
