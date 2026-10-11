# Build the EPV model end to end.
#   Rscript src/epv/build_epv.R [--force] [--refit]
#
# 1. Features for all ten games (cached in outputs/cache/epv/tables.rds; --force rebuilds them).
#    Finished folds are kept, so an interrupted run resumes; --refit (or --force) fits every fold again.
# 2. Leave-one-game-out: for each game, fit every component on the other nine and price the held-out game.
# 3. Save per-frame prices and, for every tracked shot, the steps behind its xFG to
#    outputs/cache/epv/epv_{gameId}.rds (read by the play viewer), and held-out validation tables to outputs/epv/.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/epv"
source(file.path(here, "..", "play_viewer", "R", "data.R"))
source(file.path(here, "R", "features.R"))
source(file.path(here, "R", "models.R"))

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
counts <- do.call(rbind, lapply(tabs, `[[`, "counts"))
rownames(counts) <- games
print(counts)

holders <- merge(rows[grid == TRUE], slots[is_holder == TRUE, c("game_id", "row", CONTEXT_COLS), with = FALSE],
                 by = c("game_id", "row"))
holders[, train := frame %% TRAIN_STEP == 0L]
message(sprintf("%d priced frames, %d shots, %d passes (%d intercepted)", nrow(holders), nrow(shots), nrow(passes),
                sum(passes$turnover)))

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

#' Held-out score of xFG in one game, overall and by zone. loss_gam is the location GAM alone. The overall
#' row is scored against the training make rate; a zone row against that zone's training make rate, which is
#' where its context model starts.
score_xfg <- function(model, test, base, test_game) {
  p <- data.table(zone = shot_zone(test$dist, test$three), y = as.numeric(test$made), base = base,
                  rate = predict_xfg(model, test, "rate"), loc = predict_xfg(model, test, "location"),
                  full = predict_xfg(model, test))
  one <- function(name, d, base, rounds) {
    data.table(component = name, game_id = test_game, n = nrow(d), events = sum(d$y), rounds = rounds,
               loss_base = log_loss(base, d$y), loss_gam = log_loss(d$loc, d$y), loss_full = log_loss(d$full, d$y),
               auc = if (uniqueN(d$y) == 2L) auc(d$full, d$y) else NA_real_)
  }
  rbind(one("xfg", p, p$base, NA_integer_),
        rbindlist(lapply(ZONES, function(z) one(paste0("xfg_", z), p[zone == z], p[zone == z]$rate, model$zones[[z]]$rounds))))
}

#' Fit on every game but `test_game`, then price `test_game`.
run_fold <- function(test_game) {
  message("Fold: holding out game ", test_game)
  tr <- function(dt) dt[game_id != test_game]
  te <- function(dt) dt[game_id == test_game]
  shot_m <- fit_shot_models(tr(shots), tr(ft), tr(orb))
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
  rbind(score_xfg(shot_m$xfg, unfouled(te(shots)), unfouled(tr(shots))[, mean(made)], test_game),
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
