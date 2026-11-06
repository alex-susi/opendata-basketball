# Step 02, labeler v2: a hidden Markov model of the ball after a missed shot (flight, on the rim, held, low and loose,
# and short rim / board / tip impacts) over per-frame tracking features at 25 Hz. v1 (run_step02.R) stays frozen.
#   Rscript src/rebounding/run_step02_v2.R --phase=sample|features|fit|decode|compare
# Phases, in order:
#   sample    new held-aside subset (drawn once, before any feature or fit) -> step02_v2/review/sample.csv
#   features  per-frame features for every eligible episode                -> cache/rebounding/hmm_features.rds
#   fit       EM fit (R/hmm_em.R) on episodes outside the new held-aside  -> step02_v2/hmm_fit.rds, state_means.csv
#   decode    Viterbi states and v2 labels for every eligible episode;     -> step02_v2/states.csv, auto_summary.csv,
#             development comparison on the 30 reviewer-1 episodes (v1 held-aside, now development)  dev_comparison.csv
# Settings: config/experiment.yaml (step02_v2, step02$detector).

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
opt <- function(name, default = NULL) {
  v <- sub(paste0("^--", name, "="), "", grep(paste0("^--", name, "="), args, value = TRUE))
  if (length(v)) v[1] else default
}
phase <- opt("phase", "sample")
suppressMessages(library(data.table))
source(file.path(here, "..", "play_viewer", "R", "data.R"))
for (f in c("geometry.R", "extract.R", "audit.R", "bundle.R", "step00.R", "contact_states.R", "hmm_features.R"))
  source(file.path(here, "R", f))

root <- find_repo_root()
cfg <- yaml::read_yaml(file.path(here, "config", "experiment.yaml"))
th <- cfg$step02$detector
v2 <- cfg$step02_v2
cache <- file.path(root, "outputs", "cache", "rebounding")
out <- file.path(root, "outputs", "rebounding", "step02_v2")
rev_dir <- file.path(out, "review")
for (d in c(out, rev_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
matches <- jsonlite::fromJSON(file.path(root, "data", "matches.json"))
audited <- readRDS(file.path(cache, "episodes.rds"))
hoops <- audited$hoops
s01 <- fread(file.path(root, "outputs", "rebounding", "step01", "rebound_episodes.csv"), na.strings = c("", "NA"))
el <- merge(audited$episodes, s01[eligible == TRUE, .(shot_id = episode_id, credited_outcome, ball_keyframe,
                                                      player_detected, contact_proxy_frame)], by = "shot_id")
setorder(el, game_id, f0)
v1_sample <- fread(file.path(root, "outputs", "rebounding", "step02", "review", "sample.csv"))

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

# ---- sample: the v2 held-aside subset, before anything else exists -------------------------------------------------
if (phase == "sample") {
  sm <- cfg$step02$sample
  if (file.exists(file.path(rev_dir, "sample.csv"))) stop("sample.csv exists; the v2 sample is drawn once")
  if (file.exists(file.path(cache, "hmm_features.rds"))) stop("features exist; the v2 sample must be drawn before them")
  lowq <- el$ball_keyframe <= quantile(el$ball_keyframe, sm$low_quality_quantile) |
    el$player_detected <= quantile(el$player_detected, sm$low_quality_quantile)
  el[, stratum := fcase(kind == "blocked", "blocked", kind == "airball or no contact", "airball or no contact",
                        kind == "backboard first", "backboard first", grepl("team award", credited_outcome), "team award",
                        credited_outcome == "off player", "offensive player rebound", lowq, "low tracking quality",
                        default = "ordinary defensive rebound")]
  pool <- el[!shot_id %in% v1_sample$shot_id]
  set.seed(v2$sample$seed)
  picked <- rbindlist(lapply(sm$strata, function(st) {
    p <- pool[stratum == st]
    p[sample(.N, min(.N, v2$sample$per_stratum)), .(shot_id, stratum)]
  }))
  rest <- pool[!shot_id %in% picked$shot_id]
  picked <- rbind(picked, rest[sample(.N, v2$sample$extra_random), .(shot_id, stratum = "random")])
  if (sum(picked$stratum == "airball or no contact") < v2$sample$min_no_contact)
    stop("fewer no-contact episodes than rubric v2 requires")
  picked <- merge(picked, el[, .(shot_id, game_id, f0, credited_outcome, kind)], by = "shot_id", sort = FALSE)
  picked <- picked[sample(.N)]
  picked[, `:=`(subset = "heldout_v2", item = seq_len(.N))]
  fwrite(picked, file.path(rev_dir, "sample.csv"))
  print(picked[, .N, by = stratum])
}

heldout_v2 <- if (file.exists(file.path(rev_dir, "sample.csv"))) fread(file.path(rev_dir, "sample.csv"))$shot_id else NULL

# ---- features ---------------------------------------------------------------------------------------------------------
if (phase == "features") {
  if (is.null(heldout_v2)) stop("run --phase=sample first")
  feats <- rbindlist(lapply(seq_len(nrow(el)), function(i) {
    s <- el[i]
    episode_features(read_raw(s$game_id), s, hoop_of(s), th, v2$features)
  }), fill = TRUE)
  saveRDS(feats, file.path(cache, "hmm_features.rds"))
  obs <- feats[!is.na(z)]
  cat(sprintf("%d episodes, %d frames, %d with measured ball (%.0f%%)\n", uniqueN(feats$shot_id), nrow(feats),
              nrow(obs), 100 * nrow(obs) / nrow(feats)))
  print(obs[, lapply(.SD, function(v) round(quantile(v, c(0.05, 0.5, 0.95), na.rm = TRUE), 2)), .SDcols = HMM_FEATURES])
}

# ---- fit: EM from geometric starts ------------------------------------------------------------------------------------
states <- v2$hmm$states
# allowed transitions (from row to column), hard constraints: incoming flight leaves only through a contact, a hold or the
# floor; outgoing flight never returns to incoming
ALLOWED <- list(
  flight_in        = setdiff(states, "flight_out"),
  flight_out       = setdiff(states, "flight_in"),
  on_rim           = c("flight_out", "on_rim", "held", "impact_rim_board", "impact_tip"),
  held             = c("flight_out", "held", "low_loose", "impact_tip"),
  low_loose        = c("flight_out", "held", "low_loose", "impact_tip"),
  impact_rim_board = c("flight_out", "on_rim", "held", "impact_rim_board", "impact_tip"),
  impact_tip       = c("flight_out", "held", "low_loose", "impact_rim_board", "impact_tip"))
stopifnot(setequal(names(ALLOWED), states))
is_impact <- grepl("^impact", states)
fixed_stay <- ifelse(is_impact & isTRUE(v2$hmm$impact_stay_fixed), v2$hmm$impact_stay, NA_real_)

#' Starting state of each measured frame from the geometric seed rules (NA: no rule applies). Free flight towards the
#' hoop seeds incoming flight, away from it outgoing flight.
seed_states <- function(f, r) {
  dv <- exp(f$log_dv) - v2$features$log_offsets$dv
  rel <- exp(f$log_relspeed) - v2$features$log_offsets$relspeed
  imp <- !is.na(dv) & dv > r$impact_dv_ft_s
  free <- !imp & exp(f$log_resid) - v2$features$log_offsets$resid < 0.65 & f$hoop_ft > 2.5 & f$near_ft > 3
  fcase(imp & ((f$board_face <= r$board_face_ft & f$z >= RIM_Z) | (f$hoop_ft <= r$rim_hoop_ft & f$z >= r$rim_min_z_ft)),
        "impact_rim_board",
        imp & f$near_ft <= r$tip_near_ft & f$hoop_ft > r$rim_hoop_ft, "impact_tip",
        !imp & f$hoop_ft <= 2.5 & f$z >= 9.5 & f$z <= 12, "on_rim",
        !imp & f$near_ft <= r$held_near_ft & rel <= r$held_rel_ft_s & f$z <= r$held_max_z_ft, "held",
        !imp & f$z <= r$low_z_ft & f$near_ft > r$held_near_ft, "low_loose",
        free & f$v_to_hoop > 0, "flight_in",
        free & f$v_to_hoop <= 0, "flight_out",
        default = NA_character_)
}

start_trans <- function() {
  t(vapply(states, function(fr) {
    ok <- states %in% ALLOWED[[fr]]
    stay <- if (grepl("^impact", fr)) v2$hmm$impact_stay else v2$hmm$regime_stay
    p <- ifelse(ok, (1 - stay) / (sum(ok) - 1), 0)
    p[states == fr] <- stay
    p
  }, numeric(length(states))))
}

#' Geometric masks (rows x states): rim states only in the v1 rim zone, touch states only near a player and below
#' reach, no impact state before the release guard. On frames without a measured ball the geometry is interpolated
#' between the measured frames on either side (as the vendor's filled frames are); the release guard holds on every frame.
state_mask <- function(d) {
  mk <- v2$hmm$masks
  lin <- function(x, f) { ok <- !is.na(x); if (sum(ok) < 2L) return(x); approx(f[ok], x[ok], f, rule = 2)$y }
  d <- d[, .(z = lin(z, frame), hoop_ft = lin(hoop_ft, frame), near_ft = lin(near_ft, frame), rel_frame), by = shot_id]
  rim_ok <- d$hoop_ft <= RIM_R + BALL_R + th$rim_pad_ft & d$z >= RIM_Z - th$rim_z_below_ft
  touch_ok <- d$near_ft <= th$touch_ft & d$z <= th$reach_max_z_ft
  late <- d$rel_frame >= mk$release_guard_frames
  M <- matrix(TRUE, nrow(d), length(states), dimnames = list(NULL, states))
  for (st in mk$rim_states) M[, st] <- rim_ok %in% TRUE
  for (st in mk$touch_states) M[, st] <- touch_ok %in% TRUE
  for (st in states[is_impact]) M[, st] <- M[, st] & late
  M
}

#' Feature matrix with the missing rule: a frame is observed only if every feature is present.
obs_matrix <- function(d) { X <- as.matrix(d[, ..HMM_FEATURES]); X[!complete.cases(X), ] <- NA; X }

if (phase == "fit") {
  source(file.path(here, "R", "hmm_em.R"))
  feats <- readRDS(file.path(cache, "hmm_features.rds"))
  setorder(feats, shot_id, frame)
  train <- feats[!shot_id %in% heldout_v2]
  X <- obs_matrix(train)
  M <- state_mask(train)
  print(round(colMeans(M), 3))
  train[, seed := fifelse(complete.cases(X), seed_states(.SD, v2$hmm$seed_rules), NA_character_)]
  print(train[!is.na(seed), .N, by = seed])
  start_means <- t(vapply(states, function(st) colMeans(X[which(train$seed == st), , drop = FALSE]), numeric(ncol(X))))
  start_sds <- t(vapply(states, function(st) pmax(0.1, apply(X[which(train$seed == st), , drop = FALSE], 2, sd)), numeric(ncol(X))))
  init <- as.numeric(states == v2$hmm$start_state)
  em <- v2$hmm$em
  fits <- list()
  for (r in seq_len(v2$hmm$restarts)) {
    set.seed(cfg$seeds[(r - 1L) %% length(cfg$seeds) + 1L] + r)
    jm <- if (r == 1L) start_means else start_means + matrix(rnorm(length(start_means), 0, 0.25), nrow(start_means)) * start_sds
    t0 <- Sys.time()
    f <- hmm_em(X, train$shot_id, start_trans(), jm, start_sds, init, fixed_stay, em$maxit, em$rel_tol, em$min_sd, M)
    cat(sprintf("restart %d: logLik %.1f, %d iterations%s, %.0f s\n", r, f$loglik, f$iterations,
                if (f$converged) "" else " (NOT converged)", as.numeric(Sys.time() - t0, units = "secs")))
    fits[[r]] <- f
  }
  ll <- vapply(fits, function(f) f$loglik, 0)
  best <- fits[[which.max(ll)]]
  n_obs <- sum(complete.cases(X))
  cat(sprintf("best logLik %.1f, BIC %.1f (%d free parameters, %d observed frames)\n", best$loglik,
              -2 * best$loglik + best$n_par * log(n_obs), best$n_par, n_obs))
  saveRDS(list(fit = best, states = states, features = HMM_FEATURES, start_means = start_means, loglik = ll,
               fixed_stay = fixed_stay, n_train = uniqueN(train$shot_id)), file.path(out, "hmm_fit.rds"))
  tab <- data.table(state = states, round(best$mu, 2)); setnames(tab, c("state", HMM_FEATURES))
  fwrite(tab, file.path(out, "state_means.csv"))
  sdt <- data.table(state = states, round(best$sd, 2)); setnames(sdt, c("state", HMM_FEATURES))
  fwrite(sdt, file.path(out, "state_sds.csv"))
  trm <- best$A; dimnames(trm) <- list(states, states)
  fwrite(data.table(from = states, round(trm, 3)), file.path(out, "transitions.csv"))
  print(tab); print(round(trm, 3))
}

# ---- decode: Viterbi states and v2 labels ------------------------------------------------------------------------------
#' The v2 labels of one episode from its decoded state path (frames on the 25 Hz grid).
episode_labels_v2 <- function(e, s) {
  e <- copy(e)
  # nearest players are measured on ball frames; carry them to filled frames from the closest measured frame
  for (v in c("near_id", "near_off", "near_det", "near_ft", "second_ft", "xp", "yp", "z")) {
    x <- e[[v]]
    i <- nafill(nafill(fifelse(is.na(x), NA_integer_, seq_along(x)), "locf"), "nocb")
    set(e, j = v, value = x[i])
  }
  runs <- e[, .(start = frame[1], end = frame[.N], n = .N), by = .(state, run = rleid(state))]
  actor <- function(f) {
    r <- e[frame == f]
    if (!nrow(r) || is.na(r$near_ft) || r$near_ft > th$touch_ft) return(list(id = NA_integer_, off = NA, det = NA_integer_))
    if (!is.na(r$second_ft) && r$second_ft - r$near_ft < th$actor_margin_ft) return(list(id = NA_integer_, off = r$near_off, det = r$near_det))
    list(id = r$near_id, off = r$near_off, det = r$near_det)
  }
  rimr <- runs[state %in% c("impact_rim_board", "on_rim")][1]
  rim_frame <- rimr$start
  kind <- if (is.na(rim_frame)) "none" else "rim_or_board"
  # a block: a defender's tip impact before both the rim contact and the shot's end
  pre <- runs[state == "impact_tip" & start < min(rim_frame, s$f1, na.rm = TRUE)]
  block <- NULL
  for (i in seq_len(nrow(pre))) {
    a <- actor(pre$start[i])
    if (isFALSE(a$off)) { block <- c(list(frame = pre$start[i]), a); break }
  }
  after <- fcoalesce(as.integer(rim_frame), if (is.null(block)) NA_integer_ else as.integer(block$frame), as.integer(s$f1))
  oob <- e[frame > after & (abs(xp) > COURT_HALF_L + BALL_R | abs(yp) > COURT_HALF_W + BALL_R) & z < 3]$frame[1]
  held <- runs[state == "held" & start > after & n >= v2$hmm$min_held_frames]
  if (nrow(held) && !is.na(oob) && oob < held$start[1]) held <- held[0]
  ctl <- if (nrow(held)) held[1] else NULL
  last <- min(c(ctl$start, oob, max(e$frame)), na.rm = TRUE)
  ctl_info <- NULL
  if (!is.null(ctl)) {
    hr <- e[frame >= ctl$start & frame <= ctl$end]
    shared <- mean(hr$second_ft - hr$near_ft < th$shared_margin_ft, na.rm = TRUE) >= th$shared_share
    ids <- table(hr$near_id)
    pid <- if (length(ids)) as.integer(names(which.max(ids))) else NA_integer_
    if (is.na(pid)) shared <- TRUE
    ctl_info <- list(frame = ctl$start, pid = if (shared) NA_integer_ else pid, shared = shared,
                     off = hr[near_id == pid]$near_off[1], det = e[frame == ctl$start]$near_det)
  }
  # touches after the rim contact: tip-impact runs and held runs (any length), up to control
  cand <- runs[(state == "impact_tip" | state == "held") & start > after & start <= last]
  touches <- rbindlist(lapply(seq_len(nrow(cand)), function(i) {
    r <- cand[i]
    nxt <- runs[start > r$end][1]$state
    type <- if (r$state == "held") "catch" else if (identical(nxt, "held")) "catch" else "tip"
    a <- actor(r$start)
    data.table(frame = r$start, type = type, actor_id = a$id, actor_off = a$off, actor_det = a$det)
  }))
  if (nrow(touches)) {
    # a tip impact running straight into a hold is one catch, placed at the impact
    touches <- touches[!(type == "catch" & shift(type) == "catch" & frame <= shift(frame) + v2$hmm$min_held_frames) | is.na(shift(type))]
  }
  first <- if (!is.null(block)) data.table(frame = block$frame, type = "block", actor_id = block$id, actor_off = block$off, actor_det = block$det) else
    if (nrow(touches)) touches[1] else NULL
  tips <- if (nrow(touches)) touches[type == "tip"] else touches
  terminal <- if (!is.null(ctl_info)) (if (ctl_info$shared) "held_ball" else "control") else if (!is.na(oob)) "out_of_bounds" else "unresolved"
  zat <- function(f) if (is.null(f) || is.na(f)) NA_real_ else e[frame == f]$z[1]
  data.table(
    episode_id = s$shot_id, game_id = s$game_id, f0 = s$f0,
    first_rim_or_board_frame = rim_frame, contact_kind = kind,
    first_player_contact_frame = if (!is.null(first)) first$frame else NA_integer_,
    first_contact_player_id = if (!is.null(first)) first$actor_id else NA_integer_,
    first_contact_off = if (!is.null(first)) first$actor_off else NA,
    first_contact_type = if (!is.null(first)) (if (is.na(first$actor_id) && first$type != "block") first$type else first$type) else "none",
    tip_frames_and_players = if (nrow(tips)) paste(sprintf("%d:%s", tips$frame, fifelse(is.na(tips$actor_id), "?", as.character(tips$actor_id))), collapse = ";") else "",
    n_tips = nrow(tips),
    first_control_frame = if (!is.null(ctl_info)) ctl_info$frame else NA_integer_,
    controller_id = if (!is.null(ctl_info)) ctl_info$pid else NA_integer_,
    controller_off = if (!is.null(ctl_info)) ctl_info$off else NA,
    out_of_bounds_frame = oob, terminal = terminal,
    ball_center_z_at_first_touch = zat(first$frame), ball_center_z_at_control = zat(ctl_info$frame))
}

if (phase == "decode") {
  fit_rec <- readRDS(file.path(out, "hmm_fit.rds"))
  feats <- readRDS(file.path(cache, "hmm_features.rds"))
  setorder(feats, shot_id, frame)
  source(file.path(here, "R", "hmm_em.R"))
  X <- obs_matrix(feats)
  miss <- !complete.cases(X)
  M <- state_mask(feats)
  b <- fit_rec$fit
  path <- hmm_viterbi(hmm_log_emis(X, b$mu, b$sd, M), b$A, b$init, hmm_index(feats$shot_id))
  feats[, state := states[path]]
  fwrite(feats[, .(shot_id, frame, rel_frame, state, measured = !miss)], file.path(out, "states.csv"))
  print(feats[, .N, by = state][order(-N)])
  summ <- rbindlist(lapply(split(feats, by = "shot_id"), function(e) episode_labels_v2(e, el[shot_id == e$shot_id[1]])))
  fwrite(summ, file.path(out, "auto_summary.csv"))
  print(summ[, .N, by = contact_kind]); print(summ[, .N, by = first_contact_type]); print(summ[, .N, by = terminal])
}

# ---- compare: v1 and v2 against reviewer 1 on the 30 development episodes (v1's spent held-aside subset) ----------
if (phase == "compare") {
  ag <- cfg$step02$agreement
  r1 <- fread(file.path(root, "outputs", "rebounding", "step02", "review", "reviewer1_heldout.csv"), colClasses = "character")
  lab <- function(id, off) ifelse(is.na(id), NA_character_, paste0(ifelse(off %in% TRUE, "O", "D"), as.integer(id) %% 10000L))
  num <- function(v) suppressWarnings(as.integer(v))
  ref <- r1[, .(episode_id, rim = num(first_rim_or_board_rel), touch = num(first_player_contact_rel),
                touch_p = fifelse(grepl("^[OD][0-9]+$", first_contact_player_id), first_contact_player_id, NA_character_),
                type = fifelse(first_contact_type %in% c("tip", "catch", "block", "none"), first_contact_type, NA_character_),
                ctl = num(first_control_rel),
                ctl_p = fifelse(grepl("^[OD][0-9]+$", controller_id), controller_id, NA_character_),
                tips = fifelse(nzchar(tips_rel), lengths(strsplit(tips_rel, ";")), 0L), terminal)]
  norm_auto <- function(a) {
    a <- merge(a, el[, .(episode_id = shot_id, f0)], by = "episode_id", suffixes = c("", ".el"))
    a[, .(episode_id, rim = first_rim_or_board_frame - f0, touch = first_player_contact_frame - f0,
          touch_p = lab(first_contact_player_id, first_contact_off), type = first_contact_type,
          ctl = first_control_frame - f0, ctl_p = lab(controller_id, controller_off), tips = n_tips, terminal)]
  }
  a1 <- fread(file.path(root, "outputs", "rebounding", "step02", "auto_summary.csv"), na.strings = c("", "NA"))
  # v1 summary has no first-contact team flag: recover it from the release lineup (offence if the player shot for the offence)
  if (!"first_contact_off" %in% names(a1)) {
    offmap <- function(ep, ids) {
      vapply(seq_along(ep), function(i) {
        id <- ids[i]
        if (is.na(id)) return(NA)
        s <- el[shot_id == ep[i]]
        p <- window_players(read_raw(s$game_id), s, s$f0:s$rf)[pid == id]
        if (nrow(p)) p$off[1] else NA
      }, NA)
    }
    a1[, first_contact_off := offmap(episode_id, first_contact_player_id)]
  }
  a2 <- fread(file.path(out, "auto_summary.csv"), na.strings = c("", "NA"))
  score <- function(x, y, who) {
    j <- merge(x, y, by = "episode_id", suffixes = c(".r", ".a"))
    cnt <- function(ok, n) sprintf("%d/%d", sum(ok, na.rm = TRUE), n)
    both_t <- j[!is.na(touch_p.r) & !is.na(touch_p.a)]; both_c <- j[!is.na(ctl_p.r) & !is.na(ctl_p.a)]
    ft <- j[!is.na(touch.r) & !is.na(touch.a)]; fc <- j[!is.na(ctl.r) & !is.na(ctl.a)]; fr <- j[!is.na(rim.r) & !is.na(rim.a)]
    tc <- function(n) pmin(n, 2L)
    data.table(labeler = who,
               rim_within_2 = cnt(abs(fr$rim.r - fr$rim.a) <= ag$frame_tol_contact, nrow(fr)),
               touch_both_named = cnt(rep(TRUE, nrow(both_t)), nrow(j)),
               touch_same_player = cnt(both_t$touch_p.r == both_t$touch_p.a, nrow(both_t)),
               touch_within_3 = cnt(abs(ft$touch.r - ft$touch.a) <= ag$frame_tol_player, nrow(ft)),
               tip_vs_catch_same = cnt(j[type.r %in% c("tip", "catch") & type.a %in% c("tip", "catch"), type.r == type.a],
                                       nrow(j[type.r %in% c("tip", "catch") & type.a %in% c("tip", "catch")])),
               control_both_named = cnt(rep(TRUE, nrow(both_c)), nrow(j)),
               control_same_player = cnt(both_c$ctl_p.r == both_c$ctl_p.a, nrow(both_c)),
               control_within_3 = cnt(abs(fc$ctl.r - fc$ctl.a) <= ag$frame_tol_player, nrow(fc)),
               tip_count_same = cnt(tc(j$tips.r) == tc(j$tips.a), nrow(j)),
               terminal_same = cnt(j$terminal.r == j$terminal.a, nrow(j)))
  }
  tab <- rbind(score(ref, norm_auto(a1), "v1 (frozen rules)"), score(ref, norm_auto(a2), "v2 (HMM)"))
  fwrite(tab, file.path(out, "dev_comparison.csv"))
  print(t(tab))
  per <- merge(ref, norm_auto(a2), by = "episode_id", suffixes = c(".r1", ".v2"))
  fwrite(per, file.path(out, "dev_comparison_by_episode.csv"))
}
