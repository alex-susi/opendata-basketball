# The "Archetypes" tab: how the playstyle clusters are built, what each archetype and component means.
#
# Counts, component scores, loadings, fit and stability are read from outputs/archetypes/ (written by
# src/archetypes/), so the page follows whichever solution was last built. The basketball wording below is
# written for the solution chosen on 2026-10-10 (offense: 6 clusters on 4 components; defense: 4 on 2) and is
# a reading of the numbers, not something the model produced. An archetype without a note is shown without a
# definition; a component is matched to its note by position, and its ends by the sign of the `anchor` feature.

ARCHETYPE_NOTES <- list(
  "Primary Ball Handler" = "Runs the offense. He brings the ball up, handles in pick-and-roll far more than anyone else, holds the ball longest and takes most of his shots off the dribble. He rarely spots up, sets screens or goes to the offensive glass.",
  "Slasher" = "An on-ball guard whose first aim is the rim. He drives more than any other archetype, mostly out of pick-and-roll, and starts a fair share of possessions, but handles less and takes fewer pull-up jumpers than a primary ball handler.",
  "Secondary Ball Handler" = "A scoring guard or wing who gets the ball on the move. He comes off off-ball screens more than anyone, takes a high volume of shots and creates many of them himself with pull-ups and off-the-dribble threes. He starts fewer possessions than the primary ball handlers and seldom attacks the rim or the glass.",
  "Athletic Finisher" = "A forward who scores going to the basket. His drives end at the rim, often from isolation, with layups and contested finishes, and he does little pick-and-roll handling or pull-up shooting. This is the least sharply defined archetype: it sits near the middle of the two main components.",
  "Floor Spacer" = "Plays off the ball beyond the arc. He shoots off the catch and off movement, spends more time in the corners than anyone, and when he puts the ball on the floor it is to attack a closeout. He seldom scores in the paint or handles in pick-and-roll. The largest group.",
  "Roll & Cut Big" = "The interior player. He sets on-ball and off-ball screens, catches in the paint and scores at the rim and in the post; off the ball he is in or around the lane, and he does not play on the wing or shoot threes. The name describes the role: counts of rolls and cuts were too noisy to be clustering inputs.",
  "Point of Attack" = "Guards the ball. He is assigned to the opposing ball handlers, spends the largest share of his time on the ball, defends the handler in pick-and-roll and picks the ball up furthest from the basket.",
  "Chaser" = "A perimeter defender whose man is usually off the ball. He follows cutters and shooters through off-ball screens and handoffs, stays out on the perimeter with his man and takes some turns guarding the ball.",
  "Helper" = "A wing or forward who defends away from the ball. He is assigned mostly to three-point shooters, plays furthest from his own man and spends the most time in help position, and is often the defender nearest the rim when the big is drawn away.",
  "Anchor Big" = "The interior defender. He guards the screeners, defends the screener's side of pick-and-roll and off-ball screens, stays in the paint, helps on drives and is on the defensive glass. He stays close to his own man, who is near the basket.")

COMPONENT_NOTES <- list(
  offense = list(
    list(anchor = "t_zero_drib_share", context = "The main split in the league: who has the ball and who plays off it.",
         plus = c("Off-ball screener and finisher", "Catches and shoots or finishes without a dribble, sets screens and goes to the offensive glass. Typical of bigs."),
         minus = c("On-ball creator", "Handles in pick-and-roll, brings the ball up, dribbles a lot per touch and shoots off the dribble. Typical of point guards.")),
    list(anchor = "s_corner3_share", context = "Among players off the ball, where they operate: outside or inside.",
         plus = c("Perimeter spacer", "Lives beyond the arc, especially in the corners, shoots off the catch or off movement and attacks closeouts."),
         minus = c("Interior scorer", "Scores in the paint with layups, floaters and post moves, and spends his off-ball time at the top of the floor as a screener.")),
    list(anchor = "s_layup_share", context = "How a player gets his points: jump shots in volume, or occasional attacks on the rim.",
         plus = c("Low-usage rim attacker", "Shoots little, and mostly layups; his drives end at the rim and he stands still off the ball."),
         minus = c("High-volume jump-shot scorer", "Takes many shots, with pull-ups, mid-range jumpers and shots coming off off-ball screens.")),
    list(anchor = "s_drv_iso_share", context = "Players who hunt their own shot on the wing against those who organise from the top.",
         plus = c("Isolation and off-screen wing scorer", "Drives from isolation, uses off-ball screens, takes contested shots and gets to the rim."),
         minus = c("Organiser", "Stays at the top of the floor, starts possessions, runs pick-and-roll in the middle and shoots off the catch."))),
  defense = list(
    list(anchor = "d_paint_share", context = "The main split on defense: who protects the paint and who guards the ball.",
         plus = c("Interior", "Stays in the paint, is the defender nearest the rim, guards the screeners and goes to the defensive glass."),
         minus = c("On-ball perimeter", "Guards the ball handlers far from the basket, defends the handler in pick-and-roll and picks the ball up high.")),
    list(anchor = "d_help_share", context = "Whether a defender's job is to sit in help off a shooter or to be directly involved in the action.",
         plus = c("Sagging helper", "Assigned to three-point shooters, plays well off his man and spends his time in help position."),
         minus = c("Engaged in the action", "Guards the screener or the ball, moves more and is in the middle of pick-and-roll and off-ball screens."))))

MODEL_WORDS <- c(EII = "round clusters of equal size", VII = "round clusters of different sizes", EEI = "equal-sized clusters sharing one axis-aligned shape",
                 VEI = "clusters of one shape and different sizes", VVI = "axis-aligned clusters of any shape",
                 VEV = "stretched clusters of one shape, each with its own direction", VVV = "stretched clusters of any shape and direction")
SIDE_FILE <- c(Offensive = "offense", Defensive = "defense")
SCORE_FULL <- 2          # component score (in standard deviations) at which a score bar is full length
TOP_FEATURES <- 4L       # features listed for each end of a component and as what sets an archetype apart
EXAMPLES <- 5L           # players named per archetype

#' Everything the page needs from outputs/archetypes/, or NULL if the clustering has not been run.
read_archetype_outputs <- function(root) {
  dir <- file.path(root, "outputs", "archetypes")
  per_side <- c("membership", "cluster_components", "components", "component_loadings", "cluster_profiles")
  files <- c(file.path(dir, paste0(rep(SIDE_FILE, each = length(per_side)), "_", per_side, ".csv")),
             file.path(dir, c("cluster_selection.csv", "feature_dictionary.csv")))
  if (!all(file.exists(files))) return(NULL)
  out <- lapply(SIDE_FILE, function(s) lapply(setNames(per_side, per_side), function(f) fread(file.path(dir, paste0(s, "_", f, ".csv")))))
  names(out) <- SIDE_FILE
  out$selection <- fread(file.path(dir, "cluster_selection.csv"))
  out$dictionary <- fread(file.path(dir, "feature_dictionary.csv"))
  out
}

#' +1 or -1 per kept component, so that the feature named in its note loads on the "plus" end.
component_signs <- function(loadings, notes) {
  pcs <- grep("^PC", names(loadings), value = TRUE)
  vapply(seq_along(pcs), function(j) {
    anchor <- if (j <= length(notes)) loadings[[pcs[j]]][match(notes[[j]]$anchor, loadings$feature)] else NA_real_
    if (is.na(anchor) || anchor >= 0) 1 else -1
  }, 0)
}

lower_first <- function(x) paste0(tolower(substr(x, 1, 1)), substring(x, 2))
swatch <- function(archetype) {
  tag <- ARCHETYPE_TAGS[[archetype]]
  span(class = "swatch", style = sprintf("background: var(--arch-%s)", if (is.null(tag)) "none" else tag[2]))
}

#' The numbered steps of the method, with the counts of the solution on disk.
method_steps <- function(out) {
  count <- function(s) nrow(out[[s]]$membership)
  fit <- function(s) sum(out[[s]]$membership$defines_clusters)
  kept <- function(s) out[[s]]$components[kept == TRUE]
  used <- function(s) out$dictionary[side == s & clustering == "cluster", .N]
  chosen <- function(s) out$selection[side == s & chosen == TRUE][1]
  describe <- function(s) {
    ch <- chosen(s)
    sprintf("%s: %d clusters as %s (mclust model %s)", tools::toTitleCase(s), ch$clusters, MODEL_WORDS[[ch$model]], ch$model)
  }
  step <- function(title, ...) tags$li(tags$h3(title), p(...))
  tags$ol(class = "steps",
          step("Measure tendencies, not results",
               sprintf("%d features describe what a player does and where he is on the floor: %d on offense and %d on defense. ",
                       nrow(out$dictionary), out$dictionary[side == "offense", .N], out$dictionary[side == "defense", .N]),
               "Season features come from the shot, drive and pick aggregates (293 games); tracked features come from the events and tracking of the ten sample games. ",
               "Makes, points, percentages, assists, turnovers, fouls drawn, blocks, steals and rebounds collected are all left out."),
          step("Keep only what repeats",
               "Each feature's noise is estimated (from odd against even chances for tracked features) and every player's value is pulled toward the league average in proportion to how little he was observed. ",
               sprintf("A feature enters the clustering only if its median reliability among well-sampled players is at least 0.7: %d offensive and %d defensive features pass.",
                       used("offense"), used("defense"))),
          step("Reduce to principal components",
               "The surviving features are heavily correlated, so they are combined into principal components. A component is kept only if it carries more variance than the same component of shuffled data. ",
               sprintf("That keeps %d components on offense (%.0f%% of the variance) and %d on defense (%.0f%%).", nrow(kept("offense")),
                       100 * max(kept("offense")$cumulative), nrow(kept("defense")), 100 * max(kept("defense")$cumulative))),
          step("Fit a mixture model on the well-sampled players",
               sprintf("Clusters are defined by the players seen enough to trust: %d on offense (40+ tracked chances and 50+ season attempts) and %d on defense (40+ tracked chances). ",
                       fit("offense"), fit("defense")),
               "Seven Gaussian mixture types were compared at 2 to 12 clusters on fit (BIC), on how well the clusters survive refitting on resampled players, and on cluster size. ",
               sprintf("The solution in use was chosen from that comparison. %s. %s.", describe("offense"), describe("defense"))),
          step("Give every player a probability of every archetype",
               sprintf("All %d players in the season aggregates get offensive probabilities and the %d tracked players get defensive ones. ", count("offense"), count("defense")),
               "Each player is compared with every cluster using his raw values and his own sampling noise, and features he has no data for are left out, so thinly observed players get flatter probabilities instead of confident labels."))
}

#' One component: its share of variance, basketball context, and the features that load most on each end.
component_block <- function(j, side_out, notes, sign) {
  pc <- paste0("PC", j)
  load <- side_out$component_loadings[, .(definition, loading = sign * get(pc))]
  note <- if (j <= length(notes)) notes[[j]] else list(context = "", plus = c("Positive end", ""), minus = c("Negative end", ""))
  end <- function(words, rows, mark) {
    div(class = "pc-end", tags$h4(span(class = "pc-sign", mark), words[1]), p(words[2]),
        tags$ul(lapply(seq_len(nrow(rows)), function(i) tags$li(span(class = "num", sprintf("%+.2f", rows$loading[i])), rows$definition[i]))))
  }
  div(class = "panel pc",
      div(class = "pc-head", tags$h3(sprintf("Component %d", j)), span(class = "meta", sprintf("%.0f%% of variance", 100 * side_out$components$share[j]))),
      p(class = "pc-context", note$context),
      div(class = "pc-ends", end(note$minus, load[order(loading)][seq_len(TOP_FEATURES)], "−"),
          end(note$plus, load[order(-loading)][seq_len(TOP_FEATURES)], "+")))
}

#' One archetype: definition, size, certainty, typical players and the features that set it apart.
archetype_card <- function(k, side_out) {
  m <- side_out$membership[cluster == k]
  name <- m$archetype[1]
  prof <- side_out$cluster_profiles[cluster == k]
  typical <- m[defines_clusters == TRUE][order(-probability, -season_possessions)][seq_len(min(EXAMPLES, .N)), player]
  feature_row <- function(r) {
    tags$li(span(class = "num", sprintf("%+.1f", r$z)), lower_first(dictionary_text(r$feature, side_out)))
  }
  rows <- rbind(prof[order(-z)][seq_len(TOP_FEATURES)], prof[order(z)][seq_len(2L)])
  div(class = "panel arch-card",
      tags$h3(swatch(name), name),
      p(class = "meta", sprintf("%d players · %d well-sampled · mean probability %.2f", nrow(m), sum(m$defines_clusters), mean(m$probability))),
      if (!is.null(ARCHETYPE_NOTES[[name]])) p(ARCHETYPE_NOTES[[name]]),
      p(class = "meta", tags$b("Most typical: "), paste(typical, collapse = ", ")),
      tags$h4("What sets it apart"),
      tags$ul(class = "apart", lapply(seq_len(nrow(rows)), function(i) feature_row(rows[i]))))
}

dictionary_text <- function(feature, side_out) side_out$component_loadings$definition[match(feature, side_out$component_loadings$feature)]

#' Where each archetype sits on each component: a number and a bar either side of the average player.
score_table <- function(side_out, notes, signs) {
  pcs <- grep("^PC", names(side_out$cluster_components), value = TRUE)
  header <- function(j) {
    note <- if (j <= length(notes)) notes[[j]] else list(plus = "", minus = "")
    tags$th(div(class = "pc-title", sprintf("Component %d", j)), div(class = "ends", span(note$minus[1]), span(note$plus[1])))
  }
  cell <- function(v) {
    width <- 50 * min(abs(v) / SCORE_FULL, 1)
    tags$td(div(class = "score", span(class = "num", sprintf("%+.2f", v)),
                div(class = "bar", div(class = "fill", style = sprintf("width: %.1f%%; left: %.1f%%", width, if (v < 0) 50 - width else 50)))))
  }
  cc <- side_out$cluster_components
  tags$table(class = "scores",
             tags$thead(tags$tr(tags$th("Archetype"), tags$th(class = "count", "Players"), lapply(seq_along(pcs), header))),
             tags$tbody(lapply(seq_len(nrow(cc)), function(i) {
               tags$tr(tags$td(class = "arch-name", swatch(cc$archetype[i]), cc$archetype[i]), tags$td(class = "count", cc$players[i]),
                       lapply(seq_along(pcs), function(j) cell(signs[j] * cc[[pcs[j]]][i])))
             })))
}

#' Fit, stability and certainty of one side's solution, in a sentence each.
solution_facts <- function(s, out) {
  ch <- out$selection[side == s & chosen == TRUE][1]
  best <- out$selection[side == s][which.max(bic)]
  m <- out[[s]]$membership
  tags$ul(class = "facts",
          tags$li(tags$b("Stability: "), sprintf("%.2f. This is the agreement between these clusters and the ones found when the model is refitted on resampled players (1 = identical; good to about ±0.1).", ch$stability)),
          tags$li(tags$b("Membership certainty: "), sprintf("a player's most likely archetype has probability %.2f on average; %d of %d players are under 0.5.",
                                                            mean(m$probability), sum(m$probability < 0.5), nrow(m))),
          tags$li(tags$b("Fit: "), sprintf("BIC %.0f, against %.0f for the best-fitting alternative (%s with %d clusters), which was judged too coarse to describe playstyles.",
                                           ch$bic, best$bic, best$model, best$clusters)))
}

#' One side of the ball: archetype cards, components, and the score table.
side_section <- function(label, out) {
  s <- SIDE_FILE[[label]]
  side_out <- out[[s]]
  notes <- COMPONENT_NOTES[[s]]
  signs <- component_signs(side_out$component_loadings, notes)
  clusters <- side_out$cluster_components$cluster
  tagList(tags$section(tags$h2(paste(label, "archetypes")),
                       p(class = "lead", "The numbers under \"What sets it apart\" are how far the archetype sits from the league average on that feature, in standard deviations."),
                       div(class = "arch-grid", lapply(clusters, archetype_card, side_out = side_out)),
                       solution_facts(s, out)),
          tags$section(tags$h2(paste(label, "components")),
                       p(class = "lead", "Each component is a weighted mix of the features. The lists show the features with the largest weights on each end."),
                       div(class = "pc-grid", lapply(seq_along(signs), function(j) component_block(j, side_out, notes, signs[j])))),
          tags$section(tags$h2(paste("Where each", tolower(label), "archetype sits")),
                       p(class = "lead", "Cluster centres in standard deviations of each component. Zero is the average well-sampled player."),
                       div(class = "table-wrap", score_table(side_out, notes, signs))))
}

#' The whole tab.
archetype_page <- function(root) {
  out <- read_archetype_outputs(root)
  if (is.null(out)) {
    return(div(class = "doc-inner", tags$h1("Playstyle archetypes"),
               p(class = "lead", "The archetypes have not been built yet. Run src/archetypes/build_features.R and then src/archetypes/cluster_archetypes.R.")))
  }
  div(class = "doc-inner",
      tags$h1("Playstyle archetypes"),
      p(class = "lead", "Every player is described by how he plays, not by how well: where his shots come from, how he uses the ball and screens, where he stands, whom he guards. ",
        "Players with similar habits are grouped into offensive and defensive archetypes, and each player gets a probability of belonging to each one."),
      tags$section(tags$h2("How the archetypes are built"), method_steps(out)),
      side_section("Offensive", out),
      side_section("Defensive", out),
      tags$section(tags$h2("Limits"),
                   tags$ul(class = "facts",
                           tags$li("The archetype names and the wording on this page are a reading of the numbers. The model only finds the groups."),
                           tags$li("Players lie along a continuum more than in separate clumps, so the borders between neighbouring archetypes are soft. The probabilities say how close a player is to a border."),
                           tags$li("Defensive roles rest on one or two tracked games per player, and so reflect that opponent and game plan. There is no season-long defensive data."),
                           tags$li("Probabilities are optimistic about season-long role, because noise in the tracked features is measured within games."),
                           tags$li("Several intended features were too noisy to use, including roll or pop after a screen, cuts, post-ups, isolations and the coverage a big plays against the pick-and-roll. Bigs are therefore not split into finer types."))),
      p(class = "meta", "Data: SkillCorner open data, Liga ACB 2025-2026. Inspired by BBall Index's offensive archetypes and defensive roles."))
}
