# Two-stage component models for EPV: a GAM carries the smooth structural part (court location,
# shot clock, passing-lane geometry) and gradient boosting adds the remaining features on top of the
# GAM's linear predictor. The number of boosting rounds is chosen by game-grouped inner validation and
# may come out as zero, in which case the component is the GAM alone. xFG follows the same pattern with
# one location GAM for all shots and a separate boosting stage for rim, midrange and three-point attempts.

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

#' Boosting on top of a fixed starting margin, with the number of rounds chosen by inner validation.
#' @param dt Training rows; must hold `game_id` and `features`.
#' @param y Numeric outcome, one per row of `dt`.
#' @param margin Starting prediction on the link scale, one per row of `dt`.
#' @param features Columns given to the boosting stage.
#' @param monotone Named vector of +1/-1 constraints for some of `features`.
#' @return list(bst, rounds); bst is NULL when the starting margin alone validates best.
fit_boost <- function(dt, y, margin, features, monotone = c(), binary = TRUE) {
  loss <- if (binary) log_loss else mse
  linkinv <- if (binary) plogis else identity
  signs <- ifelse(features %in% names(monotone), monotone[features], 0)
  params <- list(objective = if (binary) "binary:logistic" else "reg:squarederror", eta = 0.08, max_depth = 3,
                 min_child_weight = if (binary) 10 else 200, subsample = 0.8, colsample_bytree = 0.8, lambda = 5,
                 monotone_constraints = paste0("(", paste(signs, collapse = ","), ")"), nthread = 4)
  grow <- function(rows, rounds, from = NULL) {
    xgboost::xgb.train(params = params, data = boost_matrix(dt[rows], features, margin[rows], y[rows]),
                       nrounds = rounds, xgb_model = from, verbose = 0)
  }
  # held-out loss for the starting margin alone and for each candidate number of rounds
  curve <- vapply(inner_folds(dt$game_id), function(held) {
    tr <- which(!dt$game_id %in% held)
    te <- which(dt$game_id %in% held)
    test <- boost_matrix(dt[te], features, margin[te])
    out <- loss(linkinv(margin[te]), y[te])
    bst <- NULL
    for (i in seq_along(BOOST_ROUNDS)) {
      bst <- grow(tr, BOOST_ROUNDS[i] - c(0L, BOOST_ROUNDS)[i], bst)
      out <- c(out, loss(predict(bst, test), y[te]))
    }
    out
  }, numeric(length(BOOST_ROUNDS) + 1L))
  rounds <- c(0L, BOOST_ROUNDS)[which.min(rowMeans(curve))]
  list(bst = if (rounds > 0L) grow(seq_len(nrow(dt)), rounds), rounds = rounds)
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
  boost <- fit_boost(dt, dt$y__, margin, features, monotone, binary)
  list(gam = gam, bst = boost$bst, features = features, rounds = boost$rounds, binary = binary, linkinv = family$linkinv)
}

#' Predict a component: probability for binary components, mean for the value model.
#' @param stage "full" for GAM plus boosting, "gam" for the structural part alone.
predict_two_stage <- function(model, dt, stage = "full") {
  margin <- as.numeric(predict(model$gam, dt, type = "link"))
  if (stage == "gam" || is.null(model$bst)) return(model$linkinv(margin))
  predict(model$bst, boost_matrix(dt, model$features, margin))
}

# ---- component definitions -----------------------------------------------------------------------

RIM_ZONE <- 6            # ft from the hoop: a two from this close is a rim attempt (same cut as src/archetypes)
LOC_MIN_X <- 0           # backcourt positions are priced as shots from the half-court line
SHOT_RANGE <- 30         # ft: no shot option is priced from further out (8 of the 1,278 unfouled attempts)
ZONES <- c("rim", "mid", "three")
XFG_LOCATION <- ~ s(x, y, k = 30)
XFG_FEATURES <- c("loc_xfg", "def1", "def2", "n6", "between", "rim_def", "closing", "speed", "sc", "held", "drib")
XFG_MONOTONE <- c(loc_xfg = 1, def1 = 1, def2 = 1, n6 = -1, between = -1)
FOUL_FEATURES <- c("dist", "def1", "def2", "n6", "between", "closing", "speed", "sc", "held", "drib")
HOLDER_FEATURES <- c("dist", "x", "bound", "def1", "def2", "n6", "closing", "speed", "sc", "held", "drib", "in_air",
                     "ball_dist", "ahead", "def_spread")
VALUE_FEATURES <- c("dist", "x", "bound", "def1", "def2", "n6", "sv", "sv_other", "sc", "held", "drib", "ahead",
                    "def_spread")
PASS_FEATURES <- c("lane_margin", "lane_margin2", "len", "recv_def", "pass_def", "recv_hoop", "backcourt")

#' Rim, midrange or three-point attempt. `three` is the event flag for real shots and court geometry otherwise.
shot_zone <- function(dist, three) fifelse(three == 1L, "three", fifelse(dist <= RIM_ZONE, "rim", "mid"))

#' Shot rows with the location model's inputs and the zone that picks the context model.
shot_rows <- function(dt) copy(dt)[, c("x", "zone") := .(pmax(x, LOC_MIN_X), shot_zone(dist, three))]

#' Fit xFG on unfouled attempts: a location GAM (one joint smooth of the court), then for each zone a context
#' model that takes the location probability as a feature beside the defensive and ball context. Each zone's
#' boosting starts from that zone's make rate: starting from the location model instead was worse on held-out
#' games (docs/project/decision_log.md), because one smooth blurs the drop in make rate at the edge of the rim area.
#' @return list(loc, zones); each zone is list(bst, rounds, rate).
fit_xfg <- function(shots, location = XFG_LOCATION) {
  dt <- shot_rows(shots)[, y__ := as.numeric(made)]
  loc <- mgcv::gam(update(location, y__ ~ .), family = binomial(), data = dt, method = "REML")
  dt[, loc_xfg := as.numeric(predict(loc, dt, type = "response"))]
  list(loc = loc, zones = lapply(setNames(ZONES, ZONES), function(z) {
    rows <- which(dt$zone == z)
    rate <- mean(dt$y__[rows])
    c(fit_boost(dt[rows], dt$y__[rows], rep(qlogis(rate), length(rows)), XFG_FEATURES, XFG_MONOTONE), list(rate = rate))
  }))
}

#' Make probability of an unfouled attempt.
#' @param stage "full" for the zone context models, "location" for the location model alone, "rate" for
#'   each zone's make rate.
predict_xfg <- function(m, dt, stage = "full") {
  dt <- shot_rows(dt)
  dt[, loc_xfg := as.numeric(predict(m$loc, dt, type = "response"))]
  if (stage == "location") return(dt$loc_xfg)
  p <- unname(vapply(m$zones, `[[`, 0, "rate")[dt$zone])
  if (stage == "rate") return(p)
  for (z in ZONES) {
    rows <- which(dt$zone == z)
    if (length(rows) && !is.null(m$zones[[z]]$bst)) p[rows] <- predict(m$zones[[z]]$bst, boost_matrix(dt[rows], XFG_FEATURES, qlogis(p[rows])))
  }
  p
}

#' How xFG is built up for each shot, for display: a baseline for the shot's zone, then what each context
#' feature adds, then the result. A feature's effect is its Shapley contribution to the context model's
#' log-odds (xgboost's predcontrib), rescaled so that the effects of one shot sum to xfg - base on the
#' probability scale. `base` is the context model's average prediction over its training shots: the zone's
#' make rate, shifted slightly by the trees' mean. Where a zone's context model has no trees, base is the
#' make rate and every effect is zero.
#' @return data.table(zone, loc_xfg, rate, rounds, base, xfg, eff_<feature> for each of XFG_FEATURES).
explain_xfg <- function(m, dt) {
  dt <- shot_rows(dt)
  dt[, loc_xfg := as.numeric(predict(m$loc, dt, type = "response"))]
  rate <- unname(vapply(m$zones, `[[`, 0, "rate")[dt$zone])
  p <- base <- rate
  phi <- matrix(0, nrow(dt), length(XFG_FEATURES), dimnames = list(NULL, paste0("eff_", XFG_FEATURES)))
  for (z in ZONES) {
    rows <- which(dt$zone == z)
    if (!length(rows) || is.null(m$zones[[z]]$bst)) next
    d <- boost_matrix(dt[rows], XFG_FEATURES, qlogis(rate[rows]))
    contrib <- predict(m$zones[[z]]$bst, d, predcontrib = TRUE)
    p[rows] <- predict(m$zones[[z]]$bst, d)
    base[rows] <- plogis(contrib[, ncol(contrib)])
    phi[rows, ] <- contrib[, seq_along(XFG_FEATURES), drop = FALSE]
  }
  moved <- rowSums(phi)
  per_logit <- fifelse(abs(moved) > 1e-6, (p - base) / moved, base * (1 - base))
  cbind(data.table(zone = dt$zone, loc_xfg = dt$loc_xfg, rate = rate,
                   rounds = unname(vapply(m$zones, `[[`, 0L, "rounds")[dt$zone]), base = base, xfg = p),
        as.data.table(phi * per_logit))
}

#' Fit the shot-side components on a set of training shots, plus the constants the shot value needs.
#' The offensive-rebound rate after an unfouled miss is one constant until it is modelled spatially.
fit_shot_models <- function(shots, ft, orb) {
  list(xfg = fit_xfg(shots[fouled == FALSE]),
       foul = fit_two_stage(shots, "fouled", ~ s(dist, k = 6), binomial(), FOUL_FEATURES, c(def1 = -1)),
       oreb = shots[fouled == FALSE & made == FALSE & !is.na(oreb), mean(oreb)], ft = mean(ft$made),
       and1 = shots[fouled == TRUE, mean(made)], orb_value = mean(orb$pts))
}

#' Expected points if this player shot now: unfouled make, second chance after a miss, and free throws.
#' Beyond SHOT_RANGE the value is 0: almost no attempts exist there, so the shot is not offered as an option.
#' @return data.table(sv, xfg, pfoul, poreb).
shot_value <- function(m, dt) {
  dt <- copy(dt)[, dist := pmin(dist, 60)]
  xfg <- predict_xfg(m$xfg, dt)
  pfoul <- predict_two_stage(m$foul, dt)
  poreb <- m$oreb
  pts <- 2 + dt$three
  data.table(sv = fifelse(dt$dist > SHOT_RANGE, 0, (1 - pfoul) * (xfg * pts + (1 - xfg) * poreb * m$orb_value) +
                            pfoul * (m$and1 * (pts + m$ft) + (1 - m$and1) * pts * m$ft)),
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
