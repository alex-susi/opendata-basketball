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
