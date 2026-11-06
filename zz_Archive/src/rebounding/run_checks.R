# Scenario checks the framework requires of the forecasting contract (section 13), on real scenes.
#   Rscript src/rebounding/run_checks.R
# Needs run_flight.R, run_opportunity.R and run_skills.R. Writes outputs/rebounding/checks/scenario_checks.csv.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
load_opportunity_cpp(here, cache)
out_dir <- file.path(report, "checks")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
set.seed(7)

final <- readRDS(file.path(cache, "final_fits.rds"))
flight_all <- readRDS(file.path(cache, "flight_params_all.rds"))
f <- final$release
sample_ids <- sample(seq_along(bundles), 40)
scenes <- Filter(function(s) length(s) > 0L, lapply(sample_ids, function(i) build_scene(bundles[[i]], 0.4, flight_all, launch_rows_all, seed = i)))
probs <- function(sc, fit = f$access_obstruction, acc = f$acc) predict_cr(stack_scenes(list(sc), acc, f$players, TRUE), fit)[1, ]
checks <- list()
add <- function(name, value, pass, detail) checks[[length(checks) + 1L]] <<- data.table(check = name, value = value, pass = pass, detail = detail)

# 1. probabilities are non-negative and sum to one (ten players, two team awards, unresolved)
P <- t(vapply(scenes, probs, numeric(13)))
add("Probabilities non-negative and sum to one", max(abs(rowSums(P) - 1)), min(P) >= 0 && max(abs(rowSums(P) - 1)) < 1e-6,
    sprintf("%d scenes; largest |sum - 1| shown", nrow(P)))

# 2. player order within a side does not matter
perm_err <- max(vapply(scenes, function(sc) {
  o <- c(sample(1:5), sample(6:10))
  s2 <- sc; s2$pl <- sc$pl[o]; s2$O <- sc$O[o, o]; s2$y <- if (sc$y <= 10) match(sc$y, o) else sc$y
  max(abs(probs(s2)[1:10] - probs(sc)[o]))
}, 0))
add("Player order within a side does not change anyone's chance", perm_err, perm_err < 1e-9, "players shuffled within each side")

# 3. a player moved impossibly far away loses direct access
far <- vapply(scenes, function(sc) {
  s2 <- sc; s2$pl <- copy(sc$pl); s2$pl[1, c("x", "y", "vx", "vy") := .(-400, 0, 0, 0)]
  s2$O <- obstruction_cpp(s2$pl$x, s2$pl$y, s2$pl$off, sc$tx, sc$ty, CORRIDOR, CLOSE)
  probs(s2)[1]
}, 0)
add("A player 400 ft away has no collection chance", max(far), max(far) < 1e-3, "largest chance left to the moved player")

# 4. mirrored geometry (y to -y everywhere) gives the same chances
mir <- max(vapply(scenes, function(sc) {
  s2 <- sc; s2$pl <- copy(sc$pl); s2$pl[, c("y", "vy") := .(-y, -vy)]
  s2$by <- -sc$by; s2$ty <- -sc$ty; s2$target <- c(sc$target[1], -sc$target[2])
  max(abs(probs(s2) - probs(sc)))
}, 0))
add("Mirrored court gives the same chances", mir, mir < 1e-9, "every position and path reflected across the long axis")

# 5. switching collection effects on changes no ball path (the no-touch path is locked)
b <- bundles[[sample_ids[1]]]
s_a <- build_scene(b, 0.4, flight_all, launch_rows_all, seed = 11L)
eff <- final$release$effects
pa <- probs(s_a, eff); pb <- probs(s_a)
s_b <- build_scene(b, 0.4, flight_all, launch_rows_all, seed = 11L)
add("Collection effects leave the simulated ball paths unchanged", max(abs(s_a$bx - s_b$bx)) + max(abs(s_a$bz - s_b$bz)),
    identical(s_a$bx, s_b$bx) && identical(s_a$bz, s_b$bz), sprintf("paths identical; chances moved by up to %.3f", max(abs(pa - pb))))

# 6. no future information: the same forecast from a bundle cut at the checkpoint
leak <- max(vapply(sample_ids[1:15], function(i) {
  b <- bundles[[i]]
  t0 <- 0.4
  cut <- b
  cut$ball <- b$ball[t <= t0 + 1e-9]
  cut$players <- b$players[frame <= b$shot$f0 + round(t0 * FPS)]
  s1 <- build_scene(b, t0, flight_all, launch_rows_all, seed = i)
  s2 <- build_scene(cut, t0, flight_all, launch_rows_all, seed = i)
  if (!length(s1) || !length(s2)) return(0)
  max(abs(probs(s1) - probs(s2)))
}, 0))
add("No tracking after the checkpoint enters a forecast", leak, leak < 1e-12, "forecasts from full and truncated tracks compared at release + 0.4 s")

# 7. replaying an unchanged scene reproduces it exactly; Monte Carlo error across seeds
rep_err <- max(vapply(sample_ids[1:10], function(i) {
  a <- probs(build_scene(bundles[[i]], 0.4, flight_all, launch_rows_all, seed = i))
  b2 <- probs(build_scene(bundles[[i]], 0.4, flight_all, launch_rows_all, seed = i))
  max(abs(a - b2))
}, 0))
add("Replaying an unchanged scene gives the same forecast", rep_err, rep_err == 0, "same seed")
mc <- rbindlist(lapply(sample_ids[1:10], function(i) {
  pp <- t(vapply(1:6, function(s) probs(build_scene(bundles[[i]], 0.4, flight_all, launch_rows_all, seed = 1000L * s + i)), numeric(13)))
  data.table(id = i, sd_player = mean(apply(pp[, 1:10], 2, sd)), sd_off = sd(rowSums(pp[, c(1:5, 11)])))
}))
add("Monte Carlo spread across seeds (48 paths), offense share", mean(mc$sd_off), mean(mc$sd_off) < 0.03,
    sprintf("mean sd over seeds: offense share %.3f, a player's chance %.3f", mean(mc$sd_off), mean(mc$sd_player)))

# ---- the late model (run_late.R), on scenes after the ball has been seen reaching the rim -------------------

late_path <- file.path(cache, "late_final.rds")
if (file.exists(late_path)) {
  late <- readRDS(late_path)
  # 8. when the ball reached the rim is read from the track seen so far: cutting the track changes nothing
  cs_all <- lapply(bundles, contact_seen)
  causal <- vapply(seq_along(bundles), function(i) {
    cs <- cs_all[[i]]
    if (is.na(cs[[1]])) return(TRUE)
    isTRUE(all.equal(contact_seen(bundles[[i]], cs[[2]]), cs)) && is.na(contact_seen(bundles[[i]], cs[[2]] - 0.041)[1])
  }, NA)
  add("Late model: the rim time uses no later tracking", sum(!causal), all(causal),
      sprintf("%d misses; the rim time from a track cut where it became known equals the full track's, and is unknown a frame earlier", length(bundles)))
  late_scene <- function(i, after = 0.3) {
    cs <- cs_all[[i]]
    if (is.na(cs[[1]])) return(list())
    sc <- build_scene(bundles[[i]], cs[[2]] + after, flight_all, launch_rows_all, seed = i)
    if (length(sc)) sc$tau <- late_tau(cs[[2]] + after, cs[[1]])
    sc
  }
  lprobs <- function(sc) predict_late(stack_late(list(sc), late$acc_site), late$fit)[1, ]
  ls <- Filter(function(s) length(s) > 0L, lapply(sample_ids, late_scene))
  LP <- t(vapply(ls, lprobs, numeric(13)))
  add("Late model: probabilities non-negative and sum to one", max(abs(rowSums(LP) - 1)),
      min(LP) >= 0 && max(abs(rowSums(LP) - 1)) < 1e-6, sprintf("%d scenes 0.3 s after the rim time is known", nrow(LP)))
  lperm <- max(vapply(ls, function(sc) {
    o <- c(sample(1:5), sample(6:10))
    s2 <- sc; s2$pl <- sc$pl[o]; s2$O <- sc$O[o, o]; s2$y <- if (sc$y <= 10) match(sc$y, o) else sc$y
    max(abs(lprobs(s2)[1:10] - lprobs(sc)[o]))
  }, 0))
  add("Late model: player order within a side does not change anyone's chance", lperm, lperm < 1e-9, "players shuffled within each side")
  lfar <- vapply(ls, function(sc) {
    s2 <- sc; s2$pl <- copy(sc$pl); s2$pl[1, c("x", "y", "vx", "vy") := .(-400, 0, 0, 0)]
    s2$O <- obstruction_cpp(s2$pl$x, s2$pl$y, s2$pl$off, sc$tx, sc$ty, CORRIDOR, CLOSE)
    lprobs(s2)[1]
  }, 0)
  add("Late model: a player 400 ft away has no collection chance", max(lfar), max(lfar) < 1e-3, "largest chance left to the moved player")
  lleak <- max(vapply(sample_ids[1:15], function(i) {
    cs <- cs_all[[i]]
    if (is.na(cs[[1]])) return(0)
    t0 <- cs[[2]] + 0.3
    b <- bundles[[i]]
    cut <- b
    cut$ball <- b$ball[t <= t0 + 1e-9]
    cut$players <- b$players[frame <= b$shot$f0 + round(t0 * FPS)]
    s1 <- build_scene(b, t0, flight_all, launch_rows_all, seed = i)
    s2 <- build_scene(cut, t0, flight_all, launch_rows_all, seed = i)
    cs2 <- contact_seen(cut, t0)
    if (!length(s1) || !length(s2)) return(0)
    s1$tau <- late_tau(t0, cs[[1]]); s2$tau <- late_tau(t0, cs2[[1]])
    max(abs(lprobs(s1) - lprobs(s2)))
  }, 0))
  add("Late model: no tracking after the checkpoint enters a forecast", lleak, lleak < 1e-12,
      "late forecasts from full and truncated tracks compared 0.3 s after the rim time is known")
}

res <- rbindlist(checks)
fwrite(res, file.path(out_dir, "scenario_checks.csv"))
print(res)
