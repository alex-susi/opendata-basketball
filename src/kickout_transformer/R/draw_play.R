# One "play card" per catch, for film study: the court at the moment of the catch on the left, the models'
# probabilities and the key numbers on the right, and a header that says what happened and how to find the play in
# the dashboard. Used by 05_attention.R and 06_film_study.R.

suppressPackageStartupMessages({ library(ggplot2); library(patchwork); library(ggrepel) })

FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M
COURT_X <- 14 * FT_PER_M          # baseline
COURT_Y <- 7.5 * FT_PER_M         # sideline

COL_OFF <- "#2a6f97"; COL_DEF <- "#d1495b"; COL_ATT <- "#7b2cbf"; COL_RIGHT <- "#2a9d8f"; COL_WRONG <- "#c9ccd1"

#' Jersey number, short name and team of every player in the given games, from the supplied rosters.
load_rosters <- function(root, games) {
  rbindlist(lapply(games, function(g) {
    gd <- jsonlite::fromJSON(file.path(root, "data", "matches", g, sprintf("%s_game_data.json", g)))
    rbind(data.table(gd$homeTeam$players, team = gd$homeTeam$teamName),
          data.table(gd$awayTeam$players, team = gd$awayTeam$teamName))[
      , .(game_id = as.integer(g), pid = playerId, jersey, name = lastName, team)]
  }))
}

.passes_cache <- new.env()
#' The supplied clocks for a pass: game clock at the catch (seconds left in the period) and the raw shot clock (NA when
#' it was off). Step 1 fills a missing shot clock with 24 before the models see it; this returns the raw value.
pass_clocks <- function(root, game, pass_id) {
  key <- as.character(game)
  if (is.null(.passes_cache[[key]]))
    .passes_cache[[key]] <- jsonlite::fromJSON(file.path(root, "data", "matches", game,
                                                         sprintf("%s_dynamic_events.json", game)))$passes
  ev <- .passes_cache[[key]]
  i <- match(pass_id, ev$id)
  list(game = ev$endGameClock[i], shot = ev$shotClock[i])
}
fmt_clock <- function(s) if (is.na(s)) "n/a" else sprintf("%d:%02d", floor(s / 60), floor(s %% 60))

#' Game clock (m:ss left in the period) when the pass was caught.
catch_clock <- function(root, game, pass_id) fmt_clock(pass_clocks(root, game, pass_id)$game)

#' The attacking half court. `x_from` < 0 also shows that much of the backcourt (for players past half court).
court_layer <- function(x_from = 0) {
  arc <- seq(-pi / 2 - 0.3, pi / 2 + 0.3, length.out = 120)
  three <- data.table(x = HOOP_X - 6.75 * FT_PER_M * cos(arc), y = 6.75 * FT_PER_M * sin(arc))
  three <- three[abs(y) <= 6.6 * FT_PER_M & x <= HOOP_X]
  lane <- 4.9 / 2 * FT_PER_M; ft <- COURT_X - 5.8 * FT_PER_M
  list(if (x_from < 0) annotate("rect", xmin = x_from, xmax = 0, ymin = -COURT_Y, ymax = COURT_Y, fill = "#ece9e4", colour = "grey55"),
       annotate("rect", xmin = 0, xmax = COURT_X, ymin = -COURT_Y, ymax = COURT_Y, fill = "#f7efe3", colour = "grey55"),
       annotate("rect", xmin = ft, xmax = COURT_X, ymin = -lane, ymax = lane, fill = "#efe2cf", colour = "grey55"),
       geom_path(data = three, aes(x, y), colour = "grey55", inherit.aes = FALSE),
       annotate("segment", x = max(three$x), xend = COURT_X, y = c(-1, 1) * 6.6 * FT_PER_M,
                yend = c(-1, 1) * 6.6 * FT_PER_M, colour = "grey55"),
       annotate("point", x = HOOP_X, y = 0, shape = 21, size = 4, colour = "orange3", stroke = 1.4),
       coord_equal(xlim = c(x_from, COURT_X), ylim = c(-COURT_Y, COURT_Y), expand = FALSE, clip = "off"))
}

#' The court at the catch. `w` is the receiver's attention to each of the ten tokens (NULL to leave it out).
court_panel <- function(tokens, pids, roster, w = NULL, top_n = 3) {
  tok <- as.data.table(tokens[, c("hoop_dx", "y", "vx", "vy", "is_offense", "is_passer", "rel_dist")])
  tok[, `:=`(X = HOOP_X - hoop_dx, token = .I, pid = pids)]
  tok[roster, on = "pid", `:=`(jersey = i.jersey, name = i.name)]
  tok[is.na(jersey), `:=`(jersey = "?", name = "?")]
  tok[, side := fifelse(is_offense == 1, "Offense", "Defense")]
  tok[, role := fcase(token == 1, "RECEIVER", is_passer == 1, "passer", token == 6, "closest defender",
                      default = NA_character_)]
  tok[, w := if (is.null(w)) 0 else w]
  tok[, rank := fifelse(token == 1, NA_integer_, frank(fifelse(token == 1, Inf, -w), ties.method = "first"))]
  tok[, watched := !is.null(w) & !is.na(rank) & rank <= top_n]
  # one label per key player: role (if any), jersey and name, and the attention share for the most-watched players
  tok[, tag := ""]
  tok[!is.na(role) | watched, tag := paste0(fifelse(is.na(role), "", paste0(role, " ")), "#", jersey, " ", name)]
  tok[watched == TRUE, tag := sprintf("%s\n%.0f%% of the read", tag, 100 * w)]
  rx <- tok$X[1]; ry <- tok$y[1]
  # start each label a few feet outward: away from the receiver for the others, away from the hoop for the receiver
  tok[, `:=`(ux = fifelse(token == 1, rx - HOOP_X, X - rx), uy = fifelse(token == 1, ry, y - ry))]
  tok[, len := pmax(sqrt(ux^2 + uy^2), 1e-6)]
  tok[, `:=`(nx = 3 * ux / len, ny = 3 * uy / len)]
  g <- ggplot() + court_layer(if (min(tok$X) < 0) floor(min(tok$X) - 3) else 0)
  if (!is.null(w)) {
    g <- g +
      geom_segment(data = tok[token > 1], aes(x = rx, y = ry, xend = X, yend = y, linewidth = w, alpha = watched),
                   colour = COL_ATT, lineend = "round") +
      scale_linewidth(range = c(0.3, 3.5), guide = "none") +
      scale_alpha_manual(values = c(`TRUE` = 0.7, `FALSE` = 0.15), guide = "none")
  }
  g + geom_segment(data = tok, aes(x = X, y = y, xend = X + 0.5 * vx, yend = y + 0.5 * vy),
                   arrow = arrow(length = unit(0.14, "cm"), type = "closed"), colour = "grey35", linewidth = 0.5) +
    geom_point(data = tok[1], aes(X, y), shape = 21, size = 10.5, stroke = 1.6, colour = "black", fill = NA) +
    geom_point(data = tok, aes(X, y, fill = side), shape = 21, size = 7, colour = "white", stroke = 0.8) +
    geom_text(data = tok, aes(X, y, label = jersey), colour = "white", size = 2.9, fontface = "bold") +
    # every player is passed to the repel layer (most with an empty label) so labels steer clear of all the dots
    geom_text_repel(data = tok, aes(X, y, label = tag, colour = watched), size = 2.9, lineheight = 0.9,
                    point.size = 10, box.padding = 0.7, point.padding = 0.3, min.segment.length = 0.2, force = 4, force_pull = 0.5,
                    max.iter = 20000, max.time = 3,
                    segment.colour = "grey60", max.overlaps = Inf, seed = 1, fontface = "bold", bg.colour = "white", bg.r = 0.12,
                    position = position_nudge_repel(x = tok$nx, y = tok$ny)) +
    scale_colour_manual(values = c(`TRUE` = "#5a189a", `FALSE` = "grey20"), guide = "none") +
    scale_fill_manual(values = c(Offense = COL_OFF, Defense = COL_DEF), name = NULL) +
    theme_void(base_size = 10) +
    theme(legend.position = "bottom", legend.margin = margin(0, 0, 0, 0))
}

#' Probability bars, one block per model. The outcome that actually happened is the coloured bar.
prob_panel <- function(probs, actual) {
  pt <- rbindlist(lapply(names(probs), function(nm)
    data.table(model = nm, class = names(probs[[nm]]), p = unname(probs[[nm]]))))
  pt[, `:=`(model = factor(model, levels = names(probs)), class = factor(class, levels = rev(names(probs[[1]]))),
            happened = class == actual)]
  ggplot(pt, aes(p, class, fill = happened)) +
    geom_col(width = 0.7) +
    geom_text(aes(label = sprintf("%.0f%%", 100 * p)), hjust = -0.15, size = 3.4) +
    facet_wrap(~ model, ncol = 1) +
    scale_fill_manual(values = c(`TRUE` = COL_RIGHT, `FALSE` = COL_WRONG), guide = "none") +
    scale_x_continuous(limits = c(0, 1.15), breaks = c(0, 0.5, 1), labels = c("0%", "50%", "100%")) +
    labs(x = NULL, y = NULL, title = "What the models predicted",
         subtitle = sprintf("Green bar = what actually happened (%s)", toupper(actual))) +
    theme_minimal(base_size = 10) +
    theme(panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
          strip.text = element_text(face = "bold", hjust = 0, size = 10),
          plot.title = element_text(face = "bold", size = 11), plot.subtitle = element_text(size = 9, colour = "grey30"),
          axis.text.y = element_text(size = 10, colour = "grey15"))
}

#' The numbers the logistic model sees, in words (time to act is also the transformer's clock input).
facts_panel <- function(meta, clocks) {
  shot_clock <- if (is.na(clocks$shot)) "off" else sprintf("%.0f s", clocks$shot)
  # the models see time to act; older runs (before it existed) saw the shot clock with a missing value filled as 24
  tta <- if (!is.null(meta$time_to_act) && "time_to_act" %in% names(meta))
    sprintf("Time to act:  %.0f s  (shot clock %s, %s left in Q%d)", meta$time_to_act, shot_clock,
            fmt_clock(clocks$game), meta$period)
  else sprintf("Shot clock:  %s  (game clock %s in Q%d, not a model input)", shot_clock, fmt_clock(clocks$game), meta$period)
  lines <- c(sprintf("Closest defender:  %.1f ft away", meta$def1_dist),
             sprintf("   closing at %.1f ft/s%s", abs(meta$def1_closing),
                     if (meta$def1_closing < 0) " (moving away)" else ""),
             sprintf("2nd defender:  %.1f ft away", meta$def2_dist),
             sprintf("Defenders in the paint:  %d", as.integer(meta$defs_in_paint)),
             sprintf("Receiver to hoop:  %.0f ft%s", meta$recv_hoop_dist, if (meta$recv_corner == 1) " (corner)" else ""),
             sprintf("Receiver speed at catch:  %.1f ft/s", meta$recv_speed),
             tta,
             sprintf("Pass came out of a drive:  %s", if (meta$kickout) "yes (strict kickout)" else "no"))
  cols <- rep("grey15", length(lines))
  if (meta$recv_hoop_dist > 40) {           # a catch "beyond the arc" this far out suggests broken positions
    lines <- c(lines, sprintf("CHECK THE DATA: receiver drawn %.0f ft from the hoop;", meta$recv_hoop_dist),
               "   positions or court direction may be wrong for this play")
    cols <- c(cols, "#b5179e", "#b5179e")
  }
  ggplot() +
    annotate("text", x = 0, y = rev(seq_along(lines)), label = lines, hjust = 0, size = 3.3, colour = cols) +
    scale_x_continuous(limits = c(0, 1)) + scale_y_continuous(limits = c(0.5, length(lines) + 0.5)) +
    labs(title = "At the catch") + theme_void(base_size = 10) +
    theme(plot.title = element_text(face = "bold", size = 11))
}

header_panel <- function(headline, sub) {
  ggplot() +
    annotate("text", x = 0, y = 0.72, label = headline, hjust = 0, size = 5.2, fontface = "bold", colour = "grey10") +
    annotate("text", x = 0, y = 0.2, label = sub, hjust = 0, size = 3.4, colour = "grey30", lineheight = 1) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) + scale_y_continuous(limits = c(0, 1)) + theme_void()
}

#' A full card. probs is a named list (model label -> named probability vector over CLASSES).
play_card <- function(root, meta, tokens, pids, roster, w, probs, headline) {
  off_team <- roster[pid == meta$receiver, team][1]
  teams <- unique(roster[game_id == meta$game_id, team])
  def_team <- setdiff(teams, off_team)[1]
  clocks <- pass_clocks(root, meta$game_id, meta$pass_id)
  sub <- sprintf("%s on offense vs %s | game %s | Q%d %s left\nDashboard: #/play/%s   (%s, catch frame %d)",
                 off_team, def_team, meta$game_id, meta$period, fmt_clock(clocks$game),
                 meta$poss_id, meta$pass_id, meta$catch)
  # the right-hand column is laid out on its own (wrap_elements), so a wide court cannot squash it; a court widened
  # to show the backcourt gets proportionally more of the card's width
  min_x <- min(HOOP_X - tokens[, "hoop_dx"])
  court_w <- if (min_x < 0) (COURT_X - floor(min_x - 3)) / COURT_X else 1
  right <- wrap_elements(full = prob_panel(probs, meta$label) / facts_panel(meta, clocks) +
                           plot_layout(heights = c(1.25, 1)) & theme(plot.margin = margin(4, 8, 4, 8)))
  header_panel(headline, sub) /
    (court_panel(tokens, pids, roster[game_id == meta$game_id], w) + right + plot_layout(widths = c(court_w, 1))) +
    plot_layout(heights = c(0.16, 1)) &
    theme(plot.margin = margin(4, 8, 4, 8))
}

CARD_CAPTION <- paste(
  "How to read the court: hoop on the right. Numbers are jerseys; the ringed player is the receiver.",
  "Grey arrows show where each player moves over the next 0.5 s.",
  "Purple lines show how much of the transformer's read went to each player (the receiver's last-layer attention,",
  "heads averaged); the three heaviest are labelled in purple. Attention shows where the model looked, not what changed its mind.",
  sep = "\n")
