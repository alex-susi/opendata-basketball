# Annotations for the static site's play viewer: event locations, defensive context, shot details, possession
# context and season figures. Sourced by export_data.R after the app is loaded (`a`).
#
# Every location is in the viewer's frame. The event tables put the offense's hoop at negative x and its left at
# positive y; the viewer stores a top-down court with the offense attacking +x (see play_payload() in
# src/play_viewer/R/data.R), so an event location (x, y) is drawn at (-x, y). Over the ten games this puts shots,
# passes, dribbles, drives, closeouts, fouls, rebounds, turnovers and touches on the actor's tracked position
# (median gap under 0.01 ft).
#
# Picks, handoffs and off-ball screens are the exception: when the offense attacks the camera's left hoop, their y
# usually has the wrong sign (about 1,350 of 1,560 such events; the rest are right). Each one is placed on whichever
# of (-x, y) and (-x, -y) is nearer the screener's tracked position at that frame, or by the majority rule when he is
# not tracked; its region label is not used.
#
# Ids are the raw player ids of that game, as in the tracking. Nothing here is a model output: it is the delivered
# event fields, reshaped, plus the season aggregates summed per person and team.

ann_num <- function(recs, f) a$num_field(recs, f)
ann_int <- function(recs, f) a$int_field(recs, f)
ann_chr <- function(recs, f) a$chr_field(recs, f)
ann_lgl <- function(recs, f) a$lgl_field(recs, f)

#' One location field as two columns in the viewer's frame, rounded to 0.1 ft. Missing locations are NA.
ann_loc <- function(recs, f) {
  m <- vapply(recs, function(r) {
    v <- unlist(r[[f]])
    if (length(v) < 2) c(NA_real_, NA_real_) else c(-1, 1) * as.numeric(v[1:2])
  }, c(0, 0))
  list(round(m[1, ], 1), round(m[2, ], 1))
}

#' A table of records, or an empty table with the same columns when the family has none.
ann_table <- function(recs, build) if (length(recs)) build(recs) else NULL

#' Everything the annotations need from one game's event file, one table per kind, keyed by frame.
game_annotations <- function(game_id) {
  ev <- a$read_json_file(a$match_file(a$root, game_id, "_dynamic_events.json"))
  left_hoop <- setNames(ann_lgl(ev$possessions, "leftHoop"), ann_chr(ev$possessions, "id"))
  trk <- a$get_tracking(a$app_data, game_id)$players[, .(frame, pid, tx = x, ty = y)]

  ft <- ev$free_throws
  ft_rows <- data.table(shot = ann_chr(ft, "shotId"), foul = ann_chr(ft, "foulId"), made = ann_lgl(ft, "outcome"),
                        f = ann_int(ft, "frame"))[order(f)]
  ft_of <- function(key, ids) lapply(ids, function(i) if (is.na(i)) logical() else I(ft_rows$made[ft_rows[[key]] %in% i]))

  # Every player's position at each shot's release, by chance (a chance ends at its shot).
  cp <- ev$chance_players
  cp_loc <- ann_loc(cp, "shotLoc")
  ghosts <- data.table(chance = ann_chr(cp, "chanceId"), pid = ann_int(cp, "playerId"), x = cp_loc[[1]], y = cp_loc[[2]])[!is.na(x)]
  ghost_list <- split(ghosts[, .(pid, x, y)], ghosts$chance)

  shots <- ann_table(ev$shots, function(s) {
    l <- ann_loc(s, "location")
    out <- data.table(f = ann_int(s, "startFrame"), f1 = ann_int(s, "endFrame"), x = l[[1]], y = l[[2]],
                      pid = ann_int(s, "shooterId"), made = ann_lgl(s, "outcome"), three = ann_lgl(s, "three"),
                      fouled = ann_lgl(s, "fouled"), blocked = ann_lgl(s, "blocked"), blocker = ann_int(s, "blockerId"),
                      dist = round(ann_num(s, "distance"), 1), sq = round(ann_num(s, "shotQuality"), 1),
                      cl = ann_chr(s, "contestLevel"), defId = ann_int(s, "closestDefId"),
                      defDist = round(ann_num(s, "closestDefDist"), 1), rt = round(ann_num(s, "releaseTime"), 2),
                      drb = ann_int(s, "dribblesBefore"), cns = ann_lgl(s, "catchAndShoot"),
                      type = ann_chr(s, "complexShotType"), sc = round(ann_num(s, "shotClock"), 1),
                      passer = ann_int(s, "passerId"), assisted = ann_lgl(s, "assisted"), ao = ann_lgl(s, "assistOpp"),
                      region = ann_chr(s, "region"), chance = ann_chr(s, "chanceId"))
    out[, ft := ft_of("shot", ann_chr(s, "id"))]
    out[, ghosts := lapply(chance, function(ch) if (is.null(ghost_list[[ch]])) list() else ghost_list[[ch]])]
    out[, chance := NULL]
    out
  })

  passes <- ann_table(ev$passes, function(p) {
    l0 <- ann_loc(p, "passerLoc")
    l1 <- ann_loc(p, "receiverLoc")
    data.table(f = ann_int(p, "startFrame"), f1 = ann_int(p, "endFrame"), pid = ann_int(p, "passerId"),
               to = ann_int(p, "receiverId"), stealer = ann_int(p, "toReceiverId"), x0 = l0[[1]], y0 = l0[[2]],
               x1 = l1[[1]], y1 = l1[[2]], lost = ann_lgl(p, "turnover"))
  })

  dribbles <- ann_table(ev$dribbles, function(d) {
    l <- ann_loc(d, "location")
    data.table(f = ann_int(d, "frame"), pid = ann_int(d, "ballhandlerId"), x = l[[1]], y = l[[2]])
  })

  drives <- ann_table(ev$drives, function(d) {
    l0 <- ann_loc(d, "location")
    l1 <- ann_loc(d, "endLoc")
    data.table(f = ann_int(d, "startFrame"), f1 = ann_int(d, "endFrame"), pid = ann_int(d, "ballhandlerId"),
               def = ann_int(d, "ballhandlerDefId"), x0 = l0[[1]], y0 = l0[[2]], x1 = l1[[1]], y1 = l1[[2]],
               blowby = ann_lgl(d, "blowby"), dir = ann_chr(d, "direction"), end = ann_chr(d, "endType"),
               cat = ann_chr(d, "category"))
  })

  # Post-ups and isolations: who, when, his defender (for the trace panel's points-per-action lines).
  solos <- rbind(
    ann_table(ev$posts, function(p) data.table(kind = "post", f = ann_int(p, "startFrame"), pid = ann_int(p, "ballhandlerId"),
                                              def = ann_int(p, "ballhandlerDefId"), section = ann_chr(p, "section"))),
    ann_table(ev$isolations, function(p) data.table(kind = "isolation", f = ann_int(p, "startFrame"),
                                                    pid = ann_int(p, "ballhandlerId"), def = ann_int(p, "ballhandlerDefId"),
                                                    section = NA_character_)))

  # Picks, handoffs and off-ball screens: the screener's (setter's) spot, who used the screen and both coverages.
  screen_rows <- function(recs, kind, scr, use, cov_use, cov_scr) {
    ann_table(recs, function(r) {
      l <- ann_loc(r, "location")
      out <- data.table(f = ann_int(r, "frame"), kind = kind, x = l[[1]], y = l[[2]], scr = ann_int(r, scr),
                 use = ann_int(r, use), covUse = ann_chr(r, cov_use), covScr = ann_chr(r, cov_scr),
                 spot = if (kind == "off_ball_screen") NA_character_ else ann_chr(r, "locationType"))
      # The screener's tracked position in the viewer's frame, and which sign of y lands nearer it.
      lh <- left_hoop[ann_chr(r, "possessionId")]
      at <- trk[out[, .(frame = f, pid = scr)], on = .(frame, pid), mult = "first"]
      rot <- ifelse(lh %in% TRUE, -1, 1)
      vx <- rot * at$tx
      vy <- -rot * at$ty
      flip_y <- ifelse(is.na(vx), lh %in% TRUE,
                       (out$x - vx)^2 + (-out$y - vy)^2 < (out$x - vx)^2 + (out$y - vy)^2)
      out[flip_y, y := -y]
      out
    })
  }
  screens <- rbind(screen_rows(ev$picks, "pick", "screenerId", "ballhandlerId", "bhrDefType", "scrDefType"),
                   screen_rows(ev$handoffs, "handoff", "setterId", "receiverId", "receiverDefType", "setterDefType"),
                   screen_rows(ev$off_ball_screens, "off_ball_screen", "screenerId", "cutterId", "cutterDefType",
                               "screenerDefType"))

  closeouts <- ann_table(ev$closeouts, function(c) {
    l0 <- ann_loc(c, "startLoc")
    l1 <- ann_loc(c, "endLoc")
    data.table(f = ann_int(c, "startFrame"), f1 = ann_int(c, "endFrame"), def = ann_int(c, "ballhandlerDefId"),
               pid = ann_int(c, "ballhandlerId"), x0 = l0[[1]], y0 = l0[[2]], x1 = l1[[1]], y1 = l1[[2]],
               d0 = round(ann_num(c, "startDistance"), 1), d1 = round(ann_num(c, "endDistance"), 1),
               act = ann_chr(c, "bhrAction"))
  })

  fouls <- ann_table(ev$fouls, function(fo) {
    l <- ann_loc(fo, "location")
    out <- data.table(f = ann_int(fo, "frame"), x = l[[1]], y = l[[2]], by = ann_int(fo, "foulerId"),
                      on = ann_int(fo, "fouledId"), shooting = ann_lgl(fo, "shooting"), type = ann_chr(fo, "foulType"))
    out[, ft := ft_of("foul", ann_chr(fo, "id"))]
    out
  })

  rebounds <- ann_table(ev$rebounds, function(r) {
    l <- ann_loc(r, "location")
    data.table(f = ann_int(r, "frame"), x = l[[1]], y = l[[2]], pid = ann_int(r, "rebounderId"),
               def = ann_lgl(r, "defensive"), team = !ann_lgl(r, "rebounded"))
  })

  turnovers <- ann_table(ev$turnovers, function(t) {
    l <- ann_loc(t, "location")
    data.table(f = ann_int(t, "frame"), x = l[[1]], y = l[[2]], pid = ann_int(t, "turnedOverId"),
               stealer = ann_int(t, "stealerId"))
  })

  matchups <- ann_table(ev$matchups, function(m) {
    data.table(f = ann_int(m, "startFrame"), f1 = ann_int(m, "endFrame"), def = ann_int(m, "defPlayerId"),
               off = ann_int(m, "offPlayerId"))[!is.na(def) & !is.na(off) & f1 >= f]
  })

  # Chances: how each began, transition, tracking quality, points, and each player's minutes entering it.
  mins <- data.table(chance = ann_chr(cp, "chanceId"), pid = ann_int(cp, "playerId"),
                     min = round(ann_num(cp, "minutesPlayedBefore"), 1))[!is.na(min)]
  mins_list <- split(mins[, .(pid, min)], mins$chance)
  chances <- ann_table(ev$chances, function(ch) {
    out <- data.table(id = ann_chr(ch, "id"), poss = ann_chr(ch, "possessionId"), f = ann_int(ch, "startFrame"),
                      f1 = ann_int(ch, "endFrame"),
                      start = ann_chr(ch, "startType"), transition = ann_lgl(ch, "transition"),
                      q = ann_int(ch, "qualityIndex"), pts = ann_int(ch, "ptsScored"))
    # Three chances end before they start (KNOWN_ISSUES.md); their span is taken as written, in order.
    out[, `:=`(c0 = pmin(f, f1), c1 = pmax(f, f1))]
    out[, mins := lapply(id, function(i) if (is.null(mins_list[[i]])) list() else mins_list[[i]])]
    out
  })

  list(shots = shots, passes = passes, dribbles = dribbles, drives = drives, screens = screens, closeouts = closeouts,
       solos = solos, fouls = fouls, rebounds = rebounds, turnovers = turnovers, matchups = matchups, chances = chances)
}

#' The annotations inside one play's viewing window, as lists of records ready for JSON.
play_annotations <- function(g, lo, hi) {
  rows <- function(dt, a_col = "f", b_col = a_col) {
    if (is.null(dt)) return(list())
    sel <- dt[get(b_col) >= lo & get(a_col) <= hi]
    if (!nrow(sel)) return(list())
    sel <- sel[order(get(a_col))]
    lapply(seq_len(nrow(sel)), function(i) {
      r <- as.list(sel[i])
      r <- lapply(r, function(v) if (is.list(v)) v[[1]] else v)
      r[!vapply(r, function(v) length(v) == 1L && is.na(v), NA)]
    })
  }
  ch <- if (is.null(g$chances)) NULL else g$chances[, .(id, poss, f = c0, f1 = c1, start, transition, q, pts, mins)]
  list(shots = rows(g$shots), passes = rows(g$passes, "f", "f1"), dribbles = rows(g$dribbles),
       drives = rows(g$drives, "f", "f1"), screens = rows(g$screens), closeouts = rows(g$closeouts, "f", "f1"),
       solos = rows(g$solos),
       fouls = rows(g$fouls), rebounds = rows(g$rebounds), turnovers = rows(g$turnovers),
       matchups = rows(g$matchups, "f", "f1"), chances = rows(ch, "f", "f1"))
}

# ---- season figures from the aggregates ------------------------------------------------------------

#' Season figures per person and team from the three aggregate tables: counts only, summed over a person's alias
#' ids, so the viewer can form rates and show their sample sizes. Season-total rows (empty team_id) are left out:
#' a play shows a player with one team. Keyed "<canonical id>:<team id>".
season_figures <- function() {
  agg <- function(name) {
    dt <- fread(file.path(a$root, "data", "aggregates", sprintf("acb_%saggregates_20252026.csv", name)))
    dt <- dt[!is.na(team_id)]
    aliases <- fread(file.path(a$root, "data", "player_id_aliases.csv"))
    dt[, canon := a$canon_id(player_id, aliases)]
    dt
  }
  sum_by <- function(dt, cols) dt[, lapply(.SD, function(v) sum(v, na.rm = TRUE)), by = .(canon, team_id), .SDcols = cols]
  zones <- c(ra = "zone_restricted_area", paint = "zone_paint_non_ra", mid = "zone_mid_range",
             c3 = "zone_corner_3", ab3 = "zone_above_break_3")
  shot_cols <- c("games_played", "possessions_played", "attempts", "mades", "three_attempts", "three_mades", "total_points",
                 "ft_attempts", "ft_mades", "assisted_mades", "blocked_on_attempts", "fouled_fg_attempts", "cns_attempts", "cns_mades", "cns_three_mades",
                 "od_attempts", "od_mades", "od_three_mades", paste0(rep(zones, each = 2), c("_attempts", "_mades")))
  shots <- sum_by(agg("shots"), shot_cols)
  drives <- sum_by(agg("drives"), c("total_drives", "successful_drives", "points"))
  h_cov <- c("blitz", "ice", "over", "switch", "under")
  s_cov <- c("blitz", "ice", "show", "soft", "switch")
  pick_cols <- c("handler_total_picks", "handler_points", "screener_total_picks", "screener_points",
                 paste0("handler_picks_vs_", h_cov), paste0("handler_points_vs_", h_cov),
                 paste0("screener_picks_vs_", s_cov), paste0("screener_points_vs_", s_cov))
  picks <- sum_by(agg("picks"), pick_cols)
  keys <- unique(rbind(shots[, .(canon, team_id)], drives[, .(canon, team_id)], picks[, .(canon, team_id)]))
  out <- list()
  for (i in seq_len(nrow(keys))) {
    k <- keys[i]
    s <- shots[canon == k$canon & team_id == k$team_id]
    d <- drives[canon == k$canon & team_id == k$team_id]
    p <- picks[canon == k$canon & team_id == k$team_id]
    pair <- function(dt, n, m) if (nrow(dt)) I(c(dt[[n]], dt[[m]])) else NULL
    rec <- list(g = if (nrow(s)) s$games_played else NULL,
                poss = if (nrow(s)) s$possessions_played else NULL,
                pts = if (nrow(s)) s$total_points else NULL,
                fg3 = if (nrow(s)) I(c(s$three_attempts, s$three_mades)) else NULL,
                ft = if (nrow(s)) I(c(s$ft_attempts, s$ft_mades)) else NULL,
                astd = if (nrow(s)) s$assisted_mades else NULL,
                blkOn = if (nrow(s)) s$blocked_on_attempts else NULL,
                fouled = if (nrow(s)) s$fouled_fg_attempts else NULL,
                fg = if (nrow(s)) I(c(s$attempts, s$mades, s$three_mades)) else NULL,
                cns = if (nrow(s)) I(c(s$cns_attempts, s$cns_mades, s$cns_three_mades)) else NULL,
                od = if (nrow(s)) I(c(s$od_attempts, s$od_mades, s$od_three_mades)) else NULL,
                zone = if (nrow(s)) lapply(zones, function(z) I(c(s[[paste0(z, "_attempts")]], s[[paste0(z, "_mades")]]))) else NULL,
                drives = if (nrow(d)) I(c(d$total_drives, d$successful_drives, d$points)) else NULL,
                handler = pair(p, "handler_total_picks", "handler_points"),
                screener = pair(p, "screener_total_picks", "screener_points"),
                handlerVs = if (nrow(p)) lapply(setNames(h_cov, h_cov), function(c) I(c(p[[paste0("handler_picks_vs_", c)]], p[[paste0("handler_points_vs_", c)]]))) else NULL,
                screenerVs = if (nrow(p)) lapply(setNames(s_cov, s_cov), function(c) I(c(p[[paste0("screener_picks_vs_", c)]], p[[paste0("screener_points_vs_", c)]]))) else NULL)
    out[[paste0(k$canon, ":", k$team_id)]] <- rec[!vapply(rec, is.null, NA)]
  }
  out
}
