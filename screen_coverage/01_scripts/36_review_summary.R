## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, step 36: summary of the owner's play review (coverage product plan, Phase 3, 2026-11-23).
#   Rscript screen_coverage/01_scripts/36_review_summary.R
#
# Reads the review panel's export and the sample's strata, and summarises what the review says about timing, the
# recorded labels and the forecast. Pass 1 is the first look at all 50 cases. Pass 2 is the blind repeat of the 12
# marked cases, and the agreement section runs only once Pass 2 rows exist.
#
# Moments are in seconds from the pick marker (picks.frame), on the review panel's frame numbers. A stamp of "none"
# means the moment did not happen in the clip, a blank means it was not recorded. Both are left out of the timing
# quantiles and counted separately.
#
# The component check compares each recorded label with the owner's blind answers, before the label was shown:
#   - switch · the screener's defender takes the handler AND the ball defender takes the screener
#   - over / under · the ball defender's route
#   - show / drop · the screener's defender depth (high fits show, low fits drop, at level fits either)
#   - ice / blitz · the denial (sideline for ice, trap for blitz)
# A conflict is a disagreement between the label and what was seen. It says nothing about the forecast.
#
# Writes to screen_coverage/03_outputs/product_review/:
#   - review_moments.csv · per moment and coverage group, counts and quantiles
#   - review_timing_checks.csv · the counts behind the Phase 4 timing questions
#   - review_choices.csv · every choice by stratum
#   - review_component_check.csv · per case, the label against the blind answers (lists each case's coverage)
#   - review_pass_agreement.csv · Pass 1 against Pass 2, once Pass 2 exists
## ═════════════════════════════════════════════════════════════════════════════

source_root <- function() {
  args <- commandArgs(FALSE)
  script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
}
root <- source_root()
suppressPackageStartupMessages(library(data.table))
rv_dir <- file.path(root, "screen_coverage", "03_outputs", "product_review")
WINDOW_END <- 1
MOMENTS <- c("approach", "execution", "first_evidence", "confirmed", "pressure_start", "pressure_end", "return",
             "exchange", "decision_until", "touch_end", "new_action", "helpful_from")
CHOICES <- c("depth", "route", "sd_takes_h", "bd_takes_s", "pattern", "denial", "offense", "decision", "after_pass",
             "tracking", "roles", "confidence", "label_agrees", "misleading", "usefulness")





## ═════════════════════════════════════════════════════════════════════════════
## 01 - READ THE REVIEW AND THE STRATA ------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

rv <- fread(file.path(rv_dir, "review_cases.csv"), colClasses = "character")
st <- fread(file.path(rv_dir, "review_sample_strata.csv"))
st <- st[, .(screen_id = id, cov, scov, stratum, control, repeat_pass, rescreen, boundary, low_quality)]
rv <- merge(rv, st, by = "screen_id", all.x = TRUE)
stopifnot(!anyNA(rv$stratum))
rv[, pass := as.integer(pass)]
rv[, case := as.integer(case)]

# Coverage group: switch, show (over or under + show), drop, or outside the five (ice, blitz).
rv[, group := fifelse(cov == "switch", "switch",
                      fifelse(stratum == "outside_five", "outside five",
                              fifelse(scov == "show", "show", "drop")))]

p1 <- rv[pass == 1L & stage == "done"]
cat(sprintf("Pass 1 · %d cases done of %d\n", nrow(p1), nrow(rv[pass == 1L])))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - MOMENTS -----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

moments_long <- function(d) {
  rbindlist(lapply(MOMENTS, function(m) {
    raw <- d[[paste0(m, "_t")]]
    d[, .(pass, case, group, stratum, moment = m, raw = raw,
          t = suppressWarnings(as.numeric(raw)), unsure = get(paste0(m, "_unsure")) == "1")]
  }))
}
ml <- moments_long(p1)
ml[, state := fifelse(!is.na(t), "stamped", fifelse(raw == "none", "none", "blank"))]

moment_row <- function(d) {
  s <- d[state == "stamped"]
  q <- function(p) if (nrow(s)) round(quantile(s$t, p, names = FALSE), 2) else NA_real_
  data.table(stamped = nrow(s), unsure = sum(s$unsure), none = sum(d$state == "none"),
             blank = sum(d$state == "blank"), q10 = q(0.1), q25 = q(0.25), median = q(0.5), q75 = q(0.75),
             q90 = q(0.9), after_window_end = sum(s$t > WINDOW_END))
}
mom <- rbind(ml[, moment_row(.SD), by = moment][, group := "all"],
             ml[, moment_row(.SD), by = .(moment, group)])
mom[, moment := factor(moment, MOMENTS)]
setorder(mom, moment, group)
setcolorder(mom, c("moment", "group"))
fwrite(mom, file.path(rv_dir, "review_moments.csv"))
cat("\nMoments, all cases (seconds from the pick marker)\n")
print(mom[group == "all"])





## ═════════════════════════════════════════════════════════════════════════════
## 03 - TIMING CHECKS FOR PHASE 4 -----------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

w <- dcast(ml, case + group + stratum ~ moment, value.var = "t")
count_if <- function(what, n, k) data.table(check = what, n = n, count = k)
chk <- rbind(
  count_if("approach starts before −2 s", sum(!is.na(w$approach)), sum(w$approach < -2, na.rm = TRUE)),
  count_if("first readable sign before the pick marker", sum(!is.na(w$first_evidence)),
           sum(w$first_evidence < 0, na.rm = TRUE)),
  count_if("coverage clear after +1 s", sum(!is.na(w$confirmed)), sum(w$confirmed > WINDOW_END, na.rm = TRUE)),
  count_if("exchange done after +1 s (all cases with an exchange)", sum(!is.na(w$exchange)),
           sum(w$exchange > WINDOW_END, na.rm = TRUE)),
  count_if("exchange done after +1 s (recorded switches)", sum(!is.na(w$exchange) & w$group == "switch"),
           sum(w$exchange > WINDOW_END & w$group == "switch", na.rm = TRUE)),
  count_if("decision open after +1 s", sum(!is.na(w$decision_until)),
           sum(w$decision_until > WINDOW_END, na.rm = TRUE)),
  count_if("decision gone before the first readable sign", sum(!is.na(w$decision_until) & !is.na(w$first_evidence)),
           sum(w$decision_until < w$first_evidence, na.rm = TRUE)),
  count_if("decision gone before the coverage is clear", sum(!is.na(w$decision_until) & !is.na(w$confirmed)),
           sum(w$decision_until < w$confirmed, na.rm = TRUE)),
  count_if("forecast helpful at all (stamped)", nrow(w), sum(!is.na(w$helpful_from))),
  count_if("forecast helpful before the decision closed", sum(!is.na(w$helpful_from) & !is.na(w$decision_until)),
           sum(w$helpful_from < w$decision_until, na.rm = TRUE)),
  count_if("forecast helpful by the first readable sign", sum(!is.na(w$helpful_from) & !is.na(w$first_evidence)),
           sum(w$helpful_from <= w$first_evidence, na.rm = TRUE)),
  count_if("handler's touch ends before +1 s", sum(!is.na(w$touch_end)), sum(w$touch_end < WINDOW_END, na.rm = TRUE)),
  count_if("handler's touch ends before +2 s", sum(!is.na(w$touch_end)), sum(w$touch_end < 2, na.rm = TRUE)),
  count_if("new action before +1 s", sum(!is.na(w$new_action)), sum(w$new_action < WINDOW_END, na.rm = TRUE)),
  count_if("new action before +2 s", sum(!is.na(w$new_action)), sum(w$new_action < 2, na.rm = TRUE)),
  count_if("new action before +2 s (re-screen cases)", sum(!is.na(w$new_action) & w$case %in% p1[rescreen == TRUE, case]),
           sum(w$new_action < 2 & w$case %in% p1[rescreen == TRUE, case], na.rm = TRUE))
)
fwrite(chk, file.path(rv_dir, "review_timing_checks.csv"))
cat("\nTiming checks\n")
print(chk)





## ═════════════════════════════════════════════════════════════════════════════
## 04 - CHOICES BY STRATUM ------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

ch <- rbindlist(lapply(CHOICES, function(k) p1[, .(field = k, option = fifelse(get(k) == "", "(blank)", get(k))),
                                               by = .(case, stratum, group)]))
ch_n <- ch[, .N, by = .(field, group, stratum, option)]
setorder(ch_n, field, group, stratum, option)
fwrite(ch_n, file.path(rv_dir, "review_choices.csv"))





## ═════════════════════════════════════════════════════════════════════════════
## 05 - RECORDED LABEL AGAINST THE BLIND ANSWERS --------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One verdict per part of the label: fits, conflicts or open (an unclear or at-level answer that fits either side).
part_switch <- function(a, b) fifelse(a == "yes" & b == "yes", "fits",
                                      fifelse(a == "no" & b == "no", "conflicts", "open"))
part_route <- function(cov, route) fifelse(route %in% c("over", "under"),
                                           fifelse(route == cov, "fits", "conflicts"), "open")
part_depth <- function(scov, depth) fifelse(depth == "at level" | depth == "unclear", "open",
                                            fifelse((scov == "show" & depth == "high") | (scov == "drop" & depth == "low"),
                                                    "fits", "conflicts"))
cc <- p1[, .(case, stratum, group, cov, scov, depth, route, sd_takes_h, bd_takes_s, denial, label_agrees, repeat_pass)]
cc[group == "switch", `:=`(exchange_part = part_switch(sd_takes_h, bd_takes_s), route_part = NA_character_,
                           depth_part = NA_character_)]
cc[group %in% c("show", "drop"), `:=`(exchange_part = fifelse(sd_takes_h == "yes" & bd_takes_s == "yes", "conflicts", "fits"),
                                      route_part = part_route(cov, route), depth_part = part_depth(scov, depth))]
cc[group == "outside five", `:=`(exchange_part = NA_character_, route_part = NA_character_,
                                 depth_part = fifelse((cov == "ice" & denial == "sideline (ice-like)") |
                                                        (cov == "blitz" & denial == "trap"), "fits", "conflicts"))]
cc[, verdict := fifelse(exchange_part %in% "conflicts" | route_part %in% "conflicts" | depth_part %in% "conflicts",
                        "conflicts",
                        fifelse(exchange_part %in% "open" | route_part %in% "open" | depth_part %in% "open", "open", "fits"))]
fwrite(cc, file.path(rv_dir, "review_component_check.csv"))
cat("\nLabel against the blind answers, by group\n")
print(dcast(cc, group ~ verdict, fun.aggregate = length))
cat("\nWhich part conflicts (show and drop)\n")
print(cc[group %in% c("show", "drop"), .(route = sum(route_part == "conflicts"), depth = sum(depth_part == "conflicts"),
                                          depth_at_level = sum(depth == "at level"),
                                          exchange_seen = sum(exchange_part == "conflicts"), n = .N), by = scov])
cat("\nOwner's after-reveal answer against the component verdict\n")
print(dcast(cc, verdict ~ label_agrees, fun.aggregate = length))





## ═════════════════════════════════════════════════════════════════════════════
## 06 - PASS 1 AGAINST PASS 2 ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

p2 <- rv[pass == 2L & stage %in% c("after", "done")]
if (nrow(p2)) {
  both <- intersect(p1$case, p2$case)
  blind <- setdiff(CHOICES, c("label_agrees", "misleading", "usefulness"))
  agree_choice <- rbindlist(lapply(blind, function(k) {
    a <- p1[match(both, case)][[k]]
    b <- p2[match(both, case)][[k]]
    data.table(item = k, kind = "choice", n = length(both), agree = sum(a == b), median_abs_diff_s = NA_real_)
  }))
  m1 <- moments_long(p1[case %in% both])
  m2 <- moments_long(p2[case %in% both])
  mm <- merge(m1[, .(case, moment, t1 = t)], m2[, .(case, moment, t2 = t)], by = c("case", "moment"))
  agree_moment <- mm[moment != "helpful_from", .(kind = "moment", n = sum(!is.na(t1) & !is.na(t2)),
                                                  agree = sum(abs(t1 - t2) <= 0.2, na.rm = TRUE),
                                                  median_abs_diff_s = round(median(abs(t1 - t2), na.rm = TRUE), 2)),
                     by = .(item = moment)]
  agreement <- rbind(agree_choice, agree_moment)
  fwrite(agreement, file.path(rv_dir, "review_pass_agreement.csv"))
  cat(sprintf("\nPass agreement on %d cases (moments agree within 0.2 s)\n", length(both)))
  print(agreement)
} else {
  cat("\nPass 2 · no finished cases yet, agreement skipped\n")
}
