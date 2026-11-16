## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 23: why the live transformer misses switches and under + show. Descriptive checks only, no
# model is trained or changed.
#   Rscript screen_coverage/01_scripts/23_call_diagnostics.R
#
# Needs 01_logistic_baseline.R and the live folds (03_train_transformer.R). Every prediction is held out by game.
#   1  When each call becomes readable · recall and precision of the top call at every frame from -2 s to +1 s
#   2  The top-call rule · each call's probability divided by its share in the other nine games before taking the
#      largest (a rule that stops the common calls winning every close frame), main curve
#   3  The defense's habit · switch share by defending team, and switch recall by how many earlier screens the
#      defense had shown that night
#   4  Who is in the screen · the season picks aggregates' share of each player's picks as the ball handler (1 =
#      always the handler, 0 = always the screener), and the handler's three-point attempt rate from the shots
#      aggregates. The model is never given these. Season aggregates cover 293 games including these 10, so this is
#      descriptive only
#
# Writes screen_coverage/03_outputs/call_diagnostics/: recall_by_time.csv, prior_corrected.csv, switch_by_team.csv,
# switch_by_habit.csv, by_roles.csv, recall_by_time.png.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
source(file.path(root, "screen_coverage", "01_scripts", "R", "predictions.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "window_weights.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "call_diagnostics")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
FPS <- 25
options(width = 200)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - PREDICTIONS ------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

L <- load_logistic(root)
X <- copy(L$X)
P <- copy(L$P)
CALLS <- L$calls
SQ <- load_seqheads(root)
y <- match(X$call, CALLS)
top <- max.col(SQ$prob, ties.method = "first")
X[, w_main := window_weight(off, "main")]
X[, w_main := w_main / sum(w_main), by = id]

#' Recall and precision of each call from a vector of top calls `rd`, weighted by `w` (rows with w = 0 dropped).
rp <- function(actual, rd, w) {
  rbindlist(lapply(seq_along(CALLS), function(k) {
    data.table(call = CALLS[k], actual_screens = sum(w[actual == k]), read_screens = sum(w[rd == k]),
               recall = sum(w[actual == k & rd == k]) / sum(w[actual == k]),
               precision = sum(w[actual == k & rd == k]) / sum(w[rd == k]))
  }))
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - WHEN EACH CALL BECOMES READABLE ----------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

bt <- rbindlist(lapply(sort(unique(X$off)), function(o) {
  r <- X$off == o
  rp(y[r], top[r], rep(1, sum(r)))[, off := o]
}))
bt[, t := off / FPS]
fwrite(bt[, .(t, call, recall = round(recall, 4), precision = round(precision, 4), read_screens)], file.path(out_dir, "recall_by_time.csv"))
cat("\nRecall of each call over time:\n")
print(dcast(bt[off %in% c(-50, -25, -10, 0, 6, 12, 25)], call ~ t, value.var = "recall")[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 2) else v)])

p <- ggplot(bt, aes(t, recall, colour = call)) +
  annotate("rect", xmin = -1.8, xmax = 0.5, ymin = -Inf, ymax = Inf, fill = "grey92") +
  geom_vline(xintercept = 0, colour = "grey50") +
  geom_line(linewidth = 0.9) +
  scale_y_continuous(labels = function(v) paste0(100 * v, "%"), limits = c(0, 1)) +
  labs(title = "Share of each call caught by the live transformer's top call",
       subtitle = "Held out by game, 1,463 screens. Grey band = main time-weight curve. Line at the pick frame",
       x = "Seconds from the pick frame", y = "Recall", colour = NULL) +
  theme_minimal(base_size = 11)
ggsave(file.path(out_dir, "recall_by_time.png"), p, width = 8, height = 4.5, dpi = 150, bg = "white")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - THE TOP-CALL RULE ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Each call's share among the screens of the other nine games, so the held-out game never informs its own rule.
shares <- P[, .(game_id, k = match(call, CALLS))]
Q <- SQ$prob
for (g in unique(X$game_id)) {
  sh <- tabulate(shares[game_id != g]$k, 5) / nrow(shares[game_id != g])
  r <- X$game_id == g
  Q[r, ] <- sweep(SQ$prob[r, ], 2, sh, "/")
}
top_adj <- max.col(Q, ties.method = "first")
pr <- rbind(rp(y, top, X$w_main)[, rule := "largest probability"],
            rp(y, top_adj, X$w_main)[, rule := "largest probability / call share"])
acc <- data.table(rule = c("largest probability", "largest probability / call share"),
                  accuracy = c(sum(X$w_main[top == y]), sum(X$w_main[top_adj == y])) / sum(X$w_main))
pr <- merge(pr, acc, by = "rule")
fwrite(pr[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "prior_corrected.csv"))
cat("\nTop-call rule, main curve:\n")
print(pr[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 3) else v)])





## ═════════════════════════════════════════════════════════════════════════════
## 04 - THE DEFENSE'S HABIT ----------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Switch share per defending team in each game (each team appears once or twice in the 10 games).
names_tm <- rbindlist(lapply(jsonlite::fromJSON(file.path(root, "data", "matches.json"), simplifyVector = FALSE), function(m) {
  data.table(team = c(m$home_team$id, m$away_team$id), team_name = c(m$home_team$name, m$away_team$name))
}))
names_tm <- unique(names_tm)
st <- P[, .(screens = .N, switches = sum(call == "switch"), switch_share = round(mean(call == "switch"), 3)), by = .(game_id, def_team)]
st <- merge(st, names_tm, by.x = "def_team", by.y = "team", all.x = TRUE)[order(-switch_share)]
fwrite(st, file.path(out_dir, "switch_by_team.csv"))
cat("\nSwitch share by defending team and game:\n")
print(st)

# Switch recall on the main curve by how many earlier readable screens the defense had shown that night (n_so_far at
# the pick frame).
hb <- X[off == 0L, .(id, n_so_far)]
hb[, habit := cut(n_so_far, c(-Inf, 9, 29, Inf), labels = c("0-9 earlier screens", "10-29", "30+"))]
X <- merge(X, hb[, .(id, habit)], by = "id", sort = FALSE)
stopifnot(identical(X$idx, L$X$idx))
sh <- rbindlist(lapply(levels(hb$habit), function(h) {
  r <- X$habit == h & X$w_main > 0
  rp(y[r], top[r], X$w_main[r])[call == "switch"][, habit := h]
}))
fwrite(sh[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "switch_by_habit.csv"))
cat("\nSwitch recall by the night's screens so far:\n")
print(sh)





## ═════════════════════════════════════════════════════════════════════════════
## 05 - WHO IS IN THE SCREEN ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Season role and shooting per canonical player, summed over per-team rows (total rows dropped).
alias <- fread(file.path(root, "data", "player_id_aliases.csv"))
canon <- function(id) {
  m <- alias$canonical_player_id[match(id, alias$player_id)]
  fifelse(is.na(m), id, m)
}
pk <- fread(file.path(root, "data", "aggregates", "acb_picksaggregates_20252026.csv"),
            select = c("player_id", "team_name", "handler_total_picks", "screener_total_picks"))
pk <- pk[team_name != "total", .(h = sum(handler_total_picks), s = sum(screener_total_picks)), by = .(pid = canon(player_id))]
pk[, handler_share := h / (h + s)]
sa <- fread(file.path(root, "data", "aggregates", "acb_shotsaggregates_20252026.csv"),
            select = c("player_id", "team_name", "attempts", "three_attempts"))
sa <- sa[team_name != "total", .(fga = sum(attempts), fg3a = sum(three_attempts)), by = .(pid = canon(player_id))]
sa[, three_rate := fg3a / fga]

# Main-curve recall per screen group, with the share of each call in the group.
S <- P[, .(id, call, h_canon, s_canon)]
S[, s_handler_share := pk$handler_share[match(s_canon, pk$pid)]]
S[, h_three_rate := sa$three_rate[match(h_canon, sa$pid)]]
S[, screener_role := cut(s_handler_share, c(-Inf, 0.2, 0.6, Inf), labels = c("screener is a big (handler <20%)", "mixed (20-60%)", "screener is a guard (handler >60%)"))]
S[, handler_shooting := cut(h_three_rate, c(-Inf, 0.3, 0.5, Inf), labels = c("handler 3PA rate <30%", "30-50%", ">50%"))]
cat("\nScreens without a season role:", sum(is.na(S$screener_role)), " without a three-point rate:", sum(is.na(S$handler_shooting)), "\n")
X <- merge(X, S[, .(id, screener_role, handler_shooting)], by = "id", sort = FALSE)
stopifnot(identical(X$idx, L$X$idx))
by_group <- function(col) {
  rbindlist(lapply(levels(S[[col]]), function(g) {
    r <- !is.na(X[[col]]) & X[[col]] == g & X$w_main > 0
    s <- S[get(col) == g]
    rp(y[r], top[r], X$w_main[r])[, `:=`(grouping = col, group = g, group_screens = nrow(s),
                                          share_of_group = vapply(CALLS, function(cc) mean(s$call == cc), 0))]
  }))
}
br <- rbind(by_group("screener_role"), by_group("handler_shooting"))
setcolorder(br, c("grouping", "group", "group_screens", "call", "share_of_group"))
fwrite(br[, lapply(.SD, function(v) if (is.numeric(v)) round(v, 4) else v)], file.path(out_dir, "by_roles.csv"))
cat("\nCall shares and recall by who is in the screen:\n")
print(br[, .(grouping, group, n = group_screens, call, share = round(share_of_group, 3), recall = round(recall, 3), precision = round(precision, 3))])
cat("\nWrote", out_dir, "\n")
