## ═════════════════════════════════════════════════════════════════════════════
# Step 9: three basketball cues the film study pointed to, built only from information available at the catch.
#   Rscript kickout_transformer/01_scripts/09_cue_features.R
#
# Positions and velocities come from the same token arrays the transformer sees (step 1): offense attacks the hoop
# at (HOOP_X, 0), velocities are backward differences over 0.24 s, and the history tokens give each player's
# position 0.48 s before the catch. Nothing after the catch frame is used. Token 6 is the defender nearest the
# receiver at the catch, used here as the on-ball defender.
#
# Group A, directional space (the closeout and where the receiver could drive)
#   proj_gap      gap to the nearest defender 0.5 s from now if everyone keeps their current velocity (ft); a
#                 defender 18 ft away closing at 12 ft/s projects to about 12 ft
#   lane_best     room in the better of the two driving lanes (ft, capped at 15). Each lane is a segment running
#   lane_worst    toward the hoop, from 3 ft ahead and 3 ft to one side of the receiver to 15 ft ahead and 6 ft to that
#                 side; its room is the distance from the closest of the five defenders to it. Lanes are named
#                 better/worse, not left/right, so a mirrored play gets the same values.
# Group B, pass context (how the ball arrived)
#   return_pass   the receiver passed to this passer and got the ball straight back (passer held it under 2 s): A-B-A
#   passer_hold   seconds the passer held the ball before this pass (capped at 10)
#   since_poss    seconds since his team gained possession (capped at 30)
# Group C, screen setup (is a teammate about to screen the on-ball defender?)
#   For each of the receiver's four teammates: distance to the nearer "shoulder" of the on-ball defender (points
#   2.5 ft either side of him, across the line from him to the receiver), now and 0.48 s ago. Closing speed is how
#   fast that distance shrank. Projected distance in 1 s = now - closing speed x 1 s, floored at 0.
#   scr_dist      the smallest shoulder distance among the four teammates now (ft)
#   scr_proj      the smallest projected shoulder distance in 1 s (ft)
#   The later screen tag (picks on the receiver's touch, step 8) is used only to check these cues, never as input.
#
# Writes kickout_transformer/02_cache/4class/cues.rds and kickout_transformer/03_outputs/timing/screen_cue_check.csv.
## ═════════════════════════════════════════════════════════════════════════════

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))), "R", "common.R"))
root <- kt_root()
paths <- kt_paths(root)
out_dir <- file.path(root, "kickout_transformer", "03_outputs", "timing")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

FPS <- 25
FT_PER_M <- 3.28084
HOOP_X <- (14 - 1.575) * FT_PER_M
TAU <- 0.5            # s ahead for the projected gap
SHOULDER <- 2.5       # ft either side of the on-ball defender
LOOK_BACK <- 12L      # frames (0.48 s) for the screen approach

# Catches with their token arrays and the step-8 timing audit.
d <- readRDS(file.path(paths$base_cache, "catches.rds"))
m <- d$meta
fz <- d$freeze
hs <- d$hist
timing <- readRDS(file.path(paths$base_cache, "timing.rds"))
N <- nrow(m)

# positions now and 0.48 s ago, velocities: [catch, token]
X <- HOOP_X - fz[, , "hoop_dx"]
Y <- fz[, , "y"]
VX <- fz[, , "vx"]
VY <- fz[, , "vy"]
Xp <- X - hs[, , "dx_12"]
Yp <- Y - hs[, , "dy_12"]





## ═════════════════════════════════════════════════════════════════════════════
## 01 - A. DIRECTIONAL SPACE ---------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# Projected gap: the nearest defender's distance to the receiver TAU seconds ahead, everyone at constant velocity.
px <- X + VX * TAU
py <- Y + VY * TAU
proj_gap <- apply(sqrt((px[, 6:10] - px[, 1])^2 + (py[, 6:10] - py[, 1])^2), 1, min)

# Distance from points (qx, qy) to the segment from (ax, ay) to (bx, by).
seg_dist <- function(qx, qy, ax, ay, bx, by) {
  vx <- bx - ax
  vy <- by - ay
  t <- pmin(1, pmax(0, ((qx - ax) * vx + (qy - ay) * vy) / (vx^2 + vy^2)))
  sqrt((qx - ax - t * vx)^2 + (qy - ay - t * vy)^2)
}
# Driving lanes: the receiver's unit direction to the hoop and its normal.
ux <- HOOP_X - X[, 1]
uy <- -Y[, 1]
ul <- sqrt(ux^2 + uy^2)
ux <- ux / ul
uy <- uy / ul
nx <- -uy
ny <- ux
# Each side's lane runs from 3 to 15 ft toward the hoop, widening from 3 to 6 ft off centre; its value is the
# nearest defender's distance to it, capped at 15 ft.
lane <- sapply(c(1, -1), function(s) {
  ax <- X[, 1] + 3 * ux + s * 3 * nx
  ay <- Y[, 1] + 3 * uy + s * 3 * ny
  bx <- X[, 1] + 15 * ux + s * 6 * nx
  by <- Y[, 1] + 15 * uy + s * 6 * ny
  dd <- sapply(6:10, function(j) seg_dist(X[, j], Y[, j], ax, ay, bx, by))
  pmin(15, apply(dd, 1, min))
})
lane_best <- pmax(lane[, 1], lane[, 2])
lane_worst <- pmin(lane[, 1], lane[, 2])





## ═════════════════════════════════════════════════════════════════════════════
## 02 - B. PASS CONTEXT --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

bundle <- function(g) readRDS(file.path(root, "web", "cache", "explore", sprintf("bundle_%d.rds", g)))
# Pass context per catch: a return pass (A-B-A within 2 s), how long the passer held it, and time since the possession
# began.
ctx <- rbindlist(lapply(sort(unique(m$game_id)), function(g) {
  B <- bundle(g)
  c <- m[game_id == g, .(pass_id, game_id, poss_id, pass_start, catch, passer, receiver, pass_touch)]
  c[B$touches, on = .(pass_touch = touch), passer_t0 := i.f0]
  c[B$poss, on = .(poss_id = poss), poss_f0 := i.f0]
  prev <- B$passes[complete == TRUE, .(p_passer = passer, p_receiver = receiver, p_f1 = f1)]
  # the latest earlier pass from this receiver (A) to this passer (B); A-B-A if B sent it back within 2 s
  back <- merge(c[, .(pass_id, passer, receiver, pass_start)], prev,
                by.x = c("passer", "receiver"), by.y = c("p_receiver", "p_passer"), allow.cartesian = TRUE)
  back <- back[p_f1 <= pass_start, .(gap = (pass_start - max(p_f1)) / FPS), by = pass_id]
  c[back, on = "pass_id", gap := i.gap]
  c[, return_pass := !is.na(gap) & gap <= 2]
  # Holds are capped at 10 s and time in the possession at 30 s.
  c[, `:=`(passer_hold = pmin(10, pmax(0, (pass_start - passer_t0) / FPS)),
           since_poss = pmin(30, pmax(0, (catch - poss_f0) / FPS)))]
  c[, .(pass_id, return_pass, passer_hold, since_poss)]
}))
ctx <- ctx[match(m$pass_id, pass_id)]
# 64 passes have no touches row for the passer (the event log starts his touch nowhere): use the median hold
cat("Passes with no passer touch (passer_hold set to the median):", ctx[, sum(is.na(passer_hold))], "\n")
ctx[is.na(passer_hold), passer_hold := median(ctx$passer_hold, na.rm = TRUE)]





## ═════════════════════════════════════════════════════════════════════════════
## 03 - C. SCREEN SETUP --------------------------------------------------------
## ═════════════════════════════════════════════════════════════════════════════

shoulder_dist <- function(X, Y, j) {        # teammate j to the nearer shoulder of token 6, per catch
  ddx <- X[, 1] - X[, 6]
  ddy <- Y[, 1] - Y[, 6]
  l <- pmax(sqrt(ddx^2 + ddy^2), 0.5)
  sx <- -ddy / l * SHOULDER
  sy <- ddx / l * SHOULDER
  pmin(sqrt((X[, j] - X[, 6] - sx)^2 + (Y[, j] - Y[, 6] - sy)^2),
       sqrt((X[, j] - X[, 6] + sx)^2 + (Y[, j] - Y[, 6] + sy)^2))
}
# Screen setup: each teammate's distance to the nearer shoulder of the receiver's defender, now and 0.48 s ago.
now <- sapply(2:5, function(j) shoulder_dist(X, Y, j))
before <- sapply(2:5, function(j) shoulder_dist(Xp, Yp, j))
# Closing speed toward that shoulder, and the distance projected 1 s ahead.
closing <- (before - now) / (LOOK_BACK / FPS)
proj1 <- now - closing * 1
proj1[proj1 < 0] <- 0                                                # (pmax would drop the matrix shape)
# The teammate projected closest to a shoulder is the screen candidate.
best <- max.col(-proj1, ties.method = "first")                      # 1..4 = token 2..5
cand_pid <- d$token_pid[cbind(seq_len(N), best + 1L)]

# Every cue, one row per catch, cached for step 10.
cues <- data.table(pass_id = m$pass_id, row_all = m$row,
                   proj_gap = proj_gap, lane_best = lane_best, lane_worst = lane_worst,
                   return_pass = as.numeric(ctx$return_pass), passer_hold = ctx$passer_hold, since_poss = ctx$since_poss,
                   scr_dist = apply(now, 1, min), scr_proj = proj1[cbind(seq_len(N), best)],
                   scr_cand = cand_pid, scr_cand_now = now[cbind(seq_len(N), best)],
                   scr_cand_closing = closing[cbind(seq_len(N), best)])
saveRDS(list(cues = cues, shoulder_now = now, shoulder_closing = closing, shoulder_proj = proj1),
        file.path(paths$base_cache, "cues.rds"))

cat("Cue summaries (all catches):\n")
print(cues[, lapply(.SD, function(v) round(c(mean = mean(v), p10 = quantile(v, 0.1), p50 = median(v), p90 = quantile(v, 0.9)), 2)),
           .SDcols = c("proj_gap", "lane_best", "lane_worst", "return_pass", "passer_hold", "since_poss", "scr_dist", "scr_proj")])





## ═════════════════════════════════════════════════════════════════════════════
## 04 - DOES THE SCREEN CUE FIND REAL SCREENS? ---------------------------------
## ═════════════════════════════════════════════════════════════════════════════

# AUC of one measure for a two-way split (rank-sum form).
auc <- function(x, g) {
  r <- rank(x)
  n1 <- sum(g)
  n0 <- sum(!g)
  (sum(r[g]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
# Check the screen cue against screens tagged later on the same touch.
v <- merge(cues, timing[, .(pass_id, t_screen, screener, t_first)], by = "pass_id")
v[, screen_3s := !is.na(t_screen) & t_screen <= 3]
v[, screen_1.5s := !is.na(t_screen) & t_screen <= 1.5]
chk <- rbind(v[, .(check = "screen within 1.5 s: AUC of -scr_proj (0.5 = no signal)", value = round(auc(-scr_proj, screen_1.5s), 3), n = sum(screen_1.5s))],
             v[, .(check = "screen within 3 s: AUC of -scr_proj", value = round(auc(-scr_proj, screen_3s), 3), n = sum(screen_3s))],
             v[, .(check = "screen within 3 s: AUC of -scr_dist", value = round(auc(-scr_dist, screen_3s), 3), n = sum(screen_3s))],
             v[screen_3s == TRUE, .(check = "screen within 3 s: tagged screener is the cue's top candidate", value = round(mean(scr_cand == screener), 3), n = .N)],
             v[screen_3s == TRUE, .(check = "  ... chance if picked at random from 4 teammates", value = 0.25, n = .N)],
             v[, .(check = "share of catches with a screen tag within 3 s", value = round(mean(screen_3s), 3), n = .N)],
             v[scr_proj < 3, .(check = "scr_proj < 3 ft: share with a screen tag within 3 s", value = round(mean(screen_3s), 3), n = .N)],
             v[scr_proj >= 3, .(check = "scr_proj >= 3 ft: share with a screen tag within 3 s", value = round(mean(screen_3s), 3), n = .N)])
fwrite(chk, file.path(out_dir, "screen_cue_check.csv"))
cat("\nScreen cue vs the later screen tag:\n")
print(chk)

# worked example: Marcos catch, Fall screens at +2.40 s
ex <- m[pass_id == "pass-188630-1-66", row]
if (length(ex)) {
  cat("\nMarcos catch (pass-188630-1-66), the four teammates (Fall is the tagged screener, id 59165):\n")
  print(data.table(pid = d$token_pid[ex, 2:5], shoulder_now = round(now[ex, ], 1),
                   closing_ft_s = round(closing[ex, ], 1), proj_1s = round(proj1[ex, ], 1)))
}
