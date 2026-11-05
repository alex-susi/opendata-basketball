# Rebounding models: build record

Built 2026-10-27 from "Physics-informed rebounding: research and model framework" (Alex Susi, October 27, 2026).
Status: exploration at the owner's direction. Not the competition entry's question; its link to shot quality is not
established. Results and decisions are in `decision_log.md` (2026-10-27 entry); this file records how the pieces fit,
how to rerun them and how to review the automated labels.

## Pipeline

All code is in `src/rebounding/`. Each script caches per game or fold in `outputs/cache/rebounding/` (git-ignored) and
resumes; `--game=<id>` runs one fold so folds can run as parallel processes. Background shells die after ten minutes.

| Step | Script | Writes |
| --- | --- | --- |
| Raw windows with quality fields | `extract_windows.R` | `raw_{game}.rds`: every shot's tracking window, ball and player `isDetected`, `predError`, speed |
| Audit (framework step 1) | `run_audit.R` | `outputs/rebounding/audit/*.csv`, `episodes.rds` |
| Ball flight (step 2) | `run_flight.R` | `outputs/rebounding/flight/*.csv`, `flight_fold_{game}.rds`, `flight_params_all.rds` |
| Opportunity and collection (steps 2 and 4) | `run_opportunity.R` | `outputs/rebounding/collection/*.csv`, `scenes_{game}.rds`, `opp_fold_{game}.rds` |
| Late forecasts (after the ball reaches the rim) | `run_late.R` | `outputs/rebounding/late/*.csv`, `late_scenes_{game}.rds`, `late_fold_{game}.rds`, `late_final.rds` (the model the site uses after the rim) |
| Behaviour and skills (steps 3 and 4) | `run_skills.R` | `outputs/rebounding/skills/*.csv`, `skills_{game}.rds`, `final_fits.rds` |
| Scenario checks (section 13) | `run_checks.R` | `outputs/rebounding/checks/scenario_checks.csv` |
| Exploratory tables for the Rebounding tab | `run_eda.R` | `outputs/rebounding/eda/*.csv` (each one backs a modelling decision on the tab; shots described as rim / midrange / three by `shot_range()`) |
| Site (step 5) | `run_export.R` | `web/public/data/rebounding/{game}.json` (forecasts every 0.2 s with a landing-density grid), `web/public/data/rebounding.json` (validation and EDA tables) |

Modules: `R/extract.R` (reading), `R/audit.R` (timelines and proxies), `R/late.R` (late forecasts), `R/bundle.R` (episode bundles and the two
coordinate frames), `R/flight.R` (launch prior, filters, scoring), `R/opportunity.R` (scenes, access, competing risks,
benchmarks), `R/skills.R` (anticipation, box-outs, team value). C++ through Rcpp: `cpp/ball.cpp` (flight, contacts,
particle filter, Kalman) and `cpp/opportunity.cpp` (access, competing-risks likelihood with analytic gradient and
OpenMP, obstruction). Rtools must be on PATH; `load_ball_cpp()` adds `C:/rtools44` when it exists.

## Definitions that are easy to get wrong

- **Episode population.** Non-fouled misses with a rebound row and a ball track covering 80% of release-to-rebound
  with no gap over 12 frames. Fouled misses, the 29 misses without a rebound row, and made shots stay in the audit.
- **Two frames.** Ball physics runs relative to each game end's calibrated hoop (where made shots cross rim height);
  ball positions are shifted to the player frame by an amount that grows from zero at 4 ft to the full hoop offset at
  10 ft (`to_player_frame()`).
- **Keyframes.** Ball positions that are the exact midpoint of their neighbours are vendor interpolation and are not
  given to any filter.
- **Checkpoints.** Flight: release, release + 0.32 s, one frame before the inferred contact, contact + 0.2 s.
  Opportunity: release and one frame before the rim (contact, or the shot's end frame when no contact was found).
  Late: 0, 0.2, 0.4, 0.6, 0.8, 1.0 and 1.4 s after the rim time read from the track seen so far (`contact_seen()`),
  while the ball is still loose. The site: every 0.2 s from release until the rebound, with the release model until
  the rim time is known and the late model after it.
- **Outcome.** Twelve classes: ten players, a team award to either side. Scored on which happened, not when: the
  recorded rebound frame sits between the first possible touch and secure control.
- **Box-out labels** are rules on the obstruction series, not reviewed video: established at 0.35, held at 0.25 for
  80% of samples through the rim, lost below 0.10, ambiguous when the pair is closer than their mean `predError`.

## Gated roadmap, Gate 0: event audit and data contract

From "Rebound Probability Modeling: Original Response and Implementation Roadmap" (Part III, Gate 0), run 2026-10-28.
Status **PASS** for the target below; evidence in `outputs/rebounding/gate0/`, decision in `decision_log.md`.

| Step | Script | Writes |
| --- | --- | --- |
| Checks and data contract | `run_gate0.R` (module `R/gate0.R`, thresholds in `GATE0`) | `gate0/*.csv`, `gate_decision.csv`, `event_table.csv` (one row per non-fouled miss), cache `gate0.rds` |
| Review sample and plots | `run_gate0_review.R` | `gate0/review/sample.csv`, `page_*.png`; verdicts by hand in `review_log.csv` |

Run order: `extract_windows.R`, `run_audit.R`, `run_gate0.R`, `run_gate0_review.R`, then `run_gate0.R` again so the
decision reads the review log. About a minute each.

- **Target.** Who is credited with the rebound of a non-fouled missed field goal: ten players or a team award to
  either side (12 classes), conditional on the miss. Free-throw rebounds (55 rows, linked to `free_throws` ids) and
  fouled misses are outside it.
- **Side of a rebound** comes from `rebounds.teamId` against the shot's defence, not from `defensive`: on 14 team
  awards (games 178442 onward) the flag says offence while teamId and the next chance's offence both say defence.
  `event_table.csv` carries both (`side_by_flag`, `side`) and the 12-class `outcome12`.
- **Retained** (703): audit status eligible, minus misses without a rebound row, end-of-period team awards and the 4
  rebound rows at or before their own shot's release (tip sequences: the rebound of the previous miss is linked to
  the tip). `exclusion` gives each reason.
- **Landmarks** for later gates: release, 2 frames before contact, contact + 0.2 s, one frame before the first-touch
  proxy. A landmark without a usable ball (tracked, with a keyframe in the 2 frames up to it) moves back up to 5 frames
  to one that has it, otherwise the forecast abstains there. No contact found means no post-contact landmark.
- **`identity_suspect`**: a player rebound whose credited rebounder is never within 3 ft of the ball from 0.4 s before
  to 1 s after the rebound frame (33 retained). Kept, because the official credit is the target; for sensitivity checks.
- The review was against tracking plots (no video ships with the data, and outside video is not allowed); there is no
  second reviewer. Gate 1's reliability check still needs one.

## Before Gate 1: assumptions of a path-departure detector

`run_gate1_prereq.R` (module `R/gate1_prereq.R`) writes `outputs/rebounding/gate1_prereq/`; it needs `gate0.rds`.
Free flight is fitted from release + 2 frames to 2 frames before the contact proxy (or `endFrame`), one quadratic
per axis on measured frames only, for retained misses and made shots. Results are in `decision_log.md`. What they mean
for a detector:

- Use the curvature the track actually has (median 28.3 ft/s², lower on long flights), fitted per segment, not 32.2.
- Set the departure threshold from the leftover scatter around a fitted arc (sd 0.10–0.28 ft by axis), not from
  `predError` (mean 1.44 ft), which is several times larger.
- Mark interpolated frames as exact midpoints (tolerance about 0.001 ft). The audit's 0.015 ft also catches real
  measurements and makes long false gaps.
- Do not time a touch by a single distance threshold. Shifting the ball to the player frame moves the 2.5 ft crossing
  by up to 3 frames in 43% of misses.
- Find floor contacts where the arcs before and after a bounce meet (`fit_floor()`); the lowest measured frame is a
  median 1.5 ft high.

## Sequential manual (revision 2026-10-29): Steps 00 and 01

"Dynamic Basketball Rebounding Model — Sequential Implementation Manual" (`Rebound_Probability_Model_Step_by_Step_
Implementation_Manual.html`) replaces the earlier gated roadmap. Its Step 01 covers what that roadmap called Gate 0,
so Step 01 reads `gate0.rds` and adds the contract tables and the checks Gate 0 lacked. The manual is written for
Python; this project uses R, and its paths map as follows (also in `src/rebounding/config/experiment.yaml`, `paths`):

| Manual | Here |
| --- | --- |
| `docs/SOURCE_REGISTER.md` | `docs/project/SOURCE_REGISTER.md` (machine list: `src/rebounding/config/sources.yaml`) |
| `configs/experiment.yaml` | `src/rebounding/config/experiment.yaml` (thresholds per step live here too) |
| `requirements.lock` | `src/rebounding/renv.lock` (35 packages, R 4.4.2) |
| `external/` | `external/` (git-ignored; `fetch_sources.R` rebuilds it at the pinned commits) |
| `tests/unit`, `tests/gates/test_step_NN` | `src/rebounding/tests/unit`, `src/rebounding/tests/gates/test_step_NN.R` (testthat) |
| `gate_results/` | `outputs/rebounding/gate_results/` (`NN_*.json` status records, data checksums) |
| `reports/` | `outputs/rebounding/reports/` |
| `data/processed/rebound_episodes.parquet` | `outputs/rebounding/step01/rebound_episodes.csv` |
| `data/processed/tracking_frames.parquet` | `outputs/cache/rebounding/processed/tracking_frames.csv.gz` (git-ignored) |

| Step | Run | Writes |
| --- | --- | --- |
| 00 | `Rscript src/rebounding/run_step00.R [--write-manifest] [--isolated-lib=PATH]` (about 40 s; `--write-manifest` about 25 s more) | `gate_results/00_setup.json`, `00_sources.csv`, `00_packages.csv`, `00_tests.csv`, `data_checksums.csv` |
| 00, clean copy | `Rscript src/rebounding/check_fresh_checkout.R --lib=PATH` (about 40 s; fetches the sources from GitHub) | `gate_results/00_fresh_checkout.json` |
| 01 | `Rscript src/rebounding/run_step01.R` (about a minute; needs `raw_*.rds`, `episodes.rds`, `gate0.rds`) | `step01/*.csv`, `step01/figures/`, `reports/01_join_audit.md`, `gate_results/01_episodes.json` |
| 02 | `Rscript src/rebounding/run_step02.R --phase=calibrate`, `sample`, `label --freeze`, `pages --subset=dev\|heldout`, `score`, `gate` (each under 2 minutes; needs `raw_*.rds`, `episodes.rds` and the Step 01 table) | `step02/` (thresholds, sample, automated labels, review pages and sheets, agreement, heights, figures), `annotations/contact_events.csv`, `reports/02_annotation_reliability.md`, `gate_results/02_contact_states.json`, `02_tests.csv` |
| 03 | `Rscript src/rebounding/run_step03.R` (about 5 minutes; needs `raw_*.rds` and the Step 01 table) | `step03/` (folds, prediction points, baseline predictions, scores, paired comparisons, calibration, leakage checks, `design_freeze.json`), `reports/03_evaluation_design.md`, `gate_results/03_evaluation.json`, `03_tests.csv`; cache `step03_features.rds` |
| 04 | `Rscript src/rebounding/run_step04.R` (about 4 minutes; needs the Step 03 outputs and `step03_features.rds`) | `step04/` (out-of-fold predictions, lambda choices, coefficients, comparisons, calibration, subgroups, checks), `reports/04_static_model.md`, `gate_results/04_static.json`, `04_tests.csv` |
| 05 | `Rscript src/rebounding/run_step05.R` (about 3 minutes; needs the Step 01 table, Step 03 outputs, `step03_features.rds`, `raw_*.rds`) | `step05/` (targets, per-episode scores, coverage, comparisons, selection, figures), `reports/05_spatial_prior.md`, `gate_results/05_spatial.json`, `05_tests.csv`; cache `step05_spatial_prior.rds` (full maps) |
| 06 | `Rscript src/rebounding/run_step06.R` (about 3 minutes; needs `raw_*.rds`, the Step 01 table and Step 03 outputs) | `step06/` (segments, parameters by fold, q selection, forecasts, errors, coverage, innovations, strata, checks), `reports/06_filter_diagnostics.md`, `gate_results/06_ball_filter.json`, `06_tests.csv` |
| 07 | `Rscript src/rebounding/run_step07.R [--reuse-folds]` (about 7 minutes; needs `raw_*.rds`, Step 01, 02, 03 and 06 outputs) | `step07/` (scores, coverage, comparisons, particle diagnostics, stability, examples and figure; `first_run_exact_frames/`), `reports/07_collision_audit.md`, `gate_results/07_postimpact.json`, `07_tests.csv`; cache `step07_folds.rds` |
| 08 | `Rscript src/rebounding/run_step08.R` (about 3 minutes; needs `raw_*.rds`, Step 01, 02 and 03 outputs) | `step08/` (movement forecasts and errors, limits and damping by fold, comparisons, reach margins and sensitivity, checks), `reports/08_reachability.md`, `gate_results/08_reachability.json`, `08_tests.csv` |
| 09 | `Rscript src/rebounding/run_step09.R --fold=k` for k = 1–10 as parallel processes (about 3 minutes each; five at a time took 95 + 177 s), then `Rscript src/rebounding/run_step09.R` (13 s); needs `raw_*.rds` and Step 01, 03–06 and 08 outputs | `step09/` (out-of-fold predictions, scores, C3 comparisons, calibration, stability, degraded ball, subgroups, checks), `reports/09_model_comparison.md`, `gate_results/09_dynamic.json`, `09_tests.csv`; cache `step09_fold_NN.rds` |
| Tests only | `Rscript src/rebounding/run_tests.R unit` / `run_tests.R gates step_01` | console |

A clean package library for `--isolated-lib` / `--lib`: `renv::restore(lockfile = "src/rebounding/renv.lock", library =
PATH)` with Rtools on PATH (13 packages build from source; about 3 minutes).

- **Data provenance.** Each local `*_tracking_data.jsonl` is byte-identical to the upstream `.gz` decompressed (the
  upstream LFS objects are still in `.git/lfs`), and every other `data/` file equals upstream commit `4bbed2e`.
- **Licences.** Six of the ten code sources have no licence; they are read for ideas only (`SOURCE_REGISTER.md`).
  ReboundingPrediction's 3.6 GB of NBA SportVU games are kept out of the checkout (outside data).
- **Orientation** has two independent checks: the ball comes nearer the attacked hoop than the other one (100% at both
  ends), and the tracked shooter sits on `-shots.location` (median 0 ft). Ball position at `shots.endFrame` is not a
  valid check, because for blocked shots, heaves and some long shots endFrame is not the ball's arrival.

## Sequential manual, Step 02: contact states (BLOCKED)

Labels from `R/contact_states.R` for all 703 eligible misses, reviewed against a held-aside subset; results in
`outputs/rebounding/reports/02_annotation_reliability.md`. **No label type passed**, so Steps 03–09 use the final
credited rebounder only, and tip, controlled-catch and securing models stay blocked. What a later step must keep:

- **Order of the phases matters.** The held-aside pages may be drawn only after `label --freeze`; `score` and `gate`
  refuse to run if `contact_states.R` or `auto_summary.csv` differ from the checksums in `step02/detector_freeze.json`.
  Changing the labeler means a new version, a new held-aside subset and a new freeze.
- **Second reviewer.** `step02/review/reviewer2_heldout.csv` is blank. Fill it from the `heldout_*.png` pages with the
  rubric (`docs/project/ANNOTATION_RUBRIC.md`; frames relative to release, players as the page labels them, e.g.
  `D9138`), without looking at `reviewer1_heldout.csv` or the automated labels; then rerun `score` and `gate`, which
  judge the gate on reviewer-to-reviewer agreement.
- **`contact_events.csv`** holds the automated rows (`labeler = auto_v1`, `gate_status` per type), reviewer 1's
  held-aside rows and the official rebound frame. None is a landing point.
- **Ball heights** near the rim read 1–2.5 ft high, and control is capped at 9 ft by the labeler's own rule.

## Sequential manual, Step 03: evaluation harness (PASS)

Modules `R/folds.R` (leave-one-game-out folds), `R/metrics.R` (validation, per-episode scores, calibration, paired
comparisons, decision rules) and `R/reference_baselines.R` (prediction points, causal features, baselines, leakage
checks); settings and later steps' decision rules in `config/experiment.yaml` (`step03`, which is the manual's
`gate_thresholds.yaml`). What every later model must do to be comparable:

- **Hand in** a long table `model, time_point, episode_id, outcome_id, probability` (outcome ids: the ten players'
  raw ids at release, `team_off`, `team_def`), fitted per outer fold on the other nine games only, and pass
  `check_predictions()`. Score with `score_episodes()` and compare with `paired_comparison()` against
  `step03/reference_baselines.csv.gz` on the same episodes and time point.
- **Information time.** Tracking frames up to t only; ball frame f usable from f + 1 (whether it is measured needs the
  next frame); nominal hoop, never the calibrated hoops (they use the test game's own later made shots). Features
  carry `source_frame`; `assert_information_time()` rejects any later than t.
- **Time points.** `release`, and `rim+s` for s in 0–1.4 s after a causal rim-arrival trigger. A point exists only
  while the ball is loose (before the credited rebound frame). There is no pre-contact point.
- **Confirmatory comparisons** are fixed in the config (C1, C2 for Step 04; C3a, C3b for Step 09). Since config v3, C1
  needs superiority over every baseline and the selected reference, each on its own: call `decide_against()` with
  C1's `references`. The strongest are role prior by range (2.261), nearest to hoop (2.263) and nearest by range
  (2.268) at release.
- **Do not change** the `step03` block or the three modules after a later model has been scored.
  `step03/design_freeze.json` is written once: `run_step03.R` stops if the config, the modules or the Step 01 table
  no longer match it, and the gate fails if rerun predictions differ from the frozen ones. A deliberate change needs a
  decision-log entry, a higher `config_version` and deleting the freeze file by hand.

## Sequential manual, Step 04: static model (PASS; OREB model BLOCKED)

`R/static_geometry.R` (player and episode features), `R/conditional_choice.R` (12-outcome conditional logit),
`R/team_rebound.R` (binary OREB model, constant reference). Results in `outputs/rebounding/reports/04_static_model.md`.

- **Shipped static model:** `static_clogit`, out-of-fold predictions in `step04/static_oof.csv.gz` at release and at
  rim + 0.2 s (Step 09's same-time reference). Release log loss 2.200 against 2.261 for the best baseline.
- **OREB:** the binary model did not beat the constant rate under the frozen rule, so the constant training rate stays
  the OREB reference. The logit's implied P(OREB) did better, but only as an exploratory result.
- `dist_hoop` and `dist_minus_mean` are read together (not separately identified).
- The run stops if Step 03's freeze is not in force.

## Sequential manual, Step 05: spatial prior (BLOCKED)

`R/spatial_prior.R`: release-time maps of the credited rebound location over the attacked half court (1 ft cells).
Results in `outputs/rebounding/reports/05_spatial_prior.md`.

- The target is where the rebound was credited, never where the ball would land untouched. Team awards have no
  location.
- Kernel maps conditioned on shot range and side score best but cover too much at the 50% level, so no kernel map is
  validated. Owner decision 2026-10-31: Step 05 stays BLOCKED; the kernel maps are exploratory inputs only (zone bins
  are calibrated only on average, so they are not a fallback).
- A map for any eligible episode: `readRDS("outputs/cache/rebounding/step05_spatial_prior.rds")$maps[[model]][[episode_id]]`,
  a 46 × 50 matrix (x by y, cell edges from `spatial_grid()`).

## Sequential manual, Step 06: ball filter (PASS_BASELINE)

`R/ball_filter.R` (causal Kalman filter: `predict_state()`, `update_state()`, `run_filter()`, `forecast_state()`,
`baseline_forecasts()`) and `R/ball_noise.R` (r, g and q from training segments). Results in
`outputs/rebounding/reports/06_filter_diagnostics.md`.

- **Use the gravity-only forecast** (`baseline_forecasts()$gravity_only`: last two usable measured frames plus the
  fold's g) for free flight in later steps. The Kalman filter is BLOCKED: less accurate and miscalibrated on held-out
  games. Online uncertainty is not validated, so later steps must not present it as calibrated.
- Ball frames that are exact midpoints of their neighbours are vendor fill, never observations; frame f is usable from
  f + 1. The track's own g is about 28.2 ft/s², not 32.2.

## Sequential manual, Step 07: post-rim forecasts (BLOCKED)

`R/physics.R` (RK4 flight, rim, board and floor contacts) and `R/particle_filter.R` (particle filter, empirical analog
transitions, mixture scoring). Results in `outputs/rebounding/reports/07_collision_audit.md`.

- **Best post-rim forecast: empirical analogs** (`analog_library()`, `analog_forecast()`): far better than gravity-only
  and physics, but its coverage misses the tolerance narrowly, so it is not validated (owner decision 2026-11-05: Step 07
  stays BLOCKED; empirical is an exploratory input to Step 09 only). Physics is BLOCKED by rule
  (no validated contact labels) and fails on the data (miscalibrated, unstable).
- Score targets as the first measured frame 0–2 frames after the nominal time: the vendor's 5-frame measuring cadence
  makes exact frames at multiples of 5 after the trigger unmeasured for most shots.
- The ball track does not sit on FIBA fixtures near the rim (balls measured behind the board face); physics on
  nominal geometry needs that solved first.

## Sequential manual, Step 08: movement and reach (PASS_BASELINE)

`R/player_motion.R` (`causal_velocity()`, `forecast_position()`, limits, damping) and `R/reach.R` (`arrival_time()`,
`height_cost()`, `player_margins()`, `made_crossings()`). Results in `outputs/rebounding/reports/08_reachability.md`.

- **Use the damped-velocity forecast** for player positions (lambda and v_max per fold in
  `step08/limits_and_damping_by_fold.csv`); stationary and constant velocity stay as baselines.
- **Reach margins are exploratory**: interception is not validated (no first-contact labels), the height envelope is
  assumed, and the Step 08 margins use the realised ball path. Step 09 must use forecast ball paths.
- Velocities come from a trailing window (frames up to t), never a centred filter.

## Sequential manual, Step 09: dynamic probabilities (PASS)

`R/particle_integration.R` (particles from the Step 05 map or Step 07 analogs, access features) and `R/dynamic_choice.R`
(particle-mixture conditional logit, `predict_rebound()` replay interface). Results in
`outputs/rebounding/reports/09_model_comparison.md`.

- **Shipped model: dynamic** (`step09/dynamic_oof.csv.gz`), better than the Step 04 static model at release and at
  rim + 0.2 s (C3a, C3b met). Predict with 2,000 particles: with 30, single predictions move too much between particle
  draws (first run kept in `step09/first_run_30_particles/`). Its ball inputs are still exploratory.
- Never build a training episode's particles from models that saw its own game (the analog library would find the
  episode itself).

## Reviewing the automated labels

`outputs/rebounding/audit/review_sample.csv` lists 60 episodes, stratified by kind (rim, backboard, airball,
blocked, putback) and shot range, every game, and some excluded ones. Open each in the play viewer (game and release
frame identify the possession) and fill:

| Column | What to record |
| --- | --- |
| `label_contact` | Frame of first rim or board contact, `none` for an airball, `?` if not visible |
| `label_first_touch` | Frame of the first touch by any player after contact |
| `label_control` | Frame and player id of secure control, or `team` if the ball went out / was awarded |
| `label_dead_ball` | Out of bounds, foul, held ball, period end, or blank |
| `label_boxout` | For the two most important pairs: blocker id, opponent id, and one of none, attempted, maintained, escaped, ambiguous |
| `reviewer_note` | Anything that makes the tracking unreliable here |

Ambiguous is a valid answer. A second reviewer on a subset lets agreement be measured; until then every box-out number
is a spatial obstruction proxy.
