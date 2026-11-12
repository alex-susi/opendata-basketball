# Probability strips for single screens: how a model's probability of each coverage call moves frame by frame, each
# defender's part of it, and the two defenders' raw positions underneath. Used by 04_evaluate.R for the live model
# (the archived models in zz_Archive/ used it too). One PNG per screen, five panels in three rows:
#   row 1  the ball handler's defender alone: over / under / switch (sums of the joint calls, e.g. over = over + show
#          + over + soft), smoothed | the screener's defender alone: show / soft / switch, smoothed
#   row 2  the five joint calls, smoothed | the five joint calls, raw, frame by frame
#   row 3  the raw positions: both defenders' level against the screener (full width)

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

STRIP_CALLS <- c("over + show", "over + soft", "under + soft", "under + show", "switch")
STRIP_COLS <- c(`over + show` = "#2a78d6", `over + soft` = "#eb6834", `under + soft` = "#1baf7a",
                `under + show` = "#eda100", switch = "#e87ba4")
PART_COLS <- c(over = "#2a78d6", under = "#1baf7a", switch = "#e87ba4", show = "#eda100", soft = "#eb6834")
BALL_PARTS <- c("over", "under", "switch")
BIG_PARTS <- c("show", "soft", "switch")
# A defender's part of a joint call: "over + show" gives "over" for the ball and "show" for the big; switch is both.
part_of <- function(call, which) ifelse(call == "switch", "switch", vapply(strsplit(call, " + ", fixed = TRUE), `[`, "", if (which == "ball") 1L else 2L))

#' Draw one strip per screen and write the numbers behind them.
#'   X        one row per screen and frame offset: id, off, frame, gc_now, sc_now, bd_lvl, sd_lvl
#'   prob     probabilities in the same row order as X, one column per call (STRIP_CALLS order)
#'   P        one row per screen: id, call, poss, period, h_name, s_name, bd_name, sd_name, h_arch, s_arch
#'   ids      the screens to draw; film: the film-check table (id, forecast_call, forecast_p, right) or NULL
#'   smooth   frames in the trailing average (never uses a later frame)
draw_strips <- function(X, prob, P, ids, film, model_label, csv_path, fig_dir, offs, fps = 25, smooth = 5L) {
  dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
  # The screens' rows with their probabilities, each defender's summed part, and trailing averages per screen.
  keep <- X$id %in% ids
  S <- X[keep, .(id, off, t = off / fps, frame, gc_now, sc_now, bd_lvl, sd_lvl)]
  S <- cbind(S, setnames(as.data.table(prob[keep, , drop = FALSE]), STRIP_CALLS))
  for (pt in BALL_PARTS) S[, (paste0("ball: ", pt)) := rowSums(.SD), .SDcols = STRIP_CALLS[part_of(STRIP_CALLS, "ball") == pt]]
  for (pt in BIG_PARTS) S[, (paste0("big: ", pt)) := rowSums(.SD), .SDcols = STRIP_CALLS[part_of(STRIP_CALLS, "big") == pt]]
  setorder(S, id, off)
  sm_cols <- c(STRIP_CALLS, paste0("ball: ", BALL_PARTS), paste0("big: ", BIG_PARTS))
  for (cl_ in sm_cols) S[, (paste0(cl_, " (smoothed)")) := frollmean(get(cl_), smooth, align = "right"), by = id]
  S[P, on = "id", `:=`(call = i.call, poss = i.poss, h_name = i.h_name, s_name = i.s_name, bd_name = i.bd_name,
                       sd_name = i.sd_name, period = i.period, h_arch = i.h_arch, s_arch = i.s_arch)]
  fwrite(S[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)], csv_path)

  # Labels: the game clock as "Q2 7:05", and players' surnames.
  clock <- function(gc, per) ifelse(is.na(gc), "?", sprintf("Q%d %d:%02d", per, floor(gc / 60), floor(gc %% 60)))
  last <- function(s) sub(".* ", "", s)
  xs <- scale_x_continuous(limits = range(offs) / fps, breaks = seq(-2, 1, 0.4), labels = function(v) sprintf("%+.1f s", v), expand = c(0, 0))
  unlink(list.files(fig_dir, pattern = "\\.png$", full.names = TRUE))
  # One figure per screen.
  for (k in seq_along(ids)) {
    s <- S[id == ids[k]]
    info <- s[off == 0]
    lab_film <- if (!is.null(film) && ids[k] %in% film$id) {
      f <- film[id == ids[k]]
      sprintf("Film check: the model's -0.4 s call was %s (%.0f%%), %s.", f$forecast_call, 100 * f$forecast_p,
              if (f$right) "right" else "wrong")
    } else "Worked example."
    # A stacked-area panel of probabilities for one set of columns.
    stack <- function(cols, levels, colours, ttl, prefix = "") {
      d <- melt(s[, c("t", cols), with = FALSE], id.vars = "t", variable.name = "call", value.name = "p")
      nm <- as.character(d$call)
      if (nzchar(prefix)) nm <- sub(prefix, "", nm, fixed = TRUE)
      d[, call := factor(sub(" \\(smoothed\\)", "", nm), levels = rev(levels))]
      ggplot(d[!is.na(p)], aes(t, p, fill = call)) +
        geom_area(colour = "white", linewidth = 0.25) +
        geom_vline(xintercept = 0, colour = "grey15", linetype = "dashed") +
        scale_fill_manual(values = colours, breaks = levels, name = NULL) +
        scale_y_continuous(labels = function(v) paste0(100 * v, "%"), expand = c(0, 0)) +
        xs +
        labs(subtitle = ttl, x = NULL, y = NULL) +
        theme_minimal(base_size = 10.5) +
        theme(panel.grid.minor = element_blank(), legend.position = "bottom", plot.subtitle = element_text(size = 9.5), legend.margin = margin(0, 0, 0, 0),
              legend.key.size = unit(10, "pt"))
    }
    # The four probability panels: joint calls smoothed and raw, and each defender's part.
    a <- stack(paste0(STRIP_CALLS, " (smoothed)"), STRIP_CALLS, STRIP_COLS,
               "Joint call, smoothed (average of the last 0.2 s; never uses a later frame)")
    bd <- stack(paste0("ball: ", BALL_PARTS, " (smoothed)"), BALL_PARTS, PART_COLS[BALL_PARTS],
                sprintf("Ball handler's defender (%s): over / under / switch, smoothed. Called: %s",
                        last(info$bd_name), part_of(info$call, "ball")), prefix = "ball: ")
    bg <- stack(paste0("big: ", BIG_PARTS, " (smoothed)"), BIG_PARTS, PART_COLS[BIG_PARTS],
                sprintf("Screener's defender (%s): show / soft / switch, smoothed. Called: %s",
                        last(info$sd_name), part_of(info$call, "big")), prefix = "big: ")
    b <- stack(STRIP_CALLS, STRIP_CALLS, STRIP_COLS, "Joint call, raw, frame by frame")   # keeps its legend so row 2 lines up
    # Bottom panel: both defenders' levels against the screener.
    lv <- melt(s[, .(t, `ball defender's level (bd_lvl)` = bd_lvl, `big's level (sd_lvl)` = sd_lvl)], id.vars = "t")
    c3 <- ggplot(lv, aes(t, value, colour = variable)) +
      geom_hline(yintercept = 0, colour = "grey40") +
      geom_vline(xintercept = 0, colour = "grey15", linetype = "dashed") +
      geom_line(linewidth = 0.8) +
      scale_colour_manual(values = c("#e34948", "#6250d6"), name = NULL) +
      xs +
      labs(subtitle = "The raw positions: feet above (+) or below (-) the screener's distance from the hoop",
           x = "Seconds relative to the screen tag (dashed line)", y = "ft") +
      theme_minimal(base_size = 10.5) +
      theme(legend.position = "top", panel.grid.minor = element_blank(), plot.subtitle = element_text(size = 9.5))
    # Assemble the three rows with the screen's title and the film-check note.
    g <- (bd | bg) / (a | b) / c3 + plot_layout(heights = c(1, 1, 0.8)) +
      plot_annotation(title = sprintf("Called %s: %s (%s) screens for %s (%s)", toupper(info$call), last(info$s_name), info$s_arch,
                                      last(info$h_name), info$h_arch),
                      subtitle = sprintf("%s guards the ball, %s guards the screener. Tag at %s, shot clock %.0f. Dashboard: #/play/%s\n%s Model: %s.",
                                         last(info$bd_name), last(info$sd_name), clock(info$gc_now, info$period),
                                         info$sc_now, info$poss, lab_film, model_label),
                      theme = theme(plot.title = element_text(face = "bold", size = 13), plot.subtitle = element_text(size = 9.5)))
    ggsave(file.path(fig_dir, sprintf("%02d_%s.png", k - 1, ids[k])), g, width = 15, height = 10.5, dpi = 140, bg = "white")
  }
  invisible(S)
}
