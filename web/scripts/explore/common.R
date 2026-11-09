# Shared layer for the site's seven exploration tabs (web/scripts/explore/build.R sources this first).
#
# Everything here is descriptive: counting, averaging and simple geometry on the ten tracked games. No model is
# fitted. Each topic script turns one per-game "bundle" into a document of sections and blocks that the site's
# Explore tab renders (web/src/components/Explore.svelte); the wording is written next to the numbers it quotes, so
# the text cannot drift from the tables.
#
# Frames and coordinates. Every position is in the play viewer's frame: the offense attacks the hoop at
# (+HOOP_X, 0). Tracking (x, y) becomes (sgn * x, -sgn * y) with sgn = -1 when the possession's offense shoots at the
# camera's left hoop (possessions.leftHoop), as play_payload() does; event locations become (-x, y) (annotations.R).
#
# The unit of analysis is the CHANCE (one scoring opportunity: an offensive rebound starts a new chance in the same
# possession), because shot quality, turnovers, free throws and offensive rebounds are all decided per chance. The
# outcomes of a chance, used by every tab:
#   pts      points the offense scored in it (its made field goals and free throws; rows of the other team left out)
#   fga      it had a field-goal attempt by the FIBA rule (fouled misses are free-throw trips, not FGA)
#   xpts     SkillCorner shotQuality / 100 x the shot's value (2 or 3), averaged over the chance's FGA. shotQuality is
#            the vendor's 0-100 score; its training data are not published, so xpts is a reference, not a validated
#            make probability (in these games it averages 1.02 per FGA against 1.03 actual points)
#   tov      it ended in a turnover by the offense
#   ftrip    the offense shot free throws in it (shooting fouls, and-ones and bonus fouls)
#   live     it ended in a missed FGA that was not fouled (the ball was live off the rim)
#   oreb     on a live miss: the offense kept the ball (an offensive rebound or a team rebound to the offense)
# The population is every chance that did not end the period or in a jump ball.

suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
})

M_FT <- 3.28084
HOOP_X <- 14 * M_FT - 1.575 * M_FT          # 40.76 ft: the hoop the offense attacks, in the viewer's frame
KEY_X <- 14 * M_FT - 5.8 * M_FT             # front of the key (free-throw line), 26.9 ft
KEY_HW <- 2.45 * M_FT                        # half-width of the key, 8.0 ft
THREE_R <- 6.75 * M_FT
THREE_Y <- 6.6 * M_FT
FPS <- 25

EX_CACHE <- file.path(a$root, "outputs", "cache", "explore")
EX_OUT <- file.path(a$root, "web", "public", "data")
EX_GAMES <- as.integer(fromJSON(file.path(a$root, "data", "matches.json"))$id)

# ---- geometry ----------------------------------------------------------------------------------------------------

hoop_dist <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)
in_paint <- function(x, y) x >= KEY_X & abs(y) <= KEY_HW
beyond_arc <- function(x, y) {
  dx <- HOOP_X - x
  corner <- dx <= sqrt(THREE_R^2 - THREE_Y^2)
  fifelse(corner, abs(y) >= THREE_Y, sqrt(dx^2 + y^2) >= THREE_R) & x > 0
}
#' Coarse floor zone of a frontcourt spot (viewer frame).
floor_zone <- function(x, y) {
  d <- hoop_dist(x, y)
  dx <- HOOP_X - x
  fifelse(x <= 0, "backcourt",
  fifelse(d <= 4.1 * 1.0 + 0, "rim",
  fifelse(in_paint(x, y), "paint",
  fifelse(!beyond_arc(x, y), "mid-range",
  fifelse(dx <= sqrt(THREE_R^2 - THREE_Y^2), "corner three",
  fifelse(d > 31.5, "deep", "above-break three"))))))
}
#' Area of the convex hull of a set of points (shoelace on chull's order); NA for fewer than three points.
hull_area <- function(x, y) {
  ok <- !is.na(x) & !is.na(y)
  x <- x[ok]; y <- y[ok]
  if (length(x) < 3) return(NA_real_)
  h <- chull(x, y)
  hx <- x[h]; hy <- y[h]
  abs(sum(hx * c(hy[-1], hy[1]) - c(hx[-1], hx[1]) * hy)) / 2
}
#' Distance from points (px, py) to the segment (ax, ay)-(bx, by), and how far along it they project (0-1).
seg_dist <- function(px, py, ax, ay, bx, by) {
  vx <- bx - ax; vy <- by - ay
  L2 <- pmax(vx^2 + vy^2, 1e-9)
  t <- pmin(1, pmax(0, ((px - ax) * vx + (py - ay) * vy) / L2))
  list(d = sqrt((ax + t * vx - px)^2 + (ay + t * vy - py)^2), t = ((px - ax) * vx + (py - ay) * vy) / L2)
}

# ---- intervals and summaries --------------------------------------------------------------------------------------

Z90 <- 1.645
#' A rate with its 90% Wilson interval.
wilson <- function(k, n, z = Z90) {
  if (!n) return(list(rate = NA_real_, lo = NA_real_, hi = NA_real_))
  p <- k / n
  c0 <- (p + z^2 / (2 * n)) / (1 + z^2 / n)
  h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)
  list(rate = p, lo = max(0, c0 - h), hi = min(1, c0 + h))
}
#' One RateDots row for a share.
rrow <- function(label, k, n) c(list(label = label, n = n), wilson(k, n))
#' One RateDots row for a mean (mean +- 1.645 standard errors).
mrow <- function(label, x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 2) return(list(label = label, n = n, rate = if (n) mean(x) else NA_real_, lo = NA_real_, hi = NA_real_))
  m <- mean(x); se <- sd(x) / sqrt(n)
  list(label = label, n = n, rate = m, lo = m - Z90 * se, hi = m + Z90 * se)
}
r2 <- function(v, d = 3) round(v, d)
pct <- function(v, d = 0) ifelse(is.na(v), "–", sprintf(paste0("%.", d, "f%%"), 100 * v))
num <- function(v, d = 2) ifelse(is.na(v), "–", formatC(v, format = "f", digits = d))
int <- function(v) formatC(as.integer(v), format = "d", big.mark = ",")

#' The outcome summary of a set of chances (one row per group): counts and the five chance outcomes.
outcomes_by <- function(ch, by) {
  ch[, .(n = .N, ppc = mean(pts), xpts = mean(xpts, na.rm = TRUE), fga = sum(fga),
         tov = mean(tov), ftrip = mean(ftrip), live = sum(live), oreb = sum(oreb & live) / pmax(1, sum(live)),
         efg = sum(efg_pts[fga]) / pmax(1, sum(fga))),
     by = by]
}
#' The five outcome charts (points, shot quality, turnovers, free throws, offensive rebounds) for one grouping.
#' `ch` must carry a column `grp` (labels) and the outcome columns; levels in `order` (all if NULL). `min_n` hides
#' groups with fewer chances.
outcome_panel <- function(ch, order = NULL, min_n = 10, base = NULL, title = "", label_width = 170, total = nrow(ch)) {
  if (is.null(order)) order <- unique(ch$grp)
  order <- order[order %in% ch$grp]
  order <- order[vapply(order, function(o) sum(ch$grp == o) >= min_n, NA)]
  base <- if (is.null(base)) ch else base
  rows <- function(fn) lapply(order, function(o) fn(o, ch[grp == o]))
  GRID(
    RATES(paste0(title, if (nzchar(title)) " · " else "", "points per chance"), fmt = "num2", unit = "points per chance",
          ref = mean(base$pts), refLabel = "all", label_width = label_width,
          rows = rows(function(o, d) mrow(o, d$pts))),
    RATES(paste0(title, if (nzchar(title)) " · " else "", "shot quality (xPts per FGA)"), fmt = "num2", unit = "xPts per FGA",
          ref = mean(base$xpts, na.rm = TRUE), refLabel = "all", label_width = label_width,
          rows = rows(function(o, d) mrow(o, d$xpts))),
    RATES(paste0(title, if (nzchar(title)) " · " else "", "turnover rate"), unit = "of chances end in a turnover",
          ref = mean(base$tov), label_width = label_width, rows = rows(function(o, d) rrow(o, sum(d$tov), nrow(d)))),
    RATES(paste0(title, if (nzchar(title)) " · " else "", "free-throw trip rate"), unit = "of chances with free throws",
          ref = mean(base$ftrip), label_width = label_width, rows = rows(function(o, d) rrow(o, sum(d$ftrip), nrow(d)))),
    RATES(paste0(title, if (nzchar(title)) " · " else "", "offensive rebound rate (live misses)"), unit = "of live misses kept",
          ref = sum(base$oreb & base$live) / max(1, sum(base$live)), label_width = label_width,
          rows = rows(function(o, d) rrow(o, sum(d$oreb & d$live), sum(d$live)))),
    RATES(paste0(title, if (nzchar(title)) " · " else "", "share of chances"), unit = "of chances",
          ref = NULL, label_width = label_width, rows = rows(function(o, d) rrow(o, nrow(d), total)))
  )
}
#' The same outcomes as one table (columns tinted against the whole population).
outcome_table <- function(ch, by, base = ch, min_n = 10, label = "Group", limit = 20, title = "", sort = "n") {
  t <- outcomes_by(ch, by)[n >= min_n]
  setnames(t, by[1], "grp")
  setorderv(t, sort, -1)
  ref <- outcomes_by(copy(base)[, all := 1L], "all")
  TABLE(title, limit = limit, rows = t, cols = list(
    col("grp", label),
    col("n", "Chances", "int"),
    col("ppc", "Pts/chance", "num2", ref = ref$ppc, scale = 0.25),
    col("xpts", "xPts/FGA", "num2", ref = ref$xpts, scale = 0.15),
    col("efg", "eFG%", "pct", ref = ref$efg, scale = 0.12),
    col("tov", "TOV%", "pct", ref = ref$tov, scale = 0.08, low = TRUE),
    col("ftrip", "FT trip%", "pct", ref = ref$ftrip, scale = 0.08),
    col("oreb", "OREB%", "pct", ref = ref$oreb, scale = 0.1),
    col("live", "Live misses", "int")))
}

# ---- document blocks (rendered by web/src/components/explore/Block.svelte) ----------------------------------------

P <- function(...) list(type = "p", text = paste0(...))
H <- function(text) list(type = "h", text = text)
TAKE <- function(...) list(type = "takeaway", text = paste0(...))
CAVEAT <- function(...) list(type = "caveat", text = paste0(...))
KPIS <- function(...) list(type = "kpis", items = list(...))
KPI <- function(label, value, sub = "") list(label = label, value = value, sub = sub)
GRID <- function(..., cols = 2) list(type = "grid", cols = cols, blocks = Filter(Negate(is.null), list(...)))
DETAILS <- function(summary, ...) list(type = "details", summary = summary, blocks = list(...))
#' Dot-and-interval rows. fmt: pct, pct1, num1, num2, int.
RATES <- function(title, rows, ref = NULL, fmt = "pct", unit = "", refLabel = "all", max = NULL, min = NULL,
                  label_width = 170, note = NULL) {
  rows <- Filter(function(r) !is.na(r$rate), rows)
  list(type = "rates", title = title, rows = rows, ref = ref, fmt = fmt, unit = unit, refLabel = refLabel, max = max,
       min = min, labelWidth = label_width, note = note)
}
COLS <- function(title, categories, series, fmt = "pct", xlabel = "", ylabel = "", labels = FALSE, note = NULL) {
  list(type = "columns", title = title, categories = as.list(categories), series = series, fmt = fmt, xlabel = xlabel,
       ylabel = ylabel, labels = labels, note = note)
}
SERIES1 <- function(name, values, color = NULL) list(name = name, values = as.list(unname(values)), color = color)
#' Points (x, y, g group index 0-2, tip) and lines (list of list(points = [[x, y], ...], label, color, dashed)).
SCAT <- function(title, points = NULL, lines = list(), groups = character(), xlabel = "", ylabel = "",
                 xfmt = "num1", yfmt = "num1", xdomain = NULL, ydomain = NULL, note = NULL, radius = 3, opacity = 0.55,
                 events = list()) {
  list(type = "scatter", title = title, points = points, lines = lines, groups = as.list(groups), xlabel = xlabel,
       ylabel = ylabel, xfmt = xfmt, yfmt = yfmt, xdomain = xdomain, ydomain = ydomain, note = note, radius = radius,
       opacity = opacity, events = events)
}
#' A line from vectors.
LINE <- function(x, y, label = NULL, color = NULL, dashed = FALSE) {
  ok <- !is.na(x) & !is.na(y)
  list(points = unname(Map(function(a, b) c(r2(a), r2(b)), x[ok], y[ok])), label = label, color = color, dashed = dashed)
}
#' A half-court density map of spots in the viewer's frame (shifted so the hoop is at 0, as CourtMap draws).
COURT <- function(title, x, y, w = NULL, caption = NULL, bw = 1.5) {
  ok <- !is.na(x) & !is.na(y) & x > 0
  pts <- data.table(x = r2(x[ok] - HOOP_X, 1), y = r2(y[ok], 1))
  if (!is.null(w)) pts[, w := r2(w[ok], 3)]
  list(type = "court", title = title, points = pts, caption = caption, bw = bw)
}
#' A table column. fmt: text, int, num1, num2, pct, pct1. ref/scale tint the cell blue above ref and red below
#' (low = TRUE flips which side is called better in the tooltip).
col <- function(key, label, fmt = "text", ref = NULL, scale = NULL, low = FALSE, title = NULL) {
  list(key = key, label = label, fmt = fmt, ref = ref, scale = scale, low = low, title = title)
}
TABLE <- function(title, cols, rows, limit = 15, note = NULL) {
  list(type = "table", title = title, cols = cols, rows = rows, limit = limit, note = note)
}
SECTION <- function(id, title, ...) list(id = id, title = title, blocks = Filter(Negate(is.null), list(...)))
DOC <- function(id, title, lead, sections) {
  list(id = id, title = title, lead = lead, built = format(Sys.time(), "%Y-%m-%d %H:%M"), sections = sections)
}
save_doc <- function(doc) {
  path <- file.path(EX_OUT, paste0("explore_", doc$id, ".json"))
  write_json(doc, path, auto_unbox = TRUE, digits = 4, na = "null", null = "null", dataframe = "rows")
  message("Wrote ", path, " (", round(file.size(path) / 1024), " KB)")
}

# ---- the per-game bundle ------------------------------------------------------------------------------------------

xf <- function(recs, f) a$num_field(recs, f)
xi <- function(recs, f) a$int_field(recs, f)
xc <- function(recs, f) a$chr_field(recs, f)
xl <- function(recs, f) a$lgl_field(recs, f)
xlist <- function(recs, f) lapply(recs, function(r) as.character(unlist(r[[f]])))
#' An event location field in the viewer's frame.
xloc <- function(recs, f) {
  m <- vapply(recs, function(r) { v <- unlist(r[[f]]); if (length(v) < 2) c(NA_real_, NA_real_) else c(-1, 1) * as.numeric(v[1:2]) }, c(0, 0))
  list(m[1, ], m[2, ])
}
tbl <- function(recs, build) if (length(recs)) build(recs) else data.table()

#' Build (or read from outputs/cache/explore/) one game's bundle: events as tables keyed by chance, the chance
#' outcomes, the site's own cuts, screens and rebounding roles, and the tracking in the viewer's frame.
game_bundle <- function(g, rebuild = FALSE) {
  path <- file.path(EX_CACHE, sprintf("bundle_%d.rds", g))
  if (!rebuild && file.exists(path)) return(readRDS(path))
  message("Building bundle for game ", g)
  ev <- a$read_json_file(a$match_file(a$root, g, "_dynamic_events.json"))
  an <- game_annotations(g)
  gid <- g
  roster <- a$app_data$roster[game_id == gid, .(pid, team = team_id, canon, name, jersey, team_name)]

  PS <- data.table(poss = xc(ev$possessions, "id"), off = xi(ev$possessions, "offTeamId"), def = xi(ev$possessions, "defTeamId"),
                     f0 = xi(ev$possessions, "startFrame"), f1 = xi(ev$possessions, "endFrame"),
                     left = xl(ev$possessions, "leftHoop"), period = xi(ev$possessions, "period"))[order(f0)]
  ch <- data.table(chance = xc(ev$chances, "id"), poss = xc(ev$chances, "possessionId"), period = xi(ev$chances, "period"),
                   f0 = xi(ev$chances, "startFrame"), f1 = xi(ev$chances, "endFrame"),
                   off = xi(ev$chances, "offTeamId"), def = xi(ev$chances, "defTeamId"),
                   start = xc(ev$chances, "startType"), outcome = xc(ev$chances, "outcome"),
                   transition = xl(ev$chances, "transition"), q = xi(ev$chances, "qualityIndex"),
                   sc0 = xf(ev$chances, "startShotClock"), gc0 = xf(ev$chances, "startGameClock"), gc1 = xf(ev$chances, "endGameClock"),
                   front = xi(ev$chances, "frontcourtFrame"), vendor_paint = xl(ev$chances, "ballInPaint"),
                   last = xc(ev$chances, "lastChanceId"))
  ch[, `:=`(c0 = pmin(f0, f1), c1 = pmax(f0, f1))]
  ch[, left := PS$left[match(ch$poss, PS$poss)]]
  ch[, game := g]

  sl <- xloc(ev$shots, "location")
  shots <- tbl(ev$shots, function(s) data.table(
    shot = xc(s, "id"), chance = xc(s, "chanceId"), poss = xc(s, "possessionId"), f = xi(s, "startFrame"), f1 = xi(s, "endFrame"),
    pid = xi(s, "shooterId"), team = xi(s, "offTeamId"), made = xl(s, "outcome"), three = xl(s, "three"), fouled = xl(s, "fouled"),
    blocked = xl(s, "blocked"), assisted = xl(s, "assisted"), sq = xf(s, "shotQuality"), x = sl[[1]], y = sl[[2]],
    dist = xf(s, "distance"), region = xc(s, "region"), cl = xc(s, "contestLevel"),
    def = suppressWarnings(as.integer(xc(s, "closestDefId"))), defDist = xf(s, "closestDefDist"), rt = xf(s, "releaseTime"),
    drb = xi(s, "dribblesBefore"), cst = xc(s, "complexShotType"), stype = xc(s, "shotType"), cns = xl(s, "catchAndShoot"),
    touch = xc(s, "touchId"), sc = xf(s, "shotClock")))
  shots[, `:=`(fga = !(fouled & !made), value = fifelse(three, 3L, 2L))]
  shots[, xpts := sq / 100 * value]
  shots[, zone := fifelse(three, "three", fifelse(region %in% "ra" | (is.na(region) & dist <= 4.1), "rim",
                   fifelse(region %in% "key", "paint", "mid-range")))]
  shots[, zone := fifelse(three, "three", zone)]

  ft <- tbl(ev$free_throws, function(r) data.table(chance = xc(r, "chanceId"), team = xi(r, "offTeamId"), made = xl(r, "outcome"),
                                                   shot = xc(r, "shotId"), foul = xc(r, "foulId"), f = xi(r, "frame")))
  rb <- tbl(ev$rebounds, function(r) {
    l <- xloc(r, "location")
    data.table(shot = xc(r, "shotId"), chance = xc(r, "chanceId"), f = xi(r, "frame"), pid = xi(r, "rebounderId"),
               team = xi(r, "teamId"), defensive = xl(r, "defensive"), got = xl(r, "rebounded"), fg = xl(r, "fgReb"),
               next_chance = xc(r, "nextChanceId"), x = l[[1]], y = l[[2]], touch = xc(r, "touchId"))
  })
  to <- tbl(ev$turnovers, function(r) data.table(chance = xc(r, "chanceId"), f = xi(r, "frame"), pid = xi(r, "turnedOverId"),
                                                 team = xi(r, "offTeamId"), touch = xc(r, "touchId")))
  if (nrow(to) && !is.null(an$turnovers) && nrow(an$turnovers) == nrow(to)) to[, kind := an$turnovers$kind]
  fo <- tbl(ev$fouls, function(r) data.table(chance = xc(r, "chanceId"), f = xi(r, "frame"), by = xi(r, "foulerId"),
                                             on = xi(r, "fouledId"), shooting = xl(r, "shooting"), type = xc(r, "foulType"),
                                             fouled_team = xi(r, "fouledTeamId"), shot = xc(r, "shotId")))
  tl0 <- xloc(ev$touches, "location"); tl1 <- xloc(ev$touches, "endLoc")
  touches <- tbl(ev$touches, function(r) data.table(
    touch = xc(r, "id"), chance = xc(r, "chanceId"), pid = xi(r, "playerId"), team = xi(r, "offTeamId"),
    f0 = xi(r, "startFrame"), f1 = xi(r, "endFrame"), x0 = tl0[[1]], y0 = tl0[[2]], x1 = tl1[[1]], y1 = tl1[[2]],
    ndrb = xi(r, "numDribbles"), def = xi(r, "defenderId"), shot_touch = xl(r, "ledToShot"), ttime = xf(r, "touchTime"),
    regions = vapply(xlist(r, "regionsIn"), paste, "", collapse = "|"), outs = vapply(xlist(r, "outcomes"), paste, "", collapse = "|")))
  touches[, vendor_paint := grepl("(^|\\|)(key|ra)(\\||$)", regions)]
  passes <- tbl(ev$passes, function(r) data.table(chance = xc(r, "chanceId"), f0 = xi(r, "startFrame"), f1 = xi(r, "endFrame"),
                                                  passer = xi(r, "passerId"), receiver = xi(r, "receiverId"),
                                                  complete = xl(r, "complete"), turnover = xl(r, "turnover"), touch = xc(r, "touchId")))
  act <- function(recs, kind, actor, def, f0 = "frame", f1 = NULL, extra = NULL) tbl(recs, function(r) {
    l <- xloc(r, "location")
    out <- data.table(id = xc(r, "id"), kind = kind, chance = xc(r, "chanceId"), f0 = xi(r, f0),
                      f1 = if (is.null(f1)) xi(r, f0) else xi(r, f1), actor = xi(r, actor), adef = xi(r, def),
                      x = l[[1]], y = l[[2]], touch = xc(r, "touchId"), direct = xl(r, "direct"))
    for (e in names(extra)) out[, (e) := extra[[e]](r)]
    out
  })
  picks <- act(ev$picks, "pick", "ballhandlerId", "ballhandlerDefId",
               extra = list(screener = function(r) xi(r, "screenerId"), sdef = function(r) xi(r, "screenerDefId"),
                            cov = function(r) xc(r, "bhrDefType"), scov = function(r) xc(r, "scrDefType"),
                            spot = function(r) xc(r, "locationType")))
  handoffs <- act(ev$handoffs, "handoff", "receiverId", "receiverDefId",
                  extra = list(screener = function(r) xi(r, "setterId"), sdef = function(r) xi(r, "setterDefId"),
                               cov = function(r) xc(r, "receiverDefType")))
  obs <- act(ev$off_ball_screens, "off-ball screen", "cutterId", "cutterDefId",
             extra = list(screener = function(r) xi(r, "screenerId"), sdef = function(r) xi(r, "screenerDefId"),
                          cov = function(r) xc(r, "cutterDefType"), led_shot = function(r) xl(r, "ledToShot")))
  drives <- act(ev$drives, "drive", "ballhandlerId", "ballhandlerDefId", f0 = "startFrame", f1 = "endFrame",
                extra = list(category = function(r) xc(r, "category"), blowby = function(r) xl(r, "blowby"),
                             end = function(r) xc(r, "endType"), dir = function(r) xc(r, "direction"),
                             through = function(r) xl(r, "dribbleThrough"),
                             outs = function(r) vapply(xlist(r, "bhrOutcomes"), paste, "", collapse = "|")))
  isos <- act(ev$isolations, "iso", "ballhandlerId", "ballhandlerDefId", f0 = "startFrame", f1 = "endFrame")
  posts <- act(ev$posts, "post-up", "ballhandlerId", "ballhandlerDefId", f0 = "startFrame", f1 = "endFrame")
  co <- tbl(ev$closeouts, function(r) {
    l0 <- xloc(r, "startLoc"); l1 <- xloc(r, "endLoc"); lb <- xloc(r, "location")
    data.table(id = xc(r, "id"), chance = xc(r, "chanceId"), ft = xi(r, "touchFrame"), f0 = xi(r, "startFrame"), f1 = xi(r, "endFrame"),
               actor = xi(r, "ballhandlerId"), adef = xi(r, "ballhandlerDefId"), x = lb[[1]], y = lb[[2]],
               dx0 = l0[[1]], dy0 = l0[[2]], dx1 = l1[[1]], dy1 = l1[[2]],
               d_touch = xf(r, "touchDistance"), d0 = xf(r, "startDistance"), d1 = xf(r, "endDistance"),
               bhr_action = xc(r, "bhrAction"), touch = xc(r, "touchId"), direct = xl(r, "direct"), region = xc(r, "region"),
               outs = vapply(xlist(r, "bhrOutcomes"), paste, "", collapse = "|"))
  })
  # The site's corrected screen locations (annotations.R fixes the y sign of these tables).
  if (!is.null(an$screens) && nrow(an$screens)) {
    sc <- an$screens
    fix <- function(dt, k) if (nrow(dt)) { s <- sc[kind == k]; if (nrow(s) == nrow(dt)) dt[, `:=`(x = s$x, y = s$y)] }
    fix(picks, "pick"); fix(handoffs, "handoff"); fix(obs, "off_ball_screen")
  }
  mu <- tbl(ev$matchups, function(r) data.table(chance = xc(r, "chanceId"), f0 = xi(r, "startFrame"), f1 = xi(r, "endFrame"),
                                                def = xi(r, "defPlayerId"), off = xi(r, "offPlayerId")))[!is.na(def) & !is.na(off)]
  cp <- tbl(ev$chance_players, function(r) data.table(chance = xc(r, "chanceId"), pid = xi(r, "playerId"), offense = xl(r, "offense")))
  cuts <- if (is.null(an$cuts)) data.table() else copy(an$cuts)
  glass <- if (is.null(an$glass)) data.table() else copy(an$glass)

  # ---- chance outcomes ----
  ch[, pts := 0L]
  sp <- shots[made == TRUE, .(p = sum(value)), by = .(chance, team)]
  fp <- ft[made == TRUE, .(p = .N), by = .(chance, team)]
  allp <- rbind(sp, fp)[, .(p = sum(p)), by = .(chance, team)]
  ch[allp, on = .(chance, off = team), pts := as.integer(i.p)]
  ch[, fga := chance %in% shots[fga == TRUE]$chance]
  xp <- shots[fga == TRUE, .(xpts = mean(xpts, na.rm = TRUE), efg_pts = sum(made * fifelse(three, 1.5, 1)),
                             nfga = .N), by = chance]
  ch[xp, on = "chance", `:=`(xpts = i.xpts, efg_pts = i.efg_pts / i.nfga)]
  ch[is.nan(xpts), xpts := NA_real_]
  ch[is.na(efg_pts), efg_pts := 0]
  ch[, tov := chance %in% to$chance]
  ch[, ftrip := chance %in% ft$chance | chance %in% fo[shooting == TRUE]$chance]
  live_shots <- shots[made == FALSE & fouled == FALSE]
  ch[, live := chance %in% live_shots$chance]
  kept <- rb[shot %in% live_shots$shot & defensive == FALSE]$shot
  ch[, oreb := chance %in% live_shots[shot %in% kept]$chance]
  # The chance's last shot event (its release frame ends the "before the outcome" window).
  last_shot <- shots[order(f)][, .SD[.N], by = chance]
  ch[last_shot, on = "chance", `:=`(shot_f = i.f, shot_id = i.shot, shot_zone = i.zone, shooter = i.pid)]
  ch[, cut_f := fifelse(is.na(shot_f), c1, pmin(c1, shot_f))]
  ch[, in_pop := !(outcome %in% c("EPD", "JMP"))]

  # ---- tracking in the viewer's frame, live frames inside possessions ----
  trk <- a$get_tracking(a$app_data, g)
  P0 <- trk$players[, .(frame, pid, x, y, det)]
  k <- findInterval(P0$frame, PS$f0)
  ok <- k > 0L & P0$frame <= PS$f1[pmax(k, 1L)]
  P0 <- P0[ok]; k <- k[ok]
  P0[, `:=`(poss = PS$poss[k], sgn = fifelse(PS$left[k], -1, 1), off_team = PS$off[k])]
  P0[, team := roster$team[match(pid, roster$pid)]]
  P0[, `:=`(x = sgn * x, y = -sgn * y, off = team == off_team)]
  P0[, c("sgn", "off_team", "team") := NULL]
  setkey(P0, frame, pid)
  Fr <- trk$frames[, .(frame, period, gc, sc, stopped, bx, by, bz)]
  k <- findInterval(Fr$frame, PS$f0)
  ok <- k > 0L & Fr$frame <= PS$f1[pmax(k, 1L)]
  Fr <- Fr[ok]; k <- k[ok]
  Fr[, `:=`(poss = PS$poss[k], s = fifelse(PS$left[k], -1, 1))]
  Fr[, `:=`(bx = s * bx, by = -s * by)][, s := NULL]
  # Chance and ball holder of each frame.
  cho <- ch[order(c0)]
  kc <- findInterval(Fr$frame, cho$c0)
  Fr[, chance := fifelse(kc > 0L & Fr$frame <= cho$c1[pmax(kc, 1L)], cho$chance[pmax(kc, 1L)], NA_character_)]
  tco <- touches[!is.na(f0) & !is.na(f1)][order(f0)]
  Fr[, holder := NA_integer_]
  Fr[tco, on = .(frame >= f0, frame <= f1), holder := i.pid]
  setkey(Fr, frame)

  B <- list(game = g, roster = roster, poss = PS, ch = ch, shots = shots, ft = ft, rb = rb, to = to, fo = fo,
            touches = touches, passes = passes, picks = picks, handoffs = handoffs, obs = obs, drives = drives,
            isos = isos, posts = posts, co = co, mu = mu, cp = cp, cuts = cuts, glass = glass, P = P0, Fr = Fr)
  dir.create(EX_CACHE, recursive = TRUE, showWarnings = FALSE)
  saveRDS(B, path)
  B
}

#' Positions of `pids` at `frames` (vectors of the same length), from the nearest tracked frame within 2.
pos_at <- function(B, frames, pids) {
  out <- data.table(i = seq_along(frames), x = NA_real_, y = NA_real_, det = NA_integer_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    hit <- B$P[.(frames[miss] + d, pids[miss]), .(x, y, det), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y, det = hit$det)]
  }
  out
}
#' Every tracked player at each of `frames` (long table: frame, pid, x, y, det, off).
players_at <- function(B, frames) B$P[.(unique(frames)), nomatch = 0L]

#' The assigned defender (matchups) of each attacker at a frame.
marker_of <- function(B, frames, offs) {
  m <- B$mu
  q <- data.table(i = seq_along(frames), f = frames, off = offs)
  q[, def := NA_integer_]
  if (nrow(m)) q[m, on = .(off, f >= f0, f <= f1), def := i.def]
  q$def
}

#' Every chance of every game with the bundle's outcomes (population only), plus the canonical shooter id.
all_chances <- function(BL) rbindlist(lapply(BL, function(B) B$ch[in_pop == TRUE]), fill = TRUE)

#' Season aggregate profile per canonical player: shooting, driving, archetype (for priors and labels).
season_profiles <- function() {
  al <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
  canon <- function(p) { m <- al$canonical_player_id[match(p, al$player_id)]; fifelse(is.na(m), p, m) }
  pick_rows <- function(d) {
    d <- copy(d); d[, canon := canon(player_id)]
    tot <- d[is.na(team_id) | team_name == "total"]
    d[!(canon %in% tot$canon) | is.na(team_id) | team_name == "total"]
  }
  sh <- pick_rows(fread(file.path(a$root, "data", "aggregates", "acb_shotsaggregates_20252026.csv")))
  dr <- pick_rows(fread(file.path(a$root, "data", "aggregates", "acb_drivesaggregates_20252026.csv")))
  s <- sh[, .(three_att = sum(three_attempts), three_made = sum(three_mades), att = sum(attempts),
              rim_att = sum(rim_attempts), rim_made = sum(rim_mades), poss = sum(possessions_played),
              cns3 = sum(cns_three_attempts), name = player_name[1]), by = canon]
  d <- dr[, .(drives = sum(total_drives), blowby = sum(blowby_count), drive_pts = sum(points)), by = canon]
  out <- merge(s, d, by = "canon", all = TRUE)
  out[is.na(drives), `:=`(drives = 0L, blowby = 0L, drive_pts = 0L)]
  out[, `:=`(three_pct = three_made / pmax(1, three_att), three_rate = three_att / pmax(1, att),
             three_per100 = 100 * three_att / pmax(1, poss), drives_per100 = 100 * drives / pmax(1, poss))]
  # Shrunk three-point percentage: 100 league-average attempts of prior weight.
  lg <- sum(out$three_made, na.rm = TRUE) / sum(out$three_att, na.rm = TRUE)
  out[, three_shrunk := (three_made + 100 * lg) / (three_att + 100)]
  mem <- tryCatch(fread(file.path(a$root, "outputs", "archetypes", "offense_membership.csv"))[, .(canon = pid, archetype)],
                  error = function(e) data.table(canon = integer(), archetype = character()))
  out <- merge(out, mem, by = "canon", all.x = TRUE)
  attr(out, "league_three") <- lg
  out
}

# ---- team geometry at given frames --------------------------------------------------------------------------------

#' Team shape at each frame (only frames with all ten players tracked):
#'   def_paint / off_paint   defenders / attackers inside the key
#'   def_hull / off_hull     area (sq ft) of each team's convex hull
#'   off_arc                 attackers beyond the three-point line
#'   open_mean               mean over the attackers without the ball of the distance to the nearest defender
#'   holder_open             the ball holder's distance to the nearest defender (NA when no holder)
#'   det                     share of the ten positions detected on camera (not extrapolated)
frame_geom <- function(B, frames) {
  W <- players_at(B, frames)
  W <- W[, if (.N == 10L && sum(off) == 5L) .SD, by = frame]
  if (!nrow(W)) return(data.table())
  W[B$Fr, on = "frame", holder := i.holder]
  G <- W[, .(def_paint = sum(!off & in_paint(x, y)), off_paint = sum(off & in_paint(x, y)),
             def_hull = hull_area(x[!off], y[!off]), off_hull = hull_area(x[off], y[off]),
             off_arc = sum(off & beyond_arc(x, y)), det = mean(det == 1L)), by = frame]
  A <- W[off == TRUE, .(frame, pid, ax = x, ay = y, holder)]
  D <- W[off == FALSE, .(frame, dx = x, dy = y)]
  J <- merge(A, D, by = "frame", allow.cartesian = TRUE)[, .(near = min(sqrt((ax - dx)^2 + (ay - dy)^2))), by = .(frame, pid, holder)]
  O <- J[, .(open_mean = mean(near[is.na(holder) | pid != holder]),
             holder_open = if (any(!is.na(holder) & pid == holder)) near[!is.na(holder) & pid == holder][1] else NA_real_), by = frame]
  merge(G, O, by = "frame")
}

#' Event-aligned team geometry: for events at frames `f` (with a group label), the mean of frame_geom's columns at
#' each offset (seconds) in `offsets`, sampled on the 25 fps grid. Returns long rows: grp, t, metric means, n.
aligned_geom <- function(B, f, grp, offsets = seq(-2, 2, by = 0.2)) {
  if (!length(f)) return(data.table())
  q <- CJ(i = seq_along(f), t = offsets)
  q[, frame := f[i] + as.integer(round(t * FPS))]
  q[, grp := grp[i]]
  # Stay inside the event's possession (no positions from the next possession).
  q[, poss0 := B$Fr$poss[match(f[i], B$Fr$frame)]]
  q[, possf := B$Fr$poss[match(frame, B$Fr$frame)]]
  q <- q[!is.na(possf) & possf == poss0]
  G <- frame_geom(B, unique(q$frame))
  if (!nrow(G)) return(data.table())
  merge(q[, .(i, t, frame, grp)], G, by = "frame")
}

# The site's dark categorical order (dataviz reference palette, dark steps), in fixed order; lines may use all
# eight, scatter groups only the first three.
PAL <- c("#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767")
#' Lines from a long table (x, y, grp) with legend names, coloured in the order of `levels`.
LINES_BY <- function(d, xcol, ycol, gcol, levels = unique(d[[gcol]])) {
  gv <- d[[gcol]]
  levels <- levels[levels %in% gv]
  lapply(seq_along(levels), function(j) {
    s <- as.data.frame(d)[gv == levels[j], , drop = FALSE]
    s <- s[order(s[[xcol]]), , drop = FALSE]
    l <- LINE(s[[xcol]], s[[ycol]], color = PAL[(j - 1) %% length(PAL) + 1])
    l$name <- levels[j]
    l
  })
}
#' Quantile bins of x as ordered labels ("lo-hi").
qbins <- function(x, k = 5, d = 0) {
  br <- unique(quantile(x, seq(0, 1, length.out = k + 1), na.rm = TRUE))
  lab <- sprintf(paste0("%.", d, "f-%.", d, "f"), head(br, -1), br[-1])
  factor(lab[findInterval(x, br, rightmost.closed = TRUE, all.inside = TRUE)], levels = lab)
}
