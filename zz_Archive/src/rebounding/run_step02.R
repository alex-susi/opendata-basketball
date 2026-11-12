## ═════════════════════════════════════════════════════════════════════════════
# Step 02 of the rebounding manual: contact-state labels (rim or board contact, first player contact, tips, control,
# ball height at touch and at control) for every eligible missed shot, a stratified review with an untouched
# held-aside subset, and the agreement that decides which label types may be used later.
#   Rscript src/rebounding/run_step02.R --phase=calibrate|sample|label|pages|score|gate [--freeze] [--subset=dev|heldout]
# Phases, in order:
#   calibrate  break threshold from free flight (no labels)                       -> step02/detector_threshold.csv
#   sample     development and held-aside subsets                                 -> step02/review/sample.csv
#   label      automated labels for every eligible episode; --freeze records the  -> step02/auto_*.csv, detector_freeze.json
#              labeler's checksum (do this before the held-aside pages exist)
#   pages      review pages; dev pages show the automated labels, held-aside pages -> step02/review/{dev,heldout}_*.png
#              show neither them nor the credited rebounder (needs a frozen labeler for heldout)
#   score      agreement on the held-aside subset, height tables, contract file,  -> step02/*.csv, figures, contact_events.csv
#              example cases (reads the reviewer sheets in step02/review/)
#   gate       unit and gate tests and the status record                          -> gate_results/02_*
# Needs outputs/cache/rebounding/raw_*.rds and episodes.rds, and the Step 01 episode table.
## ═════════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
opt <- function(name, default = NULL) {
  v <- sub(paste0("^--", name, "="), "", grep(paste0("^--", name, "="), args, value = TRUE))
  if (length(v)) v[1] else default
}
phase <- opt("phase", "label")
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "step00.R", "contact_states.R")) source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step02$detector
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "step02")
rev_dir <- file.path(out, "review")
for (d in c(out, rev_dir, file.path(out, "figures"))) dir.create(d, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
audited <- readRDS(file.path(cache, "episodes.rds"))
hoops <- audited$hoops
s01 <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))
el <- merge(audited$episodes, s01[eligible == TRUE, .(shot_id = episode_id, credited_outcome, ball_keyframe,
                                                      player_detected, contact_proxy_frame)], by = "shot_id")
setorder(el, game_id, f0)

raws <- list()
read_raw <- function(g) {
  key <- as.character(g)
  if (is.null(raws[[key]])) {
    r <- readRDS(file.path(cache, sprintf("raw_%s.rds", g)))
    r$home_team <- matches$home_team$id[matches$id == g]
    raws[[key]] <<- r
  }
  raws[[key]]
}
hoop_of <- function(s) {
  h <- hoops[game_id == s$game_id & left_hoop == s$left_hoop]
  list(hx = h$hx, hy = h$hy)
}
threshold_path <- file.path(out, "detector_threshold.csv")
break_ft <- if (file.exists(threshold_path)) fread(threshold_path)$break_ft else NA_real_





## ═════════════════════════════════════════════════════════════════════════════
## 01 - CALIBRATE --------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One-step residuals on free flight, every eligible episode, no labels.

if (phase == "calibrate") {
  # free flight of made shots (config: break_population; the first rule, misses before the contact proxy, is kept in
  # the deviation note): release + 3 frames to endFrame - 3 frames
  made <- audited$episodes[made == TRUE & !is.na(f0) & !is.na(f1)]
  res <- rbindlist(lapply(seq_len(nrow(made)), function(k) {
    s <- made[k]
    stop_f <- s$f1 - 3L
    if (stop_f - s$f0 < 12L) return(NULL)
    tr <- contact_track(read_raw(s$game_id), s, s$f0 + 3L, stop_f, hoop_of(s), th$keyframe_tol_ft)
    r <- one_step_residuals(tr, th$g_track_ft_s2, th$fit_keys)
    if (length(r)) data.table(game_id = s$game_id, shot_id = s$shot_id, resid = r) else NULL
  }))
  # flights with a departure above break_exclude_flight_above_ft are carried balls or track jumps, not free flight
  not_free <- res[, .(not_free = any(resid > th$break_exclude_flight_above_ft)), by = shot_id]
  all_n <- uniqueN(res$shot_id)
  res <- res[shot_id %in% not_free[not_free == FALSE]$shot_id]
  q <- quantile(res$resid, c(0.5, 0.9, 0.99, th$break_quantile_revised, 1))
  thr <- max(th$break_floor_ft, ceiling(q[[4]] / 0.05) * 0.05)
  by_game <- res[, .(n = .N, median = median(resid), p99 = quantile(resid, 0.99)), by = game_id]
  fwrite(by_game, file.path(out, "free_flight_residuals_by_game.csv"))
  fwrite(data.table(break_ft = thr, quantile = th$break_quantile_revised, population = "made shots", flights = all_n,
                    flights_not_free = sum(not_free$not_free), residuals = nrow(res), episodes = uniqueN(res$shot_id),
                    median = q[[1]], p90 = q[[2]], p99 = q[[3]], q_break = q[[4]], max = q[[5]]), threshold_path)
  cat(sprintf("break threshold %.2f ft (q%.1f%% %.3f ft; %d residuals on %d episodes)\n", thr, 100 * th$break_quantile_revised,
              q[[4]], nrow(res), uniqueN(res$shot_id)))
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - SAMPLE: TWO DISJOINT STRATIFIED SUBSETS --------------------------------
## ═════════════════════════════════════════════════════════════════════════════

if (phase == "sample") {
  sm <- cfg$step02$sample
  if (file.exists(file.path(rev_dir, "sample.csv"))) stop("sample.csv exists; the sample is drawn once")
  lowq <- el$ball_keyframe <= quantile(el$ball_keyframe, sm$low_quality_quantile) |
    el$player_detected <= quantile(el$player_detected, sm$low_quality_quantile)
  el[, stratum := fcase(kind == "blocked", "blocked", kind == "airball or no contact", "airball or no contact",
                        kind == "backboard first", "backboard first", grepl("team award", credited_outcome), "team award",
                        credited_outcome == "off player", "offensive player rebound", lowq, "low tracking quality",
                        default = "ordinary defensive rebound")]
  set.seed(sm$seed)
  picked <- rbindlist(lapply(sm$strata, function(st) {
    pool <- el[stratum == st]
    take <- pool[sample(.N, min(.N, 2L * sm$per_stratum))]
    take[, subset := rep(c("heldout", "dev"), length.out = .N)]
    take[, .(shot_id, stratum, subset)]
  }))
  rest <- el[!shot_id %in% picked$shot_id]
  extra <- rest[sample(.N, 2L * sm$extra_random)][, .(shot_id, stratum = "random", subset = rep(c("heldout", "dev"), sm$extra_random))]
  picked <- rbind(picked, extra)
  picked <- merge(picked, el[, .(shot_id, game_id, f0, credited_outcome, kind)], by = "shot_id", sort = FALSE)
  # shuffle within subset so page order does not reveal the stratum
  picked <- picked[sample(.N)][order(subset)]
  picked[, item := seq_len(.N), by = subset]
  fwrite(picked, file.path(rev_dir, "sample.csv"))
  print(picked[, .N, by = .(subset, stratum)])
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - LABEL: EVERY ELIGIBLE EPISODE ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

if (phase == "label") {
  if (is.na(break_ft)) stop("run --phase=calibrate first")
  res <- lapply(seq_len(nrow(el)), function(k) {
    s <- el[k]
    r <- episode_contact_states(read_raw(s$game_id), s, hoop_of(s), th, break_ft)
    r$summary[, sequence_problems := paste(sequence_problems(r$summary, s$f0), collapse = ";")]
    r
  })
  summ <- rbindlist(lapply(res, `[[`, "summary"))
  evts <- rbindlist(lapply(res, `[[`, "events"), fill = TRUE)
  fwrite(summ, file.path(out, "auto_summary.csv"))
  fwrite(evts, file.path(out, "auto_events.csv"))
  print(summ[, .N, by = contact_kind])
  print(summ[, .N, by = first_contact_type])
  print(summ[, .N, by = terminal])
  print(summ[, .N, by = label_confidence])
  print(summ[nzchar(sequence_problems), .N, by = sequence_problems])
  if (!is.null(opt("freeze")) || "--freeze" %in% args) {
    rec <- list(frozen_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), break_ft = break_ft,
                contact_states_sha256 = sha256_file(file.path(here, "R", "contact_states.R")),
                config_step02_sha256 = paste(openssl::sha256(jsonlite::toJSON(cfg$step02, auto_unbox = TRUE))),
                auto_summary_sha256 = sha256_file(file.path(out, "auto_summary.csv")),
                note = "Held-aside pages may be drawn only after this record exists; the labeler must not change afterwards.")
    write_gate(file.path(out, "detector_freeze.json"), rec)
    cat("labeler frozen\n")
  }
}





## ═════════════════════════════════════════════════════════════════════════════
## 04 - PAGES ------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

draw_review <- function(raw, s, hoop, item, blind, auto, tag = if (blind) "HELD-ASIDE" else "DEV") {
  last <- s$rf + th$window_after_rebound
  tr <- contact_track(raw, s, s$f0 - 5L, last, hoop, th$keyframe_tol_ft)
  pl <- window_players(raw, s, tr$frame)
  rel <- function(f) f - s$f0
  from_near <- max(s$f0, s$f1 - 12L)
  nb <- nearest_players(tr, pl, tr$frame[tr$frame >= from_near])
  top <- nb[, .(dmin = min(d)), by = pid][order(dmin)][seq_len(min(5L, .N))]
  lab <- function(pid, off) sprintf("%s%d", ifelse(off, "O", "D"), pid %% 10000L)
  xr <- c(-5, rel(last))
  # Ball height and hoop distance over time, with the five nearest players' distances to the ball.
  par(mar = c(4, 4, 3, 1))
  plot(NA, xlim = xr, ylim = c(0, 16), xlab = "frames from release (25 per second)", ylab = "ft", xaxs = "i",
       main = sprintf("%s item %d   %s   game %d  release frame %d   %s", tag, item,
                      s$shot_id, s$game_id, s$f0, if (blind) "" else paste("credited:", s$credited_outcome, s$rpid)),
       cex.main = 0.95, xaxt = "n")
  abline(v = seq(ceiling(xr[1]), floor(xr[2])), col = "grey93")
  abline(v = seq(0, floor(xr[2]), 5), col = "grey80")
  axis(1, at = seq(0, floor(xr[2]), 5), cex.axis = 0.7)
  abline(h = RIM_Z, col = "orange", lty = 3)
  abline(h = th$floor_z_ft, col = "tan", lty = 3)
  abline(h = th$touch_ft, col = "grey60", lty = 3)
  lines(rel(tr$frame), sqrt((tr$x - hoop$hx)^2 + (tr$y - hoop$hy)^2), col = "grey50", lty = 2)
  cols <- c("#1b9e77", "#d95f02", "#7570b3", "#e7298a", "#66a61e")
  for (i in seq_len(nrow(top))) {
    p <- nb[pid == top$pid[i]]
    lines(rel(p$frame), p$d, col = cols[i], lwd = 1.6)
    m <- p[which.min(d)]
    text(rel(m$frame), m$d - 0.45, lab(m$pid, m$off), col = cols[i], cex = 0.75, font = 2)
  }
  lines(rel(tr$frame), tr$z, lwd = 1.8)
  points(rel(tr$frame[tr$key]), tr$z[tr$key], pch = 16, cex = 0.45)
  abline(v = rel(s$f1), col = "blue", lty = 2)
  mtext("endFrame", 3, 0, at = rel(s$f1), col = "blue", cex = 0.65)
  if (!blind) {
    abline(v = rel(s$rf), col = "red")
    mtext("REB", 3, 0, at = rel(s$rf), col = "red", cex = 0.65)
    a <- auto[episode_id == s$shot_id & !kind %in% c("released", "credited_rebound")]
    # a tip or block repeats its player_touch row: draw the more specific one
    a <- a[!(kind == "player_touch" & paste(frame) %in% paste(a[kind %in% c("tip", "block")]$frame))]
    if (nrow(a)) {
      code <- c(rim = "R", board = "B", rim_or_board = "RB", player_touch = "P", tip = "T", block = "K", floor = "F",
                unknown = "?", controlled = "C", out_of_bounds = "X")
      who <- fifelse(is.na(a$actor_id), "", as.character(a$actor_id %% 10000L))
      segments(rel(a$frame), 15.2, rel(a$frame), 16, col = "purple", lwd = 2)
      text(rel(a$frame), 14.8, code[a$kind], col = "purple", cex = 0.7, font = 2)
      text(rel(a$frame), 14.2, who, col = "purple", cex = 0.6)
    }
  }
  legend("topright", c("ball z (dots: measured)", "ball-hoop xy", "ball-player xy (5 nearest)"),
         lty = c(1, 2, 1), col = c("black", "grey50", cols[1]), bty = "n", cex = 0.7)
  # top-down: ball path from endFrame - 12 to the window end, player paths, final positions labelled
  par(mar = c(1, 1, 3, 1))
  plot(NA, xlim = c(14, 48), ylim = c(-20, 20), asp = 1, axes = FALSE, xlab = "", ylab = "",
       main = "top-down from endFrame - 12 (grey to black: ball; lines: players)", cex.main = 0.8)
  rect(-COURT_HALF_L, -COURT_HALF_W, COURT_HALF_L, COURT_HALF_W, border = "grey40")
  rect(COURT_HALF_L - 5.8 * FT_PER_M, -2.45 * FT_PER_M, COURT_HALF_L, 2.45 * FT_PER_M, border = "grey70")
  symbols(RIM_X, 0, circles = RIM_R, inches = FALSE, add = TRUE, fg = "orange", lwd = 2)
  b <- tr[frame >= from_near]
  points(b$xp, b$yp, pch = 16, cex = 0.4, col = grey(seq(0.8, 0, length.out = max(1L, nrow(b)))))
  pw <- pl[frame >= from_near]
  for (id in unique(pw$pid)) {
    p <- pw[pid == id][order(frame)]
    lines(p$px, p$py, col = if (p$off[1]) "tomato" else "steelblue", lwd = 1)
    e <- p[.N]
    points(e$px, e$py, pch = 21, bg = if (e$off) "tomato" else "steelblue", cex = 1.2)
    text(e$px, e$py + 1.1, lab(id, e$off), cex = 0.6)
  }
}

# Review pages for one subset; the held-aside pages hide the automated labels.
if (phase == "pages") {
  subset_name <- opt("subset", "dev")
  smp <- fread(file.path(rev_dir, "sample.csv"))[subset == subset_name]
  blind <- subset_name == "heldout"
  if (blind && !file.exists(file.path(out, "detector_freeze.json"))) stop("freeze the labeler before drawing held-aside pages")
  auto <- if (!blind) fread(file.path(out, "auto_events.csv")) else NULL
  per_page <- 2L
  smp[, page := (item - 1L) %/% per_page + 1L]
  for (p in unique(smp$page)) {
    png(file.path(rev_dir, sprintf("%s_%02d.png", subset_name, p)), width = 1700, height = 560 * per_page, res = 100)
    layout(matrix(seq_len(2L * per_page), ncol = 2, byrow = TRUE), widths = c(1.9, 1))
    for (k in which(smp$page == p)) {
      s <- el[shot_id == smp$shot_id[k]]
      draw_review(read_raw(s$game_id), s, hoop_of(s), smp$item[k], blind, auto)
    }
    dev.off()
  }
  # the reviewer sheet, written once; frames are entered as the pages show them, relative to release
  sheet <- file.path(rev_dir, sprintf("reviewer1_%s.csv", subset_name))
  if (!file.exists(sheet))
    fwrite(smp[, .(item, episode_id = shot_id, game_id, first_rim_or_board_rel = "", contact_kind = "",
                   first_player_contact_rel = "", first_contact_player_id = "", first_contact_type = "",
                   tips_rel = "", first_control_rel = "", controller_id = "", terminal = "",
                   label_confidence = "", note = "")][order(item)], sheet)
  if (blind && !file.exists(file.path(rev_dir, "reviewer2_heldout.csv"))) file.copy(sheet, file.path(rev_dir, "reviewer2_heldout.csv"))
  cat(nrow(smp), "episodes on", max(smp$page), "pages\n")
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - SCORE ------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' One labeler's held-aside labels in a common form: contact (contact / none / NA), the specific kind, frames, the
#' first touch's player and type, tips, control and terminal. Reviewer sheets use frames relative to release and the
#' page labels of players (O or D plus the id's last four digits); auto labels use frames and ids.
normalize_reviewer <- function(r, smp) {
  r <- merge(r, smp[, .(episode_id = shot_id, f0, off_ids, def_ids)], by = "episode_id")
  num <- function(v) suppressWarnings(as.integer(v))
  pid_of <- function(lab, off_ids, def_ids) {
    vapply(seq_along(lab), function(i) {
      l <- lab[i]
      if (is.na(l) || !grepl("^[OD][0-9]+$", l)) return(NA_integer_)
      ids <- as.integer(strsplit(if (startsWith(l, "O")) off_ids[i] else def_ids[i], ";")[[1]])
      hit <- ids[ids %% 10000L == as.integer(substring(l, 2))]
      if (length(hit) == 1L) hit else NA_integer_
    }, 0L)
  }
  r[, .(episode_id,
        contact = fcase(contact_kind %in% CONTACT_KINDS, "contact", contact_kind == "none", "none", default = NA_character_),
        kind = fifelse(contact_kind %in% c("rim", "board"), contact_kind, NA_character_),
        rim_frame = f0 + num(first_rim_or_board_rel),
        touch_frame = f0 + num(first_player_contact_rel), touch_none = first_player_contact_rel == "none",
        touch_player = pid_of(first_contact_player_id, off_ids, def_ids),
        touch_type = fifelse(first_contact_type %in% c("tip", "catch", "block", "none"), first_contact_type, NA_character_),
        n_tips = fifelse(is.na(tips_rel) | tips_rel == "", 0L, lengths(strsplit(tips_rel, ";"))),
        control_frame = f0 + num(first_control_rel), control_none = first_control_rel == "none",
        controller = pid_of(controller_id, off_ids, def_ids), terminal)]
}
normalize_auto <- function(a) {
  a[, .(episode_id,
        contact = fcase(contact_kind %in% CONTACT_KINDS, "contact", contact_kind == "none", "none", default = NA_character_),
        kind = fifelse(contact_kind %in% c("rim", "board"), contact_kind, NA_character_),
        rim_frame = first_rim_or_board_frame, touch_frame = first_player_contact_frame,
        touch_none = first_contact_type == "none", touch_player = first_contact_player_id,
        touch_type = fifelse(first_contact_type %in% c("tip", "catch", "block", "none"), first_contact_type, NA_character_),
        n_tips, control_frame = first_control_frame, control_none = is.na(first_control_frame),
        controller = controller_id, terminal)]
}

#' Cohen's kappa for two raters on the rows both resolved.
kappa2 <- function(a, b) {
  ok <- !is.na(a) & !is.na(b)
  a <- a[ok]
  b <- b[ok]
  if (length(a) < 2L) return(NA_real_)
  lv <- union(a, b)
  po <- mean(a == b)
  pe <- sum(vapply(lv, function(l) mean(a == l) * mean(b == l), 0))
  if (pe == 1) return(NA_real_)
  (po - pe) / (1 - pe)
}
wilson <- function(k, n, z = 1.96) {
  if (!n) return(c(NA_real_, NA_real_))
  p <- k / n
  c((p + z^2 / (2 * n) - z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2))) / (1 + z^2 / n),
    (p + z^2 / (2 * n) + z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2))) / (1 + z^2 / n))
}

#' Agreement of two labelers on the held-aside subset, one row per measure, judged against config step02$agreement.
agreement_table <- function(x, y, ag, n_total) {
  j <- merge(x, y, by = "episode_id", suffixes = c("_a", "_b"))
  rows <- list()
  add <- function(type, measure, k, n, value, target, kind = "share", resolved = NA_real_) {
    ci <- if (kind == "share") wilson(k, n) else c(NA_real_, NA_real_)
    rows[[length(rows) + 1L]] <<- data.table(type = type, measure = measure, agree = k, n = n, value = value,
                                             ci_low = ci[1], ci_high = ci[2], target = target)
  }
  # rim or board contact: contact vs none, and its frame
  both_c <- j[!is.na(contact_a) & !is.na(contact_b)]
  add("contact", "both resolved (share of subset)", nrow(both_c), n_total, nrow(both_c) / n_total, ag$contact_resolved_min)
  add("contact", "contact vs none, Cohen's kappa", sum(both_c$contact_a == both_c$contact_b), nrow(both_c),
      kappa2(both_c$contact_a, both_c$contact_b), ag$contact_kind_kappa_min, kind = "kappa")
  add("contact", "contact vs none, raw agreement", sum(both_c$contact_a == both_c$contact_b), nrow(both_c),
      mean(both_c$contact_a == both_c$contact_b), NA)
  cf <- j[!is.na(rim_frame_a) & !is.na(rim_frame_b)]
  add("contact", sprintf("frame within %d", ag$frame_tol_contact), sum(abs(cf$rim_frame_a - cf$rim_frame_b) <= ag$frame_tol_contact),
      nrow(cf), mean(abs(cf$rim_frame_a - cf$rim_frame_b) <= ag$frame_tol_contact), ag$contact_frame_share_min)
  rk <- j[!is.na(kind_a) & !is.na(kind_b)]
  add("rim vs board", "agreement where both name rim or board (not gated)", sum(rk$kind_a == rk$kind_b), nrow(rk),
      if (nrow(rk)) mean(rk$kind_a == rk$kind_b) else NA_real_, NA)
  # first player contact: player, frame, type
  tp <- j[!is.na(touch_player_a) & !is.na(touch_player_b)]
  add("first touch", "both name the player (share of subset)", nrow(tp), n_total, nrow(tp) / n_total, ag$first_touch_resolved_min)
  add("first touch", "same player", sum(tp$touch_player_a == tp$touch_player_b), nrow(tp),
      mean(tp$touch_player_a == tp$touch_player_b), ag$first_touch_player_min)
  tf <- j[!is.na(touch_frame_a) & !is.na(touch_frame_b)]
  add("first touch", sprintf("frame within %d", ag$frame_tol_player), sum(abs(tf$touch_frame_a - tf$touch_frame_b) <= ag$frame_tol_player),
      nrow(tf), mean(abs(tf$touch_frame_a - tf$touch_frame_b) <= ag$frame_tol_player), ag$first_touch_frame_share_min)
  tt <- j[touch_type_a %in% c("tip", "catch") & touch_type_b %in% c("tip", "catch")]
  add("touch type", "tip vs catch, Cohen's kappa", sum(tt$touch_type_a == tt$touch_type_b), nrow(tt),
      kappa2(tt$touch_type_a, tt$touch_type_b), ag$touch_type_kappa_min, kind = "kappa")
  add("touch type", "tip vs catch, raw agreement", sum(tt$touch_type_a == tt$touch_type_b), nrow(tt),
      if (nrow(tt)) mean(tt$touch_type_a == tt$touch_type_b) else NA_real_, NA)
  # control
  cc <- j[!is.na(controller_a) & !is.na(controller_b)]
  add("control", "both name the controller (share of subset)", nrow(cc), n_total, nrow(cc) / n_total, ag$control_resolved_min)
  add("control", "same controller", sum(cc$controller_a == cc$controller_b), nrow(cc),
      mean(cc$controller_a == cc$controller_b), ag$controller_min)
  ct <- j[!is.na(control_frame_a) & !is.na(control_frame_b)]
  add("control", sprintf("frame within %d", ag$frame_tol_player), sum(abs(ct$control_frame_a - ct$control_frame_b) <= ag$frame_tol_player),
      nrow(ct), mean(abs(ct$control_frame_a - ct$control_frame_b) <= ag$frame_tol_player), ag$control_frame_share_min)
  # tip chains
  bin <- function(n) pmin(n, 2L)
  tip_eps <- sum(j$n_tips_a > 0 | j$n_tips_b > 0)
  add("tip chain", "episodes with a tip by either labeler", tip_eps, n_total, tip_eps, ag$tip_min_episodes, kind = "count")
  add("tip chain", "same tip count (0 / 1 / 2+)", sum(bin(j$n_tips_a) == bin(j$n_tips_b)), nrow(j),
      mean(bin(j$n_tips_a) == bin(j$n_tips_b)), ag$tip_count_agree_min)
  add("terminal", "same terminal state (not gated)", sum(j$terminal_a == j$terminal_b), nrow(j), mean(j$terminal_a == j$terminal_b), NA)
  rbindlist(rows)
}

#' Which label types meet every prespecified criterion (and have enough jointly resolved episodes).
type_decisions <- function(tab, ag) {
  judged <- tab[!is.na(target)]
  judged[, met := fcase(measure %like% "share of subset", value >= target,
                        measure %like% "^episodes with a tip", value >= target,
                        default = !is.na(value) & value >= target & n >= ag$min_joint)]
  judged[, .(criteria = .N, met = sum(met), status = if (all(met)) "PASS" else "BLOCKED",
             unmet = paste(measure[!met], collapse = "; ")), by = type]
}

# Agreement of the frozen automated labels with each reviewer, and the contract file.
if (phase == "score") {
  ag <- cfg$step02$agreement
  freeze <- jsonlite::fromJSON(file.path(out, "detector_freeze.json"))
  if (sha256_file(file.path(here, "R", "contact_states.R")) != freeze$contact_states_sha256)
    stop("contact_states.R changed after the labeler was frozen")
  auto <- fread(file.path(out, "auto_summary.csv"))
  if (sha256_file(file.path(out, "auto_summary.csv")) != freeze$auto_summary_sha256) stop("auto labels changed after freezing")
  smp <- fread(file.path(rev_dir, "sample.csv"))[subset == "heldout"]
  smp <- merge(smp, s01[, .(shot_id = episode_id, off_ids = release_off_ids, def_ids = release_def_ids)], by = "shot_id")
  read_sheet <- function(f) fread(f, colClasses = "character", na.strings = NULL)
  r1 <- read_sheet(file.path(rev_dir, "reviewer1_heldout.csv"))
  r2 <- read_sheet(file.path(rev_dir, "reviewer2_heldout.csv"))
  if (any(!nzchar(r1$contact_kind))) stop("reviewer 1 has not finished the held-aside sheet")
  r2_done <- all(nzchar(r2$contact_kind))
  n1 <- normalize_reviewer(r1, smp)
  na <- normalize_auto(auto[episode_id %in% smp$shot_id])
  unmapped <- r1[grepl("^[OD][0-9]+$", first_contact_player_id) | grepl("^[OD][0-9]+$", controller_id), .N] -
    n1[, sum(!is.na(touch_player)) + 0L] * 0L
  pairs <- list(auto_vs_reviewer1 = list(na, n1))
  if (r2_done) {
    n2 <- normalize_reviewer(r2, smp)
    pairs$reviewer1_vs_reviewer2 <- list(n1, n2)
    pairs$auto_vs_reviewer2 <- list(na, n2)
  }
  tabs <- rbindlist(lapply(names(pairs), function(p) cbind(pair = p, agreement_table(pairs[[p]][[1]], pairs[[p]][[2]], ag, nrow(smp)))))
  dec <- rbindlist(lapply(names(pairs), function(p) cbind(pair = p, type_decisions(tabs[pair == p], ag))))
  fwrite(tabs, file.path(out, "agreement.csv"))
  fwrite(dec, file.path(out, "agreement_decisions.csv"))
  # every disagreement on the held-aside subset, for the report
  j <- merge(na, n1, by = "episode_id", suffixes = c("_auto", "_r1"))
  j <- merge(smp[, .(episode_id = shot_id, item, f0, stratum)], j, by = "episode_id")
  rel <- function(f, f0) fifelse(is.na(f), NA_integer_, as.integer(f - f0))
  dis <- j[, .(item, episode_id, stratum,
               contact = paste(contact_auto, contact_r1, sep = " / "),
               rim_rel = paste(rel(rim_frame_auto, f0), rel(rim_frame_r1, f0), sep = " / "),
               touch_rel = paste(rel(touch_frame_auto, f0), rel(touch_frame_r1, f0), sep = " / "),
               touch_player = paste(touch_player_auto, touch_player_r1, sep = " / "),
               touch_type = paste(touch_type_auto, touch_type_r1, sep = " / "),
               control_rel = paste(rel(control_frame_auto, f0), rel(control_frame_r1, f0), sep = " / "),
               controller = paste(controller_auto, controller_r1, sep = " / "),
               terminal = paste(terminal_auto, terminal_r1, sep = " / "),
               disagree = (contact_auto != contact_r1) %in% TRUE |
                 (abs(rim_frame_auto - rim_frame_r1) > ag$frame_tol_contact) %in% TRUE |
                 (touch_player_auto != touch_player_r1) %in% TRUE |
                 (abs(touch_frame_auto - touch_frame_r1) > ag$frame_tol_player) %in% TRUE |
                 (controller_auto != controller_r1) %in% TRUE |
                 (abs(control_frame_auto - control_frame_r1) > ag$frame_tol_player) %in% TRUE)][order(item)]
  fwrite(dis, file.path(out, "heldout_comparison.csv"))

  # ---- ball height at the first touch and at control, by touch type and detection quality ------------------------
  el_auto <- merge(auto, el[, .(episode_id = shot_id, f0, f1)], by = "episode_id")
  qz <- function(z) as.list(setNames(round(quantile(z, c(0.05, 0.25, 0.5, 0.75, 0.95), na.rm = TRUE), 2),
                                     c("p05", "p25", "median", "p75", "p95")))
  heights <- rbind(el_auto[first_contact_type %in% c("tip", "catch", "block"),
                           c(.(moment = "first touch", n = .N, above_rim = mean(ball_center_z_at_first_touch > RIM_Z, na.rm = TRUE)),
                             qz(ball_center_z_at_first_touch)),
                           by = .(type = first_contact_type, actor_detected = fifelse(first_touch_actor_detected %in% 1L, "detected", "extrapolated or unknown"))],
                   el_auto[!is.na(first_control_frame),
                           c(.(moment = "control", type = "control", n = .N, above_rim = mean(ball_center_z_at_control > RIM_Z, na.rm = TRUE)),
                             qz(ball_center_z_at_control)),
                           by = .(actor_detected = fifelse(controller_detected %in% 1L, "detected", "extrapolated or unknown"))],
                   fill = TRUE)
  setcolorder(heights, c("moment", "type", "actor_detected", "n"))
  fwrite(heights[order(moment, type, actor_detected)], file.path(out, "ball_height_by_touch_type.csv"))
  # the same heights read at the reviewer's frames on the held-aside subset
  rz <- rbindlist(lapply(seq_len(nrow(n1)), function(i) {
    r <- n1[i]
    s <- el[shot_id == r$episode_id]
    tr <- contact_track(read_raw(s$game_id), s, s$f0, s$rf + th$window_after_rebound, hoop_of(s), th$keyframe_tol_ft)
    data.table(episode_id = r$episode_id, touch_type = r$touch_type,
               z_first_touch = if (is.na(r$touch_frame)) NA_real_ else tr[frame == r$touch_frame]$z[1],
               z_control = if (is.na(r$control_frame)) NA_real_ else tr[frame == r$control_frame]$z[1])
  }))
  fwrite(rz, file.path(out, "ball_height_heldout_reviewer1.csv"))

  # ---- the contract file: automated labels for every episode, reviewer labels for the held-aside subset ------------
  ev <- fread(file.path(out, "auto_events.csv"))
  status_of <- setNames(dec[pair == "auto_vs_reviewer1"]$status, dec[pair == "auto_vs_reviewer1"]$type)
  kind_type <- c(rim = "contact", board = "contact", rim_or_board = "contact", block = "first touch", tip = "tip chain",
                 player_touch = "first touch", controlled = "control")
  ce <- ev[!kind %in% c("released"), .(episode_id, frame_idx = frame, kind, actor_id, confidence, ball_z_ft = round(ball_z_ft, 3),
                                       review_status = fifelse(kind == "credited_rebound", "official", "automated"),
                                       labeler = fifelse(kind == "credited_rebound", "event data", "auto_v1"))]
  ce[, gate_status := fifelse(kind %in% names(kind_type), status_of[kind_type[kind]], NA_character_)]
  # Reviewer 1's labels in the contract's row form, with each tip as its own row.
  r1_rows <- rbindlist(lapply(seq_len(nrow(n1)), function(i) {
    r <- n1[i]
    tips <- r1[episode_id == r$episode_id]$tips_rel
    f0 <- smp[shot_id == r$episode_id]$f0
    tip_rows <- if (nzchar(tips)) rbindlist(lapply(strsplit(tips, ";")[[1]], function(t) {
      p <- strsplit(t, ":")[[1]]
      data.table(frame_idx = f0 + as.integer(p[1]), kind = "tip",
                 actor_id = normalize_reviewer(copy(r1[episode_id == r$episode_id])[, first_contact_player_id := p[2]], smp)$touch_player)
    })) else NULL
    rows <- rbindlist(list(if (!is.na(r$rim_frame)) data.table(frame_idx = r$rim_frame, kind = r1[episode_id == r$episode_id]$contact_kind,
                                                               actor_id = NA_integer_),
                           if (!is.na(r$touch_frame)) data.table(frame_idx = r$touch_frame, actor_id = r$touch_player,
                                                                 kind = fifelse(r$touch_type %in% "block", "block", "player_touch")),
                           tip_rows,
                           if (!is.na(r$control_frame)) data.table(frame_idx = r$control_frame, kind = "controlled", actor_id = r$controller)),
                      use.names = TRUE, fill = TRUE)
    if (!nrow(rows)) return(NULL)
    rows[, `:=`(episode_id = r$episode_id, confidence = r1[episode_id == r$episode_id]$label_confidence)]
  }), fill = TRUE)
  zlook <- rbindlist(lapply(unique(r1_rows$episode_id), function(e) {
    s <- el[shot_id == e]
    contact_track(read_raw(s$game_id), s, s$f0, s$rf + th$window_after_rebound, hoop_of(s), th$keyframe_tol_ft)[, .(episode_id = e, frame_idx = frame, z)]
  }))
  r1_rows <- merge(r1_rows, zlook, by = c("episode_id", "frame_idx"), all.x = TRUE)
  r1_rows[, `:=`(ball_z_ft = round(z, 3), z = NULL, review_status = "reviewed (held-aside, blind)", labeler = "reviewer1",
                 gate_status = NA_character_)]
  contract <- rbind(ce, r1_rows, fill = TRUE)
  setcolorder(contract, c("episode_id", "frame_idx", "kind", "actor_id", "confidence", "ball_z_ft", "review_status", "labeler", "gate_status"))
  ann_dir <- file.path(root, "outputs", "rebounding", "annotations")
  dir.create(ann_dir, recursive = TRUE, showWarnings = FALSE)
  fwrite(contract[order(episode_id, frame_idx, labeler)], file.path(ann_dir, "contact_events.csv"))

  # ---- example cases with their tracking: a false positive and an ambiguous episode ------------------------------
  # false positive: the frozen labeler names a first touch where the reviewer saw a different player more than the
  # tolerance away, or none; ambiguous: the reviewer could name neither the first touch nor the controller
  fp <- dis[disagree == TRUE & !grepl("^NA /", touch_player) & !grepl("/ NA$", touch_player) &
              vapply(strsplit(touch_player, " / "), function(v) v[1] != v[2], NA)][1]
  if (!nrow(fp) || is.na(fp$item)) fp <- dis[disagree == TRUE][1]
  amb <- j[is.na(touch_player_r1) & is.na(controller_r1)][order(item)][1]
  ev_all <- fread(file.path(out, "auto_events.csv"))
  for (case in list(list(name = "false_positive", id = fp$episode_id, item = fp$item),
                    list(name = "ambiguous", id = amb$episode_id, item = amb$item))) {
    if (is.na(case$id)) next
    png(file.path(out, "figures", sprintf("%s.png", case$name)), width = 1700, height = 560, res = 100)
    layout(matrix(1:2, ncol = 2), widths = c(1.9, 1))
    s <- el[shot_id == case$id]
    draw_review(read_raw(s$game_id), s, hoop_of(s), case$item, FALSE, ev_all,
                tag = sprintf("HELD-ASIDE (%s, auto labels shown)", gsub("_", " ", case$name)))
    dev.off()
  }
  fwrite(data.table(case = c("false_positive", "ambiguous"), episode_id = c(fp$episode_id, amb$episode_id),
                    item = c(fp$item, amb$item)), file.path(out, "figures", "cases.csv"))

  # ---- order checks over every episode ------------------------------------------------------------------------------
  order_auto <- auto[, .N, by = .(sequence_problems = fifelse(is.na(sequence_problems) | !nzchar(as.character(sequence_problems)), "none", as.character(sequence_problems)))]
  r1_order <- n1[, .(episode_id, problems = vapply(seq_len(.N), function(i) {
    sm <- data.table(first_rim_or_board_frame = rim_frame[i], first_player_contact_frame = touch_frame[i],
                     first_contact_type = fcoalesce(touch_type[i], "UNKNOWN"), first_control_frame = control_frame[i],
                     out_of_bounds_frame = NA_integer_)
    paste(sequence_problems(sm, smp[shot_id == episode_id[i]]$f0), collapse = ";")
  }, ""))]
  fwrite(order_auto, file.path(out, "order_checks_auto.csv"))
  fwrite(r1_order, file.path(out, "order_checks_reviewer1.csv"))
  counts <- list(episodes = nrow(auto),
                 contact_kind = as.list(auto[, .N, by = contact_kind][, setNames(N, contact_kind)]),
                 first_contact_type = as.list(auto[, .N, by = first_contact_type][, setNames(N, first_contact_type)]),
                 terminal = as.list(auto[, .N, by = terminal][, setNames(N, terminal)]),
                 label_confidence = as.list(auto[, .N, by = label_confidence][, setNames(N, label_confidence)]))
  saveRDS(list(tabs = tabs, dec = dec, dis = dis, heights = heights, rz = rz, counts = counts, order_auto = order_auto,
               r1_order = r1_order, r2_done = r2_done, fp = fp, amb = amb, freeze = freeze), file.path(cache, "step02.rds"))
  print(tabs[, .(pair, type, measure, agree, n, value = round(value, 3), target)])
  print(dec)
  print(dis[disagree == TRUE])
}





## ═════════════════════════════════════════════════════════════════════════════
## 06 - GATE: TESTS AND THE STATUS RECORD --------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

if (phase == "gate") {
  sc <- readRDS(file.path(cache, "step02.rds"))
  gr <- file.path(root, "outputs", "rebounding", "gate_results")
  tests <- rbind(run_tests(here, root, "unit", "contact_states"), run_tests(here, root, "gates", "step_02"), fill = TRUE)
  fwrite(tests, file.path(gr, "02_tests.csv"))
  tests_pass <- nrow(tests) > 0 && !any(tests$failed > 0 | tests$error)
  dec <- sc$dec[pair == if (sc$r2_done) "reviewer1_vs_reviewer2" else "auto_vs_reviewer1"]
  # a label type describing the first touch can be used only if the first touch itself passed
  dec[, usable := status == "PASS" & (type != "touch type" | "PASS" %in% dec[type == "first touch"]$status)]
  passed <- dec[usable == TRUE]$type
  status <- if (tests_pass && length(passed)) "PASS" else "BLOCKED"
  tab <- sc$tabs[pair == dec$pair[1]]
  # Added 2026-11-05 when reviewer 2 finished (record text only; the decision rule above is unchanged): reviewer
  # agreement shows a label type can be read reliably; the automated labels that cover every episode are a separate
  # question, judged against each reviewer that finished (every one must pass).
  auto_pairs <- intersect(c("auto_vs_reviewer1", "auto_vs_reviewer2"), unique(sc$dec$pair))
  auto_dec <- sc$dec[pair %in% auto_pairs, .(status = if (all(status == "PASS")) "PASS" else "BLOCKED",
                                             against = paste(sprintf("%s %s", sub("auto_vs_", "", pair), status), collapse = ", ")), by = type]
  # The gate record.
  rec <- list(step = "02", status = status,
              scope = if (length(passed)) sprintf("contact-state labels for: %s (%s; automated labels for every episode: %s)",
                                                  paste(passed, collapse = ", "),
                                                  if (sc$r2_done) "reliability between two reviewers, so usable where reviewed" else "automated labeler vs reviewer 1",
                                                  paste(sprintf("%s %s", auto_dec$type, auto_dec$status), collapse = ", ")) else
                "none: no contact-state label type met its reliability target; final credited rebounder only for Steps 03-09",
              labels_by_type = lapply(split(dec, dec$type), function(d) list(status = d$status, usable = d$usable,
                                                                             unmet = if (nzchar(d$unmet)) d$unmet else NULL)),
              automated_labels_by_type = lapply(split(auto_dec, auto_dec$type), function(d) list(status = d$status, against = d$against)),
              source_commits = list(skillcorner = cfg$dataset$upstream_commit),
              data_revision = list(upstream = cfg$dataset$upstream_commit, manifest = cfg$dataset$checksums),
              model_revision = list(labeler = "auto_v1", contact_states_sha256 = sc$freeze$contact_states_sha256,
                                    break_ft = sc$freeze$break_ft, frozen_at = sc$freeze$frozen_at),
              repository_head = git_out(root, "rev-parse", "HEAD")[1],
              test_command = "Rscript src/rebounding/run_tests.R unit contact_states; Rscript src/rebounding/run_tests.R gates step_02",
              unit_tests_passed = !any(tests[dir == "unit"]$failed > 0 | tests[dir == "unit"]$error),
              data_audit_passed = all(sc$order_auto$sequence_problems == "none"),
              heldout_metrics_file = "outputs/rebounding/step02/agreement.csv",
              acceptance_criteria_version = sprintf("manual %s, config v%d (step02, fixed 2026-10-29 before the held-aside subset was opened)",
                                                    cfg$manual_revision, cfg$config_version),
              agreement = lapply(split(tab, seq_len(nrow(tab))), function(r)
                list(type = r$type, measure = r$measure, agree = r$agree, n = r$n, value = round(r$value, 3), target = r$target)),
              labelers = list(a = "automated labeler auto_v1, frozen before the held-aside pages were drawn",
                              b = "reviewer 1 (Claude), tracking plots only, blind to the labeler and to the credited rebounder",
                              second_human_reviewer = if (sc$r2_done) "done (reviewer 2, the owner): the gate is judged on reviewer 1 vs reviewer 2" else "not done: outputs/rebounding/step02/review/reviewer2_heldout.csv is blank"),
              deviations = list(list(check = "break threshold: 99.5th percentile of one-step residuals on misses before the contact proxy (prespecified)",
                                     result = "2.20 ft (median residual 0.15 ft): 11% of those segments are not free flight",
                                     decision = "Replaced before any label was reviewed: made shots, release + 3 to endFrame - 3, flights with a residual above 1 ft excluded (35 of 346), 99th percentile: 0.65 ft. Owner to confirm."),
                                list(check = "second reviewer on the held-aside subset (manual: where practical)",
                                     result = if (sc$r2_done) "added 2026-11-05: the owner labelled the held-aside subset (reviewer2_heldout.csv)" else "no second person available in this session",
                                     decision = if (sc$r2_done) "Gate judged on reviewer 1 vs reviewer 2, as written before scoring. Both read the same tracking plots (no video), so agreement is consistency of tracking-based judgements, not accuracy. Automated-label status is reported separately (automated_labels_by_type)." else "Reliability measured between two independent labelers: the frozen automated labeler and a blind reviewer. Both read the same tracking and the reviewer wrote the labeler, so agreement is consistency of tracking-based judgements, not accuracy. A second human review can be added in reviewer2_heldout.csv and rescored."),
                                list(check = "contact kind kappa over rim / board / none (prespecified)",
                                     result = "the widened rim zone overlaps the board zone",
                                     decision = "Changed before freezing to contact vs none; rim vs board reported, not gated.")),
              counts = sc$counts,
              evidence = c("docs/project/ANNOTATION_RUBRIC.md", "outputs/rebounding/annotations/contact_events.csv",
                           "outputs/rebounding/reports/02_annotation_reliability.md", "src/rebounding/R/contact_states.R",
                           "outputs/rebounding/step02/agreement.csv", "outputs/rebounding/step02/agreement_decisions.csv",
                           "outputs/rebounding/step02/heldout_comparison.csv", "outputs/rebounding/step02/ball_height_by_touch_type.csv",
                           "outputs/rebounding/step02/ball_height_heldout_reviewer1.csv", "outputs/rebounding/step02/review/",
                           "outputs/rebounding/step02/figures/", "outputs/rebounding/step02/detector_freeze.json",
                           "outputs/rebounding/step02/detector_threshold.csv"),
              reviewer = if (sc$r2_done) "Claude (labeler author and blind reviewer 1); the owner (reviewer 2)" else "Claude (labeler author and blind reviewer 1); owner review pending",
              date = format(Sys.Date()),
              open_risks = list("No video: every label, the reviewer's included, comes from the same tracking",
                                "The reviewer wrote the labeler; the two labelers are not independent in method",
                                "30 held-aside episodes: wide intervals on every agreement measure",
                                "Ball heights near the rim read 1-2 ft high, and the control rule caps ball height at 9 ft, so control heights are truncated"),
              decision_note = if (status == "PASS") paste0("Usable label types: ", paste(passed, collapse = ", "),
                                                           if (any(auto_dec[type %in% passed]$status != "PASS")) ". Reviewed labels only: the automated labels of these types do not meet the targets against the reviewers, so models that need them on every episode stay blocked." else "") else
                "BLOCKED: continue with the final credited rebounder only for Steps 03-09; tip physics, controlled-catch and securing models stay blocked. Labels remain in the contract file for description, flagged by gate_status.")
  write_gate(file.path(gr, "02_contact_states.json"), rec)
  print(tests[, .(dir, file, test = substr(test, 1, 60), expectations, failed, error)])
  print(dec)
  cat("STEP 02:", status, "\n")
}
