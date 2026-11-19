## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 28: each player's position (guard, wing or big) for every held-out game, without that game.
#   Rscript screen_coverage/01_scripts/28_fold_positions.R
#
# The personnel experiment (29_build_personnel.R) gives the models each screen player's position. A position read
# from the published archetypes would carry the graded game's tracking (the archetypes were fitted on all ten
# games), so for every held-out game g this step rebuilds the offensive archetype features with g's tracked counts
# removed, refits the owner's chosen offensive solution (10 clusters, EII, 4 principal components, fit players with
# 25+ tracked chances and 30+ season attempts; archetypes/01_scripts/cluster_archetypes.R), names the clusters
# after the same anchor players, and groups them:
#   guard   Primary Ball Handler, Secondary Ball Handler, Slasher
#   wing    Off Screen Shooter, Movement Shooter, Stationary Shooter, Athletic Finisher
#   big     Post Scorer, Roll & Cut Big, Versatile Big
# A player's group probability is the sum of his cluster probabilities in that group; his position is the largest.
# Offensive archetypes only: no coverage share and no defensive (matchups) feature enters them.
#
# What still overlaps the graded game: the season aggregate files (293 games) include it, about 1 of each team's
# 31-34 games, and they cannot be split by game. They hold offensive counts only (the coverage-faced columns are
# not clustering features).
#
# Check: the same code with nothing removed must reproduce archetypes/03_outputs/offense_membership.csv.
#
# Writes screen_coverage/02_cache/experiments/personnel/positions_by_fold.rds and
# screen_coverage/03_outputs/experiments/personnel/positions_check.csv.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(mclust)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
arch <- file.path(root, "archetypes", "01_scripts")
source(file.path(root, "play_viewer", "01_app", "R", "data.R"))
for (f in c("spec.R", "assemble.R", "season.R", "cluster.R")) source(file.path(arch, "R", f))
cache_dir <- file.path(root, "screen_coverage", "02_cache", "experiments", "personnel")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "experiments", "personnel")
for (d in c(cache_dir, out_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# As in archetypes/01_scripts/build_features.R and cluster_archetypes.R (the owner's chosen offensive solution).
MIN_CHANCES <- 40L
MIN_ATTEMPTS <- 50L
RELIABILITY_BAR <- 0.7
FIT <- list(k = 10L, model = "EII", pcs = 4L, fit_chances = 25, fit_attempts = 30)
ANCHORS <- c("Primary Ball Handler" = "Marcelinho Huertas", "Secondary Ball Handler" = "Kevin Punter",
             "Slasher" = "Matteo Spagnolo", "Off Screen Shooter" = "Matt Thomas",
             "Movement Shooter" = "Yves Pons", "Stationary Shooter" = "Bakary Dibba",
             "Athletic Finisher" = "Howard Sant-Roos", "Versatile Big" = "Pierre Pelos",
             "Post Scorer" = "Ante Tomic", "Roll & Cut Big" = "Martinas Geben")
POS_OFF <- c("Primary Ball Handler" = "guard", "Secondary Ball Handler" = "guard", "Slasher" = "guard",
             "Off Screen Shooter" = "wing", "Movement Shooter" = "wing", "Stationary Shooter" = "wing",
             "Athletic Finisher" = "wing", "Post Scorer" = "big", "Roll & Cut Big" = "big", "Versatile Big" = "big")
POS_LV <- c("guard", "wing", "big")

games <- as.integer(jsonlite::fromJSON(file.path(root, "data", "matches.json"))$id)
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
spec <- feature_spec()
per_game <- lapply(games, function(g) readRDS(file.path(root, "archetypes", "02_cache", paste0("counts_", g, ".rds"))))
season <- season_counts(root, aliases)
people <- season_people(root, aliases)
off_spec <- spec[side == "offense"]
by_tier <- function(tier_name) off_spec[tier == tier_name]
off_season <- estimate_features(by_tier("season"), feature_values(by_tier("season"), season))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - OFFENSIVE ARCHETYPES WITHOUT ONE GAME ----------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' The offensive archetype fit and every player's position with the tracked games `use` (season files unchanged).
fold_fit <- function(use) {
  # Tracked counts of the games used, by canonical id, half and game.
  tracked <- rbindlist(lapply(per_game[games %in% use], `[[`, "counts"))
  tracked[, pid := canon_id(pid, aliases)]
  tracked <- tracked[, .(value = sum(value)), by = .(pid, half, game_id, stat)]
  ts <- by_tier("tracked")
  off_tracked <- estimate_features(ts, feature_values(ts, wide_counts(tracked)), feature_values(ts, wide_counts(tracked[half == 0L])),
                                   feature_values(ts, wide_counts(tracked[half == 1L])))
  values <- rbind(off_season$values, off_tracked$values, fill = TRUE)
  priors <- rbind(off_season$priors, off_tracked$priors)

  # Players and their exposure in the games used; who may define the clusters.
  exposure <- wide_counts(tracked[stat %in% c("off_ch", "def_ch", "touches", "shots")])
  players <- merge(people, season[, .(pid, season_attempts = attempts)], by = "pid")
  players <- merge(players, exposure[, .(pid, tracked_off_chances = off_ch)], by = "pid", all.x = TRUE)
  players[is.na(tracked_off_chances), tracked_off_chances := 0]
  players[, fit_rel := tracked_off_chances >= MIN_CHANCES & season_attempts >= MIN_ATTEMPTS]
  setorder(players, player)

  # Reliability over the reliability players, then the clustering features (reliability bar 0.7).
  rel <- values[, .(reliability = stats::median(reliability[pid %in% players$pid[players$fit_rel]])), by = feature]
  dictionary <- merge(merge(off_spec, priors, by = "feature"), rel, by = "feature")
  dictionary[, clustering := fifelse(use != "cluster", use, fifelse(reliability < RELIABILITY_BAR, "low_reliability", "cluster"))]
  feats <- dictionary[clustering == "cluster", feature]

  # The chosen mixture on the fit players' principal components, then every player's cluster probabilities.
  set.seed(20261010)
  M <- scaled_matrices(values, dictionary, feats, players$pid)
  in_fit <- players$tracked_off_chances >= FIT$fit_chances & players$season_attempts >= FIT$fit_attempts
  Z <- M$shrunk[in_fit, , drop = FALSE]
  pca <- stats::prcomp(Z, center = TRUE, scale. = FALSE)
  fit <- fit_clusters(Z, FIT$k, FIT$pcs, FIT$model, pca)
  P <- assign_clusters(fit, M$raw, M$noise)
  top <- max.col(P, ties.method = "first")
  # Clusters named after the anchor players: one anchor per cluster, the pairing that maximises the anchors' summed
  # log probability of their cluster (lpSolve's assignment solver). With all ten games every anchor sits in its own
  # top cluster; without one game two anchors can share a top cluster, and the pairing still names every cluster.
  A <- P[match(players$pid[match(ANCHORS, players$player)], rownames(P)), , drop = FALSE]
  if (anyNA(A)) stop("An anchor player is missing with games ", paste(use, collapse = ","))
  sol <- lpSolve::lp.assign(-log(pmax(A, 1e-300)))$solution
  names_k <- names(ANCHORS)[apply(sol, 2, which.max)]
  moved <- sum(apply(sol, 1, which.max) != max.col(A, ties.method = "first"))
  grp <- POS_OFF[names_k]
  gp <- sapply(POS_LV, function(p) rowSums(P[, grp == p, drop = FALSE]))
  data.table(pid = as.integer(rownames(P)), player = players$player, archetype = names_k[top], p_guard = gp[, "guard"],
             p_wing = gp[, "wing"], p_big = gp[, "big"], pos = POS_LV[max.col(gp, ties.method = "first")],
             n_feats = length(feats), anchors_off_top = moved)
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - EVERY FOLD, AND THE CHECK ----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

t0 <- Sys.time()
full <- fold_fit(games)
pub <- fread(file.path(root, "archetypes", "03_outputs", "offense_membership.csv"))
same <- merge(full[, .(pid, archetype)], pub[, .(pid, published = archetype)], by = "pid")
cat(sprintf("All ten games: %d of %d players match the published archetype (%d clustering features)\n",
            same[, sum(archetype == published)], nrow(same), full$n_feats[1]))
folds <- lapply(games, function(g) {
  r <- fold_fit(setdiff(games, g))
  r[, game_id := g]
  r
})
names(folds) <- games
cat(sprintf("Ten folds refitted in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))

# How positions move when a game is left out, for the players of that game.
roster_of <- function(g) {
  ev <- jsonlite::fromJSON(file.path(root, "data", "matches", g, paste0(g, "_game_data.json")))
  canon_id(c(ev$homeTeam$players$playerId, ev$awayTeam$players$playerId), aliases)
}
chk <- rbindlist(lapply(games, function(g) {
  f <- folds[[as.character(g)]]
  ids <- intersect(roster_of(g), f$pid)
  m <- merge(f[pid %in% ids, .(pid, player, pos_fold = pos, arch_fold = archetype)], full[, .(pid, pos_all = pos, arch_all = archetype)], by = "pid")
  data.table(game_id = g, players = nrow(m), same_position = sum(m$pos_fold == m$pos_all), same_archetype = sum(m$arch_fold == m$arch_all),
             anchors_off_top = f$anchors_off_top[1],
             changed = paste(m[pos_fold != pos_all, sprintf("%s %s->%s", player, pos_all, pos_fold)], collapse = "; "))
}))
print(chk)
fwrite(chk, file.path(out_dir, "positions_check.csv"))
saveRDS(list(folds = folds, full = full, games = games, settings = FIT, made = Sys.time()), file.path(cache_dir, "positions_by_fold.rds"))
