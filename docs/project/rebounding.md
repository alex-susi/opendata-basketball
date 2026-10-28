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
