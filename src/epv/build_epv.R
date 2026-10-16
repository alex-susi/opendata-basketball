# Build the EPV model end to end.
#   Rscript src/epv/build_epv.R [--force] [--refit] [--constant-oreb]
#
# 1. Features for all ten games (cached in outputs/cache/epv/tables.rds; --force rebuilds them), plus the
#    spatial offensive-rebound chance of every potential shooter from src/court_control/price_rebounds.R
#    (run src/court_control/build_control.R and that script after the tables exist). --constant-oreb uses
#    the training games' offensive-rebound rate instead, as before 2026-10-16.
#    Finished folds are kept, so an interrupted run resumes; --refit (or --force) fits every fold again.
# 2. The closest-defender slope and catch-and-shoot effect for jump shots, from the season aggregates
#    (outputs/epv/jump_fixed_effects.csv).
#    Leave-one-game-out: for each game, fit every component on the other nine and price the held-out game.
# 3. Save per-frame prices and, for every tracked shot, the steps behind its xFG to
#    outputs/cache/epv/epv_{gameId}.rds (read by the play viewer), and held-out validation tables to outputs/epv/.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/epv"
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "features.R"))
source(file.path(here, "R", "models.R"))
source(file.path(here, "R", "season.R"))

set.seed(20261010)
app <- load_app_data()
games <- app$matches$game_id
cache <- file.path(app$root, "outputs", "cache", "epv")
report <- file.path(app$root, "outputs", "epv")
dir.create(cache, recursive = TRUE, showWarnings = FALSE)
dir.create(report, recursive = TRUE, showWarnings = FALSE)

# ---- features ------------------------------------------------------------------------------------

#' Pass duration as a linear function of pass length, from completed passes in the event data.
pass_flight <- function() {
  pa <- rbindlist(lapply(games, function(g) game_events(app$root, g)$passes))
  pa <- pa[!turnover & !is.na(receiver) & passer != receiver & end_frame > frame & end_frame - frame <= 50L & len_ev > 3]
  unname(coef(lm(I((end_frame - frame) / 25) ~ len_ev, data = pa)))
}

tables_path <- file.path(cache, "tables.rds")
if (file.exists(tables_path) && !"--force" %in% args) {
  tabs <- readRDS(tables_path)
} else {
  flight <- pass_flight()
  message(sprintf("Pass flight time: %.2f s + %.3f s per foot", flight[1], flight[2]))
  tabs <- lapply(games, function(g) {
    message("Features for game ", g)
    game_tables(app, g, flight)
  })
  saveRDS(tabs, tables_path)
}
bind <- function(name) rbindlist(lapply(tabs, `[[`, name), fill = TRUE)
rows <- bind("rows")
slots <- bind("slots")
cands <- bind("cands")
shots <- bind("shots")
shots[, three := as.integer(three_ev)]   # real attempts take the scorer's two or three, not court geometry
passes <- bind("passes")
orb <- bind("orb")
ft <- bind("ft")

# Offensive-rebound chance from the ten players' positions for every potential shooter on every priced frame,
# each game priced with rebound parameters fitted without it (src/court_control/price_rebounds.R). A pass
# receiver takes his chance at the frame the pass is priced, from where he stands then.
poreb_files <- file.path(app$root, "outputs", "cache", "court_control", paste0("poreb_", games, ".rds"))
if ("--constant-oreb" %in% args) {
  message("Offensive-rebound rate: the training games' constant (--constant-oreb)")
} else if (!all(file.exists(poreb_files))) {
  stop("No spatial rebound prices for game(s) ", paste(games[!file.exists(poreb_files)], collapse = ", "),
       ". Run Rscript src/court_control/build_control.R, then Rscript src/court_control/price_rebounds.R",
       " (it reads the feature tables just saved), then this script again.")
} else {
  poreb <- rbindlist(lapply(seq_along(games), function(k) readRDS(poreb_files[k])[, game_id := games[k]]))
  row_frames <- rows[, .(game_id, row, frame)]
  add_poreb <- function(dt) {
    f <- row_frames[dt, on = .(game_id, row), x.frame]
    dt[, poreb_spatial := poreb[data.table(game_id = dt$game_id, frame = f, pid = dt$pid), on = .(game_id, frame, pid), x.poreb]]
  }
  add_poreb(slots)
  add_poreb(cands)
  message(sprintf("Spatial P(OREB) on %.1f%% of shooter rows within %d ft (mean %.3f)",
                  100 * slots[dist <= SHOT_RANGE, mean(!is.na(poreb_spatial))], SHOT_RANGE, mean(slots$poreb_spatial, na.rm = TRUE)))
}

counts <- do.call(rbind, lapply(tabs, `[[`, "counts"))
rownames(counts) <- games
print(counts)

holders <- merge(rows[grid == TRUE], slots[is_holder == TRUE, c("game_id", "row", CONTEXT_COLS), with = FALSE],
                 by = c("game_id", "row"))
holders[, train := frame %% TRAIN_STEP == 0L]
message(sprintf("%d priced frames, %d shots, %d passes (%d intercepted)", nrow(holders), nrow(shots), nrow(passes),
                sum(passes$turnover)))

# ---- fixed effects from the season aggregates --------------------------------------------------------

# The same two effects for every fold: they are built from season outcomes outside the tracked games, and from
# the tracked games' labels and positions only.
season <- season_jump_effects(app$root, shots)
fwrite(season$detail, file.path(report, "jump_fixed_effects.csv"))
print(season$detail, digits = 4)
message(sprintf("Jump shots: %.4f log-odds per foot of closest-defender distance up to %d ft, %.4f for a catch-and-shoot attempt",
                season$fixed[["def1"]], DEF_CAP, season$fixed[["cs"]]))

# ---- leave-one-game-out --------------------------------------------------------------------------

#' Held-out score of one component in one game, against the training base rate and the GAM alone.
score_component <- function(name, model, test, y, base, test_game) {
  binary <- model$binary
  loss <- if (binary) log_loss else mse
  full <- predict_two_stage(model, test)
  data.table(component = name, game_id = test_game, n = nrow(test), events = if (binary) sum(test[[y]]) else NA_real_,
             rounds = model$rounds, loss_base = loss(rep(base, nrow(test)), test[[y]]),
             loss_gam = loss(predict_two_stage(model, test, "gam"), test[[y]]), loss_full = loss(full, test[[y]]),
             auc = if (binary && uniqueN(test[[y]]) == 2L) auc(full, test[[y]]) else NA_real_)
}

#' Held-out score of xFG in one game: all shots, each context model's shots (rim, jump), and jump shots
#' split into midrange and three. loss_gam is the location GAM alone. Every row is scored against the
#' training make rate of the same kind of shot.
#' @param train,test Unfouled attempts of the training games and of the held-out game.
score_xfg <- function(model, test, train, test_game) {
  p <- data.table(area = shot_area(test$dist, test$three), y = as.numeric(test$made),
                  loc = predict_xfg(model, test, "location"), full = predict_xfg(model, test))
  train_area <- shot_area(train$dist, train$three)
  one <- function(name, areas, rounds) {
    d <- p[area %in% areas]
    data.table(component = name, game_id = test_game, n = nrow(d), events = sum(d$y), rounds = rounds,
               loss_base = log_loss(mean(train$made[train_area %in% areas]), d$y), loss_gam = log_loss(d$loc, d$y),
               loss_full = log_loss(d$full, d$y), auc = if (uniqueN(d$y) == 2L) auc(d$full, d$y) else NA_real_)
  }
  jump <- model$zones$jump$rounds
  rbind(one("xfg", c("rim", "mid", "three"), NA_integer_), one("xfg_rim", "rim", model$zones$rim$rounds),
        one("xfg_jump", c("mid", "three"), jump), one("xfg_mid", "mid", jump), one("xfg_three", "three", jump))
}

#' Fit on every game but `test_game`, then price `test_game`.
run_fold <- function(test_game) {
  message("Fold: holding out game ", test_game)
  tr <- function(dt) dt[game_id != test_game]
  te <- function(dt) dt[game_id == test_game]
  shot_m <- fit_shot_models(tr(shots), tr(ft), tr(orb), season$fixed)
  pass_m <- fit_pass_model(tr(passes))

  # shot value for all five offensive players on the rows this fold needs
  need <- holders[game_id == test_game | train == TRUE]
  sl <- slots[need[, .(game_id, row)], on = .(game_id, row)]
  sl <- cbind(sl, shot_value(shot_m, sl))
  setorder(sl, game_id, row, -sv)
  top <- sl[, .(best = sv[1], best_slot = slot[1], second = sv[2]), by = .(game_id, row)]
  h <- merge(need, sl[is_holder == TRUE, .(game_id, row, sv, xfg, pfoul, poreb)], by = c("game_id", "row"))
  h <- merge(h, top, by = c("game_id", "row"))
  h[, sv_other := fifelse(best_slot == slot, second, best)]
  state_m <- fit_state_models(h[game_id != test_game & train == TRUE])

  # price the held-out game: holder state, then every pass option at the receiver's arrival
  hh <- h[game_id == test_game][order(poss_id, frame)]
  hh[, c("epv", "haz", "rop") := .(predict_two_stage(state_m$value, hh), predict_two_stage(state_m$haz, hh),
                                   predict_two_stage(state_m$rop, hh))]
  hh[, cum := 1 - cumprod((1 - haz)^(GRID_STEP / HAZARD_FRAMES)), by = poss_id]
  cd <- te(cands)
  cd <- cbind(cd, shot_value(shot_m, cd)[, .(sv)])
  cd <- merge(cd, top, by = c("game_id", "row"))
  cd[, sv_other := fifelse(best_slot == slot, second, best)]
  cd[, ptov := predict_two_stage(pass_m, cd)]
  cd[, pv := (1 - ptov) * predict_two_stage(state_m$value, cd)]
  setorder(cd, row, -pv)
  best <- cd[, .(pass_best = pv[1], pass_pid = pid[1]), by = row]
  frames <- merge(hh[, .(game_id, row, frame, poss_id, holder, epv, haz, rop, cum, sv, xfg, pfoul, poreb)], best,
                  by = "row", all.x = TRUE)
  players <- merge(sl[game_id == test_game, .(row, pid, sv)], cd[, .(row, pid, pv, ptov)], by = c("row", "pid"), all.x = TRUE)
  players[, frame := frames$frame[match(row, frames$row)]]
  # every tracked attempt of the held-out game at its release: the context features and what each adds to xFG
  held <- te(shots)
  steps <- cbind(held[, c("shot_id", "poss_id", "frame", "pid", "made", "fouled", "three", "dist",
                          setdiff(XFG_FEATURES, "loc_xfg")), with = FALSE], explain_xfg(shot_m$xfg, held))
  stopifnot(isTRUE(all.equal(steps$xfg, predict_xfg(shot_m$xfg, held))))
  saveRDS(list(frames = frames[order(frame)], players = players[order(frame, pid), .(frame, pid, sv, pv, ptov)],
               shots = steps[order(frame)]),
          file.path(cache, sprintf("epv_%d.rds", test_game)))

  unfouled <- function(dt) dt[fouled == FALSE]
  rbind(score_xfg(shot_m$xfg, unfouled(te(shots)), unfouled(tr(shots)), test_game),
        score_component("foul", shot_m$foul, te(shots), "fouled", tr(shots)[, mean(fouled)], test_game),
        score_component("pass_turnover", pass_m, te(passes), "turnover", tr(passes)[, mean(turnover)], test_game),
        score_component("turnover_2s", state_m$haz, hh, "haz_y", h[game_id != test_game, mean(haz_y)], test_game),
        score_component("turnover_rest", state_m$rop, hh, "rop_y", h[game_id != test_game, mean(rop_y)], test_game),
        score_component("value", state_m$value, hh, "pts_y", h[game_id != test_game, mean(pts_y)], test_game))
}

#' Run one fold, or reuse its saved result when the prices and validation rows are already on disk.
fold_result <- function(test_game) {
  done <- file.path(cache, sprintf("validation_%d.rds", test_game))
  if (!file.exists(done) || !file.exists(epv_cache_path(app$root, test_game))) saveRDS(run_fold(test_game), done)
  readRDS(done)
}

# A forced run starts from scratch; otherwise finished folds are reused.
if (any(c("--force", "--refit") %in% args)) unlink(list.files(cache, "^validation_[0-9]+[.]rds$", full.names = TRUE))

started <- Sys.time()
by_game <- rbindlist(lapply(games, fold_result))
fwrite(by_game, file.path(report, "validation_by_game.csv"))

# Pooled held-out loss per component, and the game-level paired gain over the base rate with its standard error.
summary_tab <- by_game[, .(n = sum(n), events = sum(events), rounds = paste(sort(unique(rounds)), collapse = "/"),
                           loss_base = weighted.mean(loss_base, n), loss_gam = weighted.mean(loss_gam, n),
                           loss_full = weighted.mean(loss_full, n), auc = mean(auc, na.rm = TRUE),
                           gain_vs_base = mean(loss_base - loss_full), gain_se = sd(loss_base - loss_full) / sqrt(.N),
                           games_better = sum(loss_full < loss_base)),
                       by = component]
fwrite(summary_tab, file.path(report, "validation_summary.csv"))
print(summary_tab, digits = 4)
message(sprintf("Done in %.1f min. Prices in %s, validation in %s.", as.numeric(difftime(Sys.time(), started, units = "mins")),
                cache, report))
