## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 37: timing audit, episode stops and per-time eligibility (coverage product plan, Phase 4,
# 2026-11-23).
#   Rscript screen_coverage/01_scripts/37_audit_timing.R
#
# Every on-ball screen of the ten games, −3 s to +3 s around its pick frame. Reads tracking and events only, never a
# model output. Two kinds of result, kept apart:
#   - retrospective diagnostics · may look past the moment they describe (the closest handler-screener point, the
#     matchups table's hand-over, the approach measured back from the closest point). For describing plays and
#     choosing rules, never as model inputs
#   - online rules · use only what has happened by the frame (the geometry exchange alert, episode stops, the per-time
#     eligibility of R/episode_eligibility.R)
#
# Sections:
#   03 closest handler-screener point within ±0.48 s (the old "contact"), ±1 s and ±2 s of the pick frame, and how
#      often the minimum sits on the edge of the span
#   04 approach · the last time the pair came within 15 ft and 10 ft before the closest point, censored when the
#      tracking runs out first
#   05 episode stops · the handler's pass, next screen or hand-off, dead ball, chance end (version 2, the owner's
#      rules of 2026-11-24), against version 1 without the pass, and the handler's touch end (flagged only)
#   06 switch timing · the matchups table's hand-over (retrospective) and a geometry alert confirmed over a trailing
#      0.2 s or 0.4 s (online)
#   07 per-time eligibility under the chosen +1.5 s end and the +1 s and +2 s ends for comparison, against the old cohort
#   08 the owner's Pass 1 review stamps against these measures
#
# Writes screen_coverage/03_outputs/timing_audit/ (CSV per section, per_screen.csv) and caches the eligibility rows in
# screen_coverage/02_cache/eligibility_rows.rds.
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
source(file.path(root, "screen_coverage", "01_scripts", "R", "past_only.R"))
source(file.path(root, "screen_coverage", "01_scripts", "R", "episode_eligibility.R"))
out_dir <- file.path(root, "screen_coverage", "03_outputs", "timing_audit")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)





## ═════════════════════════════════════════════════════════════════════════════
## 01 - SETTINGS ---------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Predeclared 2026-11-23. Diagnostic span ±3 s. Closest-point search spans in frames. Approach distances. The exchange
# alert: the screener's defender nearer the handler than the handler's own defender is, the handler's defender nearer
# the screener than the screener's defender is, each within EX_FT, held for the trailing persistence window.
DIAG <- -75:75
SPANS <- c(12L, 25L, 50L)
NEAR_FT <- c(15, 10)
EX_FT <- 6
PERSIST <- c(5L, 10L)
EX_FROM <- -25L
CALLS <- c("over + show", "over + drop", "under + drop", "under + show", "switch")
games <- as.integer(jsonlite::fromJSON(file.path(root, "data", "matches.json"))$id)
cohort <- readRDS(file.path(root, "screen_coverage", "02_cache", "logistic_per_frame.rds"))$P$id





## ═════════════════════════════════════════════════════════════════════════════
## 02 - EVERY SCREEN, ITS POSITIONS, STOPS AND ELIGIBILITY ---------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Exact-frame positions (no fill) of players `ids` at `frames`, kept only inside possession `poss`.
exact_xy <- function(B, frames, ids, poss) {
  h <- B$P[.(frames, ids), .(x, y, det, poss), nomatch = NA]
  bad <- is.na(h$poss) | h$poss != poss
  h[bad, `:=`(x = NA_real_, y = NA_real_, det = NA_integer_)]
  h
}

pres_offs <- (DOMAIN_START - (HISTORY_STEPS - 1L) * HISTORY_STEP):max(END_CANDIDATES)
one_game <- function(g) {
  B <- readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
  p <- merge(B$picks[, .(id, chance, f0, touch, H = actor, BD = adef, S = screener, SD = sdef, cov, scov)],
             B$ch[, .(chance, poss, q)], by = "chance", all.x = TRUE)
  p <- merge(p, B$poss[, .(poss, pf0 = f0, pf1 = f1)], by = "poss", all.x = TRUE)
  setorder(p, f0)
  p[, game_id := g]
  # Four players' exact positions over the diagnostic span, as [screens x offsets] matrices.
  n <- nrow(p)
  frames <- rep(p$f0, times = length(DIAG)) + rep(DIAG, each = n)
  poss <- rep(p$poss, times = length(DIAG))
  XY <- lapply(c(H = "H", S = "S", BD = "BD", SD = "SD"), function(r) {
    h <- exact_xy(B, frames, rep(p[[r]], times = length(DIAG)), poss)
    list(x = matrix(h$x, n), y = matrix(h$y, n), det = matrix(h$det, n))
  })
  # The matchups table's hand-overs (retrospective): when the screener's defender is first listed on the handler,
  # and the handler's defender on the screener, from 1 s before to 3 s after the pick frame.
  mu <- merge(B$mu, B$ch[, .(chance, poss)], by = "chance")
  hand <- function(off_id, def_id, i) {
    m <- mu[poss == p$poss[i] & off == off_id & def == def_id & f1 >= p$f0[i] - FPS & f0 <= p$f0[i] + 3L * FPS]
    if (nrow(m)) (max(min(m$f0), p$f0[i] - FPS) - p$f0[i]) / FPS else NA_real_
  }
  p[, mu_h_to_sd := vapply(seq_len(.N), function(i) hand(H[i], SD[i], i), 0)]
  p[, mu_s_to_bd := vapply(seq_len(.N), function(i) hand(S[i], BD[i], i), 0)]
  stops <- episode_stops(B, p)
  stops_v1 <- episode_stops(B, p, passes = FALSE)[, .(id, stop_v1 = stop, stop_kind_v1 = stop_kind)]
  pres <- four_present(B, p, pres_offs)
  elig <- eligibility_rows(p, stops, pres, pres_offs)
  elig[, game_id := g]
  list(p = merge(merge(p, stops, by = "id"), stops_v1, by = "id"), XY = XY, elig = elig)
}
built <- lapply(games, one_game)
P <- rbindlist(lapply(built, `[[`, "p"))
XY <- lapply(c(H = "H", S = "S", BD = "BD", SD = "SD"), function(r) {
  lapply(c(x = "x", y = "y", det = "det"), function(k) do.call(rbind, lapply(built, function(b) b$XY[[r]][[k]])))
})
ELIG <- rbindlist(lapply(built, `[[`, "elig"))
stopifnot(nrow(P) == nrow(XY$H$x), identical(P$id, unlist(lapply(built, function(b) b$p$id))))
P[scov == "soft", scov := "drop"]
P[, call := fifelse(cov == "switch" | scov == "switch", "switch",
                    fifelse(cov %in% c("over", "under") & scov %in% c("show", "drop"), paste(cov, "+", scov), NA_character_))]
P[, group := fifelse(is.na(call), "outside five", call)]
P[, in_cohort := id %in% cohort]
ns <- nrow(P)
col0 <- match(0L, DIAG)
cat(sprintf("Screens %d · five coverages %d · old cohort %d\n", ns, sum(!is.na(P$call)), sum(P$in_cohort)))
dd <- function(a, b) sqrt((XY[[a]]$x - XY[[b]]$x)^2 + (XY[[a]]$y - XY[[b]]$y)^2)
D_HS <- dd("H", "S")





## ═════════════════════════════════════════════════════════════════════════════
## 03 - CLOSEST HANDLER-SCREENER POINT (RETROSPECTIVE) -------------------------
## ═════════════════════════════════════════════════════════════════════════════

# For each span: the time and distance of the pair's smallest distance, and whether it sits on the span's edge.
closest <- rbindlist(lapply(SPANS, function(s) {
  cols <- (col0 - s):(col0 + s)
  k <- apply(D_HS[, cols, drop = FALSE], 1, function(d) if (all(is.na(d))) NA_integer_ else which.min(d))
  data.table(id = P$id, span_s = s / FPS, t = DIAG[cols[k]] / FPS, dist = D_HS[cbind(seq_len(ns), cols[k])],
             edge = !is.na(k) & (k == 1L | k == length(cols)))
}))
closest <- merge(closest, P[, .(id, group, in_cohort)], by = "id")
cp_sum <- closest[in_cohort == TRUE, .(screens = .N, found = sum(!is.na(t)), on_edge = sum(edge), on_edge_share = round(mean(edge), 3),
                                       p10 = quantile(t, .1, na.rm = TRUE), p25 = quantile(t, .25, na.rm = TRUE),
                                       median = median(t, na.rm = TRUE), p75 = quantile(t, .75, na.rm = TRUE),
                                       p90 = quantile(t, .9, na.rm = TRUE), median_dist_ft = round(median(dist, na.rm = TRUE), 1)),
                  by = span_s]
# How far the closest point moves when the span widens, and in which direction.
wide <- dcast(closest[in_cohort == TRUE], id ~ span_s, value.var = "t")
setnames(wide, c("id", "t_048", "t_1", "t_2"))
cp_sum[, moved_from_048 := c(0L, wide[, sum(abs(t_1 - t_048) > 1e-9, na.rm = TRUE)], wide[, sum(abs(t_2 - t_048) > 1e-9, na.rm = TRUE)])]
fwrite(cp_sum, file.path(out_dir, "closest_point_spans.csv"))
cat("\nClosest handler-screener point, old cohort\n")
print(cp_sum)
cp_by_group <- closest[span_s == 1, .(screens = .N, median = median(t, na.rm = TRUE), on_edge = sum(edge)), by = group][order(group)]
fwrite(cp_by_group, file.path(out_dir, "closest_point_by_coverage.csv"))
P[, cp_t := closest[span_s == 1][match(P$id, id)]$t]
P[, cp_t_048 := closest[span_s == 0.48][match(P$id, id)]$t]





## ═════════════════════════════════════════════════════════════════════════════
## 04 - APPROACH AND CENSORING (RETROSPECTIVE) ---------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Walking back from the ±1 s closest point: the last frame the pair was farther than `ft` (approach = the frame
# after). Censored when tracking runs out, or the −3 s edge is reached, before the pair is found farther apart.
# Never within: the pair never came within `ft` of each other at the closest point.
cp_col <- match(round(P$cp_t * FPS), DIAG)
approach <- rbindlist(lapply(NEAR_FT, function(ft) {
  res <- t(vapply(seq_len(ns), function(i) {
    c0 <- cp_col[i]
    if (is.na(c0)) return(c(NA_real_, NA_real_))
    if (D_HS[i, c0] > ft) return(c(NA_real_, 2))
    k <- c0
    while (k >= 1L && !is.na(D_HS[i, k]) && D_HS[i, k] <= ft) k <- k - 1L
    if (k < 1L || is.na(D_HS[i, k])) return(c(DIAG[k + 1L] / FPS, 1))
    c(DIAG[k + 1L] / FPS, 0)
  }, numeric(2)))
  data.table(id = P$id, ft = ft, t = res[, 1], status = c("found", "censored", "never within")[res[, 2] + 1L])
}))
approach <- merge(approach, P[, .(id, game_id, group, in_cohort)], by = "id")
app_sum <- approach[!is.na(status), .(screens = .N, found = sum(status == "found"), censored = sum(status == "censored"),
                                      never_within = sum(status == "never within"),
                                      median_found = round(median(t[status == "found"]), 2)),
                    by = .(ft, group)][order(ft, group)]
app_game <- approach[!is.na(status), .(screens = .N, censored = sum(status == "censored"), never_within = sum(status == "never within")),
                     by = .(ft, game_id)][order(ft, game_id)]
fwrite(app_sum, file.path(out_dir, "approach_by_coverage.csv"))
fwrite(app_game, file.path(out_dir, "approach_by_game.csv"))
cat("\nApproach (pair within 15 ft / 10 ft before the closest point)\n")
print(app_sum)
P[, approach_15ft := approach[ft == 15][match(P$id, id)]$t]





## ═════════════════════════════════════════════════════════════════════════════
## 05 - EPISODE STOPS (ONLINE) -------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

P[, `:=`(stop_t = (stop - f0) / FPS, stop_v1_t = (stop_v1 - f0) / FPS, handler_pass_t = (handler_pass - f0) / FPS,
         touch_end_t = (touch_end - f0) / FPS, next_screen_t = (next_screen - f0) / FPS,
         dead_ball_t = (dead_ball - f0) / FPS, chance_end_t = (chance_end - f0) / FPS)]
before <- function(v, s) sum(!is.na(v) & v < s)
stop_stats <- function(d) {
  d[, .(screens = .N, median_stop = median(stop_t, na.rm = TRUE), stop_before_1 = before(stop_t, 1),
        stop_before_1.5 = before(stop_t, 1.5), stop_before_2 = before(stop_t, 2),
        median_stop_v1 = median(stop_v1_t, na.rm = TRUE), stop_v1_before_1.5 = before(stop_v1_t, 1.5),
        pass_before_1.5 = before(handler_pass_t, 1.5), touch_end_before_1 = before(touch_end_t, 1),
        touch_end_before_1.5 = before(touch_end_t, 1.5), touch_end_before_2 = before(touch_end_t, 2),
        stop_at_or_before_0 = sum(stop_t <= 0, na.rm = TRUE))]
}
stop_sum <- rbind(cbind(group = "all", stop_stats(P)),
                  rbindlist(lapply(sort(unique(P$group)), function(gr) cbind(group = gr, stop_stats(P[group == gr])))))
stop_kind <- P[!is.na(stop_t) & stop_t < 2, .N, by = .(stop_kind, before_1 = stop_t < 1)][order(stop_kind, before_1)]
fwrite(stop_sum, file.path(out_dir, "stops_by_coverage.csv"))
fwrite(stop_kind, file.path(out_dir, "stops_by_kind.csv"))
cat("\nEpisode stops (seconds from the pick frame)\n")
print(stop_sum)
print(stop_kind)





## ═════════════════════════════════════════════════════════════════════════════
## 06 - SWITCH TIMING ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Online geometry exchange: both sides at once, and the handler side alone. Each holds at a frame when the defender
# who took the man is within EX_FT and nearer than the original defender. An alert fires at the END of a run of
# `w` frames in which it held, from EX_FROM on. Missing positions count as not holding.
D_H_SD <- dd("H", "SD")
D_H_BD <- dd("H", "BD")
D_S_BD <- dd("S", "BD")
D_S_SD <- dd("S", "SD")
hside <- D_H_SD < D_H_BD & D_H_SD <= EX_FT
sside <- D_S_BD < D_S_SD & D_S_BD <= EX_FT
both <- hside & sside
hside[is.na(hside)] <- FALSE
both[is.na(both)] <- FALSE
alert_at <- function(M, w) {
  from <- match(EX_FROM, DIAG)
  apply(M, 1, function(v) {
    run <- 0L
    for (k in from:length(v)) {
      run <- if (v[k]) run + 1L else 0L
      if (run >= w) return(DIAG[k] / FPS)
    }
    NA_real_
  })
}
for (w in PERSIST) {
  P[, (sprintf("alert_both_%.1fs", w / FPS)) := alert_at(both, w)]
  P[, (sprintf("alert_hside_%.1fs", w / FPS)) := alert_at(hside, w)]
}
P[, mu_both := pmax(mu_h_to_sd, mu_s_to_bd)]
ex_cols <- c("mu_h_to_sd", "mu_both", grep("^alert_", names(P), value = TRUE))
ex_kind <- c(mu_h_to_sd = "retrospective", mu_both = "retrospective")
sw <- rbindlist(lapply(ex_cols, function(k) {
  P[!is.na(call), .(measure = k, kind = if (k %in% names(ex_kind)) ex_kind[[k]] else "online", screens = .N,
                    by_1s = sum(get(k) <= 1, na.rm = TRUE), by_2s = sum(get(k) <= 2, na.rm = TRUE),
                    by_3s = sum(get(k) <= 3, na.rm = TRUE), median_t = round(median(get(k), na.rm = TRUE), 2)),
    by = .(is_switch = call == "switch")]
}))
sw[, share_by_2s := round(by_2s / screens, 3)]
setorder(sw, measure, -is_switch)
fwrite(sw, file.path(out_dir, "switch_timing.csv"))
cat("\nSwitch timing · recorded switches against the other four coverages\n")
print(sw)
# The geometry alert against the matchups table on the other coverages: temporary shows and help.
sw_other <- P[!is.na(call) & call != "switch", .(screens = .N, mu_h_to_sd_by_3s = sum(mu_h_to_sd <= 3, na.rm = TRUE),
                                                 alert_both_0.4_by_2s = sum(`alert_both_0.4s` <= 2, na.rm = TRUE),
                                                 alert_hside_0.4_by_2s = sum(`alert_hside_0.4s` <= 2, na.rm = TRUE)), by = call]
fwrite(sw_other, file.path(out_dir, "switch_alerts_other_coverages.csv"))
print(sw_other)





## ═════════════════════════════════════════════════════════════════════════════
## 07 - PER-TIME ELIGIBILITY (ONLINE) ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ELIG <- merge(ELIG, P[, .(id, group, call, in_cohort)], by = "id")
saveRDS(list(rows = ELIG, rules = EPISODE_RULES, made = format(Sys.Date())), file.path(root, "screen_coverage", "02_cache", "eligibility_rows.rds"))
reason_cols <- grep("^reason_end_", names(ELIG), value = TRUE)
el_sum <- rbindlist(lapply(reason_cols, function(rc) {
  r <- ELIG[!is.na(call) & off >= DOMAIN_START & off <= as.integer(round(as.numeric(sub("reason_end_", "", rc)) * FPS))]
  r[, .(end = sub("reason_end_", "", rc), rows = .N, eligible = sum(get(rc) == "eligible"),
        screens_with_any = uniqueN(id[get(rc) == "eligible"]),
        other_possession = sum(get(rc) == "other_possession"), after_stop = sum(get(rc) == "after_stop"),
        players_missing = sum(get(rc) == "players_missing"), short_history = sum(get(rc) == "short_history"))]
}))
old_rows <- ELIG[in_cohort == TRUE & off >= DOMAIN_START & off <= 25L, .N]
el_sum[, old_cohort_rows := old_rows]
fwrite(el_sum, file.path(out_dir, "eligibility_summary.csv"))
cat(sprintf("\nEligibility, five-coverage screens (old cohort: %d screens x 76 frames = %d rows)\n", sum(P$in_cohort), old_rows))
print(el_sum)
# By offset (for the +2 s end): eligible share of five-coverage screens, and the leading reason when not.
by_off <- ELIG[!is.na(call), .(eligible = mean(`reason_end_+2.0` == "eligible"),
                               after_stop = mean(`reason_end_+2.0` == "after_stop"),
                               players_missing = mean(`reason_end_+2.0` == "players_missing"),
                               short_history = mean(`reason_end_+2.0` == "short_history"),
                               other_possession = mean(`reason_end_+2.0` == "other_possession"),
                               touch_ended = mean(touch_ended)), by = off][order(off)]
fwrite(by_off, file.path(out_dir, "eligibility_by_offset.csv"))
by_cov <- ELIG[!is.na(call), .(screens = uniqueN(id), eligible_rows_end_1 = sum(`reason_end_+1.0` == "eligible"),
                               eligible_rows_end_1.5 = sum(`reason_end_+1.5` == "eligible"),
                               eligible_rows_end_2 = sum(`reason_end_+2.0` == "eligible"),
                               old_cohort_rows = sum(in_cohort & off <= 25L)), by = call][order(call)]
fwrite(by_cov, file.path(out_dir, "eligibility_by_coverage.csv"))
print(by_cov)
# Screens with no eligible row at all, and why (the reason at the pick frame).
none <- ELIG[!is.na(call), .(any = any(reason == "eligible"), at0 = reason[off == 0L]), by = id][any == FALSE]
fwrite(none[, .N, by = at0], file.path(out_dir, "eligibility_no_forecast.csv"))
print(none[, .N, by = at0])





## ═════════════════════════════════════════════════════════════════════════════
## 08 - THE OWNER'S REVIEW AGAINST THE AUDIT -----------------------------------
## ═════════════════════════════════════════════════════════════════════════════

rv <- fread(file.path(root, "screen_coverage", "03_outputs", "product_review", "review_cases.csv"))[pass == 1]
num <- function(v) suppressWarnings(as.numeric(v))
rv <- merge(rv[, .(id = screen_id, case, execution = num(execution_t), exchange = num(exchange_t),
                   new_action = num(new_action_t), touch_end = num(touch_end_t), sd_takes_h, bd_takes_s)],
            P[, .(id, group, cp_t, cp_t_048, stop_t, stop_v1_t, touch_end_t, mu_both, mu_h_to_sd,
                  alert_both = `alert_both_0.4s`, alert_hside = `alert_hside_0.4s`)], by = "id")
cmp <- function(a, b, what) {
  ok <- !is.na(a) & !is.na(b)
  data.table(comparison = what, pairs = sum(ok), median_diff_s = round(median(a[ok] - b[ok]), 2),
             within_0.2s = sum(abs(a[ok] - b[ok]) <= 0.2), cor = round(suppressWarnings(cor(a[ok], b[ok])), 2))
}
rv_cmp <- rbind(cmp(rv$execution, rv$cp_t, "screen engaged (review) − closest point ±1 s"),
                cmp(rv$execution, rv$cp_t_048, "screen engaged (review) − closest point ±0.48 s"),
                cmp(rv$touch_end, rv$touch_end_t, "handler's touch ends (review) − touches table"),
                cmp(rv$new_action, rv$stop_t, "new action (review) − episode stop"),
                cmp(rv$new_action, rv$stop_v1_t, "new action (review) − episode stop, version 1 without the pass"),
                cmp(rv$exchange, rv$alert_both, "exchange done (review) − geometry alert, both sides, 0.4 s"),
                cmp(rv$exchange, rv$mu_both, "exchange done (review) − matchups table, both sides"))
# The reviewer saw both defenders take the other's man: how often each measure fires by +3 s.
rv[, saw_exchange := sd_takes_h == "yes" & bd_takes_s == "yes"]
rv_ex <- rv[, .(cases = .N, alert_both = sum(alert_both <= 3, na.rm = TRUE), alert_hside = sum(alert_hside <= 3, na.rm = TRUE),
                matchups_both = sum(mu_both <= 3, na.rm = TRUE)), by = saw_exchange]
fwrite(rv_cmp, file.path(out_dir, "review_vs_audit.csv"))
fwrite(rv_ex, file.path(out_dir, "review_exchange_vs_measures.csv"))
cat("\nReview stamps against the audit\n")
print(rv_cmp)
print(rv_ex)





## ═════════════════════════════════════════════════════════════════════════════
## 09 - PER SCREEN -------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

per <- P[, c("id", "game_id", "poss", "f0", "call", "group", "in_cohort", "q", "cp_t_048", "cp_t", "approach_15ft",
             "stop_t", "stop_kind", "stop_v1_t", "stop_kind_v1", "handler_pass_t", "next_screen_t", "dead_ball_t",
             "chance_end_t", "touch_end_t", "mu_h_to_sd", "mu_s_to_bd",
             grep("^alert_", names(P), value = TRUE)), with = FALSE]
fwrite(per, file.path(out_dir, "per_screen.csv"))
cat("\nWrote", out_dir, "\n")
