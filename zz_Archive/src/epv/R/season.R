# Effects for the shot model taken from the season aggregates. The ten tracked games cannot size how much a
# closer defender lowers a jump shot's make chance, or how much a catch-and-shoot attempt raises it, so both
# are set from the season's three-point percentages. The tracked games' own shots are taken out of the season
# counts first, so no held-out outcome enters them. Requires src/play_viewer/R/data.R and R/models.R.

# The vendor's contest levels as the aggregates group them (docs/aggregates_columns.md).
CONTESTED_LEVELS <- c("average", "plus", "blocked")
UNCONTESTED_LEVELS <- c("open", "light")
# Each season split of threes: its two groups, the larger make rate first, and their columns in the shots aggregate.
SEASON_SPLITS <- list(contest = c(uncontested = "uncontested_three", contested = "contested_three"),
                      release = c(catch_and_shoot = "cns_three", off_dribble = "od_three"))

#' The fixed effects of the jump-shot model, in log-odds: `def1` per foot of closest-defender distance up to
#' DEF_CAP, and `cs` for a catch-and-shoot attempt.
#' Season side: the log-odds gap between uncontested and contested threes, and between catch-and-shoot and
#' off-the-dribble threes, over the games without tracking (per-team rows of the shots aggregate, less the
#' tracked games' box-score attempts). Tracked side: how the same vendor labels differ in the model's own two
#' features, mean closest-defender distance and share released within CATCH_SECONDS. Catch-and-shoot threes
#' are also more open, so the two gaps are solved together: the effects are the pair that reproduces both
#' season gaps given those differences. Each is a line through two points, so the shape over distance is an
#' assumption. Only labels and positions of the tracked games are used.
#' @param shots Tracked shots with `shot_id`, `game_id`, `def1` and `held` (the `shots` table of game_tables()).
#' @return list(fixed, detail); detail is one row per group with the counts and features behind the effects.
season_jump_effects <- function(root, shots) {
  label <- rbindlist(lapply(unique(shots$game_id), function(g) {
    s <- read_json_file(match_file(root, g, "_dynamic_events.json"))$shots
    has <- function(name) !vapply(s, function(r) is.null(r[[name]]), NA)
    data.table(shot_id = chr_field(s, "id"), three = lgl_field(s, "three"), made = lgl_field(s, "outcome"),
               fouled = lgl_field(s, "fouled"), level = chr_field(s, "contestLevel"), cns = lgl_field(s, "catchAndShoot"),
               typed = has("catchAndShoot") & has("complexShotType"))
  }))
  # the aggregates count box-score attempts (a miss while fouled is not one) and leave unlabelled shots out
  label <- label[three & !(fouled & !made)]
  at <- match(label$shot_id, shots$shot_id)
  label[, c("close", "cs") := .(pmin(shots$def1[at], DEF_CAP), fifelse(is.na(at), NA_real_, catch_shoot(shots$held[at])))]
  label[, contest := fifelse(level %in% UNCONTESTED_LEVELS, "uncontested", fifelse(level %in% CONTESTED_LEVELS, "contested", NA_character_))]
  label[, release := fifelse(!typed, NA_character_, fifelse(cns, "catch_and_shoot", "off_dribble"))]
  season <- fread(file.path(root, "data", "aggregates", "acb_shotsaggregates_20252026.csv"))[!is.na(team_id)]
  detail <- rbindlist(lapply(names(SEASON_SPLITS), function(split) {
    cols <- SEASON_SPLITS[[split]]
    out <- label[!is.na(get(split)), .(tracked_attempts = .N, tracked_mades = sum(made), tracked_located = sum(!is.na(close)),
                                       mean_def_dist = mean(close, na.rm = TRUE), catch_share = mean(cs, na.rm = TRUE)),
                 by = c(group = split)][match(names(cols), group)]
    out[, c("season_attempts", "season_mades") := .(vapply(cols, function(k) sum(season[[paste0(k, "_attempts")]]), 0),
                                                    vapply(cols, function(k) sum(season[[paste0(k, "_mades")]]), 0))]
    out[, c("attempts", "mades") := .(season_attempts - tracked_attempts, season_mades - tracked_mades)]
    out[, pct := mades / attempts]
    # the standard error counts the season's sampling only; the tracked features are taken as given
    cbind(split = split, out, log_odds_gap = -diff(qlogis(out$pct)), gap_se = sqrt(sum(1 / (out$attempts * out$pct * (1 - out$pct)))))
  }))
  apart <- detail[, .(gap = log_odds_gap[1], def_dist = -diff(mean_def_dist), catch = -diff(catch_share)), by = split]
  fixed <- setNames(solve(cbind(apart$def_dist, apart$catch), apart$gap), c("def1", "cs"))
  detail[, c("def_slope", "catch_effect") := .(fixed[["def1"]], fixed[["cs"]])]
  list(fixed = fixed, detail = detail[])
}
