## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, first step: can the call be FORECAST before the screen, or only RECOGNISED as it happens?
#   Rscript screen_coverage/zz_Archive/01_scripts/01_lead_time_baseline.R
#
# A learning exercise that follows the "Pick coverage" exploration tab (web/scripts/explore/coverage.R). No
# transformer yet: frequency baselines and small logistic models, scored at fixed times around the screen tag.
#
# Label. The joint call of the two defenders on an on-ball screen (picks.bhrDefType + picks.scrDefType):
# over + show, over + soft, under + soft, under + show, switch. Ice (14), blitz (4) and over + none (6) are too
# rare to learn from in ten games and are left out (24 of 1,520 picks).
#
# The four players. Ball handler H, screener S, the handler's defender BD (ballhandlerDefId) and the screener's
# defender SD (screenerDefId); both defender ids are the ones BEFORE any switch. Positions are in the site's frame
# (offense attacks the hoop at +HOOP_X), from the explore bundles (web/cache/explore/).
#
# Cutoffs. The tag frame is picks.frame (time 0). Every model sees only positions at the cutoff and 0.24 s before
# it: -0.8 s and -0.4 s are forecasts, 0 s is the tag itself, +0.4 s is recognition (the defenders have started to
# play the screen).
#
# Four-player measures at a cutoff, all relative to where S stands at that moment:
#   d_hs, d_bd, d_sd, d_def   distances H-S, H-BD, H-SD, BD-SD (ft)
#   bd_lvl                    BD's hoop distance minus S's: + = BD is above the screener (toward the ball, "over")
#   sd_lvl                    SD's hoop distance minus S's: + = SD is up at the level of the screen ("show")
#   h_lvl, s_hoop             H's level vs S, and S's distance from the hoop. (H's own hoop distance is exactly
#                             h_lvl + s_hoop, so it is not added separately.)
#   bd_lvl_v, sd_lvl_v        how fast bd_lvl and sd_lvl changed over the last 0.24 s (ft/s)
#   sc                        shot clock at the tag
#
# The other six players (three attackers o1-o3, three defenders x1-x3), each ordered by distance to the screener at
# the cutoff (o1 = the attacker nearest the screen). For each: x, y (ft, site frame: x from half court toward the
# hoop at +40.8, y across the floor) and vx, vy (ft/s, backward difference over 0.24 s). Each play is mirrored so the
# screener is on the y >= 0 side of the floor: a screen on the left and its mirror image on the right then look the
# same, and "y" reads as "toward the screen's side (+) or the far side (-)". That is 24 numbers per pick.
#
# Every model is scored on the same picks: those with all ten players tracked at every cutoff.
#
# Models (leave one game out: fitted on nine games, scored on the tenth)
#   league                  the five calls' shares in the nine training games
#   defense so far          this defense's earlier calls in the same game, with the league mix worth 5 picks
#                           (online: uses only picks before this one)
#   4 players               multinomial logistic (ridge penalty) on the four-player measures
#   4 players + so far      the same plus the "defense so far" shares (as logs)
#   10 players              the four-player measures plus the other six players' positions and velocities
#   10 players + so far     the same plus the "defense so far" shares
#
# "Committed?" check. For over vs under and for show vs soft, an AUC at each cutoff: pick one pick of each call at
# random; how often does bd_lvl (or sd_lvl) rank them the right way round? 0.5 = no sign yet, 1 = always.
#
# Writes screen_coverage/zz_Archive/03_outputs/: lead_time_scores.csv, six_players_effect.csv, feature_weights.csv,
# commitment_auc.csv, worked_example.csv, film_check.csv (10-player model), film_check_4players.csv, penalty_check.csv,
# figures/lead_time_scores.png,
# figures/worked_example_fall_marcos.png.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(ggplot2)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
out_dir <- file.path(root, "screen_coverage", "zz_Archive", "03_outputs")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)

# Cutoffs are seconds from the screen tag; VLAG is the velocity lag in frames; PRIOR_W weights the league mix.
FPS <- 25
FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M
CUTS <- c(-0.8, -0.4, 0, 0.4)
VLAG <- 6L
CALLS <- c("over + show", "over + soft", "under + soft", "under + show", "switch")
PRIOR_W <- 5
DECAY <- 1
hoop_dist <- function(x, y) sqrt((HOOP_X - x)^2 + y^2)

games <- as.integer(jsonlite::fromJSON(file.path(root, "data", "matches.json"))$id)
bundle <- function(g) readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))

# Position of each (frame, player) pair, falling back to the nearest frame within two either side.
pos_at <- function(B, frames, pids) {
  out <- data.table(x = rep(NA_real_, length(frames)), y = NA_real_, poss = NA_character_)
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    miss <- which(is.na(out$x))
    if (!length(miss)) break
    hit <- B$P[.(frames[miss] + d, pids[miss]), .(x, y, poss), nomatch = NA]
    out[miss, `:=`(x = hit$x, y = hit$y, poss = hit$poss)]
  }
  out
}

# Columns for the other six players: slots o1-o3 (attackers) and x1-x3 (defenders), each with position and velocity.
SIX_SLOTS <- c(paste0("o", 1:3), paste0("x", 1:3))
SIX <- as.vector(t(outer(SIX_SLOTS, c("_x", "_y", "_vx", "_vy"), paste0)))

#' The six players not in the action at each pick's cutoff frame: three attackers and three defenders, each ordered
#' by distance to the screener, mirrored so the screener is at y >= 0. One row per pick; NA where not all six are
#' tracked in the pick's possession (nearest frame within 2, as for the four).
others_at <- function(B, p, frames, sx, sy) {
  n <- nrow(p)
  found <- data.table()
  left <- seq_len(n)
  # Use the first frame offset at which three attackers and three defenders besides the four are tracked.
  for (d in c(0L, -1L, 1L, -2L, 2L)) {
    if (!length(left)) break
    q <- data.table(i = left, frame = frames[left] + d)
    h <- B$P[q, on = "frame", nomatch = 0L, allow.cartesian = TRUE]
    h <- h[poss == p$poss[i] & !(pid == p$H[i] | pid == p$S[i] | pid == p$BD[i] | pid == p$SD[i])]
    ok <- h[, .(n_off = sum(off), n_def = sum(!off)), by = i][n_off == 3L & n_def == 3L]$i
    found <- rbind(found, h[i %in% ok])
    left <- setdiff(left, ok)
  }
  out <- matrix(NA_real_, n, length(SIX), dimnames = list(NULL, SIX))
  if (!nrow(found)) return(out)
  # Velocity over VLAG frames; mirror y so the screener is at y >= 0; slot each side by distance to the screener.
  bef <- pos_at(B, found$frame - VLAG, found$pid)
  found[, `:=`(vx = (x - bef$x) / (VLAG / FPS), vy = (y - bef$y) / (VLAG / FPS), bposs = bef$poss)]
  found <- found[!is.na(vx) & bposs == poss]
  found[, flip := fifelse(sy[i] < 0, -1, 1)]
  found[, `:=`(yy = flip * y, vyy = flip * vy, ds = sqrt((x - sx[i])^2 + (y - sy[i])^2))]
  found[, slot := paste0(fifelse(off, "o", "x"), frank(ds, ties.method = "first")), by = .(i, off)]
  # Fill the output only for picks with all six slots.
  complete <- found[, .N, by = i][N == 6L]$i
  for (s in SIX_SLOTS) {
    r <- found[slot == s & i %in% complete]
    out[r$i, paste0(s, "_x")] <- r$x
    out[r$i, paste0(s, "_y")] <- r$yy
    out[r$i, paste0(s, "_vx")] <- r$vx
    out[r$i, paste0(s, "_vy")] <- r$vyy
  }
  out
}





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PICKS AND THEIR MEASURES AT EACH CUTOFF --------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One game's picks: the four players and the call, then their positions and measures at each cutoff.
build_game <- function(g) {
  B <- bundle(g)
  p <- B$picks[, .(id, chance, f0, H = actor, BD = adef, S = screener, SD = sdef, cov, scov, spot, touch)]
  if (!nrow(p)) return(NULL)
  # Shot clock, defending team and period come from the event file; the possession comes from the chance.
  ev <- jsonlite::fromJSON(file.path(root, "data", "matches", g, paste0(g, "_dynamic_events.json")))$picks
  p[as.data.table(ev)[, .(id, sc = shotClock, def_team = defTeamId, period)], on = "id", `:=`(sc = i.sc, def_team = i.def_team, period = i.period)]
  p[B$ch, on = "chance", poss := i.poss]
  p[, `:=`(game_id = g, call = fifelse(cov %in% c("switch", "ice", "blitz"), cov, paste(cov, scov, sep = " + ")))]
  roster <- B$roster
  nm <- function(id) roster$name[match(id, roster$pid)]
  p[, `:=`(h_name = nm(H), s_name = nm(S), bd_name = nm(BD), sd_name = nm(SD))]
  # At each cutoff: the four now and VLAG frames earlier, their distances, levels relative to the screener and rates.
  feats <- rbindlist(lapply(CUTS, function(cut) {
    f <- p$f0 + as.integer(round(cut * FPS))
    look <- function(role, ff) pos_at(B, ff, p[[role]])
    now <- lapply(c(H = "H", S = "S", BD = "BD", SD = "SD"), look, ff = f)
    bef <- lapply(c(H = "H", S = "S", BD = "BD", SD = "SD"), look, ff = f - VLAG)
    ok <- Reduce(`&`, lapply(c(now, bef), function(h) !is.na(h$x) & !is.na(h$poss) & h$poss == p$poss))
    lv <- function(P, role) hoop_dist(P[[role]]$x, P[[role]]$y) - hoop_dist(P$S$x, P$S$y)
    dd <- function(P, a, b) sqrt((P[[a]]$x - P[[b]]$x)^2 + (P[[a]]$y - P[[b]]$y)^2)
    # The other six players, and whether all six are tracked.
    six <- others_at(B, p, f, now$S$x, now$S$y)
    cbind(data.table(id = p$id, cut = cut, tracked = ok, tracked6 = !apply(is.na(six), 1, any),
                     d_hs = dd(now, "H", "S"), d_bd = dd(now, "H", "BD"), d_sd = dd(now, "H", "SD"), d_def = dd(now, "BD", "SD"),
                     bd_lvl = lv(now, "BD"), sd_lvl = lv(now, "SD"), h_lvl = lv(now, "H"),
                     s_hoop = hoop_dist(now$S$x, now$S$y),
                     bd_lvl_v = (lv(now, "BD") - lv(bef, "BD")) / (VLAG / FPS),
                     sd_lvl_v = (lv(now, "SD") - lv(bef, "SD")) / (VLAG / FPS),
                     hx = now$H$x, hy = now$H$y, sx = now$S$x, sy = now$S$y, bx = now$BD$x, by = now$BD$y,
                     dx = now$SD$x, dy = now$SD$y),
          as.data.table(six))
  }))
  list(p = p, f = feats)
}

# Keep picks with one of the five calls and all ten players tracked at every cutoff. A missing shot clock counts as 24.
built <- lapply(games, build_game)
P <- rbindlist(lapply(built, `[[`, "p"))
Fe <- rbindlist(lapply(built, `[[`, "f"))
P <- P[call %in% CALLS][order(game_id, f0)]
cat("Picks:", nrow(P), "with one of the five calls (", P[, .N, by = call][, paste(call, N, collapse = ", ")], ")\n")
full <- Fe[id %in% P$id, .(four = all(tracked), ten = all(tracked & tracked6)), by = id]
cat("All four players tracked at every cutoff:", full[, sum(four)], "| all ten:", full[, sum(ten)], "\n")
P <- P[id %in% full[ten == TRUE]$id]
P[, sc := fifelse(is.na(sc), 24, sc)]
cat("Scored set (all ten players tracked at every cutoff):", nrow(P), "picks\n")





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FREQUENCY BASELINES ----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# "Defense so far": each defense's earlier calls in the game, shrunk toward the league mix of the other games.
cnt <- function(v) as.numeric(table(factor(v, CALLS)))
SOFAR <- paste0("so_far_", seq_along(CALLS))
P[, (SOFAR) := NA_real_]
league_p <- matrix(NA_real_, nrow(P), length(CALLS))
# League mix from the other nine games; then, per defense in order, its earlier calls plus PRIOR_W picks of that mix.
for (g in unique(P$game_id)) {
  lg <- cnt(P[game_id != g]$call)
  lg <- lg / sum(lg)
  rows <- which(P$game_id == g)
  league_p[rows, ] <- matrix(lg, length(rows), length(CALLS), byrow = TRUE)
  for (dt in unique(P$def_team[rows])) {
    r <- rows[P$def_team[rows] == dt]
    for (j in seq_along(r)) {
      before <- if (j > 1) cnt(P$call[r[seq_len(j - 1)]]) else rep(0, length(CALLS))
      sh <- (before + PRIOR_W * lg) / (sum(before) + PRIOR_W)
      set(P, r[j], SOFAR, as.list(sh))
    }
  }
}
so_far_p <- as.matrix(P[, ..SOFAR])
# Log shares are the model inputs.
LSF <- paste0("lsf_", seq_along(CALLS))
for (k in seq_along(SOFAR)) set(P, j = LSF[k], value = log(P[[SOFAR[k]]]))

# Inputs: the four players' geometry and the shot clock, optionally with the other six and the defense so far.
GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "sc")
MODELS <- list(`4 players` = GEOM, `4 players + so far` = c(GEOM, LSF),
               `10 players` = c(GEOM, SIX), `10 players + so far` = c(GEOM, SIX, LSF))

# Leave-one-game-out multinomial logit on standardised inputs. Returns held-out probabilities and mean |coef| per input.
logo_logit <- function(d, feats) {
  Pm <- matrix(NA_real_, nrow(d), length(CALLS))
  W <- list()
  for (g in unique(d$game_id)) {
    tr <- d$game_id != g
    te <- !tr
    X <- as.matrix(d[tr, ..feats])
    mu <- colMeans(X)
    sdv <- apply(X, 2, sd)
    sdv[sdv == 0] <- 1
    fit <- multinom(y ~ ., data = data.frame(y = factor(d$call[tr], CALLS), scale(X, mu, sdv)),
                    decay = DECAY, trace = FALSE, maxit = 2000, MaxNWts = 5000)
    Pm[te, ] <- predict(fit, newdata = data.frame(scale(as.matrix(d[te, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE]
    cf <- coef(fit)[, feats, drop = FALSE]
    W[[length(W) + 1]] <- data.table(feature = feats, weight = colMeans(abs(cf)))   # mean |coef| over the 4 contrasts
  }
  list(P = Pm, W = rbindlist(W)[, .(weight = mean(weight)), by = feature])
}
# ll_of: per-pick log loss of the true call. boot_ci: the mean with a 95% interval from resampling whole games.
ll_of <- function(Pm, y) -log(pmax(Pm[cbind(seq_along(y), match(y, CALLS))], 1e-12))
boot_ci <- function(score, game, reps = 2000L) {
  set.seed(1)
  s <- split(score, game)
  sums <- vapply(s, sum, 0)
  ns <- lengths(s)
  b <- replicate(reps, {
    k <- sample(names(s), length(s), TRUE)
    sum(sums[k]) / sum(ns[k])
  })
  c(mean(score), quantile(b, c(0.025, 0.975)))
}

# Score every model at every cutoff against the baselines. lls keeps per-pick losses for the paired comparisons.
scores <- list()
probs <- list()
lls <- list()
weights <- list()
y <- P$call
base_ll <- ll_of(so_far_p, y)
# Record a model's log loss, accuracy, and difference from "defense so far" with its game-bootstrap interval.
add <- function(model, cut, Pm) {
  ll <- ll_of(Pm, y)
  ci <- boot_ci(ll - base_ll, P$game_id)
  lls[[paste(model, cut)]] <<- ll
  scores[[length(scores) + 1]] <<- data.table(model = model, cut = cut, n = length(y), logloss = mean(ll),
                                              accuracy = mean(max.col(Pm, ties.method = "first") == match(y, CALLS)),
                                              vs_so_far = ci[1], lo = ci[2], hi = ci[3])
}
add("league", NA, league_p)
add("defense so far", NA, so_far_p)
# At each cutoff: join that cutoff's measures to the picks and fit all four position models.
for (k_cut in CUTS) {
  d <- merge(P, Fe[cut == k_cut, c("id", setdiff(GEOM, "sc"), SIX), with = FALSE], by = "id", sort = FALSE)
  stopifnot(identical(d$id, P$id))
  probs[[as.character(k_cut)]] <- list()
  for (mn in names(MODELS)) {
    fit <- logo_logit(d, MODELS[[mn]])
    add(mn, k_cut, fit$P)
    probs[[as.character(k_cut)]][[mn]] <- fit$P
    if (mn == "10 players + so far") weights[[length(weights) + 1]] <- fit$W[, cut := k_cut]
  }
}
# Round and write the score table.
S <- rbindlist(scores)
S[, (c("logloss", "accuracy", "vs_so_far", "lo", "hi")) := lapply(.SD, round, 4), .SDcols = c("logloss", "accuracy", "vs_so_far", "lo", "hi")]
fwrite(S, file.path(out_dir, "lead_time_scores.csv"))
cat("\nHeld-out log loss by cutoff (vs_so_far < 0 = better than the defense's own earlier calls; 95% game bootstrap):\n")
print(S)

# paired: does adding the other six players help? (same picks, same held-out games)
six_eff <- rbindlist(lapply(CUTS, function(k) rbindlist(lapply(c("", " + so far"), function(sfx) {
  a <- lls[[paste0("10 players", sfx, " ", k)]]
  b <- lls[[paste0("4 players", sfx, " ", k)]]
  ci <- boot_ci(a - b, P$game_id)
  data.table(cut = k, comparison = paste0("10 players", sfx, " minus 4 players", sfx),
             change = round(ci[1], 4), lo = round(ci[2], 4), hi = round(ci[3], 4),
             games_helped = sum(tapply(a - b, P$game_id, mean) < 0))
}))))
fwrite(six_eff, file.path(out_dir, "six_players_effect.csv"))
cat("\nAdding the other six players (change in log loss; < 0 = helped; 95% game bootstrap; games of 10 where it helped):\n")
print(six_eff)

# which inputs carry weight in the full model? mean |standardised coefficient| over folds and contrasts
W <- rbindlist(weights)
W[, group := fcase(feature %in% LSF, "defense so far", feature %in% SIX, "other six players", default = "four players")]
fwrite(W[order(cut, -weight)][, weight := round(weight, 3)], file.path(out_dir, "feature_weights.csv"))
cat("\nFull model: average |standardised coefficient| per input, by group (higher = leans on it more):\n")
print(dcast(W[, .(mean_weight = round(mean(weight), 3), top = round(max(weight), 3)), by = .(cut, group)],
            group ~ cut, value.var = "mean_weight"))
cat("\nTop 8 inputs at -0.4 s:\n")
print(W[cut == -0.4][order(-weight)][1:8, .(feature, group, weight = round(weight, 3))])





## ═════════════════════════════════════════════════════════════════════════════
## 03 - WHEN DO THE DEFENDERS COMMIT? ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# AUC of one measure for a two-way split (rank-sum form), with NAs dropped.
auc <- function(x, g) {
  ok <- !is.na(x)
  x <- x[ok]
  g <- g[ok]
  r <- rank(x)
  n1 <- sum(g)
  n0 <- sum(!g)
  (sum(r[g]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
# At each cutoff: does one defender's position already separate the calls?
FA <- merge(Fe[id %in% P$id], P[, .(id, cov, scov)], by = "id")
com <- rbind(FA[cov %in% c("over", "under"), .(question = "over vs under, from BD's level (bd_lvl)", auc = auc(bd_lvl, cov == "over"), n = .N), by = cut],
             FA[scov %in% c("show", "soft") & cov %in% c("over", "under"), .(question = "show vs soft, from SD's level (sd_lvl)", auc = auc(sd_lvl, scov == "show"), n = .N), by = cut],
             FA[, .(question = "switch vs not, from BD-SD distance (closer = switch)", auc = auc(-d_def, cov == "switch"), n = .N), by = cut])
com[, auc := round(auc, 3)]
fwrite(com, file.path(out_dir, "commitment_auc.csv"))
cat("\nHow well one defender's position separates the calls at each cutoff (AUC, 0.5 = no sign yet):\n")
print(dcast(com, question ~ cut, value.var = "auc"))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - WORKED EXAMPLE ---------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Fall screens for Marcos, under + soft.

FULL <- "10 players + so far"
ex <- P[game_id == 188630 & S == 59165 & call == "under + soft" & grepl("Marcos", h_name)]
ex <- ex[order(f0)][1]
if (nrow(ex)) {
  # Each model's probability of under + soft for this pick at the four cutoffs, and the full model's top call.
  i <- match(ex$id, P$id)
  j_us <- match("under + soft", CALLS)
  wx <- Fe[id == ex$id]
  pk <- function(mn) vapply(as.character(wx$cut), function(k) probs[[k]][[mn]][i, j_us], 0)
  wx[, `:=`(p_so_far = so_far_p[i, j_us], p_4 = pk("4 players"), p_4_so_far = pk("4 players + so far"),
            p_10 = pk("10 players"), p_10_so_far = pk(FULL))]
  wx[, top_call_full := vapply(as.character(cut), function(k) CALLS[which.max(probs[[k]][[FULL]][i, ])], "")]
  # Save and print the example's measures and probabilities.
  fwrite(cbind(ex[, .(id, poss, call, h_name, s_name, bd_name, sd_name)],
               wx[, .(cut, bd_lvl, sd_lvl, d_hs, d_bd, d_sd, bd_lvl_v, sd_lvl_v, p_so_far, p_4, p_4_so_far, p_10,
                      p_10_so_far, top_call_full)]),
         file.path(out_dir, "worked_example.csv"))
  cat(sprintf("\nWorked example %s (%s): %s screens for %s; %s guards the ball, %s guards the screener; called %s\n",
              ex$id, ex$poss, ex$s_name, ex$h_name, ex$bd_name, ex$sd_name, ex$call))
  cat("Probability of under + soft by model:\n")
  print(wx[, .(cut, bd_lvl = round(bd_lvl, 1), sd_lvl = round(sd_lvl, 1), so_far = round(p_so_far, 2),
               `4p` = round(p_4, 2), `4p+sf` = round(p_4_so_far, 2), `10p` = round(p_10, 2),
               `10p+sf` = round(p_10_so_far, 2), top_call_full)])

  # snapshots: the four players of the action plus the other six (faded), un-mirrored so they match the viewer
  sn <- melt(wx[, .(cut, H_x = hx, H_y = hy, S_x = sx, S_y = sy, BD_x = bx, BD_y = by, SD_x = dx, SD_y = dy)],
             id.vars = "cut", measure = patterns(x = "_x$", y = "_y$"), variable.name = "role")
  sn[, role := c("H", "S", "BD", "SD")[role]]
  flip <- wx[, .(cut, flip = fifelse(sy < 0, -1, 1))]
  ot <- rbindlist(lapply(SIX_SLOTS, function(s) wx[, .(cut, slot = s, x = get(paste0(s, "_x")), y = get(paste0(s, "_y")))]))
  ot[flip, on = "cut", y := y * i.flip]
  ot[, side := fifelse(substr(slot, 1, 1) == "o", "Offense", "Defense")]
  # Labels: each player's surname and role. Each panel's title gives the full model's probability at that cutoff.
  last <- function(s) sub(".* ", "", s)
  who <- c(H = paste0(last(ex$h_name), " (ball)"), S = paste0(last(ex$s_name), " (screener)"),
           BD = paste0(last(ex$bd_name), " (on ball)"), SD = paste0(last(ex$sd_name), " (on screener)"))
  sn[, who := who[role]]
  lab <- function(cut) sprintf("%+.1f s  |  under + soft: %.0f%%", cut, 100 * wx$p_10_so_far[match(cut, wx$cut)])
  sn[, panel := factor(lab(cut), levels = lab(CUTS))]
  ot[, panel := factor(lab(cut), levels = lab(CUTS))]
  sn[, side := fifelse(role %in% c("H", "S"), "Offense", "Defense")]
  # The three-point arc in front of the hoop, then the plot.
  arc <- data.table(a = seq(-pi / 2, pi / 2, length.out = 100))[, .(x = HOOP_X - 6.75 * FT_PER_M * cos(a), y = 6.75 * FT_PER_M * sin(a))]
  allx <- c(sn$x, ot$x, HOOP_X)
  ally <- c(sn$y, ot$y)
  pe <- ggplot(sn, aes(x, y)) +
    geom_path(data = arc[x <= HOOP_X], colour = "grey70") +
    annotate("point", x = HOOP_X, y = 0, shape = 21, size = 3, colour = "grey40") +
    geom_point(data = ot, aes(fill = side), shape = 21, size = 3.5, colour = "white", alpha = 0.45) +
    geom_point(aes(fill = side), shape = 21, size = 6, colour = "white", stroke = 1) +
    geom_text(aes(label = role), size = 2.6, colour = "white", fontface = "bold") +
    ggrepel::geom_text_repel(aes(label = who), size = 3, seed = 2, box.padding = 0.5, point.size = 6, colour = "grey15") +
    scale_fill_manual(values = c(Offense = "#2a78d6", Defense = "#e34948"), name = NULL) +
    facet_wrap(~ panel, nrow = 1) +
    coord_equal(xlim = range(allx) + c(-3, 2), ylim = range(ally) + c(-3, 3)) +
    labs(title = sprintf("Worked example: %s screens for %s, called under + soft (%s)", ex$s_name, ex$h_name, ex$poss),
         subtitle = paste("Big dots: the four players of the screen. Faded dots: the other six. Four moments around the tag (0 s); above each,",
                          "\nthe '10 players + so far' model's probability for under + soft using only that moment and the 0.24 s before it. Hoop on the right."),
         x = NULL, y = NULL) +
    theme_minimal(base_size = 11) +
    theme(legend.position = "top", panel.grid = element_blank(), axis.text = element_blank(),
          plot.title = element_text(face = "bold"), strip.text = element_text(face = "bold", size = 10))
  ggsave(file.path(out_dir, "figures", "worked_example_fall_marcos.png"), pe, width = 15, height = 5.6, dpi = 150, bg = "white")
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - FILM CHECK -------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Picks to watch, where the -0.4 s forecast was confident.

# The full and four-player models' -0.4 s forecasts for every pick, with the measures a viewer would check.
pf <- probs[["-0.4"]][[FULL]]
p4 <- probs[["-0.4"]][["4 players + so far"]]
fc <- P[, .(id, poss, game_id, period, call, h_name, s_name, bd_name, sd_name)]
fc[, `:=`(forecast_call = CALLS[max.col(pf, ties.method = "first")], forecast_p = round(apply(pf, 1, max), 2),
          four_player_call = CALLS[max.col(p4, ties.method = "first")], four_player_p = round(apply(p4, 1, max), 2))]
fc[, `:=`(right = forecast_call == call, dashboard = paste0("#/play/", poss))]
fa <- Fe[cut == -0.4, .(id, bd_lvl_at_minus0.4 = round(bd_lvl, 1), sd_lvl_at_minus0.4 = round(sd_lvl, 1))]
fc <- merge(fc, fa, by = "id")
# Six confident right and six confident wrong forecasts, drawn reproducibly.
pick_film <- function(fc) {
  set.seed(3)
  rbind(fc[forecast_p >= 0.6 & right == TRUE][sample(.N, min(.N, 6))],
        fc[forecast_p >= 0.6 & right == FALSE][sample(.N, min(.N, 6))])
}
fwrite(pick_film(fc), file.path(out_dir, "film_check.csv"))
cat("\nConfident -0.4 s forecasts (", FULL, "): ", fc[forecast_p >= 0.6, .N], " of ", nrow(fc), " picks, ",
    sprintf("%.0f%% right", 100 * fc[forecast_p >= 0.6, mean(right)]), "\n", sep = "")
# the same list from the four-player model (the earlier film_check.csv)
f4 <- copy(fc)[, `:=`(forecast_call = four_player_call, forecast_p = four_player_p)][, right := forecast_call == call]
f4[, c("four_player_call", "four_player_p") := NULL]
fwrite(pick_film(f4), file.path(out_dir, "film_check_4players.csv"))
cat("Confident -0.4 s forecasts (4 players + so far): ", f4[forecast_p >= 0.6, .N], ", ",
    sprintf("%.0f%% right", 100 * f4[forecast_p >= 0.6, mean(right)]), "\n", sep = "")





## ═════════════════════════════════════════════════════════════════════════════
## 06 - PENALTY CHECK ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Is the six-player loss overfitting, or no information?

# Refit at -0.4 s with a stronger ridge penalty. If a heavier penalty closes the gap, the six players were adding
# noise the model chased; if 10 players never beats 4, they carry little the four don't already have.
d <- merge(P, Fe[cut == -0.4, c("id", setdiff(GEOM, "sc"), SIX), with = FALSE], by = "id", sort = FALSE)
# For each ridge strength: held-out loss of the four- and ten-player models and their paired difference.
# logo_logit reads the global DECAY, so it is set for each run and restored afterwards.
pen <- rbindlist(lapply(c(1, 5, 20, 50), function(dc) {
  DECAY <<- dc
  a <- ll_of(logo_logit(d, MODELS[["4 players + so far"]])$P, y)
  b <- ll_of(logo_logit(d, MODELS[[FULL]])$P, y)
  ci <- boot_ci(b - a, P$game_id)
  data.table(decay = dc, four_players = round(mean(a), 4), ten_players = round(mean(b), 4),
             ten_minus_four = round(ci[1], 4), lo = round(ci[2], 4), hi = round(ci[3], 4))
}))
DECAY <- 1
fwrite(pen, file.path(out_dir, "penalty_check.csv"))
cat("\nPenalty check at -0.4 s (both with 'so far'; decay = ridge strength, 1 is the main run):\n")
print(pen)





## ═════════════════════════════════════════════════════════════════════════════
## 07 - FIGURE: LOG LOSS BY CUTOFF ---------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Model curves by cutoff, with the two position-free baselines as dashed lines.
lines <- S[!is.na(cut)][, model := factor(model, levels = names(MODELS))]
flat <- S[is.na(cut)]
pl <- ggplot(lines, aes(cut, logloss, colour = model)) +
  geom_hline(data = flat, aes(yintercept = logloss, colour = model), linetype = "dashed") +
  geom_line(linewidth = 0.9) +
  geom_point(size = 2.6) +
  geom_vline(xintercept = 0, colour = "grey60") +
  annotate("text", x = -0.6, y = min(S$logloss) - 0.02, label = "forecast (before the tag)", size = 3.4, colour = "grey30") +
  annotate("text", x = 0.2, y = min(S$logloss) - 0.02, label = "recognition", size = 3.4, colour = "grey30") +
  scale_colour_manual(values = c(league = "#9a9a96", `defense so far` = "#eda100", `4 players` = "#2a78d6",
                                 `4 players + so far` = "#eb6834", `10 players` = "#1baf7a",
                                 `10 players + so far` = "#6250d6"),
                      breaks = c("league", "defense so far", names(MODELS)), name = NULL) +
  scale_x_continuous(breaks = CUTS, labels = function(v) sprintf("%+.1f s", v)) +
  guides(colour = guide_legend(nrow = 1)) +
  labs(title = "Predicting the screen coverage from player positions: how early is it possible?",
       subtitle = sprintf("%s screens with one of five calls, all ten players tracked; scored on held-out games. Dashed: baselines that ignore positions. Lower is better.",
                          format(nrow(P), big.mark = ",")),
       x = "Seconds relative to the screen tag (the model sees positions up to this moment)", y = "Held-out log loss") +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(size = 9.5))
ggsave(file.path(out_dir, "figures", "lead_time_scores.png"), pl, width = 11, height = 6, dpi = 150, bg = "white")
