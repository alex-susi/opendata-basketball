## ═════════════════════════════════════════════════════════════════════════════
# Step 10: does each cue help? One logistic comparison, one cue group at a time, same held-out games.
#   Rscript src/kickout_transformer/10_cue_comparison.R
#
# Base model: the step-2 logistic regression (ten hand-built features, including time to act), fitted
# leave-one-game-out exactly as in step 2. Each cue group from step 9 is added on its own, then all three together:
#   + space    proj_gap, lane_best, lane_worst
#   + pass     return_pass, passer_hold, since_poss
#   + screen   scr_dist, scr_proj
#   + all      the eight cues together
# Two targets, scored on the same catches for every model:
#   same touch    the current label (shot / drive / pass), the 1,662 catches without "other"
#   at 1.25 s     the step-8 horizon state (shot / drive / pass / other / hold), all 1,738 catches
# Every comparison is paired: the same catch scored by the base model and by base + cue, with a 95% interval from
# resampling whole games. A negative change in log loss means the cue helped.
#
# Calibration of confident calls: every prediction whose top class has at least 60% probability, right or wrong,
# binned by that probability. A well-calibrated model's 70-80% calls come true 70-80% of the time.
#
# Writes outputs/kickout_timing/: cue_comparison.csv, cue_comparison_by_game.csv, cue_calibration.csv,
# cue_coefficients.csv, cue_film_plays.csv, figures/cue_comparison.png, figures/cue_calibration.png.
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
suppressPackageStartupMessages({
  library(nnet)
  library(ggplot2)
})
out_dir <- file.path(root, "outputs", "kickout_timing")
dir.create(file.path(out_dir, "figures"), recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# The step-2 base features, the cue groups added one at a time (and all together), ridge decay, and the confidence cut.
BASE <- c("recv_hoop_dist", "recv_corner", "recv_speed", "def1_dist", "def1_closing", "def2_dist",
          "defs_in_paint", "time_to_act", "kickout", "from_paint")                  # = step 2 LOGIT_FEATS
GROUPS <- list(base = character(),
               `+ space` = c("proj_gap", "lane_best", "lane_worst"),
               `+ pass` = c("return_pass", "passer_hold", "since_poss"),
               `+ screen` = c("scr_dist", "scr_proj"))
GROUPS$`+ all` <- unlist(GROUPS[-1], use.names = FALSE)
DECAY <- 1
CONF <- 0.6





## ═════════════════════════════════════════════════════════════════════════════
## 02 - DATA AND TARGETS -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Catches joined to their step-9 cues and step-8 horizon state.
m <- readRDS(file.path(paths$base_cache, "catches.rds"))$meta
cues <- readRDS(file.path(paths$base_cache, "cues.rds"))$cues
timing <- readRDS(file.path(paths$base_cache, "timing.rds"))
m <- merge(m, cues[, !"row_all"], by = "pass_id")
m[timing, on = "pass_id", horizon := as.character(i.horizon)]
setorder(m, row)

# Two targets: the same-touch label without "other", and the state 1.25 s after the catch.
TARGETS <- list(`same touch` = list(rows = m[label != "other", which = TRUE], y = "label", classes = c("shot", "drive", "pass")),
                `at 1.25 s` = list(rows = seq_len(nrow(m)), y = "horizon", classes = c("shot", "drive", "pass", "other", "hold")))

#' Leave-one-game-out multinomial logistic predictions for one feature set: an [n x classes] matrix.
logo_logit <- function(d, y, classes, feats) {
  P <- matrix(NA_real_, nrow(d), length(classes))
  coefs <- list()
  for (g in sort(unique(d$game_id))) {
    tr <- d$game_id != g
    te <- !tr
    X <- as.matrix(d[tr, ..feats]) * 1
    mu <- colMeans(X)
    sdv <- apply(X, 2, sd)
    sdv[sdv == 0] <- 1
    dtr <- data.frame(y = factor(y[tr], levels = classes), scale(X, mu, sdv))
    dte <- data.frame(scale(as.matrix(d[te, ..feats]) * 1, mu, sdv))
    fit <- multinom(y ~ ., data = dtr, decay = DECAY, trace = FALSE, maxit = 1000)
    P[te, ] <- predict(fit, newdata = dte, type = "probs")[, classes, drop = FALSE]
    coefs[[length(coefs) + 1]] <- data.table(game_id = g, class = rownames(coef(fit)), coef(fit))
  }
  list(P = P, coef = rbindlist(coefs))
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - FITS -------------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# For each target and cue group: held-out probabilities, per-catch log loss, confident-call records, film-play
# probabilities.
res <- list()
cal <- list()
cf <- list()
film <- list()
film_ids <- c(fread(file.path(root, "outputs", "kickout_transformer_3class", "film_study_plays.csv"))$pass_id, "pass-188630-1-66")
for (tn in names(TARGETS)) {
  T <- TARGETS[[tn]]
  d <- m[T$rows]
  y <- d[[T$y]]
  cls <- T$classes
  ll <- list()
  for (gn in names(GROUPS)) {
    fit <- logo_logit(d, y, cls, c(BASE, GROUPS[[gn]]))
    P <- fit$P
    p_true <- P[cbind(seq_len(nrow(d)), match(y, cls))]
    ll[[gn]] <- -log(pmax(p_true, 1e-12))
    # The top class and whether it was right, for the calibration check.
    top <- apply(P, 1, max)
    hit <- max.col(P, ties.method = "first") == match(y, cls)
    cal[[length(cal) + 1]] <- data.table(target = tn, model = gn, top = top, hit = hit,
                                         call = cls[max.col(P, ties.method = "first")])
    # Fold-averaged cue coefficients of the "+ all" model.
    if (gn == "+ all") {
      cc <- fit$coef[, c("game_id", "class", GROUPS$`+ all`), with = FALSE]
      cf[[tn]] <- cc[, lapply(.SD, function(v) round(mean(v), 3)), by = class, .SDcols = GROUPS$`+ all`][, target := tn]
    }
    # Probability given to what happened on the film-study plays.
    fi <- which(d$pass_id %in% film_ids)
    film[[length(film) + 1]] <- data.table(target = tn, model = gn, pass_id = d$pass_id[fi], actual = y[fi],
                                           p_actual = round(p_true[fi], 3))
    res[[length(res) + 1]] <- data.table(target = tn, model = gn, n = nrow(d), game_id = d$game_id, kickout = d$kickout,
                                         logloss = ll[[gn]], acc = hit)
  }
}





## ═════════════════════════════════════════════════════════════════════════════
## 04 - PAIRED COMPARISONS AND CALIBRATION -------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Each catch's base-model log loss, for the paired differences.
R <- rbindlist(res)
R[, i := seq_len(.N), by = .(target, model)]                              # catch position, same in every model
R[R[model == "base"], on = .(target, i), base_ll := i.logloss]

# paired differences vs the base model, all catches and strict kickouts
summ <- rbindlist(lapply(c("all catches", "strict kickouts"), function(s) {
  R[if (s == "all catches") rep(TRUE, .N) else kickout == TRUE, {
    ci <- game_bootstrap(logloss - base_ll, game_id)
    .(subset = s, n = .N, logloss = round(mean(logloss), 4), accuracy = round(mean(acc), 3),
      change = round(ci[["mean"]], 4), lo = round(ci[["lo"]], 4), hi = round(ci[["hi"]], 4))
  }, by = .(target, model)]
}))
fwrite(summ, file.path(out_dir, "cue_comparison.csv"))
cat("Logistic log loss, base vs base + one cue group (change < 0 = the cue helped; 95% game-bootstrap interval):\n")
print(summ)

# Change per game, and how many of the ten games each cue group helped.
by_game <- R[model != "base", .(n = .N, change = round(mean(logloss - base_ll), 4)), by = .(target, model, game_id)]
by_game_w <- dcast(by_game, target + game_id + n ~ model, value.var = "change")
fwrite(by_game_w, file.path(out_dir, "cue_comparison_by_game.csv"))
cat("\nGames where '+ all' helped (of 10):\n")
print(by_game[model == "+ all", .(helped = sum(change < 0), games = .N), by = target])

# calibration of confident calls (>= 60%), right or wrong
C <- rbindlist(cal)[top >= CONF]
C[, bin := cut(top, c(CONF, 0.7, 0.8, 1.0001), right = FALSE, labels = c("60-70%", "70-80%", "80%+"))]
calib <- C[, .(calls = .N, mean_predicted = round(mean(top), 3), came_true = round(mean(hit), 3)), by = .(target, model, bin)][order(target, model, bin)]
calib_call <- C[, .(calls = .N, mean_predicted = round(mean(top), 3), came_true = round(mean(hit), 3)), by = .(target, model, call)]
fwrite(rbind(calib[, .(target, model, group = as.character(bin), calls, mean_predicted, came_true)],
             calib_call[, .(target, model, group = paste("call:", call), calls, mean_predicted, came_true)]),
       file.path(out_dir, "cue_calibration.csv"))
cat("\nConfident calls (top class >= 60%): predicted vs came true\n")
print(dcast(calib, target + bin ~ model, value.var = c("came_true")), digits = 3)
print(calib[model %in% c("base", "+ all")])

cfo <- rbindlist(cf)
fwrite(cfo, file.path(out_dir, "cue_coefficients.csv"))
cat("\n'+ all' model: cue coefficients averaged over folds (standardised; relative to 'shot'):\n")
print(cfo)

fp <- dcast(rbindlist(film), target + pass_id + actual ~ model, value.var = "p_actual")
fwrite(fp, file.path(out_dir, "cue_film_plays.csv"))
cat("\nFilm plays: probability given to what actually happened\n")
print(fp)





## ═════════════════════════════════════════════════════════════════════════════
## 05 - FIGURES ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

lv <- rev(names(GROUPS)[-1])
fs <- summ[model != "base"][, model := factor(model, levels = lv)]
fs[, `:=`(subset = factor(subset, levels = c("all catches", "strict kickouts")), target = factor(target, levels = names(TARGETS)))]
pg <- ggplot(fs, aes(change, model)) +
  geom_vline(xintercept = 0, colour = "grey40") +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0.2, orientation = "y", colour = "#2a78d6", linewidth = 0.8) +
  geom_point(size = 3, colour = "#2a78d6") +
  geom_text(aes(label = sprintf("%+.3f", change)), vjust = -1.1, size = 3.2, colour = "grey15") +
  facet_grid(subset ~ target, labeller = labeller(target = c(`same touch` = "Target: what the receiver did on his touch (3 outcomes)",
                                                             `at 1.25 s` = "Target: his state 1.25 s after the catch (5 states)"))) +
  labs(title = "Does adding a cue improve the logistic model? Change in held-out log loss vs the base model",
       subtitle = "Left of zero = the cue helped. Bars: 95% interval from resampling whole games. Same catches, same held-out games in every row.",
       x = "Change in log loss (base + cue minus base)", y = NULL) +
  theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold", size = 13),
        strip.text = element_text(face = "bold"))
ggsave(file.path(out_dir, "figures", "cue_comparison.png"), pg, width = 12, height = 6.5, dpi = 150, bg = "white")

# Calibration of confident calls for the base model and base + all cues.
cb <- calib[model %in% c("base", "+ all")][, `:=`(target = factor(target, levels = names(TARGETS)), model = factor(model, levels = c("base", "+ all")))]
pc <- ggplot(cb, aes(mean_predicted, came_true, colour = model)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey50") +
  geom_line(linewidth = 0.8) +
  geom_point(aes(size = calls)) +
  ggrepel::geom_text_repel(aes(label = calls), size = 3, colour = "grey20", show.legend = FALSE, seed = 1) +
  facet_wrap(~ target, labeller = labeller(target = c(`same touch` = "Same-touch target", `at 1.25 s` = "1.25 s target"))) +
  scale_colour_manual(values = c(base = "#2a78d6", `+ all` = "#eb6834"), name = NULL,
                      labels = c(base = "base logistic", `+ all` = "base + all cues")) +
  scale_size_area(max_size = 6, guide = "none") +
  scale_x_continuous(labels = function(v) paste0(100 * v, "%"), limits = c(0.6, 1)) +
  scale_y_continuous(labels = function(v) paste0(100 * v, "%"), limits = c(0.3, 1)) +
  labs(title = "Confident calls: how often a 60%+ call came true",
       subtitle = "Every held-out call whose top outcome had at least 60%, right or wrong, binned at 60-70%, 70-80% and 80%+.\nOn the dashed line the model is as sure as it should be. Numbers: calls in the bin.",
       x = "Average probability the model gave its call", y = "Share of calls that came true") +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top", panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"))
ggsave(file.path(out_dir, "figures", "cue_calibration.png"), pc, width = 11, height = 5.8, dpi = 150, bg = "white")
