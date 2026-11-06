# Two-stage component models for EPV: a GAM carries the smooth structural part (court location,
# shot clock, passing-lane geometry) and gradient boosting adds the remaining features on top of the
# GAM's linear predictor. The number of boosting rounds is chosen by game-grouped inner validation and
# may come out as zero, in which case the component is the GAM alone. xFG follows the same pattern with
# one location GAM for all shots and a separate boosting stage for rim attempts and for jump shots; jump
# shots also carry a closest-defender slope and a catch-and-shoot effect set from the season aggregates
# (R/season.R).

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
DEF_CAP <- 10           # ft: a closest defender further from a jump shooter than this counts as this far
CATCH_SECONDS <- 1.5     # s on the ball at release: no more than this is a catch-and-shoot attempt
ZONES <- c("rim", "jump")
XFG_LOCATION <- ~ s(x, y, k = 30)
XFG_FEATURES <- c("loc_xfg", "def1", "def2", "n6", "between", "rim_def", "closing", "speed", "sc", "held", "drib")
JUMP_FEATURES <- setdiff(XFG_FEATURES, "rim_def")   # the defender nearest the hoop is not an input for jump shots
XFG_MONOTONE <- c(loc_xfg = 1, def1 = 1, def2 = 1, n6 = -1, between = -1)
FOUL_FEATURES <- c("dist", "def1", "def2", "n6", "between", "closing", "speed", "sc", "held", "drib")
HOLDER_FEATURES <- c("dist", "x", "bound", "def1", "def2", "n6", "closing", "speed", "sc", "held", "drib", "in_air",
                     "ball_dist", "ahead", "def_spread")
VALUE_FEATURES <- c("dist", "x", "bound", "def1", "def2", "n6", "sv", "sv_other", "sc", "held", "drib", "ahead",
                    "def_spread")
PASS_FEATURES <- c("lane_margin", "lane_margin2", "len", "recv_def", "pass_def", "recv_hoop", "backcourt")

#' Which context model prices a shot: a two from within RIM_ZONE of the hoop is a rim attempt, every other
#' shot a jump shot. `three` is the event flag for real shots and court geometry otherwise.
shot_zone <- function(dist, three) fifelse(three == 0L & dist <= RIM_ZONE, "rim", "jump")

#' Rim, midrange or three-point attempt: jump shots split by their value, for reporting and display.
shot_area <- function(dist, three) fifelse(three == 1L, "three", fifelse(dist <= RIM_ZONE, "rim", "mid"))

#' Inputs of a zone's context model.
zone_features <- function(z) if (z == "rim") XFG_FEATURES else JUMP_FEATURES

#' Shot rows with the location model's inputs and the zone that picks the context model.
shot_rows <- function(dt) copy(dt)[, c("x", "zone") := .(pmax(x, LOC_MIN_X), shot_zone(dist, three))]

#' Catch-and-shoot attempt: released within CATCH_SECONDS of the shooter's touch starting (the vendor's rule
#' on its own release time). A shooter with no tracked touch is not counted as one.
catch_shoot <- function(held) as.numeric(!is.na(held) & held <= CATCH_SECONDS)

#' Log-odds a jump shot gains from its two fixed effects: closest-defender distance up to DEF_CAP, and being a
#' catch-and-shoot attempt. `fixed` is c(def1 = per foot, cs = for a catch-and-shoot attempt).
jump_fixed <- function(dt, fixed) fixed[["def1"]] * pmin(dt$def1, DEF_CAP) + fixed[["cs"]] * catch_shoot(dt$held)

#' Fit xFG on unfouled attempts: a location GAM (one joint smooth of the court), then a context model for rim
#' attempts and one for jump shots. Each takes the location probability as a feature beside the defensive and
#' ball context. Boosting starts from the make rate, not from the location model, which was worse on held-out
#' games (docs/project/decision_log.md): one smooth blurs the drop in make rate at the edge of the rim area.
#' Jump shots start from the make rate of twos or of threes plus two effects that are not fitted here, a
#' closest-defender slope and a catch-and-shoot step: held-out games cannot size them, so they are set from
#' the season aggregates (R/season.R).
#' @param fixed c(def1, cs), see jump_fixed().
#' @return list(loc, fixed, zones). rim is list(bst, rounds, rate); jump is list(bst, rounds, intercept,
#'   centre). intercept is the starting log-odds less the fixed effects, for twos (1) and threes (2); centre
#'   holds the training means the fixed effects are measured from (close, cs), likewise for twos and threes.
fit_xfg <- function(shots, fixed, location = XFG_LOCATION) {
  dt <- shot_rows(shots)[, y__ := as.numeric(made)]
  loc <- mgcv::gam(update(location, y__ ~ .), family = binomial(), data = dt, method = "REML")
  dt[, loc_xfg := as.numeric(predict(loc, dt, type = "response"))]
  rim <- dt[zone == "rim"]
  rate <- mean(rim$y__)
  jump <- dt[zone == "jump"]
  jump[, c("close", "cs", "set") := .(pmin(def1, DEF_CAP), catch_shoot(held), jump_fixed(jump, fixed))]
  level <- unname(coef(glm(y__ ~ three, binomial(), jump, offset = jump$set)))
  intercept <- c(level[1], level[1] + level[2])
  by_value <- function(col) c(mean(jump[[col]][jump$three == 0L]), mean(jump[[col]][jump$three == 1L]))
  list(loc = loc, fixed = fixed,
       zones = list(rim = c(fit_boost(rim, rim$y__, rep(qlogis(rate), nrow(rim)), XFG_FEATURES, XFG_MONOTONE), list(rate = rate)),
                    jump = c(fit_boost(jump, jump$y__, intercept[jump$three + 1L] + jump$set, JUMP_FEATURES,
                                       XFG_MONOTONE[intersect(names(XFG_MONOTONE), JUMP_FEATURES)]),
                             list(intercept = intercept, centre = list(close = by_value("close"), cs = by_value("cs"))))))
}

#' Where each shot's context model starts, on the log-odds scale: the rim make rate, or for a jump shot the
#' level for twos or threes plus the fixed effects. `dt` must hold `zone`.
xfg_start <- function(m, dt) {
  fifelse(dt$zone == "rim", qlogis(m$zones$rim$rate), m$zones$jump$intercept[dt$three + 1L] + jump_fixed(dt, m$fixed))
}

#' Make probability of an unfouled attempt.
#' @param stage "full" for the context models, "location" for the location model alone.
predict_xfg <- function(m, dt, stage = "full") {
  dt <- shot_rows(dt)
  dt[, loc_xfg := as.numeric(predict(m$loc, dt, type = "response"))]
  if (stage == "location") return(dt$loc_xfg)
  start <- xfg_start(m, dt)
  p <- plogis(start)
  for (z in ZONES) {
    rows <- which(dt$zone == z)
    if (length(rows) && !is.null(m$zones[[z]]$bst)) p[rows] <- predict(m$zones[[z]]$bst, boost_matrix(dt[rows], zone_features(z), start[rows]))
  }
  p
}

#' How xFG is built up for each shot, for display: a baseline, then what each context feature adds, then the
#' result. A feature's effect is its contribution to the log-odds, rescaled so that the effects of one shot
#' sum to xfg - base on the probability scale. Contributions are the trees' Shapley values (xgboost's
#' predcontrib) plus, for a jump shot, its two fixed effects measured from the training average of twos or of
#' threes: the closest-defender slope goes to `def1`, the catch-and-shoot step to `held` (time on the ball,
#' which decides it). `base` is the model's xFG at those averages with the trees at their mean: close to the
#' make rate of rim attempts, midrange shots or threes. A feature the shot's model does not take (rim_def
#' for jump shots) has an NA effect.
#' @return data.table(zone, area, loc_xfg, rounds, fixed, base, xfg, eff_<feature> for each of XFG_FEATURES);
#'   `fixed` names the features whose effect includes one that was not fitted ("" for rim attempts).
explain_xfg <- function(m, dt) {
  dt <- shot_rows(dt)
  dt[, loc_xfg := as.numeric(predict(m$loc, dt, type = "response"))]
  start <- xfg_start(m, dt)
  p <- plogis(start)
  tree_mean <- numeric(nrow(dt))
  phi <- matrix(0, nrow(dt), length(XFG_FEATURES), dimnames = list(NULL, paste0("eff_", XFG_FEATURES)))
  for (z in ZONES) {
    rows <- which(dt$zone == z)
    used <- paste0("eff_", zone_features(z))
    phi[rows, setdiff(colnames(phi), used)] <- NA
    if (!length(rows) || is.null(m$zones[[z]]$bst)) next
    d <- boost_matrix(dt[rows], zone_features(z), start[rows])
    contrib <- predict(m$zones[[z]]$bst, d, predcontrib = TRUE)
    p[rows] <- predict(m$zones[[z]]$bst, d)
    stopifnot(max(abs(rowSums(contrib) - qlogis(p[rows]))) < 1e-3)
    tree_mean[rows] <- contrib[, ncol(contrib)] - start[rows]
    phi[rows, used] <- contrib[, seq_along(used), drop = FALSE]
  }
  jump <- dt$zone == "jump"
  centre <- m$zones$jump$centre
  value <- dt$three + 1L
  def_term <- fifelse(jump, m$fixed[["def1"]] * (pmin(dt$def1, DEF_CAP) - centre$close[value]), 0)
  catch_term <- fifelse(jump, m$fixed[["cs"]] * (catch_shoot(dt$held) - centre$cs[value]), 0)
  phi[, "eff_def1"] <- phi[, "eff_def1"] + def_term
  phi[, "eff_held"] <- phi[, "eff_held"] + catch_term
  base <- plogis(start - def_term - catch_term + tree_mean)
  moved <- rowSums(phi, na.rm = TRUE)
  per_logit <- fifelse(abs(moved) > 1e-6, (p - base) / moved, base * (1 - base))
  cbind(data.table(zone = dt$zone, area = shot_area(dt$dist, dt$three), loc_xfg = dt$loc_xfg,
                   rounds = unname(vapply(m$zones, `[[`, 0L, "rounds")[dt$zone]), fixed = fifelse(jump, "def1,held", ""),
                   base = base, xfg = p),
        as.data.table(phi * per_logit))
}

#' Fit the shot-side components on a set of training shots, plus the constants the shot value needs.
#' `oreb`, the training rate of offensive rebounds after an unfouled miss, is only a fallback: shot_value()
#' uses the spatial chance from src/court_control/ wherever a row has one.
#' @param fixed The fixed effects for jump shots, see jump_fixed().
fit_shot_models <- function(shots, ft, orb, fixed) {
  list(xfg = fit_xfg(shots[fouled == FALSE], fixed),
       foul = fit_two_stage(shots, "fouled", ~ s(dist, k = 6), binomial(), FOUL_FEATURES, c(def1 = -1)),
       oreb = shots[fouled == FALSE & made == FALSE & !is.na(oreb), mean(oreb)], ft = mean(ft$made),
       and1 = shots[fouled == TRUE, mean(made)], orb_value = mean(orb$pts))
}

#' Expected points if this player shot now: unfouled make, second chance after a miss, and free throws.
#' Beyond SHOT_RANGE the value is 0: almost no attempts exist there, so the shot is not offered as an option.
#' The second chance uses the row's spatial offensive-rebound chance (`poreb_spatial`, from the ten players'
#' positions; src/court_control/price_rebounds.R) where it has one, and the training rate otherwise.
#' @return data.table(sv, xfg, pfoul, poreb).
shot_value <- function(m, dt) {
  dt <- copy(dt)[, dist := pmin(dist, 60)]
  xfg <- predict_xfg(m$xfg, dt)
  pfoul <- predict_two_stage(m$foul, dt)
  poreb <- if ("poreb_spatial" %in% names(dt)) fcoalesce(dt$poreb_spatial, m$oreb) else rep(m$oreb, nrow(dt))
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
