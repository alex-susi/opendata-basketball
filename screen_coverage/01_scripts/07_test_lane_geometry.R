## ═════════════════════════════════════════════════════════════════════════════
# Screen coverage, lane experiment: checks of the roll-lane geometry before any fit (added 2026-11-15).
#   Rscript screen_coverage/01_scripts/07_test_lane_geometry.R
#
# Part 1 (hand-made cases, runbook section 2.5) runs the pure helpers in R/lane_geometry.R:
#   - segment (0, 0)-(10, 0), defender (4, 3) -> (4, 2) in 0.2 s: gap 2 ft, projection 0.4, closing +5 ft/s (-5 reversed)
#   - defender at (12, 3): sqrt(13) ft to the rim end, raw projection 1.2
#   - defender standing still while the screener moves: closing 0 (both gaps use the current segment)
#   - the play mirrored (y -> -y), and the off-ball defenders reordered: values agree and follow the player
#   - missing position, missing history, screener on the rim (zero-length segment): not valid, channel values 0, and
#     0 after standardising; a defender exactly on the lane: distance 0, valid
# Part 2 (added for the screening of runbook section 4): pop and drive options on hand-made plays, with mirroring.
# Part 3 (needs 02_build_sequences.R --variant=A and --variant=B): variant A's sequences are identical to the live
# cache, and variant B's first 16 channels are too.
#
# Writes screen_coverage/03_outputs/experiments/lanes/geometry_checks.csv; stops with an error if any check fails.
## ═════════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages(library(data.table))
args <- commandArgs(FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
root <- normalizePath(file.path(dirname(normalizePath(script)), "..", ".."), winslash = "/")
for (f in c("past_only.R", "lane_geometry.R", "lane_variants.R", "seq_transformer.R")) {
  source(file.path(root, "screen_coverage", "01_scripts", "R", f))
}
out_dir <- lane_out_dir(root)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
res <- list()
check <- function(name, ok) res[[length(res) + 1L]] <<- data.table(check = name, pass = isTRUE(ok))
near <- function(a, b) isTRUE(all.equal(a, b, tolerance = 1e-9))





## ═════════════════════════════════════════════════════════════════════════════
## 01 - POINT TO SEGMENT -------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

s <- segment_distances(4, 2, 0, 0, 10, 0)
check("gap 2 ft at projection 0.4", near(s$distance, 2) && near(s$projection, 0.4))
g_now <- segment_distances(4, 2, 0, 0, 10, 0)$distance
g_before <- segment_distances(4, 3, 0, 0, 10, 0)$distance
check("closing +5 ft/s toward the lane", near((g_before - g_now) / 0.2, 5))
check("closing -5 ft/s away from the lane", near((g_now - g_before) / 0.2, -5))
s <- segment_distances(12, 3, 0, 0, 10, 0)
check("beyond the rim: sqrt(13) ft, projection 1.2", near(s$distance, sqrt(13)) && near(s$projection, 1.2))
s <- segment_distances(-3, 4, 0, 0, 10, 0)
check("behind the screener: 5 ft to the start, projection -0.3", near(s$distance, 5) && near(s$projection, -0.3))
s <- segment_distances(5, 0, 0, 0, 10, 0)
check("on the lane: distance 0", near(s$distance, 0))
s <- segment_distances(5, 1, 3, 3, 3, 3)
check("coincident endpoints: NA", is.na(s$distance) && is.na(s$projection))
s <- segment_distances(NA, 1, 0, 0, 10, 0)
check("missing point: NA", is.na(s$distance))





## ═════════════════════════════════════════════════════════════════════════════
## 02 - ROLL LANE ON SMALL SYNTHETIC PLAYS -------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# One stored frame (offset 0) with positions at -10, -5 and 0; the rim is at (HOOP_X, 0), so the screener stands 10 ft
# short of it and the lane runs along y = 0.
POS <- -10:0
k <- function(o) match(o, POS)
play <- function(ns = 1L) {
  list(PX = array(NA_real_, c(ns, length(POS), 10L)), PY = array(NA_real_, c(ns, length(POS), 10L)))
}
fill <- function(pl, s, j, xs, ys) {
  # Same position at every offset unless given per offset (-10, -5, 0).
  for (i in seq_along(POS)) {
    o <- POS[i]
    pl$PX[s, i, j] <- if (length(xs) == 3) xs[match(o, c(-10, -5, 0), nomatch = 3)] else xs
    pl$PY[s, i, j] <- if (length(ys) == 3) ys[match(o, c(-10, -5, 0), nomatch = 3)] else ys
  }
  pl
}
present_of <- function(pl) {
  pr <- !is.na(pl$PX[, k(0), , drop = FALSE]) & !is.na(pl$PX[, k(-5), , drop = FALSE]) & !is.na(pl$PX[, k(-10), , drop = FALSE])
  array(as.numeric(pr), c(dim(pl$PX)[1], 1L, 10L))
}
rl_of <- function(pl) roll_lane_features(pl$PX, pl$PY, present_of(pl), pos_offs = POS, base_offs = 0L, step = 5L)
H0 <- HOOP_X

# Screen 1: defender 8 moves from 3 ft to 2 ft off the lane; 9 moves away; 10 sits beyond the rim.
pl <- play(1L)
pl <- fill(pl, 1, 2, H0 - 10, 0)
pl <- fill(pl, 1, 8, H0 - 6, c(3, 3, 2))
pl <- fill(pl, 1, 9, H0 - 6, c(2, 2, 3))
pl <- fill(pl, 1, 10, H0 + 2, 3)
rl <- rl_of(pl)
check("roll: gap 2, projection 0.4, closing +5", near(rl$distance[1, 1, 8], 2) && near(rl$projection[1, 1, 8], 0.4) &&
        near(rl$closing[1, 1, 8], 5) && rl$valid[1, 1, 8])
check("roll: moving away closes -5", near(rl$closing[1, 1, 9], -5))
check("roll: beyond the rim sqrt(13), projection 1.2", near(rl$distance[1, 1, 10], sqrt(13)) && near(rl$projection[1, 1, 10], 1.2))
check("roll: nearest point is on the lane", near(rl$nearest_x[1, 1, 8], H0 - 6) && near(rl$nearest_y[1, 1, 8], 0))
check("roll: only rows 8-10 carry values", all(is.na(rl$distance[1, 1, 1:7])) && !any(rl$valid[1, 1, 1:7]))

# Screener moves, defender holds: both gaps use the current segment, so closing is 0.
pl2 <- play(1L)
pl2 <- fill(pl2, 1, 2, c(H0 - 20, H0 - 15, H0 - 10), c(8, 4, 0))
pl2 <- fill(pl2, 1, 8, H0 - 6, 4)
rl2 <- rl_of(pl2)
check("roll: defender holds while screener moves -> closing 0", near(rl2$closing[1, 1, 8], 0) && rl2$valid[1, 1, 8])

# Mirror the play (y -> -y) and reorder the off-ball defenders (8, 9, 10) -> (10, 8, 9).
plm <- pl
plm$PY <- -plm$PY
rlm <- rl_of(plm)
check("mirror: distance, closing and projection unchanged",
      near(rlm$distance[1, 1, 8:10], rl$distance[1, 1, 8:10]) && near(rlm$closing[1, 1, 8:10], rl$closing[1, 1, 8:10]) &&
        near(rlm$projection[1, 1, 8:10], rl$projection[1, 1, 8:10]))
plr <- pl
plr$PX[, , 8:10] <- pl$PX[, , c(10, 8, 9)]
plr$PY[, , 8:10] <- pl$PY[, , c(10, 8, 9)]
rlr <- rl_of(plr)
check("reorder: values follow the player", near(rlr$distance[1, 1, 8:10], rl$distance[1, 1, c(10, 8, 9)]) &&
        near(rlr$closing[1, 1, 8:10], rl$closing[1, 1, c(10, 8, 9)]))

# Not valid: defender missing now (8), missing 0.4 s ago (9: not present), screener on the rim (screen 2).
# Valid at 0 ft: defender on the lane (screen 3).
pl3 <- play(3L)
pl3 <- fill(pl3, 1, 2, H0 - 10, 0)
pl3 <- fill(pl3, 1, 8, c(H0 - 6, H0 - 6, NA), 2)
pl3 <- fill(pl3, 1, 9, c(NA, H0 - 6, H0 - 6), 2)
pl3 <- fill(pl3, 2, 2, H0, 0)
pl3 <- fill(pl3, 2, 8, H0 - 6, 2)
pl3 <- fill(pl3, 3, 2, H0 - 10, 0)
pl3 <- fill(pl3, 3, 8, H0 - 5, 0)
rl3 <- rl_of(pl3)
check("invalid: defender missing now", !rl3$valid[1, 1, 8])
check("invalid: defender history missing (not present)", !rl3$valid[1, 1, 9])
check("invalid: screener on the rim (zero-length lane)", !rl3$valid[2, 1, 8])
check("valid at 0 ft: defender on the lane", rl3$valid[3, 1, 8] && near(rl3$distance[3, 1, 8], 0))
ch <- roll_lane_base(rl3, ROLL_FEATS)
check("invalid slots carry 0 in every channel", all(ch[1, 1, 8:9, ] == 0) && all(ch[2, 1, 8, ] == 0))
check("on-lane slot: distance 0 with flag 1", ch[3, 1, 8, "roll_distance_ft"] == 0 && ch[3, 1, 8, "roll_lane_valid"] == 1)

# Standardised: invalid entries 0 for distance and closing whatever the scaling; the flag stays 0/1.
feats <- lane_feats("B")
h <- array(0, c(1L, 10L, 1L, length(feats)))
h[1, , 1, match(ROLL_FEATS, feats)] <- ch[1, 1, , ]
norm <- list(mu = c(rep(0, length(SEQ_FEATS)), 6, 1, 0), sdv = c(rep(1, length(SEQ_FEATS)), 3, 4, 1), feats = feats,
             masked = LANE_MASKED)
z <- as_array(standardise_history(h, norm))
check("standardised: invalid distance and closing are 0", all(z[1, 8:9, 1, match(c("roll_distance_ft", "roll_closing_fps"), feats)] == 0))
h2 <- h
h2[1, 8, 1, match(ROLL_FEATS, feats)] <- c(9, 2, 1)
z2 <- as_array(standardise_history(h2, norm))
check("standardised: valid entries are scaled", near(z2[1, 8, 1, match("roll_distance_ft", feats)], 1) &&
        near(z2[1, 8, 1, match("roll_closing_fps", feats)], 0.25) && z2[1, 8, 1, match("roll_lane_valid", feats)] == 1)
check("standardised without masks = (h - mu) / sdv",
      near(as_array(standardise_history(h2, list(mu = norm$mu, sdv = norm$sdv))),
           as_array((torch_tensor(h2) - torch_tensor(norm$mu)) / torch_tensor(norm$sdv))))





## ═════════════════════════════════════════════════════════════════════════════
## 03 - POP AND DRIVE OPTIONS --------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Pop: the screener 2 ft from the right slot spot (3); the right wing spot (4) is reachable but taken by an attacker;
# the handler 10 ft straight below spot 3, so the pass runs along x = spot 3's x. The handler's defender sits 3 ft off
# the middle of that pass; the screener's defender 4.5 ft from the spot, beyond its end.
sp <- pop_spots()
s3 <- unlist(sp[3, .(x, y)])
s4 <- unlist(sp[4, .(x, y)])
at <- function(v, dx, dy) c(v[1] + dx, v[2] + dy)
pos <- rbind(at(s3, 0, -10), at(s3, 2, 0), at(s3, 3, -5), at(s3, 4, 2), at(s4, 1, 1), c(30, -20), c(5, 20),
             c(HOOP_X - 1, 0), c(HOOP_X - 1, -20), c(5, -20))
px <- matrix(pos[, 1], 1)
py <- matrix(pos[, 2], 1)
po <- pop_option(px, py)
check("pop: spot 3 kept; spot 4 reachable but occupied", isTRUE(po$pop_available) && po$pop_spot == 3L &&
        po$pop_n_reachable == 2L && po$pop_n_occupied == 1L)
check("pop: move 2 ft, catch sqrt(20) ft, pass 3 ft", near(po$pop_move, 2) && near(po$pop_catch, sqrt(20)) && near(po$pop_pass, 3))
pom <- pop_option(px, -py)
check("pop mirrored: same move, catch and pass (spot 2 instead of 3)", pom$pop_spot == 2L && near(pom$pop_move, po$pop_move) &&
        near(pom$pop_catch, po$pop_catch) && near(pom$pop_pass, po$pop_pass))
px2 <- px
px2[1, 3] <- 5
py2 <- py
py2[1, 3] <- -15
check("pop: no defender along the pass -> pass gap capped at 15 ft", near(pop_option(px2, py2)$pop_pass, 15))
px3 <- px
px3[1, 9] <- NA
check("pop: a missing player -> unknown, no candidate", !pop_option(px3, py)$pop_known && !pop_option(px3, py)$pop_available)

# Drive: handler 20 ft straight out from the rim (lane along y = 0), his defender 2 ft off it near him, a helper 4 ft
# off it low on the minus side, the screener 5 ft to the plus side.
dpos <- rbind(c(HOOP_X - 20, 0), c(HOOP_X - 21, 5), c(HOOP_X - 18, 2), c(HOOP_X - 22, 6), c(10, 20), c(10, -20), c(20, 20),
              c(HOOP_X - 5, -4), c(HOOP_X - 10, 12), c(HOOP_X - 2, 20))
dx <- matrix(dpos[, 1], 1)
dy <- matrix(dpos[, 2], 1)
dr <- drive_options(dx, dy)
check("drive: direct lane on-ball gap 2 ft at projection 0.1, help gap 4 ft",
      near(dr$drv_direct_onball, 2) && near(dr$drv_direct_onball_proj, 0.1) && near(dr$drv_direct_help, 4))
wp <- c(HOOP_X - 15, 3)
wm <- c(HOOP_X - 15, -3)
exp_scr_on <- segment_distances(HOOP_X - 18, 2, HOOP_X - 20, 0, wp[1], wp[2])$distance
exp_rej_help <- min(segment_distances(HOOP_X - 5, -4, wm[1], wm[2], HOOP_X, 0)$distance,
                    segment_distances(HOOP_X - 5, -4, HOOP_X - 20, 0, wm[1], wm[2])$distance)
check("drive: screen-side is the screener's (+) side; its on-ball gap uses the first leg",
      isTRUE(dr$drv_screen_valid) && near(dr$drv_side_ft, 5) && near(dr$drv_screen_onball, exp_scr_on))
check("drive: the reject route passes the low helper", isTRUE(dr$drv_reject_valid) && near(dr$drv_reject_help, exp_rej_help) &&
        dr$drv_reject_help < dr$drv_screen_help)
drm <- drive_options(dx, -dy)
check("drive mirrored: identical screen-side and reject gaps",
      near(unlist(drm[, .(drv_direct_onball, drv_direct_help, drv_screen_onball, drv_screen_help, drv_reject_onball, drv_reject_help)]),
           unlist(dr[, .(drv_direct_onball, drv_direct_help, drv_screen_onball, drv_screen_help, drv_reject_onball, drv_reject_help)])))
dy2 <- dy
dy2[1, 2] <- 0.5
dr2 <- drive_options(dx, dy2)
check("drive: screener within 1 ft of the lane line -> routes unknown, direct lane kept",
      !dr2$drv_side_known && !dr2$drv_screen_valid && !dr2$drv_reject_valid && near(dr2$drv_direct_onball, 2))





## ═════════════════════════════════════════════════════════════════════════════
## 04 - VARIANT CACHES AGAINST THE LIVE CACHE ----------------------------------
## ═════════════════════════════════════════════════════════════════════════════

live <- readRDS(file.path(root, "screen_coverage", "02_cache", "sequences.rds"))
for (v in c("A", "B", "C")) {
  path <- file.path(lane_dir(root, v), "sequences.rds")
  if (!file.exists(path)) next
  S <- readRDS(path)
  nf <- length(SEQ_FEATS)
  same_core <- identical(unname(S$base[, , , seq_len(nf)]), unname(live$base)) && identical(S$ctx, live$ctx) &&
    identical(S$roster, live$roster) && identical(S$screen_ids, live$screen_ids) && identical(S$rules, live$rules)
  check(sprintf("variant %s: movement features, context and roster identical to the live cache", v), same_core)
  check(sprintf("variant %s: feature axis as defined", v), identical(S$feats, lane_feats(v)))
  if (v == "A") check("variant A: whole base identical to the live cache", identical(S$base, live$base))
  rm(S)
  gc()
}





## ═════════════════════════════════════════════════════════════════════════════
## 05 - VERDICT ----------------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

R <- rbindlist(res)
fwrite(R, file.path(out_dir, "geometry_checks.csv"))
print(R)
if (!all(R$pass)) stop("LANE GEOMETRY CHECKS FAILED: ", paste(R[pass == FALSE]$check, collapse = "; "))
cat("\nAll", nrow(R), "lane geometry checks passed.\n")
