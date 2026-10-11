# Build the playstyle archetype feature tables.
#   Rscript src/archetypes/build_features.R [--force]
#
# 1. Counts for each of the ten tracked games (cached per game in outputs/cache/archetypes/; --force rebuilds).
# 2. Season counts for every player in the aggregate files.
# 3. Features = ratios of counts (R/spec.R), each with its sampling noise and a value shrunk to the league mean.
# 4. Reliability of every feature; features under RELIABILITY_BAR are kept but not offered for clustering.
# Writes outputs/archetypes/*.csv and outputs/cache/archetypes/features.rds (read by cluster_archetypes.R).

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/archetypes"
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "..", "epv", "R", "features.R"))
for (f in c("tracked.R", "season.R", "spec.R", "assemble.R")) source(file.path(here, "R", f))

MIN_CHANCES <- 40L        # tracked chances on one side of the ball for a player to help define the clusters
MIN_ATTEMPTS <- 50L       # season attempts, likewise (offense)
RELIABILITY_BAR <- 0.7    # median reliability among those players for a feature to enter the clustering

app <- load_app_data()
root <- app$root
games <- app$matches$game_id
cache <- file.path(root, "outputs", "cache", "archetypes")
report <- file.path(root, "outputs", "archetypes")
dir.create(cache, recursive = TRUE, showWarnings = FALSE)
dir.create(report, recursive = TRUE, showWarnings = FALSE)
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
spec <- feature_spec()

# ---- counts --------------------------------------------------------------------------------------

per_game <- lapply(games, function(g) {
  path <- file.path(cache, paste0("counts_", g, ".rds"))
  if (file.exists(path) && !"--force" %in% args) return(readRDS(path))
  message("Counting game ", g)
  out <- game_counts(app, g)
  saveRDS(out, path)
  out
})
tracked <- rbindlist(lapply(per_game, `[[`, "counts"))
tracked[, pid := canon_id(pid, aliases)]
tracked <- tracked[, .(value = sum(value)), by = .(pid, half, game_id, stat)]
pairs <- rbindlist(lapply(per_game, `[[`, "pairs"))
pairs[, c("def", "off") := .(canon_id(def, aliases), canon_id(off, aliases))]
season <- season_counts(root, aliases)
people <- season_people(root, aliases)
if (!all(tracked$pid %in% season$pid)) stop("A tracked player is missing from the season aggregates")

# ---- features ------------------------------------------------------------------------------------

by_tier <- function(side_name, tier_name) spec[side == side_name & tier == tier_name]
#' Estimates for tracked features from long counts: totals plus the odd and even halves.
tracked_estimates <- function(sp, counts) {
  estimate_features(sp, feature_values(sp, wide_counts(counts)), feature_values(sp, wide_counts(counts[half == 0L])),
                    feature_values(sp, wide_counts(counts[half == 1L])))
}
off_season <- estimate_features(by_tier("offense", "season"), feature_values(by_tier("offense", "season"), season))
off_tracked <- tracked_estimates(by_tier("offense", "tracked"), tracked)

# who each defender guards: his men's own offensive profile, weighted by assignment time
pick <- function(est, f) est$values[feature == f, .(pid, v = shrunk)]
three <- merge(pick(off_season, "s_corner3_share"), pick(off_season, "s_ab3_share"), by = "pid")[, .(pid, three = v.x + v.y)]
profile <- Reduce(function(a, b) merge(a, b, by = "pid"),
                  list(setnames(pick(off_tracked, "t_touch_per100"), "v", "touch"), three,
                       setnames(pick(off_season, "s_pick_scr_per100"), "v", "screener"),
                       setnames(pick(off_season, "s_pick_bh_per100"), "v", "handler")))
tracked <- rbind(tracked, guard_counts(pairs, profile), use.names = TRUE)
def_tracked <- tracked_estimates(by_tier("defense", "tracked"), tracked)

values <- rbind(off_season$values, off_tracked$values, def_tracked$values, fill = TRUE)
priors <- rbind(off_season$priors, off_tracked$priors, def_tracked$priors)

# ---- players -------------------------------------------------------------------------------------

exposure <- wide_counts(tracked[stat %in% c("off_ch", "def_ch", "touches", "shots")])
exposure <- merge(exposure, tracked[stat %in% c("off_ch", "def_ch"), .(tracked_games = uniqueN(game_id)), by = pid], by = "pid")
players <- merge(people, season[, .(pid, season_games = games, season_possessions = possessions, season_attempts = attempts)], by = "pid")
players <- merge(players, exposure, by = "pid", all.x = TRUE)
setnames(players, c("off_ch", "def_ch", "touches", "shots"), c("tracked_off_chances", "tracked_def_chances", "tracked_touches", "tracked_shots"))
for (col in grep("^tracked_", names(players), value = TRUE)) set(players, which(is.na(players[[col]])), col, 0)
players[, fit_offense := tracked_off_chances >= MIN_CHANCES & season_attempts >= MIN_ATTEMPTS]
players[, fit_defense := tracked_def_chances >= MIN_CHANCES]
setorder(players, player)

# ---- reliability ---------------------------------------------------------------------------------

#' Game-by-game raw values for players seen in two tracked games.
two_game <- function(sp) {
  per <- rbindlist(lapply(games, function(g) feature_values(sp, wide_counts(tracked[game_id == g]))[, game_id := g]))
  per <- per[den > 0][order(game_id), if (.N == 2L) .(first = num[1] / den[1], second = num[2] / den[2]), by = .(pid, feature)]
  per[, as.list(pair_cor(first, second)), by = feature][, .(feature, two_game_n = n, two_game_r = r)]
}
fit_ids <- function(side_name) players[[paste0("fit_", side_name)]]
reliability <- values[, {
  fit <- pid %in% players$pid[fit_ids(spec$side[match(feature, spec$feature)])]
  halves <- pair_cor(raw0[fit], raw1[fit])
  .(players_with_data = sum(den > 0), median_denominator = stats::median(den[fit]), reliability = stats::median(reliability[fit]),
    split_half_r = halves[["r"]], split_half_stepped = halves[["stepped"]])
}, by = feature]
dictionary <- Reduce(function(a, b) merge(a, b, by = "feature", all.x = TRUE, sort = FALSE),
                     list(spec, priors, reliability, two_game(spec[tier == "tracked"])))
dictionary[, clustering := fifelse(use != "cluster", use, fifelse(reliability < RELIABILITY_BAR, "low_reliability", "cluster"))]
setnames(dictionary, c("num", "den"), c("numerator", "denominator"))

# ---- write ---------------------------------------------------------------------------------------

#' One row per player, one column per feature of a side; tracked columns are empty for untracked players.
wide_table <- function(side_name, column) {
  keep <- spec[side == side_name, feature]
  w <- dcast(values[feature %in% keep], pid ~ feature, value.var = column)
  setcolorder(w, c("pid", keep))
  merge(players, w, by = "pid", all.x = side_name == "offense")[order(player)]
}
round_cols <- function(dt, digits = 4) dt[, lapply(.SD, function(v) if (is.double(v)) round(v, digits) else v)]
fwrite(round_cols(dictionary[, .(feature, side, tier, clustering, definition, numerator, denominator, scale, league_mean, between_sd, unit_sd,
                                 prior_strength, players_with_data, median_denominator, reliability, split_half_r, split_half_stepped,
                                 two_game_n, two_game_r)]), file.path(report, "feature_dictionary.csv"))
for (side_name in c("offense", "defense")) {
  fwrite(round_cols(wide_table(side_name, "shrunk")), file.path(report, paste0(side_name, "_features.csv")))
  fwrite(round_cols(wide_table(side_name, "raw")), file.path(report, paste0(side_name, "_features_raw.csv")))
}
long <- merge(players[, .(pid, player)], values[, .(pid, feature, num, den, raw, shrunk, noise_sd, reliability)], by = "pid")
fwrite(round_cols(long[order(player, feature)], 5), file.path(report, "feature_values.csv"))
saveRDS(list(players = players, values = values, dictionary = dictionary, pairs = pairs), file.path(cache, "features.rds"))

message(sprintf("%d players: %d tracked, %d define the offensive clusters, %d the defensive ones.", nrow(players),
                players[tracked_off_chances + tracked_def_chances > 0, .N], sum(players$fit_offense), sum(players$fit_defense)))
print(dictionary[, .N, by = .(side, tier, clustering)][order(side, tier, clustering)])
print(dictionary[tier == "tracked", .(feature, clustering, league_mean = signif(league_mean, 3), median_denominator, reliability = round(reliability, 2),
                                      split = round(split_half_stepped, 2), two_game_r = round(two_game_r, 2), two_game_n)], nrows = 200)
print(dictionary[tier == "season", .(feature, clustering, league_mean = signif(league_mean, 3), median_denominator, reliability = round(reliability, 2))], nrows = 200)
