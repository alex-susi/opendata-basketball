## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 32: scores for each part of the read, live against the personnel experiment's versions.
#   Rscript screen_coverage/01_scripts/32_switch_head_compare.R
#
# "Live" is the model live from 2026-11-15 to 2026-11-19 (SEQ_MAIN_DIR). The switch-part version became the live model
# on 2026-11-19 (33_promote_switch_positions.R).
#
# Agreed with the owner before the switch-part run (2026-11-19). The read has three parts, so each is scored on its
# own as well as together (31_personnel_compare.R has the joint and per-defender scores):
#   Switch          switch or not, every screen. Log loss and screen-level AUC of the switch probability, before
#                   the pick frame (-2 s to -0.04 s) and at and after it (0 to +1 s)
#   Under or over   on screens that were not switched: the probability of under given no switch,
#                   (under + drop + under + show) / (1 - switch). Log loss and accuracy (50% cut), same two windows
#   Show or drop    on screens that were not switched: (over + show + under + show) / (1 - switch), likewise
# Each screen's frames are averaged within a window first, so every screen counts once. Paired changes against the
# live transformer (above 0 = better), 95% intervals from resampling whole games, and games improved of 10.
# The conditional parts are read from the five joint probabilities, so every version is scored the same way.
#
# Writes screen_coverage/03_outputs/experiments/personnel/by_part.csv and by_part_gain.csv.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
exp_root <- file.path(root, "screen_coverage", "02_cache", "experiments")
out_dir <- file.path(root, "screen_coverage", "03_outputs", "experiments", "personnel")
N_BOOT <- 2000L
SEED <- 20261119L





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PREDICTIONS ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- L$X
CALLS <- L$calls
#' A version's held-out joint probabilities: its two seed halves averaged into four starts.
version <- function(v) {
  (load_seqheads(root, file.path(exp_root, v, "tf_s1-2"))$prob + load_seqheads(root, file.path(exp_root, v, "tf_s3-4"))$prob) / 2
}
MODELS <- list("Live" = load_seqheads(root, do.call(file.path, c(list(root), SEQ_MAIN_DIR)))$prob,
               "Split head, no positions (control)" = version("split_head_control"),
               "Positions in the switch part (four screen players)" = version("personnel_hard_swhead_nomem"),
               "Positions on all ten players" = version("personnel_hard_nomem"),
               "Positions on the two defenders" = version("personnel_hard_def_nomem"),
               "Memory only" = version("personnel_memory"))
k <- function(cc) match(cc, CALLS)
y_sw <- X$call == "switch"
y_under <- X$call %in% c("under + drop", "under + show")
y_show <- X$call %in% c("over + show", "under + show")
X[, window := fifelse(off < 0, "before the pick frame", "at and after the pick frame")]





## ═════════════════════════════════════════════════════════════════════════════
## 02 - EACH PART, PER SCREEN --------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Per screen and window: switch log loss and probability; on non-switch screens, the two conditional log losses and
#' whether the 50% cut was right.
by_screen <- function(Pm) {
  p_sw <- pmin(pmax(Pm[, k("switch")], 1e-6), 1 - 1e-6)
  rest <- pmax(1 - Pm[, k("switch")], 1e-6)
  p_un <- pmin(pmax((Pm[, k("under + drop")] + Pm[, k("under + show")]) / rest, 1e-6), 1 - 1e-6)
  p_sh <- pmin(pmax((Pm[, k("over + show")] + Pm[, k("under + show")]) / rest, 1e-6), 1 - 1e-6)
  d <- data.table(idx = X$idx, game_id = X$game_id, window = X$window, sw = y_sw,
                  sw_ll = -fifelse(y_sw, log(p_sw), log(1 - p_sw)), p_sw = p_sw,
                  un_ll = -fifelse(y_under, log(p_un), log(1 - p_un)), un_ok = (p_un > 0.5) == y_under,
                  sh_ll = -fifelse(y_show, log(p_sh), log(1 - p_sh)), sh_ok = (p_sh > 0.5) == y_show)
  d[, .(game_id = game_id[1], sw = sw[1], sw_ll = mean(sw_ll), p_sw = mean(p_sw), un_ll = mean(un_ll), un_acc = mean(un_ok),
        sh_ll = mean(sh_ll), sh_acc = mean(sh_ok)), by = .(window, idx)]
}
S <- lapply(MODELS, by_screen)
boot <- function(v, g) {
  set.seed(SEED)
  s <- tapply(v, g, sum)
  n <- tapply(v, g, length)
  b <- replicate(N_BOOT, {
    kk <- sample(names(s), length(s), TRUE)
    sum(s[kk]) / sum(n[kk])
  })
  c(mean = mean(v), lo = unname(quantile(b, 0.025)), hi = unname(quantile(b, 0.975)))
}
auc <- function(p, yy) {
  r <- rank(p)
  (sum(r[yy]) - sum(yy) * (sum(yy) + 1) / 2) / (sum(yy) * sum(!yy))
}
PARTS <- list(c("sw_ll", "Switch · log loss", "all"), c("un_ll", "Under or over · log loss (non-switch screens)", "nosw"),
              c("un_acc", "Under or over · accuracy (non-switch screens)", "nosw"), c("sh_ll", "Show or drop · log loss (non-switch screens)", "nosw"),
              c("sh_acc", "Show or drop · accuracy (non-switch screens)", "nosw"))
rows_of <- function(d, who) if (who == "all") d else d[sw == FALSE]
tab <- rbindlist(lapply(names(MODELS), function(m) {
  rbindlist(lapply(unique(X$window), function(w) {
    d <- S[[m]][window == w]
    rbind(rbindlist(lapply(PARTS, function(pp) {
      dd <- rows_of(d, pp[3])
      as.data.table(as.list(boot(dd[[pp[1]]], dd$game_id)))[, `:=`(model = m, window = w, part = pp[2])]
    })), data.table(mean = auc(d$p_sw, d$sw), lo = NA_real_, hi = NA_real_, model = m, window = w, part = "Switch · AUC"))
  }))
}))
setcolorder(tab, c("model", "window", "part"))
fwrite(tab[, .(model, window, part, mean = round(mean, 4), lo = round(lo, 4), hi = round(hi, 4))], file.path(out_dir, "by_part.csv"))
cat("\nEach part of the read (log loss lower is better; accuracy and AUC higher):\n")
print(dcast(tab, part + window ~ model, value.var = "mean")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])

# Paired changes: every version against live, and the switch-part run against the control (what the positions alone
# add, the split being the same in both). Log losses old minus new, accuracies new minus old (above 0 = better).
CMP <- c(lapply(setdiff(names(MODELS), "Live"), function(m) c("Live", m)),
         list(c("Split head, no positions (control)", "Positions in the switch part (four screen players)")))
gain <- rbindlist(lapply(CMP, function(pr) {
  m <- pr[2]
  rbindlist(lapply(unique(X$window), function(w) {
    a <- S[[pr[1]]][window == w]
    b <- S[[m]][window == w][match(a$idx, idx)]
    rbindlist(lapply(PARTS, function(pp) {
      keep <- if (pp[3] == "all") rep(TRUE, nrow(a)) else !a$sw
      sgn <- if (grepl("acc", pp[1])) -1 else 1
      d <- sgn * (a[[pp[1]]] - b[[pp[1]]])[keep]
      g <- a$game_id[keep]
      bt <- boot(d, g)
      data.table(against = pr[1], model = m, window = w, part = pp[2], gain = bt[["mean"]], lo = bt[["lo"]], hi = bt[["hi"]], games_better = sum(tapply(d, g, mean) > 0))
    }))
  }))
}))
fwrite(gain[, .(against, model, window, part, gain = round(gain, 4), lo = round(lo, 4), hi = round(hi, 4), games_better)], file.path(out_dir, "by_part_gain.csv"))
cat("\nChange against the older version (above 0 = better), 95% game interval, games improved of 10:\n")
print(gain[, .(against = substr(against, 1, 12), model = substr(model, 1, 40), window = substr(window, 1, 12), part = substr(part, 1, 34), gain = round(gain, 4),
               lo = round(lo, 4), hi = round(hi, 4), games_better)], nrows = 200)
