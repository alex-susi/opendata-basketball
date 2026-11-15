## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, lane experiment: cheap screening of the pop and drive options before any transformer is trained
# (added 2026-11-15, at the owner's request; runbook section 4 geometry, roll-diagnostics method).
#   Rscript screen_coverage/01_scripts/11_screen_pop_drive.R [--workers=8]
#
# Needs 01_logistic_baseline.R and 02_build_sequences.R (the live roster). Geometry: R/lane_geometry.R (pop_option,
# drive_options), at each prediction row's own frame, from past-only positions (pos_past via ten_player_positions).
#   pop     the screener's best spot 1 ft beyond the arc (slots and wings, within 10 ft, not taken by a teammate):
#           move distance, catch gap (nearest defender to the spot), pass gap (defender closest to the handler's pass
#           to it, capped at 15 ft), and flags for geometry known and spot available. "Open space" = min(catch, pass).
#   drive   direct lane (handler to rim): the handler's defender's gap and the nearest off-ball defender's gap;
#           screen-side and reject routes: the same two gaps on each, with validity flags.
#
# Steps:
#   1. A past-only spot check: rebuilt features match the cache, do not change when everything after the frame is
#      scrambled, and do change when the frame itself is (control).
#   2. Descriptive: each defender's call by bins of each measure at -0.8 s and -0.4 s (95% Wilson intervals).
#   3. Held out by game: each group's measures alone against no inputs, for the big's and the guard's call.
#   4. The logistic baseline ("no timing, + closeness", four screen players only) refit with each group added: pop,
#      drive direct, drive direct + routes; and routes against direct. Same rows, folds, weights and penalty.
# Gate (decided before looking): a group goes on to a transformer variant only if it improves the logistic for the
# defender it targets (pop: big; drive: guard) at -0.4 s or -0.8 s with a 95% interval below zero, or by more than
# 0.004 (twice the roll lane's logistic gain) with 7 or more of the 10 games improving.
#
# Writes screen_coverage/03_outputs/experiments/lanes/screening/ (features cached in
# screen_coverage/02_cache/experiments/lanes/screening_features.rds).
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
  library(parallel)
  library(ggplot2)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
for (f in c("past_only.R", "lane_geometry.R", "lane_variants.R")) {
  source(file.path(root, "screen_coverage", "01_scripts", "R", f))
}
hit <- grep("^--workers=", commandArgs(TRUE), value = TRUE)
WORKERS <- if (length(hit)) as.integer(sub("^--workers=", "", hit)) else 8L
out_dir <- file.path(lane_out_dir(root), "screening")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)
BOOT_SEED <- 20261115L
DECAY <- 1
bundle <- function(g) readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - POP AND DRIVE FEATURES AT EVERY PREDICTION ROW -------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))
P <- L$P
X <- copy(L$X)
CALLS <- L$calls
OFFS <- L$offs
ROSTER <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))$roster
stopifnot(nrow(ROSTER) == nrow(P))

#' Pop and drive features for screens `s` (rows of P) at offsets `offs`, from bundle B: [screens x offsets] rows.
features_for <- function(B, s, offs, roster = ROSTER) {
  pos <- ten_player_positions(B, P[s], roster[s, , drop = FALSE], pos_offs = offs)
  q <- CJ(k = seq_along(s), o = seq_along(offs))
  px <- t(sapply(seq_len(nrow(q)), function(i) pos$PX[q$k[i], q$o[i], ]))
  py <- t(sapply(seq_len(nrow(q)), function(i) pos$PY[q$k[i], q$o[i], ]))
  cbind(data.table(idx = s[q$k], off = offs[q$o]), pop_option(px, py), drive_options(px, py))
}
cache <- file.path(lane_dir(root, "B"), "..", "screening_features.rds")
if (file.exists(cache) && identical(readRDS(cache)$rules, PAST_ONLY_RULES)) {
  FT <- readRDS(cache)$features
} else {
  t0 <- Sys.time()
  FT <- rbindlist(lapply(sort(unique(P$game_id)), function(g) features_for(bundle(g), which(P$game_id == g), OFFS)))
  saveRDS(list(features = FT, rules = PAST_ONLY_RULES), cache)
  cat(sprintf("Features built in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
}
X <- merge(X, FT, by = c("idx", "off"), sort = FALSE)
setorder(X, off, idx)
stopifnot(nrow(X) == nrow(L$X), identical(X$id, L$X$id), identical(X$off, L$X$off))
X[, pop_open := pmin(pop_catch, pop_pass)]
X[, drv_route_help_diff := drv_screen_help - drv_reject_help]
X[, drv_route_onball_diff := drv_screen_onball - drv_reject_onball]
avail <- X[, .(rows = .N, pop_known = mean(pop_known), pop_available = mean(pop_available), drv_known = mean(drv_known),
               drv_side_known = mean(drv_side_known), drv_screen_valid = mean(drv_screen_valid),
               drv_reject_valid = mean(drv_reject_valid)), by = .(t = off / FPS)][order(t)]
fwrite(avail[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)], file.path(out_dir, "availability_by_lead.csv"))
cat("Availability at -0.4 s:\n")
print(avail[abs(t + 0.4) < 1e-9])





## ═════════════════════════════════════════════════════════════════════════════
## 02 - PAST-ONLY SPOT CHECK ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Three screens per game at five moments: rebuild from the bundle as delivered, after scrambling everything after
# the frame (moved up to 12 ft, 30% deleted), and after scrambling only the frame itself (must change).
scramble <- function(B, at, seed, at_frame_only = FALSE) {
  set.seed(seed)
  B2 <- B
  B2$P <- copy(B$P)
  hit <- if (at_frame_only) which(B2$P$frame == at) else which(B2$P$frame > at)
  set(B2$P, hit, "x", B2$P$x[hit] + runif(length(hit), -12, 12))
  set(B2$P, hit, "y", B2$P$y[hit] + runif(length(hit), -12, 12))
  if (!at_frame_only) B2$P <- B2$P[-sample(hit, round(0.3 * length(hit)))]
  setkey(B2$P, frame, pid)
  B2
}
FEAT_COLS <- setdiff(names(FT), c("idx", "off"))
same <- function(a, b) isTRUE(all.equal(unlist(a[, ..FEAT_COLS]), unlist(b[, ..FEAT_COLS]), tolerance = 1e-9))
set.seed(20261115)
chk <- list()
for (g in sort(unique(P$game_id))) {
  B <- bundle(g)
  for (k in sample(which(P$game_id == g), 3)) {
    for (o in c(-50L, -20L, -10L, 0L, 25L)) {
      at <- P$f0[k] + o
      f0 <- features_for(B, k, o)
      f1 <- features_for(scramble(B, at, k * 100L + o + 60L), k, o)
      f2 <- features_for(scramble(B, at, k * 100L + o + 60L, at_frame_only = TRUE), k, o)
      chk[[length(chk) + 1L]] <- data.table(game_id = g, idx = k, off = o, matches_cache = same(f0, FT[idx == k & off == o]),
                                            future_scrambled_same = same(f0, f1), control_now_scrambled_changes = !same(f0, f2))
    }
  }
}
chk <- rbindlist(chk)
fwrite(chk, file.path(out_dir, "past_only_spot_check.csv"))
cat("\nPast-only spot check:", nrow(chk), "rows | matches cache", sum(chk$matches_cache), "| future scramble unchanged",
    sum(chk$future_scrambled_same), "| control changes", sum(chk$control_now_scrambled_changes), "\n")
stopifnot(all(chk$matches_cache), all(chk$future_scrambled_same), all(chk$control_now_scrambled_changes))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - DESCRIPTIVE: EACH DEFENDER'S CALL BY EACH MEASURE ----------------------
## ═════════════════════════════════════════════════════════════════════════════

BIG_OF <- c("show", "soft", "soft", "show", "switch")
BD_OF <- c("over", "over", "under", "under", "switch")
LV <- list(big = c("show", "soft", "switch"), guard = c("over", "under", "switch"))
X[, big := BIG_OF[match(call, CALLS)]]
X[, guard := BD_OF[match(call, CALLS)]]
wilson <- function(k, n, z = 1.96) {
  p <- k / n
  mid <- (p + z^2 / (2 * n)) / (1 + z^2 / n)
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)
  list(lo = mid - half, hi = mid + half)
}
MEASURES <- c(pop_open = "pop: open space at the best spot (min of catch and pass gap, ft)",
              pop_catch = "pop: catch gap (ft)", pop_pass = "pop: pass gap (ft)", pop_move = "pop: screener's move (ft)",
              drv_direct_onball = "drive: handler's defender's gap to the direct lane (ft)",
              drv_direct_help = "drive: nearest off-ball defender's gap to the direct lane (ft)",
              drv_route_help_diff = "drive: help gap, screen-side minus reject route (ft)",
              drv_route_onball_diff = "drive: on-ball gap, screen-side minus reject route (ft)")
#' Bins of measure v among rows `keep`: fifths of its values at -0.4 s (the same edges at every horizon, labelled
#' with their ft range; the outer edges stretched to cover every row), plus "not available".
bins_of <- function(v, keep) {
  b <- rep(NA_character_, length(v))
  ok <- keep & !is.na(v)
  ref <- X$off == -10L & !is.na(v)
  br <- unique(quantile(v[ref], seq(0, 1, 0.2)))
  lab <- sprintf("%.1f to %.1f", head(br, -1), tail(br, -1))
  br[1] <- -Inf
  br[length(br)] <- Inf
  b[ok] <- as.character(cut(v[ok], br, lab, include.lowest = TRUE))
  b[keep & is.na(v)] <- "not available"
  factor(b, c(lab, "not available"))
}
rates <- list()
for (m in names(MEASURES)) {
  for (o in c(-20L, -10L)) {
    keep <- X$off == o
    bn <- bins_of(X[[m]], keep)
    for (who in names(LV)) {
      d <- data.table(bin = bn[keep], y = factor(X[[who]][keep], LV[[who]]))
      r <- d[, .(n = .N, k = as.numeric(table(y)), outcome = LV[[who]]), by = bin]
      r[, share := k / n]
      r[, c("lo", "hi") := wilson(k, n)]
      rates[[length(rates) + 1L]] <- cbind(measure = m, label = MEASURES[[m]], t = o / FPS, defender = who, r[order(bin, outcome)])
    }
  }
}
rates <- rbindlist(rates)
fwrite(rates[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "call_rates_by_measure.csv"))

# Figures: the big by pop open space, and the guard by the direct-lane on-ball gap.
COL <- list(big = c(show = "#2a78d6", soft = "#eb6834", switch = "#1baf7a"),
            guard = c(over = "#2a78d6", under = "#eb6834", switch = "#1baf7a"))
draw_rates <- function(m, who, file, title) {
  fig <- rates[measure == m & defender == who]
  fig[, panel := factor(sprintf("%+.1f s before the screen tag", t), sprintf("%+.1f s before the screen tag", sort(unique(t))))]
  fig[, x := as.integer(bin)]
  lab <- fig[, .SD[x == max(x)], by = panel]
  nlab <- unique(fig[, .(panel, x, n)])
  brk <- fig[panel == levels(panel)[1], .(x, bin)][!duplicated(x)][order(x)]
  p <- ggplot(fig, aes(x, share, colour = outcome, group = outcome)) +
    geom_linerange(aes(ymin = lo, ymax = hi), linewidth = 0.6, alpha = 0.5, position = position_dodge(width = 0.3)) +
    geom_line(linewidth = 0.7, position = position_dodge(width = 0.3)) +
    geom_point(size = 2.6, position = position_dodge(width = 0.3)) +
    geom_text(data = lab, aes(x = x + 0.25, label = outcome), hjust = 0, size = 3.4, colour = "grey20") +
    geom_text(data = nlab, aes(x = x, y = -0.05, label = paste0("n=", n)), inherit.aes = FALSE, size = 3, colour = "grey45") +
    facet_wrap(~panel, nrow = 1) +
    scale_colour_manual(values = COL[[who]], name = if (who == "big") "Big's call" else "Guard's call") +
    scale_x_continuous(breaks = brk$x, labels = brk$bin, expand = expansion(add = c(0.4, 0.9))) +
    scale_y_continuous(labels = function(v) paste0(round(100 * v), "%"), limits = c(-0.08, NA)) +
    labs(title = title, subtitle = paste("Share of screens with each call (bars: 95% interval); bins are fifths of the measure",
                                         "at -0.4 s (ranges in ft). 1,463 screens, 10 games."),
         x = MEASURES[[m]], y = "Share of screens") +
    theme_minimal(base_size = 11) +
    theme(legend.position = "top", panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
          plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9, colour = "grey30"),
          axis.text.x = element_text(size = 8))
  ggsave(file.path(out_dir, "figures", file), p, width = 12, height = 5.5, dpi = 150, bg = "white")
}
draw_rates("pop_open", "big", "big_by_pop_open_space.png", "The big's call by how open the screener's best pop spot is")
draw_rates("drv_direct_onball", "guard", "guard_by_direct_lane_onball_gap.png",
           "The guard's call by how far his own defender is from the handler's straight line to the rim")
draw_rates("drv_route_help_diff", "guard", "guard_by_route_help_difference.png",
           "The guard's call by how much more help sits on the screen side than on the reject side")





## ═════════════════════════════════════════════════════════════════════════════
## 04 - EACH GROUP ALONE, HELD OUT BY GAME -------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

GROUPS <- list(pop = list(cont = c("pop_move", "pop_catch", "pop_pass"), flag = c("pop_known", "pop_available")),
               drive_direct = list(cont = c("drv_direct_onball", "drv_direct_help"), flag = "drv_known"),
               drive_routes = list(cont = c("drv_direct_onball", "drv_direct_help", "drv_screen_onball", "drv_screen_help",
                                            "drv_reject_onball", "drv_reject_help"),
                                   flag = c("drv_known", "drv_side_known", "drv_screen_valid", "drv_reject_valid")))

#' Training and test copies with a group's measures ready: missing values take the training mean, flags become 0/1,
#' each measure also times closeness (as the baseline's measures). Returns the column names added.
prep <- function(tr, te, grp) {
  for (v in grp$cont) {
    m <- mean(tr[[v]], na.rm = TRUE)
    set(tr, which(is.na(tr[[v]])), v, m)
    set(te, which(is.na(te[[v]])), v, m)
    set(tr, j = paste0(v, "_close"), value = tr[[v]] * tr$closeness)
    set(te, j = paste0(v, "_close"), value = te[[v]] * te$closeness)
  }
  for (v in grp$flag) {
    set(tr, j = v, value = as.numeric(tr[[v]]))
    set(te, j = v, value = as.numeric(te[[v]]))
  }
  c(grp$cont, paste0(grp$cont, "_close"), grp$flag)
}
boot_ci <- function(d, game, reps = 2000L) {
  set.seed(BOOT_SEED)
  s <- split(d, game)
  sums <- vapply(s, sum, 0)
  ns <- lengths(s)
  b <- replicate(reps, {
    g <- sample(names(s), length(s), TRUE)
    sum(sums[g]) / sum(ns[g])
  })
  c(mean(d), quantile(b, c(0.025, 0.975)))
}
alone <- list()
for (gname in names(GROUPS)) {
  grp <- GROUPS[[gname]]
  for (who in names(LV)) {
    for (o in c(-20L, -10L)) {
      d <- X[off == o]
      ll <- rbindlist(lapply(sort(unique(d$game_id)), function(g) {
        tr <- copy(d[game_id != g])
        te <- copy(d[game_id == g])
        fs <- setdiff(prep(tr, te, grp), paste0(grp$cont, "_close"))
        mu <- colMeans(as.matrix(tr[, ..fs]))
        sdv <- apply(as.matrix(tr[, ..fs]), 2, sd)
        sdv[!is.finite(sdv) | sdv == 0] <- 1
        y_tr <- factor(tr[[who]], LV[[who]])
        fit <- multinom(y ~ ., data = data.frame(y = y_tr, scale(as.matrix(tr[, ..fs]), mu, sdv)), trace = FALSE, maxit = 1000)
        p1 <- predict(fit, newdata = data.frame(scale(as.matrix(te[, ..fs]), mu, sdv)), type = "probs")[, LV[[who]], drop = FALSE]
        p0 <- matrix(as.numeric(table(y_tr)) / nrow(tr), nrow(te), 3, byrow = TRUE)
        yy <- match(te[[who]], LV[[who]])
        data.table(game_id = g, with = -log(pmax(p1[cbind(seq_len(nrow(te)), yy)], 1e-12)),
                   none = -log(pmax(p0[cbind(seq_len(nrow(te)), yy)], 1e-12)))
      }))
      ci <- boot_ci(ll$with - ll$none, ll$game_id)
      alone[[length(alone) + 1L]] <- data.table(group = gname, defender = who, t = o / FPS, screens = nrow(ll),
                                                logloss_no_inputs = mean(ll$none), logloss_group_alone = mean(ll$with),
                                                delta = ci[1], lo = ci[2], hi = ci[3],
                                                games_improved = sum(ll[, mean(with - none), by = game_id]$V1 < 0))
    }
  }
}
alone <- rbindlist(alone)
rnd <- function(D) D[, lapply(.SD, function(v) if (is.numeric(v) && !is.integer(v)) round(v, 4) else v)]
fwrite(rnd(alone), file.path(out_dir, "group_alone_heldout.csv"))
cat("\nEach group alone vs no inputs (held out by game; below zero = it helps):\n")
print(rnd(alone))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - THE LOGISTIC BASELINE WITH EACH GROUP ADDED ----------------------------
## ═════════════════════════════════════════════════════════════════════════════

GEOM <- c("d_hs", "d_bd", "d_sd", "d_def", "bd_lvl", "sd_lvl", "h_lvl", "s_hoop", "bd_lvl_v", "sd_lvl_v", "tta_now")
CLOSE <- paste0(setdiff(GEOM, c("d_hs", "tta_now")), "_close")
FEATS <- c(GEOM, paste0("lsf_", 1:5), "closeness", CLOSE)
SETS <- list(`baseline (refit)` = NULL, `baseline + pop` = "pop", `baseline + drive direct` = "drive_direct",
             `baseline + drive direct + routes` = "drive_routes")
fold <- function(g, gname) {
  tr <- copy(X[game_id != g])
  te <- copy(X[game_id == g])
  feats <- c(FEATS, if (!is.null(gname)) prep(tr, te, GROUPS[[gname]]))
  Xtr <- as.matrix(tr[, ..feats])
  mu <- colMeans(Xtr)
  sdv <- apply(Xtr, 2, sd)
  sdv[sdv == 0] <- 1
  fit <- multinom(y ~ ., data = data.frame(y = factor(tr$call, CALLS), scale(Xtr, mu, sdv)),
                  weights = rep(1 / length(OFFS), nrow(tr)), decay = DECAY, trace = FALSE, maxit = 2000)
  list(rows = which(X$game_id == g),
       P = predict(fit, newdata = data.frame(scale(as.matrix(te[, ..feats]), mu, sdv)), type = "probs")[, CALLS, drop = FALSE])
}
t0 <- Sys.time()
cl <- makeCluster(WORKERS)
invisible(clusterEvalQ(cl, suppressPackageStartupMessages({
  library(data.table)
  library(nnet)
})))
clusterExport(cl, c("X", "CALLS", "OFFS", "DECAY", "FEATS", "GROUPS", "prep", "fold"))
jobs <- CJ(set = names(SETS), g = sort(unique(X$game_id)), sorted = FALSE)
res <- parLapply(cl, seq_len(nrow(jobs)), function(i, jobs, SETS) fold(jobs$g[i], SETS[[jobs$set[i]]]), jobs, SETS)
stopCluster(cl)
cat(sprintf("\nLogistic fits done in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
PR <- lapply(names(SETS), function(s) {
  Pm <- matrix(NA_real_, nrow(X), length(CALLS))
  for (i in which(jobs$set == s)) Pm[res[[i]]$rows, ] <- res[[i]]$P
  Pm
})
names(PR) <- names(SETS)
dev <- max(abs(PR[["baseline (refit)"]] - L$prob[["no timing, + closeness"]]))
cat("Refit baseline vs cached baseline, largest probability difference:", signif(dev, 3), "\n")
stopifnot(dev < 1e-4)

# Paired changes, game bootstrap: each group against the baseline, and routes against the direct lane.
y5 <- match(X$call, CALLS)
loss <- function(Pm, who) {
  if (who == "joint") return(-log(pmax(Pm[cbind(seq_len(nrow(Pm)), y5)], 1e-12)))
  of <- if (who == "big") BIG_OF else BD_OF
  M <- sapply(LV[[who]], function(l) rowSums(Pm[, of == l, drop = FALSE]))
  -log(pmax(M[cbind(seq_len(nrow(M)), match(X[[who]], LV[[who]]))], 1e-12))
}
HOR <- list(`-0.8 s` = X$off == -20L, `-0.4 s` = X$off == -10L, `before the tag (forecast)` = X$off < 0L,
            `tag to +1 s (recognition)` = X$off >= 0L)
PAIRS <- list(c("baseline + pop", "baseline (refit)"), c("baseline + drive direct", "baseline (refit)"),
              c("baseline + drive direct + routes", "baseline (refit)"),
              c("baseline + drive direct + routes", "baseline + drive direct"))
out <- list()
bygame <- list()
for (pp in PAIRS) {
  for (who in c("big", "guard", "joint")) {
    ref <- loss(PR[[pp[2]]], who)
    var <- loss(PR[[pp[1]]], who)
    for (h in names(HOR)) {
      d <- data.table(idx = X$idx, game_id = X$game_id, ref = ref, var = var)[HOR[[h]]][, .(ref = mean(ref), var = mean(var), game_id = game_id[1]), by = idx]
      ci <- boot_ci(d$var - d$ref, d$game_id)
      g <- d[, .(screens = .N, delta = mean(var - ref)), by = game_id]
      out[[length(out) + 1L]] <- data.table(model = pp[1], reference = pp[2], defender = who, horizon = h,
                                            loss_reference = mean(d$ref), loss_model = mean(d$var), delta = ci[1], lo = ci[2],
                                            hi = ci[3], screens = nrow(d), games_improved = sum(g$delta < 0))
      bygame[[length(bygame) + 1L]] <- g[, .(model = pp[1], reference = pp[2], defender = who, horizon = h, game_id, screens, delta)]
    }
  }
}
out <- rbindlist(out)
fwrite(rnd(out), file.path(out_dir, "logistic_plus_group.csv"))
fwrite(rnd(rbindlist(bygame)), file.path(out_dir, "logistic_plus_group_by_game.csv"))
cat("\nLogistic baseline with each group added (delta below zero = it helps; 95% game bootstrap), before the screen:\n")
print(rnd(out)[horizon %in% c("-0.8 s", "-0.4 s"), .(model, reference, defender, horizon, loss_reference, loss_model, delta, lo, hi, games_improved)])

# The gate, as stated in the header: the targeted defender at -0.4 s or -0.8 s.
gate <- out[horizon %in% c("-0.8 s", "-0.4 s") & reference == "baseline (refit)" &
              ((model == "baseline + pop" & defender == "big") | (model != "baseline + pop" & defender == "guard"))]
gate[, passes := hi < 0 | (delta < -0.004 & games_improved >= 7)]
fwrite(rnd(gate), file.path(out_dir, "gate.csv"))
cat("\nGate (targeted defender; passes if the interval is below zero, or delta < -0.004 with 7+ games better):\n")
print(rnd(gate)[, .(model, defender, horizon, delta, lo, hi, games_improved, passes)])
cat("\nWrote", out_dir, "\n")
