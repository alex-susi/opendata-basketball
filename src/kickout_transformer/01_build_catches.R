# Step 1: one row per perimeter catch, with what the receiver did next and one "token" per player.
#   Rscript src/kickout_transformer/01_build_catches.R
#
# Sample: every completed, live-ball pass (not an inbound) whose receiver was beyond the arc (receiverRegion is a
# "three" region). `kickout` marks the strict subset: the pass that ended a drive SkillCorner tagged endType = kickout.
#
# Label: the receiver's touch that starts at, or within 1 s after, the pass reception.
#   drive  the touch has a drives row (a drive that ends in a shot still counts as a drive: it was the first choice)
#   shot   otherwise, the touch has a shots row
#   pass   otherwise, the touch's outcomes include a pass
#   other  anything else (foul drawn without a shot, turnover, timeout, held ball)
#
# Tokens: the ten on-court players at the catch frame (the pass endFrame), in a frame where the offense attacks
# +x and the hoop is at (HOOP_X, 0). Positions use the play viewer's corrected orientation (raw y is mirrored, see
# src/play_viewer/R/data.R). Velocities are backward differences over 0.24 s, so nothing after the catch is used.
#   freeze tokens: position, velocity, position relative to the receiver, team and role flags
#   history tokens: the same, plus each player's displacement over the last 0.24 / 0.48 / 0.72 / 1.00 s
# Token order is receiver, then the other four attackers by distance to the receiver, then the five defenders by
# distance to the receiver. The transformer does not care about the order; it only makes the tables readable.
#
# Writes outputs/cache/kickout_transformer/catches.rds and outputs/kickout_transformer/sample_*.csv.

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
source(file.path(root, "src", "play_viewer", "R", "data.R"))
paths <- kt_paths(root)
suppressPackageStartupMessages(library(jsonlite))

FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M      # hoop centre, feet from half court (FIBA court, as in src/archetypes)
VEL_LAG <- 6L                          # frames: 0.24 s
HIST_LAGS <- c(6L, 12L, 18L, 25L)      # frames: 0.24, 0.48, 0.72, 1.00 s before the catch
TOL <- 2L                              # a tracked position may come from a frame at most 2 frames (0.08 s) away
MAX_REACT <- 25L                       # receiver's touch must start within 1 s of the reception

app <- load_app_data(root)
aliases <- fread(file.path(root, "data", "player_id_aliases.csv"))
arch <- fread(file.path(root, "outputs", "archetypes", "offense_membership.csv"), select = c("pid", "archetype"))

as_dt <- function(x) if (length(x)) as.data.table(x) else data.table()

# ---- labels --------------------------------------------------------------------------------------

label_game <- function(g) {
  ev <- fromJSON(match_file(root, g, "_dynamic_events.json"), simplifyVector = TRUE)
  ps <- as_dt(ev$passes); tc <- as_dt(ev$touches); dr <- as_dt(ev$drives); sh <- as_dt(ev$shots)
  ps <- ps[complete %in% TRUE & !(inbounds %in% TRUE) & grepl("three", receiverRegion)]
  tc[, outs := vapply(outcomes, paste, "", collapse = ",")]
  rec <- tc[, .(t_id = id, t_player = playerId, t_start = startFrame, t_outs = outs)]
  m <- rec[ps, on = .(t_player = receiverId, t_start >= endFrame), mult = "first", nomatch = NA,
           .(pass_id = i.id, game_id = g, poss_id = i.possessionId, chance_id = i.chanceId, period = i.period,
             pass_start = i.startFrame, catch = i.endFrame, passer = i.passerId, receiver = i.receiverId,
             passer_region = i.passerRegion, receiver_region = i.receiverRegion, pass_touch = i.touchId,
             shot_clock = i.shotClock, game_clock = i.endGameClock, t_id = x.t_id, t_start = x.t_start,
             t_outs = x.t_outs)]
  m[, react := t_start - catch]
  m[, kickout := pass_touch %in% dr[endType == "kickout"]$touchId]
  m[, from_paint := passer_region %in% c("key", "ra")]
  m[, label := fcase(is.na(t_id) | react > MAX_REACT, NA_character_,
                     t_id %in% dr$touchId, "drive",
                     t_id %in% sh$touchId, "shot",
                     grepl("PASS|AST", t_outs), "pass",
                     default = "other")]
  m[, other_kind := fifelse(label == "other", fcase(grepl("TO", t_outs), "turnover", grepl("FOU", t_outs), "foul",
                                                     grepl("TMO", t_outs), "timeout", default = "held / none"), NA_character_)]
  m
}

catches <- rbindlist(lapply(app$matches$game_id, label_game))
drops <- list(no_touch = catches[is.na(label), .N])
catches <- catches[!is.na(label)]

# ---- tokens --------------------------------------------------------------------------------------

#' Nearest tracked position of each (pid, frame) within TOL frames; NA where there is none.
lookup <- function(pl, pid, frame) {
  q <- data.table(pid = pid, frame = frame)
  hit <- pl[q, on = .(pid, frame), roll = "nearest", .(x = x.x, y = x.y, det = x.det, got = x.frame)]
  bad <- is.na(hit$got) | abs(hit$got - frame) > TOL
  hit[bad, c("x", "y", "det") := .(NA_real_, NA_real_, NA_integer_)]
  hit
}

FREEZE_FEATS <- c("hoop_dx", "y", "hoop_dist", "vx", "vy", "speed", "rel_x", "rel_y", "rel_dist",
                  "is_offense", "is_receiver", "is_passer", "detected")
HIST_FEATS <- c(FREEZE_FEATS, paste0(rep(c("dx_", "dy_"), length(HIST_LAGS)), rep(HIST_LAGS, each = 2)))

tokens_game <- function(g) {
  cg <- catches[game_id == g]
  if (!nrow(cg)) return(NULL)
  trk <- readRDS(tracking_cache_path(root, g))
  pl <- trk$players[, .(pid, frame, x, y, det, home)]
  setkey(pl, pid, frame)
  plays <- app$plays[game_id == g]
  roster <- app$roster[game_id == g]
  out <- vector("list", nrow(cg))
  for (i in seq_len(nrow(cg))) {
    r <- cg[i]
    play <- plays[id == r$poss_id]
    if (nrow(play) != 1L) play <- plays[start_frame <= r$catch & end_frame >= r$catch][1]
    if (!nrow(play) || is.na(play$left_hoop)) { out[[i]] <- list(drop = "no_possession"); next }
    # who is on court: everyone tracked within TOL frames of the catch
    near <- pl[frame >= r$catch - TOL & frame <= r$catch + TOL, .(home = home[1]), by = pid]
    off_home <- play$off_team == play$home_team
    near[, offense := home == off_home]
    if (near[, sum(offense)] != 5L || near[, sum(!offense)] != 5L || !(r$receiver %in% near$pid)) {
      out[[i]] <- list(drop = "not_5v5_at_catch"); next
    }
    flip <- if (play$left_hoop) -1 else 1
    lag_frames <- c(0L, HIST_LAGS)
    pos <- lapply(lag_frames, function(l) {
      h <- lookup(pl, near$pid, rep(r$catch - l, nrow(near)))
      h[, c("X", "Y") := .(flip * x, -flip * y)]
      h
    })
    if (anyNA(pos[[1]]$X)) { out[[i]] <- list(drop = "missing_position_at_catch"); next }
    if (any(vapply(pos[-1], function(h) anyNA(h$X), NA))) { out[[i]] <- list(drop = "missing_history"); next }
    now <- pos[[1]]; v0 <- pos[[2]]                         # pos[[2]] is 0.24 s earlier
    tok <- data.table(pid = near$pid, is_offense = as.numeric(near$offense),
                      X = now$X, Y = now$Y, detected = as.numeric(now$det),
                      vx = (now$X - v0$X) / (VEL_LAG / 25), vy = (now$Y - v0$Y) / (VEL_LAG / 25))
    for (k in seq_along(HIST_LAGS)) {
      set(tok, j = paste0("dx_", HIST_LAGS[k]), value = now$X - pos[[k + 1]]$X)
      set(tok, j = paste0("dy_", HIST_LAGS[k]), value = now$Y - pos[[k + 1]]$Y)
    }
    rx <- tok[pid == r$receiver, X]; ry <- tok[pid == r$receiver, Y]
    tok[, `:=`(hoop_dx = HOOP_X - X, y = Y, hoop_dist = sqrt((HOOP_X - X)^2 + Y^2), speed = sqrt(vx^2 + vy^2),
               rel_x = X - rx, rel_y = Y - ry, rel_dist = sqrt((X - rx)^2 + (Y - ry)^2),
               is_receiver = as.numeric(pid == r$receiver), is_passer = as.numeric(pid == r$passer))]
    tok[, grp := fifelse(is_receiver == 1, 0L, fifelse(is_offense == 1, 1L, 2L))]
    setorder(tok, grp, rel_dist)
    out[[i]] <- list(drop = NA_character_, tok = tok, flip = flip)
  }
  out
}

built <- unlist(lapply(app$matches$game_id, tokens_game), recursive = FALSE)
reason <- vapply(built, `[[`, "", "drop")
for (rsn in unique(na.omit(reason))) drops[[rsn]] <- sum(reason == rsn, na.rm = TRUE)
keep <- is.na(reason)
catches <- catches[keep]
toks <- lapply(built[keep], `[[`, "tok")

N <- length(toks)
freeze <- array(NA_real_, c(N, 10L, length(FREEZE_FEATS)), dimnames = list(NULL, NULL, FREEZE_FEATS))
hist <- array(NA_real_, c(N, 10L, length(HIST_FEATS)), dimnames = list(NULL, NULL, HIST_FEATS))
token_pid <- matrix(NA_integer_, N, 10L)
for (i in seq_len(N)) {
  freeze[i, , ] <- as.matrix(toks[[i]][, ..FREEZE_FEATS])
  hist[i, , ] <- as.matrix(toks[[i]][, ..HIST_FEATS])
  token_pid[i, ] <- toks[[i]]$pid
}

# ---- simple hand-built features (for the logistic baseline and for reading results) -----------------

catches[, row := .I]
catches[, `:=`(
  recv_hoop_dist = freeze[, 1, "hoop_dist"],
  recv_corner = as.numeric(abs(freeze[, 1, "y"]) > 6.6 * FT_PER_M - 1 & freeze[, 1, "hoop_dx"] < 14),
  recv_speed = freeze[, 1, "speed"],
  def1_dist = freeze[, 6, "rel_dist"],                                        # token 6 = defender nearest the receiver
  # closing speed of that defender: how fast the gap to the receiver is shrinking (ft/s, positive = closing)
  def1_closing = -((freeze[, 6, "rel_x"] * (freeze[, 6, "vx"] - freeze[, 1, "vx"]) +
                    freeze[, 6, "rel_y"] * (freeze[, 6, "vy"] - freeze[, 1, "vy"])) / pmax(freeze[, 6, "rel_dist"], 0.5)),
  def2_dist = freeze[, 7, "rel_dist"],
  defs_in_paint = rowSums(freeze[, 6:10, "is_offense"] == 0 & freeze[, 6:10, "hoop_dist"] < 16)
)]
# Time to act: whichever runs out first, the shot clock or the game clock (seconds). At the end of a period the shot
# clock is often off (NA); the game clock then sets the limit. Filling a missing shot clock with 24 made a buzzer-beater
# look like a fresh possession, so shot_clock_raw keeps the supplied value and time_to_act is the input that matters.
catches[, shot_clock_raw := shot_clock]
catches[, time_to_act := pmin(shot_clock_raw, game_clock, 24, na.rm = TRUE)]   # a missing mid-period shot clock counts as 24
catches[, shot_clock := fifelse(is.na(shot_clock), 24, shot_clock)]
roster <- app$roster[, .(game_id, pid, canon)]
catches[roster, canon := i.canon, on = .(game_id, receiver = pid)]
catches[is.na(canon), canon := receiver]
catches[arch, archetype := i.archetype, on = .(canon = pid)]
catches[is.na(archetype), archetype := "unassigned"]

saveRDS(list(meta = catches, freeze = freeze, hist = hist, token_pid = token_pid,
             freeze_feats = FREEZE_FEATS, hist_feats = HIST_FEATS, drops = drops,
             built = Sys.time()), file.path(paths$cache, "catches.rds"))

# ---- reports -------------------------------------------------------------------------------------

drop_tab <- data.table(reason = names(drops), catches = unlist(drops))
fwrite(drop_tab, file.path(paths$out, "sample_drops.csv"))
lab <- dcast(catches[, .N, by = .(game_id, label)], game_id ~ label, value.var = "N", fill = 0)
lab_k <- dcast(catches[kickout == TRUE, .N, by = .(game_id, label)], game_id ~ label, value.var = "N", fill = 0)
fwrite(lab, file.path(paths$out, "sample_labels_all.csv"))
fwrite(lab_k, file.path(paths$out, "sample_labels_kickout.csv"))
fwrite(catches[label == "other", .N, by = other_kind], file.path(paths$out, "sample_other_kinds.csv"))

cat("\nDropped:\n"); print(drop_tab)
cat("\nKept", N, "catches (", catches[kickout == TRUE, .N], "strict kickouts )\n")
print(catches[, .N, by = label][, share := round(N / sum(N), 3)][])
cat("\nStrict kickouts:\n"); print(catches[kickout == TRUE, .N, by = label][, share := round(N / sum(N), 3)][])
cat("\nOther, by kind:\n"); print(catches[label == "other", .N, by = other_kind])
cat("\nToken array:", paste(dim(freeze), collapse = " x "), "(catches x players x features)\n")
