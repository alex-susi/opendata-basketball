# Cluster players into offensive and defensive playstyle archetypes, with a probability of each for every player.
#   Rscript src/archetypes/cluster_archetypes.R [--offense-k=6] [--offense-model=EII] [--offense-pcs=4]
#                                               [--defense-k=4] [--defense-model=EEI] [--defense-pcs=2] [--bic] [--tag=alt]
#
# Run src/archetypes/build_features.R first. Clusters are fitted on the well-sampled players (fit_offense,
# fit_defense) and then every player is assigned: all aggregate players on offense, the tracked players on
# defense. Defaults: principal components by parallel analysis, then the owner's chosen solution (CHOSEN below).
# --bic takes the model type and number of clusters with the best BIC instead; --tag adds a suffix to the
# output files so two solutions can be kept side by side.
# Writes to outputs/archetypes/: {side}_membership, {side}_cluster_profiles, {side}_components (variance per
# component), {side}_component_loadings, {side}_cluster_components (each cluster's centre on the components) and
# cluster_selection (BIC and bootstrap stability of the candidates).

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/archetypes"
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "cluster.R"))

CANDIDATES <- 2:12
# Chosen by the owner on 2026-10-10 after comparing BIC, stability and cluster sizes across seven model types.
CHOSEN <- list(offense = list(k = 6L, model = "EII"), defense = list(k = 4L, model = "EEI"))
STABILITY_TOP <- 6L       # the best candidates by BIC that get a bootstrap stability check
STABILITY_REPS <- 30L
# A cluster is named after a well-known player it contains, so names survive a change in cluster order.
# The names are a reading of the profiles, not something the model produced; one set per number of clusters
# ("clusters@components" where the reading differs by number of components).
ANCHORS <- list(offense = list("3" = c("Ball handler" = "Facundo Campazzo", "Floor Spacer" = "Jonathan Barreiro",
                                       "Roll & Cut Big" = "Walter Tavares"),
                               "6" = c("Primary Ball Handler" = "Marcelinho Huertas", "Slasher" = "Theo Maledon",
                                       "Secondary Ball Handler" = "Patty Mills", "Floor Spacer" = "Jonathan Barreiro",
                                       "Athletic Finisher" = "Tornike Shengelia", "Roll & Cut Big" = "Walter Tavares"),
                               "6@5" = c("Pick-and-roll orchestrator" = "Marcelinho Huertas", "Primary Ball Handler" = "Facundo Campazzo",
                                         "Secondary Ball Handler" = "Patty Mills", "Floor Spacer" = "Jonathan Barreiro",
                                         "Athletic Finisher" = "Tornike Shengelia", "Roll & Cut Big" = "Walter Tavares"),
                               "7" = c("Primary Ball Handler" = "Marcelinho Huertas", "Slasher" = "Theo Maledon",
                                       "Secondary Ball Handler" = "Patty Mills", "Stretch shooter" = "Aaron Doornekamp",
                                       "Corner wing" = "Bakary Dibba", "Athletic Finisher" = "Tornike Shengelia",
                                       "Roll & Cut Big" = "Walter Tavares")),
                defense = list("3" = c("Perimeter defender" = "Trae Bell-Haynes", "Helper" = "Bakary Dibba",
                                       "Anchor Big" = "Walter Tavares"),
                               "4" = c("Point of Attack" = "Trae Bell-Haynes", "Chaser" = "Kassius Robertson",
                                       "Helper" = "Jermaine Samuels", "Anchor Big" = "Walter Tavares")))

set.seed(20261010)
root <- find_repo_root()
report <- file.path(root, "outputs", "archetypes")
built <- readRDS(file.path(root, "outputs", "cache", "archetypes", "features.rds"))
option <- function(name) {
  hit <- sub(paste0("^--", name, "="), "", grep(paste0("^--", name, "="), args, value = TRUE))
  if (length(hit)) hit[1] else NULL
}
tag <- if (is.null(option("tag"))) "" else paste0("_", option("tag"))
out_file <- function(name) file.path(report, paste0(name, tag, ".csv"))
slug <- function(x) gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(x)))

#' Name clusters after the anchor players whose most likely cluster they are.
cluster_names <- function(P, players, anchors) {
  top <- max.col(P, ties.method = "first")[match(players$pid[match(anchors, players$player)], rownames(P))]
  vapply(seq_len(ncol(P)), function(k) {
    hit <- names(anchors)[which(top == k)]
    if (length(hit)) paste(hit, collapse = " / ") else paste("Cluster", k)
  }, "")
}

selection <- list()
for (side_name in c("offense", "defense")) {
  dict <- built$dictionary[side == side_name & clustering == "cluster"]
  pool <- if (side_name == "offense") built$players else built$players[tracked_def_chances > 0]
  M <- scaled_matrices(built$values, built$dictionary, dict$feature, pool$pid)
  in_fit <- pool[[paste0("fit_", side_name)]]
  F <- lapply(M, function(m) m[in_fit, , drop = FALSE])

  # principal components
  pc <- principal_components(F$shrunk)
  q <- if (is.null(option(paste0(side_name, "-pcs")))) pc$keep else as.integer(option(paste0(side_name, "-pcs")))
  fwrite(pc$table[, .(component, variance = round(variance, 3), share = round(share, 4), cumulative = round(cumulative, 4),
                      shuffled_95 = round(shuffled_95, 3), kept = component <= q)], out_file(paste0(side_name, "_components")))
  loadings <- data.table(feature = rownames(pc$pca$rotation), round(pc$pca$rotation[, seq_len(q), drop = FALSE], 3))
  fwrite(merge(dict[, .(feature, definition)], loadings, by = "feature", sort = FALSE), out_file(paste0(side_name, "_component_loadings")))

  # mixture: every candidate's BIC, the chosen one, and how the best few survive resampling
  grid <- fit_clusters(F$shrunk, CANDIDATES, q, pca = pc$pca)
  k <- option(paste0(side_name, "-k"))
  model <- option(paste0(side_name, "-model"))
  if (is.null(k) && is.null(model) && !"--bic" %in% args) {
    k <- CHOSEN[[side_name]]$k
    model <- CHOSEN[[side_name]]$model
  }
  fit <- if (is.null(k) && is.null(model)) grid else {
    fit_clusters(F$shrunk, if (is.null(k)) CANDIDATES else as.integer(k), q, if (is.null(model)) MIXTURE_MODELS else model, pc$pca)
  }
  bic <- as.data.table(as.table(unclass(grid$bic)[, , drop = FALSE]))
  setnames(bic, c("clusters", "model", "bic"))
  bic <- bic[!is.na(bic)][order(-bic)][, clusters := as.integer(clusters)]
  bic[, chosen := clusters == fit$G & model == fit$model]
  check <- which(seq_len(nrow(bic)) <= STABILITY_TOP | bic$chosen)
  stable <- t(vapply(check, function(i) cluster_stability(F, bic$clusters[i], q, bic$model[i], STABILITY_REPS), c(stability = 0, failed = 0)))
  bic[check, c("stability", "failed_refits") := .(round(stable[, "stability"], 2), round(stable[, "failed"], 2))]
  selection[[side_name]] <- cbind(side = side_name, components = q, bic[, bic := round(bic, 1)])

  # every player's probability of every cluster
  P <- assign_clusters(fit, M$raw, M$noise)
  anchors <- ANCHORS[[side_name]][[paste0(fit$G, "@", q)]]
  if (is.null(anchors)) anchors <- ANCHORS[[side_name]][[as.character(fit$G)]]
  names_k <- if (is.null(anchors)) paste("Cluster", seq_len(fit$G)) else cluster_names(P, pool, anchors)
  top <- max.col(P, ties.method = "first")
  seen <- rowSums(!is.na(M$raw[, dict[tier == "tracked", feature], drop = FALSE])) > 0
  membership <- cbind(pool[, .(pid, player, teams, season_possessions, season_attempts, tracked_games, tracked_off_chances,
                               tracked_def_chances)],
                      defines_clusters = in_fit, basis = fifelse(seen, "season and tracked", "season only"), cluster = top,
                      archetype = names_k[top], probability = round(P[cbind(seq_len(nrow(P)), top)], 3),
                      setnames(as.data.table(round(P, 3)), paste0("p_", slug(names_k))))
  if (side_name == "defense") membership[, c("basis", "season_attempts") := NULL]
  fwrite(membership[order(cluster, -probability)], out_file(paste0(side_name, "_membership")))

  profiles <- cluster_profiles(P[in_fit, , drop = FALSE], F$shrunk, built$values, built$dictionary)
  profiles[, archetype := names_k[cluster]]
  profiles <- merge(profiles, membership[, .(players = .N, defining_players = sum(defines_clusters)), by = cluster], by = "cluster")
  fwrite(profiles[order(cluster, -z), .(cluster, archetype, players, defining_players, feature, z = round(z, 2), value = round(value, 4),
                                       league_mean = round(league_mean, 4))], out_file(paste0(side_name, "_cluster_profiles")))

  # each cluster's centre on the components, in component standard deviations (0 = the average fit player)
  centres <- data.table(cluster = seq_len(fit$G), archetype = names_k, players = tabulate(top, fit$G),
                        round(sweep(fit$means, 2, pc$pca$sdev[seq_len(q)], "/"), 2))
  fwrite(centres, out_file(paste0(side_name, "_cluster_components")))

  message(sprintf("\n%s: %d features, %d principal components (%.0f%% of variance), %s with %d clusters, fitted on %d players.",
                  side_name, nrow(dict), q, 100 * pc$table$cumulative[q], fit$model, fit$G, sum(in_fit)))
  print(bic[check])
  print(centres)
  print(membership[, .(players = .N, defining = sum(defines_clusters), mean_probability = round(mean(probability), 2),
                       under_half = sum(probability < 0.5)), by = .(cluster, archetype)][order(cluster)])
  if (side_name == "offense") print(membership[, .(players = .N, mean_probability = round(mean(probability), 2),
                                              under_half = sum(probability < 0.5)), by = basis])
}
fwrite(rbindlist(selection), out_file("cluster_selection"))
