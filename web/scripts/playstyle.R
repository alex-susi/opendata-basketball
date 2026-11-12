# Each player's playstyle for the site's player card (sourced by export_data.R, which defines `a`): his archetype
# probabilities on offense and defense (archetypes/03_outputs/*_membership.csv) and his scores on the principal
# components the Archetypes tab describes.
#
# The archetype script (archetypes/01_scripts/cluster_archetypes.R) saves the components' loadings and each archetype's
# centre, not the players' scores, so they are rebuilt here the same way: the same feature cache and scaling
# (archetypes/01_scripts/R/cluster.R, scaled_matrices), the PCA refitted on the same fit players, every player projected
# onto the kept components and divided by each component's standard deviation (the units of the tab's score
# table). Signs follow the tab (component_signs), so "+" is the end its notes name. The refit's loadings must
# match the saved ones, which the function checks.

playstyle_figures <- function() {
  arch_dir <- file.path(a$root, "archetypes", "01_scripts")
  env <- new.env()
  sys.source(file.path(arch_dir, "R", "cluster.R"), envir = env)
  built <- readRDS(file.path(a$root, "archetypes", "02_cache", "features.rds"))
  out_dir <- file.path(a$root, "archetypes", "03_outputs")
  fit_rules <- list(offense = function(pool) pool$tracked_off_chances >= 25 & pool$season_attempts >= 30,
                    defense = function(pool) pool$fit_defense)

  sides <- list()
  players <- list()
  # Per side: refit the PCA on the fit players, check it against the saved loadings, and score every player.
  for (s in c("offense", "defense")) {
    key <- if (s == "offense") "off" else "def"
    saved <- fread(file.path(out_dir, paste0(s, "_component_loadings.csv")))
    q <- sum(grepl("^PC", names(saved)))
    dict <- built$dictionary[side == s & clustering == "cluster"]
    pool <- if (s == "offense") built$players else built$players[tracked_def_chances > 0]
    M <- env$scaled_matrices(built$values, built$dictionary, dict$feature, pool$pid)
    fit <- fit_rules[[s]](pool)
    pca <- stats::prcomp(M$shrunk[fit, , drop = FALSE], center = TRUE, scale. = FALSE)
    rot <- pca$rotation[saved$feature, seq_len(q), drop = FALSE]
    stopifnot(max(abs(abs(round(rot, 3)) - abs(as.matrix(saved[, paste0("PC", seq_len(q)), with = FALSE])))) < 0.002)
    # Same orientation as the saved loadings, then the tab's signs.
    flip <- sign(colSums(rot * as.matrix(saved[, paste0("PC", seq_len(q)), with = FALSE])))
    notes <- a$COMPONENT_NOTES[[s]]
    signs <- a$component_signs(saved, notes) * flip
    Z <- sweep(M$shrunk, 2, pca$center)[, saved$feature, drop = FALSE]
    scores <- sweep(Z %*% pca$rotation[saved$feature, seq_len(q), drop = FALSE], 2, pca$sdev[seq_len(q)] / signs, "/")

    # The saved components, centres and memberships; the rebuilt scores' cluster means should match the centres.
    comps <- fread(file.path(out_dir, paste0(s, "_components.csv")))
    cc <- fread(file.path(out_dir, paste0(s, "_cluster_components.csv")))
    mem <- fread(file.path(out_dir, paste0(s, "_membership.csv")))
    pcols <- grep("^p_", names(mem), value = TRUE)
    # The saved centres in the tab's signs, to check the rebuilt scores against.
    centres <- sweep(as.matrix(cc[, paste0("PC", seq_len(q)), with = FALSE]), 2, a$component_signs(saved, notes), "*")
    got <- t(vapply(cc$cluster, function(k) colMeans(scores[as.character(mem[cluster == k & defines_clusters == TRUE, pid]), , drop = FALSE]), numeric(q)))
    message(sprintf("  playstyle %s: rebuilt scores' cluster means vs saved centres, max gap %.2f", s, max(abs(got - centres))))

    # The tab's text for each component and archetype, then each player's probabilities and scores.
    sides[[key]] <- list(components = lapply(seq_len(q), function(j) {
                           n <- if (j <= length(notes)) notes[[j]] else list(plus = c("Positive end", ""), minus = c("Negative end", ""), context = "")
                           list(share = round(comps$share[j], 3), context = n$context, minus = n$minus[1], plus = n$plus[1],
                                minusText = n$minus[2], plusText = n$plus[2])
                         }),
                         archetypes = lapply(seq_len(nrow(cc)), function(i) {
                           tag <- a$ARCHETYPE_TAGS[[cc$archetype[i]]]
                           list(name = cc$archetype[i], short = if (is.null(tag)) cc$archetype[i] else tag[1], slot = if (is.null(tag)) NULL else tag[2],
                                centre = I(round(centres[i, ], 2)))
                         }))
    for (i in seq_len(nrow(mem))) {
      pid <- as.character(mem$pid[i])
      probs <- unlist(mem[i, ..pcols])
      players[[pid]][[key]] <- list(top = mem$archetype[i], p = mem$probability[i], defines = mem$defines_clusters[i],
                                    probs = I(round(as.numeric(probs[paste0("p_", gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(cc$archetype))))]), 3)),
                                    scores = I(round(as.numeric(scores[pid, ]), 2)))
    }
  }
  list(sides = sides, players = players)
}
