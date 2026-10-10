# BUILD SPEC — Defensive Space-Control Surface (SkillCorner ACB tracking)

> **For the Claude Code agent reading this:** this document is the complete brief for an entry to the SkillCorner X PySport Analytics Cup (basketball edition). Build it in the numbered phases in §12. Do not skip the acceptance gate at the end of each phase. Read §2 (repo docs) before writing any loader. Ask the user before: installing system-level toolchains, deleting or overwriting anything under `data/`, or changing any default in §10 that is marked `LOCKED`. Everything else, proceed autonomously.

---

## 1. Goal and scope

Build a **defensive space-control model** from broadcast tracking data and turn it into a validated metric.

**The chain of objects:**
1. A per-frame **space-control surface** — for every point on the offensive half, the probability the defense controls that point, given all ten players' positions and velocities.
2. A **court-value surface** — expected points from each spot on the floor.
3. **Space conceded** — the value-weighted offensive control, integrated over the court, per possession, split to the rim / perimeter and to individual defenders via ground-truth matchups.
4. A **link model** — a hierarchical Bayesian logistic regression proving that defensive control at the shooter's location predicts shot outcome *beyond* nearest-defender distance and contest level. This is the result that makes the metric credible; it is not optional.

**Two deliverables** matching the competition's two tracks:
- Research: the metric + the link-model result + validation.
- Analyst: an animated space-control surface and a per-defender/lineup report a coach can read.

**Non-negotiable constraints:** open-source tools only (R / Stan / Python fine; no Excel/Tableau/PowerBI), MIT or Apache license, must run out of the box, individual work. Package it so it can become an installable tool — that is an explicit judging axis.

---

## 2. Read these first (in the repo)

The repository root is `opendata-basketball/`. Before coding, read:
- `README.md`
- `docs/PRIMER.md` — coordinate system, units, clocks, gotchas.
- `docs/KNOWN_ISSUES.md` — data hazards you must guard against.
- `docs/data_dictionary/README.md` and the per-table pages for: `tracking_data`, `chances`, `possessions`, `shots`, `matchups`, `chance_players`, `passes`, `rebounds`, `touches`, `drives`, `game_data`.
- `docs/aggregates_columns.md` — only if you use the season aggregates as priors (optional, v2).

Then verify the raw tracking format yourself before writing the loader: stream the **first 20 non-empty lines** of one tracking file and confirm the frame schema in §3.2 matches. Do **not** load a whole tracking file into memory.

---

## 3. The data

### 3.1 Files and locations (all relative to repo root)

| Path | What | Notes |
|---|---|---|
| `data/matches.json` | 10 games: ids, teams, scores, season ids | small |
| `data/player_id_aliases.csv` | duplicate player-id → canonical id | **merge before any player join** |
| `data/matches/{gameId}/{gameId}_game_data.json` | rosters, team ids | ~2 KB |
| `data/matches/{gameId}/{gameId}_dynamic_events.json` | one JSON object, 20 keys, each an event array | ~3 MB |
| `data/matches/{gameId}/{gameId}_tracking_data.jsonl` | 25 fps frames, one JSON per line | 150–225 MB uncompressed; may also appear as `.jsonl.gz` — detect the extension and open accordingly (`gzfile()` for `.gz`). Git-LFS tracked; confirm the file is materialized (real size, not a pointer). |
| `data/aggregates/acb_*aggregates_20252026.csv` | season, offense-only roll-ups | optional priors only |

**The 10 gameIds:** `114086, 114099, 114169, 114234, 114243, 178442, 179612, 184439, 188630, 191313`.

### 3.2 Tracking frame schema (one JSON object per line)

Top level: `frameIdx` (int, 25 fps count from video start), `wallClock` (ms), `gameClock` (s remaining in period; 0 = period over), `gameClockStopped` (bool), `period` (int, starts at 1), `shotClock` (s or null), `homePlayers` (list), `awayPlayers` (list), `ball` (object).

Player object: `xyz` ([x, y, z] feet; z always 0 for players), `speed` (ft/s), `jersey` (str), `playerId` (int), `isDetected` (0/1; 0 = extrapolated), `predError` (ft; 90% radius of position error).

Ball object: `xyz` (z is real, can go slightly negative), `speed`, `isDetected` (float 0.0/1.0), `predError`.

**Dead frames:** ~half of all rows have empty `homePlayers`/`awayPlayers` and `ball == {}`, but keep valid clock fields. Skip them for spatial work. Never assume 10 players + a ball on a row — check.

### 3.3 Event tables you will use (essential fields only; see docs for the rest)

- **chances** (finest scoring unit): `id`, `possessionId`, `gameId`, `period`, `startFrame`, `endFrame`, `offTeamId`, `defTeamId`, `startType`, `outcome`, `offPlayerIds[]`, `defPlayerIds[]`, `ptsScored`, `frontcourtFrame`, `transition`, `qualityIndex` (0–5), `usable` (bool, qualityIndex ≥ 3), `endLoc`.
- **possessions**: `id`, `offTeamId`, `startFrame`, `endFrame`, `leftHoop` (bool — TRUE if offense shoots at the left broadcast hoop; **use for orientation**).
- **shots**: `id`, `chanceId`, `possessionId`, `period`, `startFrame` (release), `location` [x,y] at release, `region`, `shooterId`, `offTeamId`, `defTeamId`, `three` (bool), `outcome` (bool = made), `fouled`, `assisted`, `blocked`, `distance` (ft to hoop at release), `contestLevel` (open/light/average/plus/blocked), `contested` (bool), `catchAndShoot`, `releaseTime`, `shotQuality` (0–100, sometimes null), `closestDefId`, `closestDefDist` (ft), `touchId`.
- **matchups** (defensive assignment intervals): `chanceId`, `possessionId`, `period`, `startFrame`, `endFrame`, `defPlayerId`, `offPlayerId`. Multiple rows per chance when assignments switch.
- **chance_players**: `chanceId`, `playerId`, `offense` (bool), `startMatchupId`, `endMatchupId`, `shotLoc`, `rimLoc`, `reboundLoc`, `minutesPlayedBefore`.
- **rebounds** (external check): `rebounderId`, `location`, `defensive` (bool), `rebounded` (bool), `fgReb`, `shotId`, `chanceId`, `frame`.
- **passes** (external check): `passerId`, `receiverId`, `toReceiverId` (**the interceptor, not the target**), `complete` (bool), `turnover` (bool), `passerLoc`, `receiverLoc`, `startFrame`, `endFrame`.
- **game_data**: `homeTeam.teamId`, `homeTeam.players[].playerId`, `awayTeam...` — to map `homePlayers`/`awayPlayers` to offense vs defense via `offTeamId`.

### 3.4 Coordinate system

Feet; origin `(0,0)` at court center. Offensive hoop at **negative x**, defensive at positive x. When a team attacks, its left is **positive y**, right is negative y. Every `location`/`endLoc`/`*Loc` field uses this same system as `tracking_data`. FIBA court is 28 × 15 m (91.86 × 49.21 ft); rims sit ~5.2 ft off each baseline, so hoops are near `(±40.8, 0)` — **calibrate exactly** (§5.2). Region strings (`ra`, `key`, `left corner three`, …) are coarse zone labels; use `location` for geometry, `region` for zone grouping.

### 3.5 Data hazards (from KNOWN_ISSUES — enforce in code)

1. Merge duplicate player ids via `player_id_aliases.csv` before any player-level join.
2. Score teams from `shots` + `free_throws`, never `chances.ptsScored`.
3. `passes.toReceiverId` is the intercepting defender.
4. Filter to `chances.usable == TRUE` for spatial work.
5. `shotQuality` is null on some shots — handle explicitly (drop from the shotQuality-response model, keep for the made/miss model).
6. Frames within a possession, and shots within a game, are heavily correlated — this dictates the CV design (§9). Do not use random row splits.

---

## 4. Repository layout to create

Put **all new code under `project/`** so the dataset stays clean. Structure it package-ready (so it can become the OSS deliverable) but drive it with `targets`.

```
opendata-basketball/
  project/
    _targets.R                 # pipeline DAG
    config.yml                 # all tunable constants (§10)
    R/
      config.R                 # load config.yml into a list
      load.R                   # streaming loaders (§6.1)
      orient.R                 # orientation + hoop calibration (§6.2)
      smooth.R                 # Kalman track smoothing (§6.3)
      assign.R                 # frame→chance, off/def, matchup lookup (§6.4)
      influence.R              # influence field + control surface (§6.5)
      value.R                  # court-value surface (§6.6)
      metric.R                 # space conceded + defender attribution (§6.7)
      linkdata.R               # shot-level modeling frame (§6.8)
      fit.R                    # cmdstanr wrapper + loo (§6.9)
      validate.R               # CV, external checks, reliability (§9)
      viz.R                    # ggplot / gganimate surfaces (§6.10)
      utils.R
    stan/
      space_link.stan          # §8, full model provided
    tests/
      testthat/                # unit + acceptance tests (§11)
    analysis/
      report.qmd               # final write-up (Quarto)
    renv.lock                  # created by renv::snapshot()
    README.md
    LICENSE                    # MIT
```

---

## 5. Coding conventions (follow exactly)

- **R is the primary language** (`dplyr`/`tidyr` for wrangling, `data.table` where speed matters, `ggplot2` for plots). Bayesian models in **Stan via `cmdstanr`**. Python only if a specific step is clearly better there.
- **Spaces around every binary operator**: `options = {"disp": False}`, `a <- b + c`, not `a<-b+c`.
- **No line may end in an opening parenthesis, and no line may begin with a closing parenthesis.** When a call spans lines, put the first argument on the same line as `(` and align following arguments under it:

  ```r
  hp_ranges <- cars %>%
    filter(!is.na(horsepower)) %>%
    group_by(cylinders_factor) %>%
    summarise(hp_min = min(horsepower),
              hp_max = max(horsepower),
              .groups = "drop")
  ```

- `snake_case` for objects and functions; explicit `package::function()` for anything non-base that is used once.
- Every function gets a roxygen-style header (`@param`, `@return`). Pure functions where possible; side effects (writing files, plots) isolated in `targets` and `viz.R`.
- Reproducibility: `renv` for packages, `targets` for the DAG, a fixed RNG seed in `config.yml`. No absolute paths in code — resolve everything from repo root via `here::here()`.
- Prose in the README and report follows plain-English rules: short words, active voice, cut anything that can be cut.

---

## 6. Module specifications

Each function below lists its contract. Implement to the signature; the agent chooses internal detail unless an algorithm is specified.

### 6.1 `load.R`

- `load_matches()` → tibble of the 10 games from `data/matches.json`.
- `load_aliases()` → tibble; helper `canonicalize_ids(df, id_cols)` remaps any player-id column via the alias table.
- `load_game_data(game_id)` → list with `home_team_id`, `away_team_id`, and a `players` tibble (`player_id`, `team_id`, `jersey`, `name`).
- `load_events(game_id, table)` → tibble for one of the 20 dynamic-event families (parse the single JSON object, pull the keyed array, `canonicalize_ids`). Cache per (game, table).
- `stream_tracking(game_id, frames = NULL, keep_dead = FALSE)` → tibble of frames, **streamed** (read line-by-line with `jsonlite::stream_in` on a `file()`/`gzfile()` connection, or `arrow`), never `readLines` the whole file. If `frames` is a set of frame indices, return only those (for event-frame reduction). Explode into long form: one row per (frame, player) with `team = home/away`, `player_id`, `x`, `y`, `speed`, `is_detected`, `pred_error`; plus a separate ball tibble. Drop dead frames unless `keep_dead`.

Acceptance: for game 114086, `nrow(load_events(114086, "shots"))` ≈ 139; live-frame count is roughly half the total lines.

### 6.2 `orient.R`

- `orient_frames(frames_long, chances, possessions)` — join each frame to its chance by `startFrame ≤ frameIdx ≤ endFrame` (interval join), attach `offTeamId`, `defTeamId`, `leftHoop`. Reflect coordinates so **offense always attacks −x**: when the offense shoots at the right hoop, set `x <- -x` and `y <- -y` (180° rotation preserves handedness). Output frames tagged with `off_team_id`, plus per-player `role = off/def` (from team membership).
- `calibrate_hoop(shots_oriented)` — §5.2: after orientation, fit hoop center `(h_x, h_y)` by least squares so `distance` ≈ `sqrt((x - h_x)^2 + (y - h_y)^2)` over restricted-area / layup shots. Return `(h_x, h_y)` and the median residual.

Acceptance: after orientation, ≥ 99% of **made** shots have shooter `x < 0`; median `|reported distance − computed distance|` < 1.0 ft; hoop residual < 1.5 ft. If these fail, the orientation join is wrong — stop and fix before proceeding.

### 6.3 `smooth.R`

- `smooth_tracks(frames_long)` — per (game, possession, player), fit a **constant-acceleration Kalman filter + RTS smoother** on `(x, y)`. State `[x, vx, ax, y, vy, ay]`. Measurement variance per frame = `pred_error^2 * I` (so extrapolated frames, `is_detected == 0`, get large variance and are pulled less). Process-noise spectral density from `config.yml` (default tuned so the filter follows a hard cut without lag — start `q = 40 ft^2/s^3`, calibrate). Return smoothed `x, y`, smoothed velocity `(vx, vy)`, speed, heading, and the posterior positional variance `pos_var` (used as `predVar` in §6.5). Fallback if a KF is unstable on short segments: Savitzky-Golay (`signal::sgolayfilt`, order 2, window 7) on position, differentiate for velocity.

Acceptance: on detected frames, smoothed speed correlates with raw `speed` at r > 0.9; extrapolated frames carry visibly larger `pos_var`.

### 6.4 `assign.R`

- `players_at_frame(smoothed, frame_idx)` → the 10 players (5 off, 5 def) with position, velocity, `pos_var`, `role`, `player_id`, and distance to ball.
- `matchup_at(matchups, chance_id, frame_idx)` → for each offensive player, the assigned `defPlayerId` active at that frame (pick the interval covering `frame_idx`).
- `event_frames(events)` → the set of frames at which to compute the full surface: all `shots.startFrame`, pass release/reception frames, drive `startFrame`, plus a coarse downsample of live frames at `metric_hz` (default 3) across each usable chance.

Acceptance: at any shot's release frame, exactly 5 offensive and 5 defensive players resolve, and the shooter is on offense.

### 6.5 `influence.R` — control surface

Implement the **Fernández–Bornn player-influence model** as the base.

- `court_grid(config)` → grid over the offensive half: `x ∈ [-46, 0]`, `y ∈ [-25, 25]`, cell size `grid_ft` (default 2). Return cell centers and cell area.
- `player_influence(p, v, pos_var, dist_to_ball, config)` → a bivariate Gaussian:
  - center `mu = p + horizon * v` (`horizon` default 0.5 s),
  - radius `R = radius_min + (radius_max - radius_min) * saturate(dist_to_ball / ball_ref)`, where `saturate(u) = min(u, 1)^ball_pow` (defaults `radius_min = 3`, `radius_max = 10` ft, `ball_ref = 18` ft, `ball_pow = 1`),
  - speed ratio `sr = (speed / s_max)^2` (`s_max` default 23 ft/s),
  - covariance in motion frame `diag(R * (1 + sr), R * (1 - 0.5 * sr))`, rotate by heading, then add `pos_var * I` (tracking-noise inflation),
  - value at `q`: `exp(-0.5 * (q - mu)^T Sigma_inv (q - mu))`.
- `control_surface(players, grid, config)` → for each cell `q`, `pc_def(q) = plogis(b0 + b1 * (sum_def I_i(q) - sum_off I_j(q)))`; return `pc_off = 1 - pc_def` per cell. `b0, b1` from `config` (fit in §9 step 2; default `b0 = 0`, `b1 = 1`). Vectorize over cells (matrix ops); if a single game's event frames are slow, move the inner Gaussian to `Rcpp`.
- `pc_at(surface, loc)` → bilinear-interpolate `pc_off`/`pc_def` at an arbitrary point (used for the shooter's release location).
- **Alternative model** `control_surface_physical(...)` — Spearman time-to-arrive: `tau_i(q)` from position, velocity, reaction time `delta` (0.7 s), `a_max` (13 ft/s²), `v_max` (23 ft/s); control `= plogis(scale * (tau_off_min(q) - tau_def_min(q)))`. Implement behind the same interface so §9 can swap models for a robustness check.

Acceptance (sanity, one game): at the ball-handler's cell, `pc_off > 0.5` on a clear majority of frames; a lone help defender in open space shows a local `pc_def` bump. Produce a static surface plot for one possession and eyeball it.

### 6.6 `value.R` — court-value surface

- `fit_value_surface(shots_oriented, config)` — model `P(make | x, y)` with `mgcv::gam(outcome ~ s(x, y, bs = "tp", k = 60), family = binomial)` (or a Stan GP for full uncertainty in v2). Predict on the grid, multiply by point value (3 where `three == TRUE` for that region else 2) → expected points `v(q)`. Return two surfaces: `v_latent` (unweighted) and `v_realized` (multiplied by a smoothed shot-frequency surface). Default metric uses `v_latent`.

Acceptance: `P(make)` decreases with distance to hoop and peaks at the rim; no wild extrapolation outside the shot support (clamp `k` and inspect `gam.check`).

### 6.7 `metric.R` — space conceded

- `space_conceded_frame(pc_off, value_surface, grid)` → `S = sum_cells pc_off(q) * v(q) * cell_area`. Also `S_rim` (restricted-area cells only) and `S_perimeter`.
- `space_conceded_possession(...)` → mean `S` over the possession's computed frames (or the release-frame value for a shot-specific read).
- `attribute_to_defenders(pc_off, value_surface, players, matchups, grid)` → assign each cell's conceded value to the responsible defender: v1 = the defender whose assigned man (from `matchup_at`) is nearest that cell, or the nearest defender for help space; return conceded value per `defPlayerId`. v2 (if time) = leave-one-defender-out recomputation of the surface (Shapley-style) for principled credit.
- Roll up to per-defender and per-lineup **per-possession** rates; apply hierarchical shrinkage when reporting player values (the link model in §8 already pools defender effects — reuse those posteriors, do not report raw per-defender means as if reliable).

### 6.8 `linkdata.R`

- `build_link_frame(all_games)` → one row per shot with: `made` (int 0/1), `shot_quality` (0–100, may be NA), `pc_def_release` (`pc_at` the shooter's release location on that frame's surface), `closest_def_dist`, `distance` (to hoop), a natural-cubic-spline basis of `distance` (`splines::ns(distance, df = 5)` → matrix `Xspline`), `zone` (grouped `region`), `shooter_id`, `closest_def_id` as `defender`, `contest_level`, `catch_and_shoot`, `game_id`, `possession_id`. Standardize `pc_def_release` and `closest_def_dist` (store the scaling). Integer-index `shooter`, `defender`, `zone` for Stan.

### 6.9 `fit.R`

- `fit_link(link_frame, stan_file = "stan/space_link.stan", ...)` → compile with `cmdstanr::cmdstan_model`, sample (4 chains, 1000 warmup / 1000 draws, `adapt_delta = 0.95`, `max_treedepth = 12`). Return the fit + a tidy summary of `beta_pc`, `beta_cd`, the sigmas, and `loo::loo()` from the `log_lik` matrix.
- `fit_baseline(...)` → same model **without** `pc_def` (drop `beta_pc`) for the incremental-value comparison.
- `compare_models(fit_full, fit_baseline)` → `loo::loo_compare`, but **use grouped LOO** (§9) — pass grouped log-lik or brute-force game refits; report ΔELPD ± SE.

### 6.10 `viz.R`

- `plot_surface(surface, players, ball, value_surface = NULL)` → ggplot heatmap of `pc_off` (diverging fill centered at 0.5), players as points colored by role with velocity arrows, ball marked, hoop marked. Dark-mode-safe palette.
- `animate_possession(game_id, possession_id)` → `gganimate` over the possession's frames; save GIF/MP4 to `analysis/`.
- `plot_defender_report(...)` → ranked per-defender space-conceded with posterior intervals; a small-multiple of each defender's rim vs perimeter split.

---

## 7. Configuration (`config.yml`)

All tunables in one file. Mark which are calibrated vs fixed.

```yaml
seed: 20260916

grid:
  x_min: -46      # LOCKED (offensive half, offense attacks -x)
  x_max: 0        # LOCKED
  y_min: -25
  y_max: 25
  grid_ft: 2

smoothing:
  process_q: 40          # CALIBRATE: KF process-noise spectral density
  sgolay_window: 7
  sgolay_order: 2

influence:                # CALIBRATE all, then LOCK before final outcome test
  horizon_s: 0.5
  radius_min_ft: 3
  radius_max_ft: 10
  ball_ref_ft: 18
  ball_pow: 1
  s_max_fts: 23
  b0: 0
  b1: 1

physical:                 # robustness model
  reaction_s: 0.7
  a_max_fts2: 13
  v_max_fts: 23
  scale: 1

metric:
  metric_hz: 3            # downsample rate for possession integral

value:
  gam_k: 60

fit:
  chains: 4
  warmup: 1000
  draws: 1000
  adapt_delta: 0.95
  max_treedepth: 12
```

---

## 8. Stan model (`stan/space_link.stan`)

Drop in as-is. Non-centered hierarchical logistic; `log_lik` for LOO. For the baseline model, delete the `beta_pc` term and its prior.

```stan
data {
  int<lower=1> N;
  array[N] int<lower=0, upper=1> made;
  int<lower=1> K;
  matrix[N, K] Xspline;
  vector[N] pc_def;
  vector[N] def_dist;
  int<lower=1> n_shooter;
  int<lower=1> n_def;
  int<lower=1> n_zone;
  array[N] int<lower=1, upper=n_shooter> shooter;
  array[N] int<lower=1, upper=n_def> defender;
  array[N] int<lower=1, upper=n_zone> zone;
}
parameters {
  real alpha;
  vector[K] gamma;
  real beta_pc;
  real beta_cd;
  vector[n_shooter] z_shooter;
  vector[n_def] z_def;
  vector[n_zone] z_zone;
  real<lower=0> sigma_shooter;
  real<lower=0> sigma_def;
  real<lower=0> sigma_zone;
}
transformed parameters {
  vector[N] eta = alpha
                + Xspline * gamma
                + beta_pc * pc_def
                + beta_cd * def_dist
                + sigma_shooter * z_shooter[shooter]
                + sigma_def * z_def[defender]
                + sigma_zone * z_zone[zone];
}
model {
  alpha ~ normal(0, 1.5);
  gamma ~ normal(0, 1);
  beta_pc ~ normal(0, 1);
  beta_cd ~ normal(0, 1);
  z_shooter ~ std_normal();
  z_def ~ std_normal();
  z_zone ~ std_normal();
  sigma_shooter ~ normal(0, 1);
  sigma_def ~ normal(0, 1);
  sigma_zone ~ normal(0, 1);
  made ~ bernoulli_logit(eta);
}
generated quantities {
  vector[N] log_lik;
  for (i in 1:N)
    log_lik[i] = bernoulli_logit_lpmf(made[i] | eta[i]);
}
```

The scientific result the pipeline must report: the posterior for `beta_pc` (does its central interval exclude 0, and in the direction that more defensive control → lower make probability), and ΔELPD of the full model over the baseline under grouped LOO. State it as a finding, whichever way it comes out.

---

## 9. Validation protocol

The correlation structure of the data makes naive validation a lie. Enforce:

1. **Grouped cross-validation.** Fold by `possession_id` (all shots of a possession in one fold). Then report the harder number: **leave-one-game-out** — 10 folds, one per `game_id` — which tests whether the metric generalizes to unseen opponents. Report predictive log-loss and AUC on held-out folds.
2. **Tuning/test separation.** Calibrate the `influence:` shape constants (and `b0`, `b1`) on a subset of games against the proxy label in step 5, then **freeze them in `config.yml`** before the final outcome evaluation. Shape constants must never see the shots that judge them.
3. **Bayesian workflow gates:** prior-predictive check (simulated make-rates land in a plausible 0.2–0.7 band); after fitting, all `Rhat < 1.01`, no divergences, bulk-ESS > 400; posterior-predictive check that replicated make-rate by zone and by contest level matches observed within Monte-Carlo error.
4. **Model comparison respecting groups.** PSIS-LOO assumes iid; here use **leave-one-group-out** (game) — either brute-force refit on the 10 game-folds and sum held-out ELPD, or `loo` with an integration over grouped folds. Report ΔELPD ± SE, not a single point estimate.
5. **External validity of the surface** (no direct "control" label, so triangulate — each is a small standalone model):
   - **Rebounds:** control at `rebounds.location` at the rebound frame should predict which team wins the board (`defensive`); target AUC clearly above 0.5.
   - **Passes:** offensive control at the target cell (`receiverLoc`) should predict `complete == TRUE` and lower `turnover`; report the coefficient sign and significance.
   - **Next-event:** higher offensive control should precede a shot/score within the possession.
6. **Reliability.** Split games into halves; correlate each defender's shrunken space-conceded across halves. Report it honestly. State plainly that team/lineup conclusions are firm on 10 games while individual-defender numbers are provisional. Do not overclaim player-level results.
7. **Model-form robustness.** Re-run the headline result with `control_surface_physical` (Spearman) instead of the Gaussian influence model; report that `beta_pc` and ΔELPD are stable across both, or explain the difference.

---

## 10. Compute budget and defaults you must respect

- **Never** load a full tracking file into memory. Stream, and compute the full surface only at `event_frames` (§6.4) — tens of thousands of frames per game, not millions.
- Grid is 2 ft (`grid_ft`), offensive half only (~575 cells). Keep it there unless a phase's acceptance needs finer.
- Vectorize the influence field across cells; profile on one game before scaling to all 10. If a single game's event-frame surface build exceeds ~2 min, move the inner Gaussian to `Rcpp`.
- Cache every expensive step through `targets` keyed by `game_id`, so re-runs are incremental.
- `LOCKED` config values (grid extent, offense-attacks-−x convention) must not change. `CALIBRATE` values are tuned in §9 step 2, then frozen.

---

## 11. Tests (`tests/testthat/`)

Write these alongside the code; a phase is not done until its tests pass.

- `test-load.R`: shot count for 114086 ≈ 139; alias merge collapses the 9 known duplicate players; streaming a tracking file never holds more than one chunk in memory (assert peak object size).
- `test-orient.R`: after orientation, made-shot `x < 0` rate ≥ 0.99 across all 10 games; hoop residual < 1.5 ft; a hand-checked frame flips correctly.
- `test-smooth.R`: smoothed-vs-raw speed correlation > 0.9 on detected frames; extrapolated frames have larger `pos_var`.
- `test-assign.R`: at 20 random shot frames, exactly 5 off + 5 def resolve and the shooter is offensive.
- `test-influence.R`: `control_surface` returns values in [0,1]; sums are finite; a synthetic frame with one defender alone near a cell yields `pc_def > 0.7` there.
- `test-value.R`: `P(make)` monotone-decreasing in distance on a coarse check; grid predictions finite.
- `test-metric.R`: `space_conceded_frame` is non-negative and rises when defenders vacate the paint on a synthetic frame.
- `test-fit.R`: model compiles; on a 1-game subset it samples with `Rhat < 1.05` and returns a `log_lik` matrix of the right shape.

---

## 12. Build phases (do them in order; commit at each gate)

**Phase 0 — Environment.** Create `project/`, `renv::init()`, install packages (`cmdstanr`, `arrow`, `data.table`, `dplyr`, `tidyr`, `jsonlite`, `mgcv`, `splines`, `loo`, `ggplot2`, `gganimate`, `targets`, `here`, `testthat`, `signal`, optionally `Rcpp`), then `cmdstanr::install_cmdstan()`. On Windows confirm the Rtools toolchain. Write `config.yml`, `config.R`, `LICENSE` (MIT), a stub `README.md`, and a smoke script that streams 20 non-empty frames from game 114086 and prints the schema. **Gate:** smoke script prints a valid frame; `cmdstanr` compiles the example model.

**Phase 1 — Loaders (one game, 114086).** Implement `load.R`. **Gate:** `test-load.R` passes; event counts match §6.1.

**Phase 2 — Orientation + hoop calibration.** Implement `orient.R`. **Gate:** `test-orient.R` passes on all 10 games (run the check across games even though later phases stay on one game).

**Phase 3 — Smoothing.** Implement `smooth.R`. **Gate:** `test-smooth.R` passes.

**Phase 4 — Assignment.** Implement `assign.R`. **Gate:** `test-assign.R` passes; `event_frames(114086)` returns a sane count.

**Phase 5 — Control surface (114086).** Implement `influence.R` (Gaussian model first). Produce and save one possession's surface plot. **Gate:** `test-influence.R` passes; the plot passes eyeball sanity (ball-handler owns their space).

**Phase 6 — Value surface.** Implement `value.R`. **Gate:** `test-value.R` passes; `gam.check` clean.

**Phase 7 — Metric (114086).** Implement `metric.R`; produce per-possession and per-defender space-conceded for one game. **Gate:** `test-metric.R` passes.

**Phase 8 — Link model.** Implement `linkdata.R`, `fit.R`, `stan/space_link.stan`. Fit on 114086, then on all 10 games. **Gate:** convergence diagnostics clean; pipeline reports `beta_pc` posterior and ΔELPD vs baseline.

**Phase 9 — Validation, all 10 games.** Implement `validate.R`: possession CV, leave-one-game-out, external checks (rebounds, passes, next-event), split-half reliability, Spearman-model robustness. Calibrate then freeze the `influence:` constants here (§9 step 2). **Gate:** every check in §9 runs and reports; results written to `analysis/`.

**Phase 10 — Deliverables.** `viz.R` animation + defender report; `analysis/report.qmd` (problem, method, the `beta_pc` result, validation, limitations, coaching read); polish `README.md` (install + `targets::tar_make()` one-command run); confirm MIT license and open-source-only stack; `renv::snapshot()`. **Gate:** a fresh clone runs `targets::tar_make()` end-to-end and reproduces the figures and the headline result.

---

## 13. What to ask the user about

Proceed autonomously except: before installing system toolchains (Rtools/CmdStan) if not present; before writing anything into `data/`; before changing a `LOCKED` config value; and if orientation acceptance (Phase 2) fails after a genuine fix attempt — that means an assumption about `leftHoop` or the frame→chance join is wrong and needs a human eye. If the headline `beta_pc` result comes out null, that is a valid finding — report it with the validation, do not tune the model to manufacture significance.

## 14. Reference

Fernández & Bornn, "Wide Open Spaces: A statistical technique for measuring space creation in professional soccer," MIT Sloan Sports Analytics Conference 2018 — https://www.lukebornn.com/papers/fernandez_ssac_2018.pdf. Physical-control variant: Spearman, "Beyond Expected Goals," MIT Sloan SAC 2018. Court-value lineage: Cervone, D'Amour, Bornn, Goldsberry, "A Multiresolution Stochastic Process Model for Predicting Basketball Possession Outcomes," JASA 2016.
