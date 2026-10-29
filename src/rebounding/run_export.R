# Step 5 of the rebounding framework: what the site shows.
#   Rscript src/rebounding/run_export.R [--refit]
# Needs run_flight.R, run_opportunity.R, run_skills.R and run_late.R. Writes:
#   web/public/data/rebounding/{gameId}.json  every eligible miss of a game, forecast every 0.2 s from release
#                                             until the rebound from the observed prefix only (replay mode)
#   web/public/data/rebounding.json           every table the Rebounding tab reads
# Per-game forecasts are cached in outputs/cache/rebounding/site_{gameId}.rds.

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
here <- if (length(script)) dirname(script) else "src/rebounding"
source(file.path(here, "R", "setup.R"))
load_opportunity_cpp(here, cache)
web <- file.path(root, "web", "public", "data")
dir.create(file.path(web, "rebounding"), recursive = TRUE, showWarnings = FALSE)

SITE_STEP <- 0.2      # s between forecasts
SITE_MAX <- 4         # s after release at most
LAND_SHOWN <- 40L     # landing points kept per forecast for the dot view
HEAT <- list(x0 = RIM_X - 36, y0 = -COURT_HALF_W - 4, cell = 1.5, nx = 32L, ny = 39L, bw = 2)   # landing density grid

#' Landing density of a forecast on the HEAT grid: a Gaussian kernel (bandwidth HEAT$bw ft) over every simulated
#' landing, scaled so its peak is 100. Returned as flat (column, row, weight) integer triplets for cells of 3+.
landing_heat <- function(land) {
  if (!nrow(land)) return(integer(0))
  cx <- HEAT$x0 + HEAT$cell * (seq_len(HEAT$nx) - 0.5)
  cy <- HEAT$y0 + HEAT$cell * (seq_len(HEAT$ny) - 0.5)
  kx <- outer(cx, land[, 1], function(a, b) dnorm(a, b, HEAT$bw))
  ky <- outer(cy, land[, 2], function(a, b) dnorm(a, b, HEAT$bw))
  d <- kx %*% t(ky)
  w <- round(100 * d / max(d))
  keep <- which(w >= 3, arr.ind = TRUE)
  as.integer(t(cbind(keep[, 1] - 1L, keep[, 2] - 1L, w[keep])))
}

final <- readRDS(file.path(cache, "final_fits.rds"))
late_path <- file.path(cache, "late_final.rds")
late <- if (file.exists(late_path)) readRDS(late_path) else list(used = FALSE)
flight_all <- readRDS(file.path(cache, "flight_params_all.rds"))
ident <- fread(file.path(report, "skills", "identification.csv"))
talent <- isTRUE(ident[component == "Collection", passes])
box_pairs <- fread(file.path(report, "skills", "boxout_pairs.csv"))
ant_rows <- fread(file.path(report, "skills", "anticipation_rows.csv"))
r3 <- function(v) round(v, 3)

#' Every forecast of one episode in replay mode, with the population model (and the talent-aware one when
#' collection effects passed their identification test).
episode_forecasts <- function(i) {
  b <- bundles[[i]]
  s <- b$shot
  tm <- bundle_times(b)
  t_end <- min(c(tm$rebound, SITE_MAX), na.rm = TRUE)
  t_rim <- rim_time(b) - 0.04
  cs <- contact_seen(b)
  steps <- lapply(seq(0, max(0, t_end - 0.04), by = SITE_STEP), function(t) {
    sc <- build_scene(b, t, flight_all, launch_rows_all, seed = i, landing = TRUE)
    if (!length(sc)) return(NULL)
    # the late model once the ball's arrival at the rim has been seen (when it passed its held-out test);
    # otherwise the release model, then the rim model from the recorded rim time
    late_now <- isTRUE(late$used) && !is.na(cs[[1]]) && t >= cs[[2]] - 1e-9
    f <- final[[if (late_now || t < t_rim - 1e-9) "release" else "rim"]]
    st <- stack_scenes(list(sc), f$acc, f$players, TRUE)
    P <- if (late_now) {
      sc$tau <- late_tau(t, cs[[1]])
      predict_late(stack_late(list(sc), late$acc_site), late$fit)[1, ]
    } else predict_cr(st, f$access_obstruction)[1, ]
    pairs <- which(sc$O >= 0.15, arr.ind = TRUE)
    land <- sc$land[seq_len(min(nrow(sc$land), LAND_SHOWN)), , drop = FALSE]
    out <- list(f = sc$frame, pid = sc$pl$pid, p = r3(P[1:10]),
                team = r3(c(sum(P[1:5]), sum(P[6:10]), P[11], P[12], P[13])),
                land = lapply(seq_len(nrow(land)), function(k) round(land[k, 1:2], 1)),
                heat = landing_heat(sc$land), out = r3(mean(out_of_court(sc$land[, 1], sc$land[, 2]))),
                box = lapply(seq_len(nrow(pairs)), function(k) list(b = sc$pl$pid[pairs[k, 1]], o = sc$pl$pid[pairs[k, 2]],
                                                                    s = r3(sc$O[pairs[k, 1], pairs[k, 2]]))))
    if (talent && !late_now) out$pt <- r3(predict_cr(st, f$effects)[1, 1:10])
    if (late_now) out$tau <- round(t - cs[[1]], 2)
    if (late_now && isTRUE(late$talent))
      out$pt <- r3(predict_late(stack_late(list(sc), late$acc_site, names(late$effects$u)), late$effects)[1, 1:10])
    out
  })
  steps <- Filter(Negate(is.null), steps)
  if (!length(steps)) return(NULL)
  bp <- box_pairs[shot_id == b$id & label != "none"]
  an <- ant_rows[shot_id == b$id]
  list(id = b$id, f0 = s$f0, f1 = s$f1, rf = s$rf, rim = s$f0 + round(rim_time(b) * FPS), shooter = s$pid,
       outcome = s$outcome, rebounder = if (s$grabbed %in% TRUE) s$rpid else NULL, kind = s$kind, range = as.character(s$range),
       steps = steps,
       pairs = lapply(seq_len(nrow(bp)), function(k) list(b = bp$blocker[k], o = bp$opponent[k], label = bp$label[k],
                                                          max = r3(bp$max_obs[k]))),
       anticipation = lapply(seq_len(nrow(an)), function(k) list(pid = an$pid[k], gain = r3(an$v_obs[k] - an$v_ref[k]),
                                                                 team = r3(an$team_obs[k] - an$team_ref[k]),
                                                                 exposure = r3(an$v_ref_sd[k]), moved = round(an$moved_ft[k], 1))))
}

only <- sub("^--game=", "", grep("^--game=", args, value = TRUE))
for (g in if (length(only)) as.integer(only) else games) {
  path <- file.path(cache, sprintf("site_%s.rds", g))
  if (!file.exists(path) || "--refit" %in% args) {
    t0 <- Sys.time()
    eps <- Filter(Negate(is.null), lapply(which(bundle_game == g), episode_forecasts))
    saveRDS(eps, path)
    message(sprintf("Site forecasts %s: %d episodes, %.0f s", g, length(eps), as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }
  # the site describes shots by the EDA's ranges (rim, midrange, three), set here so cached forecasts need no refit
  eps <- lapply(readRDS(path), function(e) {
    s <- episodes[shot_id == e$id]
    e$range <- as.character(shot_range(s$shot_dist, s$three))
    e
  })
  jsonlite::write_json(list(game = g, talent = talent || isTRUE(late$talent), heat = HEAT[c("x0", "y0", "cell", "nx", "ny")], episodes = eps), file.path(web, "rebounding", sprintf("%s.json", g)),
                       auto_unbox = TRUE, digits = NA, null = "null", na = "null")
}

if (length(only)) quit(save = "no")

# ---- the Rebounding tab's tables ----------------------------------------------------------------------------

app <- load_app_data(root)
names_of <- unique(app$roster[, .(canon, name, team_name)], by = "canon")
named <- function(dt) {
  dt <- merge(dt, names_of, by = "canon", all.x = TRUE)
  dt[is.na(name), name := paste("Player", canon)]
  dt
}
tab <- function(dir, file) {
  p <- file.path(report, dir, file)
  if (file.exists(p)) fread(p) else NULL
}
coll <- named(tab("skills", "collection_player.csv"))
antp <- named(tab("skills", "anticipation_player.csv"))
boxp <- named(tab("skills", "boxout_player.csv"))
doc <- list(
  built = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), talent = talent || isTRUE(late$talent),
  episodes = length(bundles), checks = tab("checks", "scenario_checks.csv"),
  eda = { fs <- list.files(file.path(report, "eda"), "[.]csv$"); setNames(lapply(fs, function(f) fread(file.path(report, "eda", f))), sub("[.]csv$", "", fs)) },
  audit = list(counts = tab("audit", "counts.csv"), population = tab("audit", "population.csv"), by_game = tab("audit", "by_game.csv"),
               quality = tab("audit", "tracking_quality.csv"), hoops = tab("audit", "hoop_calibration.csv"),
               gaps = tab("audit", "frame_index_gaps.csv"), timeline = tab("audit", "timeline_by_kind.csv"),
               held = tab("audit", "held_ball_offset.csv")),
  flight = list(params = jsonlite::fromJSON(file.path(report, "flight", "params.json")), summary = tab("flight", "validation_summary.csv"),
                landing = tab("flight", "landing_validation.csv"), folds = tab("flight", "fold_parameters.csv"),
                grid = tab("flight", "contact_grid.csv")),
  collection = list(summary = tab("collection", "validation_summary.csv"), calibration = tab("collection", "calibration_team.csv"),
                    contested = tab("collection", "contested_subsets.csv"), folds = tab("collection", "fold_parameters.csv"),
                    access_grid = tab("collection", "access_grid.csv"), sensitivity = tab("skills", "collection_sensitivity.csv"),
                    recovery = tab("skills", "collection_recovery.csv"),
                    theta = lapply(final, function(f) as.list(f$access_obstruction$theta)),
                    acc = lapply(final, function(f) f$acc),
                    players = coll[checkpoint == "rim" & scenes >= 20][order(-effect)]),
  skills = list(identification = ident, movement = tab("skills", "movement_validation.csv"),
                movement_roles = tab("skills", "movement_by_role.csv"), boxout_labels = tab("skills", "boxout_labels.csv"),
                boxout_validation = tab("skills", "boxout_validation.csv"), variance = tab("skills", "variance_components.csv"),
                anticipation_players = antp[episodes >= 15][order(-effect)],
                boxout_players = boxp[obstructing_scenes >= 15][order(-team_value)]),
  late = if (dir.exists(file.path(report, "late"))) {
    fs <- list.files(file.path(report, "late"), "[.]csv$")
    setNames(lapply(fs, function(f) fread(file.path(report, "late", f))), sub("[.]csv$", "", fs))
  } else NULL)
jsonlite::write_json(doc, file.path(web, "rebounding.json"), auto_unbox = TRUE, digits = 4, dataframe = "rows", null = "null", na = "null")
message("Wrote ", file.path(web, "rebounding.json"))
