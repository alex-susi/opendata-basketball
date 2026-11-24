## ═════════════════════════════════════════════════════════════════════════════
# Episodes and per-time eligibility for the screen-coverage forecast (coverage product plan, Phase 4, 2026-11-23).
#
# Each forecast belongs to one screen (its pick id, the stable event identity) and one prediction frame. A row
# (screen, frame) is eligible when every rule below holds, checked in this order. The first one that fails is the
# row's reason:
#   outside_domain   the frame is before DOMAIN_START or after the window end
#   other_possession the frame is outside the screen's possession
#   after_stop       the frame is at or after the screen's stop, the first observable new action after the pick frame
#                    (a pass by the handler, another screen or hand-off in the possession, a dead ball, or the end of
#                    the chance)
#   players_missing  one of the four screen players has no position at the frame (or the MAX_GAP frames before it)
#   short_history    fewer than HISTORY_MIN of the HISTORY_STEPS history moments have all four players
# Everything is past-only at the frame except two premises the whole project keeps: the screen and its four players
# come from the pick event, and the episode stop is read from events at the moment they happen. The handler's touch end
# is recorded (touch_ended). It stops an episode only through a pass, since a shot or turnover ends the chance anyway.
#
# Owner's choices 2026-11-24 · window end +1.5 s (WINDOW_END) and a pass by the handler stops the episode. Version 1
# (2026-11-23, no pass stop) is kept in EPISODE_RULES_V1 for the record.
#
# Used by 37_audit_timing.R. The old cohort rule (all four players at every frame from -2 s to +1 s) stays in
# 01_logistic_baseline.R for reproduction.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages(library(data.table))

# Predeclared settings (2026-11-23, before any model was scored on them). Pass stop and window end added 2026-11-24.
EPISODE_RULES_V1 <- "episodes v1 (2026-11-23): domain -2 s, stop = next screen/hand-off, dead ball (0.2 s), chance end, history 7 of 9 at 0.2 s"
EPISODE_RULES <- "episodes v2 (2026-11-24): domain -2 s to +1.5 s, stop = handler pass, next screen/hand-off, dead ball (0.2 s), chance end, history 7 of 9 at 0.2 s"
DOMAIN_START <- -50L          # frames from the pick frame (-2 s)
WINDOW_END <- 38L             # the owner's window end, +1.5 s (1.52 s at 25 fps)
END_CANDIDATES <- c(25L, 38L, 50L)   # +1 s (old), +1.5 s (chosen), +2 s, kept for comparison
HISTORY_STEPS <- 9L           # the live model's history: now, 0.2 s ago ... 1.6 s ago
HISTORY_STEP <- 5L            # frames between history moments
HISTORY_MIN <- 7L             # moments with all four players needed for a forecast
DEAD_RUN <- 5L                # a dead ball is a stopped game clock that stays stopped for 0.2 s
REASONS <- c("eligible", "outside_domain", "other_possession", "after_stop", "players_missing", "short_history")





## ═════════════════════════════════════════════════════════════════════════════
## 01 - EPISODE STOPS ----------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' The observable stops after each screen of `p` (id, chance, poss, f0, touch, H) in game bundle `B`. Returns one row
#' per screen: the handler's first pass, the next screen or hand-off in the possession, the first dead ball, the chance
#' end, the handler's touch end, and the stop (the earliest of the first four) with its kind. With `passes = FALSE` the
#' pass is left out (the version 1 rule).
episode_stops <- function(B, p, passes = TRUE) {
  scr <- rbind(B$picks[, .(sid = id, chance, f0)], B$handoffs[, .(sid = id, chance, f0)])
  scr <- merge(scr, B$ch[, .(chance, poss)], by = "chance")
  next_screen <- vapply(seq_len(nrow(p)), function(i) {
    f <- scr[poss == p$poss[i] & f0 > p$f0[i] & sid != p$id[i]]$f0
    if (length(f)) min(f) else NA_real_
  }, 0)
  # The handler's first pass release after the pick frame in the possession. Self-passes (passer = receiver) are
  # marking noise and left out. Incomplete passes count.
  ps <- merge(B$passes[is.na(receiver) | receiver != passer, .(chance, f0, passer)], B$ch[, .(chance, poss)], by = "chance")
  handler_pass <- vapply(seq_len(nrow(p)), function(i) {
    f <- ps[poss == p$poss[i] & passer == p$H[i] & f0 > p$f0[i]]$f0
    if (length(f)) min(f) else NA_real_
  }, 0)
  # Dead ball: the first frame after the pick frame where the game clock stops and stays stopped for DEAD_RUN frames.
  Fr <- B$Fr[order(frame), .(frame, stopped)]
  run <- frollsum(as.integer(Fr$stopped), DEAD_RUN, align = "left", fill = 0L) == DEAD_RUN
  dead_frames <- Fr$frame[run]
  dead <- vapply(p$f0, function(f) {
    k <- dead_frames[dead_frames > f]
    if (length(k)) min(k) else NA_real_
  }, 0)
  chance_end <- B$ch$f1[match(p$chance, B$ch$chance)]
  touch_end <- B$touches$f1[match(p$touch, B$touches$touch)]
  out <- data.table(id = p$id, handler_pass = handler_pass, next_screen = next_screen, dead_ball = dead,
                    chance_end = as.numeric(chance_end), touch_end = as.numeric(touch_end))
  M <- as.matrix(out[, .(handler_pass, next_screen, dead_ball, chance_end)])
  if (!passes) M[, "handler_pass"] <- NA
  M[is.na(M)] <- Inf
  k <- max.col(-M, ties.method = "first")
  out[, stop := M[cbind(seq_len(.N), k)]]
  out[, stop_kind := c("handler pass", "next screen", "dead ball", "chance end")[k]]
  out[!is.finite(stop), `:=`(stop = NA_real_, stop_kind = NA_character_)]
  out[]
}





## ═════════════════════════════════════════════════════════════════════════════
## 02 - FOUR-PLAYER PRESENCE ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' Whether all four screen players (H, S, BD, SD of `p`) have a past-only position in the screen's possession at each
#' offset of `offs` (pos_past from R/past_only.R). Returns a logical [screens x offsets] matrix.
four_present <- function(B, p, offs) {
  n <- nrow(p)
  frames <- rep(p$f0, times = length(offs)) + rep(offs, each = n)
  poss <- rep(p$poss, times = length(offs))
  ok <- rep(TRUE, length(frames))
  for (r in c("H", "S", "BD", "SD")) {
    h <- pos_past(B, frames, rep(p[[r]], times = length(offs)))
    ok <- ok & !is.na(h$x) & !is.na(h$poss) & h$poss == poss
  }
  matrix(ok, n, length(offs))
}





## ═════════════════════════════════════════════════════════════════════════════
## 03 - ELIGIBILITY ROWS -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

#' One row per screen and prediction offset from DOMAIN_START to max(END_CANDIDATES), with the reason it is or is not
#' eligible under each candidate end, and `reason` under the chosen WINDOW_END. `p` holds id, f0, poss and the possession frames pf0/pf1. `stops` comes from
#' episode_stops() and `pres` is four_present() over `pres_offs`, which must reach HISTORY_STEPS - 1 steps before
#' DOMAIN_START.
eligibility_rows <- function(p, stops, pres, pres_offs) {
  offs <- DOMAIN_START:max(END_CANDIDATES)
  n <- nrow(p)
  R <- data.table(id = rep(p$id, times = length(offs)), off = rep(offs, each = n))
  R[, frame := rep(p$f0, times = length(offs)) + off]
  R[, `:=`(pf0 = rep(p$pf0, times = length(offs)), pf1 = rep(p$pf1, times = length(offs)))]
  st <- stops[match(R$id, stops$id)]
  R[, `:=`(stop_off = st$stop - frame + off, touch_end_off = st$touch_end - frame + off)]
  i <- rep(seq_len(n), times = length(offs))
  col <- function(o) match(o, pres_offs)
  R[, present_now := pres[cbind(i, col(off))]]
  hist_n <- Reduce(`+`, lapply(0:(HISTORY_STEPS - 1L), function(k) pres[cbind(i, col(R$off - k * HISTORY_STEP))]))
  R[, history_n := hist_n]
  R[, touch_ended := !is.na(touch_end_off) & off >= touch_end_off]
  # The reason before any candidate end is applied, then one eligibility column per candidate end.
  R[, base_reason := fcase(frame < pf0 | frame > pf1, "other_possession",
                           !is.na(stop_off) & off >= stop_off, "after_stop",
                           !present_now, "players_missing",
                           history_n < HISTORY_MIN, "short_history",
                           default = "eligible")]
  for (e in END_CANDIDATES) {
    nm <- sprintf("reason_end_%+.1f", e / FPS)
    R[, (nm) := fifelse(off > e, "outside_domain", base_reason)]
  }
  R[, reason := fifelse(off > WINDOW_END, "outside_domain", base_reason)]
  R[, c("pf0", "pf1") := NULL]
  R[]
}
