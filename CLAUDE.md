# SkillCorner Basketball Analytics Cup 2.0 Repository Guide

## How Claude Code should use this file

Treat this `CLAUDE.md` as the main guide for the local `SkillCorner/opendata-basketball` project. Assume the repository and relevant data have already been downloaded with the upstream directory structure. Resolve paths relative to the directory containing this file. Inspect local files first; do not download the dataset again or rename its directories to fit a new template.

Build an original, reproducible basketball analysis with a clear use for a coach or analyst. The working question concerns how movement creates shot quality; the final question and model should follow the data audit. Keep raw data unchanged, preserve upstream documentation and license notices, and store new analysis code and outputs outside `data/`.

This guide combines project instructions, competition requirements, an updated roadmap, complete upstream documentation, and every delivered aggregate column name. Requirements and data facts come from the linked sources; analysis choices and audit procedures are project guidance. Do not treat candidate models as approved methodology or planned work as completed work.

Reviewed October 10, 2026 against upstream commit `4bbed2e35e8fdd2cf083e8c8b280b3e5381a2c66`. Compare the user's local revision with that snapshot before relying on counts. The review checked all documentation, the aggregate CSVs, match list and alias map, and one sample game's metadata/events. It did not audit every tracking frame or every event in all 10 games.

Read the operational sections before editing code. Use the complete reference appendices to look up a field's type, definition, allowed values, and PBP provenance. Local `docs/` remains the source for future upstream changes; record a discrepancy instead of silently changing the snapshot in this file.

## Navigation

1. [Competition goals and requirements](#competition-goals-and-requirements)
2. [Local repository and data coverage](#local-repository-and-data-coverage)
3. [Coordinates clocks and tracking quality](#coordinates-clocks-and-tracking-quality)
4. [Relational structure and joins](#relational-structure-and-joins)
5. [Shot analysis and feature timing](#shot-analysis-and-feature-timing)
6. [Aggregates and player identity](#aggregates-and-player-identity)
7. [Known issues and conflicting documentation](#known-issues-and-conflicting-documentation)
8. [Required data audit](#required-data-audit)
9. [Project roadmap](#project-roadmap)
10. [Complete upstream reference](#complete-upstream-reference)
11. [Exact aggregate column inventory](#exact-aggregate-column-inventory)
12. [Upstream attribution and license](#upstream-attribution-and-license)

## Competition goals and requirements

Sources: [current edition](https://pysport.org/analytics-cup/editions/analytics-cup2) and [submission portal](https://pretalx.pysport.org/analytics-cup-2/cfp). The basketball theme is shot quality, including positioning, pressure, movement, spacing, and context; other useful questions are allowed.

### Rules from the current edition

Worldwide entry; individuals or pairs; each person registers. Choose one region, with at most one entry per sport there. Finalists present in person; travel costs fall to entrants. Staff of the organizers cannot win prizes or present.

Create substantial new work; disclose licensed reuse. Use only current/prior Analytics Cup data. External data, video, and extra matches disqualify. Reproduce with nonproprietary tools. Work stays open source. Retain ownership; secure employer/university permissions. Organizers retain dataset rights and may promote entries.

Professional conduct, truthful registration, original work, timely submission, and runnable code are required. Organizers may clarify rules through the website/Discord. Finalists may receive extra data under a separate EULA.

| Date | Event |
| --- | --- |
| September 9, 2026 | Opens |
| December 18, 2026 | Entries due |
| January 8, 2027 | Finalists announced |
| February 17, 2027 | Paris final |
| February 24, 2027 | Boston final |

Six finalists per region receive €500/$500 per submission. Winners receive €1,500/$1,500 after completing the agreed open-source deliverable.

### Submission and judging from the portal

| Deliverable | Requirement |
| --- | --- |
| Pitch | Public YouTube video, at most 60 seconds; entrant or teammate presents and voices it |
| Repository | Public GitHub, open-source code, all reproduction resources except competition data; include `LICENSE.md` |
| README | At most 1,000 words and two figures/tables combined; explain results and reproduction |
| Evaluation | Relevance, methodology, originality, communication, and open-source potential: 20% each |
| Portal cutoff | December 19, 2026 at 00:01 UTC, equivalent to December 18 at 7:01 p.m. America/New_York |

Confirm the cutoff before submission. Plan USA/Boston, subject to actual registration and attendance. Internal target: December 17. Check repository/video access and clean-environment reproduction; record confirmation after submission. A winning deliverable may be a Python package or contribution to an existing package; a full package is not required for the initial entry.

Do not use the separate 2025–2026 rules page as this edition's rules. Keep this operational guide out of the limited submission narrative: it is not the competition `README.md`. Do not contact organizers, publish, or submit unless the owner has instructed it.

## Local repository and data coverage

There are three data layers: broadcast-derived tracking, derived Game Intelligence events, and offensive season aggregates. The raw tracking and event bundle cover 10 games. The aggregates cover **293 of the season's 327 games**, not all 327. Missing games are mostly playoffs plus some regular-season games. The 10 sample games belong to the 293-game source set; their events cannot reproduce full-season totals.

The competition page's advertised 327-game coverage conflicts with the delivered repository's 293-game coverage. Use the delivered count for analysis and report the difference. Do not manufacture event-level or tracking records for the other games.

| Local path | Contents and treatment |
| --- | --- |
| `README.md` | Upstream release overview; contains the sample-game list |
| `LICENSE` | Upstream MIT notice; preserve it |
| `docs/PRIMER.md` | Pipeline, units, coordinate conventions, clocks, aggregate construction |
| `docs/KNOWN_ISSUES.md` | Identity, scoring, attempts, direct picks, noisy markings |
| `docs/aggregates_columns.md` | Aggregate metric families, denominators, coverage, nulls |
| `docs/data_dictionary/README.md` | Event catalog, keys, shared regions, provenance |
| `docs/data_dictionary/*.md` | Complete schemas for 20 event families plus metadata and tracking |
| `data/matches.json` | Sample match list, dates, teams, scores, competition/season IDs |
| `data/player_id_aliases.csv` | 18 ID rows mapping 9 duplicated people to canonical IDs |
| `data/aggregates/acb_shotsaggregates_20252026.csv` | 326 rows, 308 columns; 316 distinct raw player IDs |
| `data/aggregates/acb_drivesaggregates_20252026.csv` | 301 rows, 71 columns |
| `data/aggregates/acb_picksaggregates_20252026.csv` | 319 rows, 684 columns |
| `data/matches/{gameId}/{gameId}_game_data.json` | One game metadata object and both rosters |
| `data/matches/{gameId}/{gameId}_dynamic_events.json` | One object containing 20 event arrays |
| `data/matches/{gameId}/{gameId}_tracking_data.jsonl.gz` | Gzip JSON Lines; one frame per line; roughly 30–46 MB per game |

Match IDs: `114243`, `114234`, `114169`, `114099`, `114086`, `178442`, `179612`, `184439`, `188630`, `191313`. Full dates, teams, scores, and match-list fields appear below. Do not assume there are tutorial notebooks or a runnable analysis pipeline: upstream publishes data and documentation.

Tracking is stored with Git LFS. An already-downloaded `.jsonl.gz` must contain actual gzip data, not a small LFS pointer. Only run `git lfs pull` if missing bytes justify it. Read compressed JSONL directly or stream it; do not treat it as one JSON array. Avoid loading and exploding all 10 games into memory before selecting the required frame windows. Empty player arrays and an empty ball object are valid records.

Keep `data/` exclusively for supplied datasets. Suggested additions are `src/`, `notebooks/`, `outputs/`, and `docs/project/` for new work. Put progress, research specification, decision log, and submission checklist in `docs/project/` to keep them separate from upstream documentation. These are proposed additions, not existing upstream files.

## Coordinates clocks and tracking quality

| Quantity | Convention |
| --- | --- |
| Position and distance | Feet; `(0, 0)` at court center |
| Player/ball speed | Feet per second |
| Event attack convention | Offensive hoop at negative x; offensive left at positive y |
| Frame rate | 25 fps; nominal frame step 0.04 seconds |
| Frame origin | Start of game video; event `frame`/`startFrame` match tracking `frameIdx` |
| Video clock | `wallClock` and siblings: elapsed milliseconds, including breaks |
| Game clock | `gameClock` and siblings: seconds remaining in `period`; stops on whistles |
| Shot clock | Seconds remaining; may be null |
| Scheduled tip-off | UTC `game_data.date` equals `matches.json.date_time`; not tracking's time origin |

Join a shot to `(gameId, frameIdx = shots.startFrame)`. Its `startWallClock` should agree with the matched tracking row. Use exact frame identity before approximate clock matching. Repeated stopped game-clock values are not unique join keys. A 1–2-second window means roughly 25–50 frame steps, but compute actual elapsed time and check gaps rather than relying on row count.

The primer describes shared event/tracking coordinates, while the tracking dictionary describes x/y from the camera view and possessions provide `leftHoop`. Before normalizing attacks, compare the shooter position at release with `shots.location` and inspect both attack directions. Apply a rotation/reflection only when the local data needs it; document the transform and avoid flipping already-normalized event coordinates twice. Do not borrow NBA or NFL court dimensions or basket locations without verifying the ACB geometry.

Player z is always zero in this release, so it cannot measure jumping or body pose. Ball z represents height but may be slightly negative from calibration noise. Neither body orientation nor player acceleration is a supplied tracking-object field. Derive acceleration from an explicitly smoothed speed/position series and report units, edge effects, and sensitivity.

About half of frame records are dead time with no spatial objects. About 76–83% of player positions are directly detected; the rest are extrapolated. Player `isDetected` is integer 0/1, ball `isDetected` is float 0.0/1.0. Normalize consistently. `predError` is in feet and describes the radius containing ground truth in about 90% of cases; it is not a supplied standard deviation. Typical all-player means are 1.5–1.9 ft, 95th percentiles 4.9–6.3 ft; extrapolated means 4.4–5.2 ft. Ball calibration is less accurate.

Retain detection/error flags in derived features. Do not interpolate across long missing spans, period breaks, or dead time. Do not count missing coordinates as zero. Differentiate tracked movement from extrapolation and test whether conclusions change on better-quality windows.

## Relational structure and joins

The dynamic-event object has exactly these documented keys: `possessions`, `chances`, `chance_players`, `matchups`, `shots`, `free_throws`, `rebounds`, `turnovers`, `fouls`, `timeouts`, `passes`, `touches`, `dribbles`, `picks`, `handoffs`, `off_ball_screens`, `drives`, `isolations`, `posts`, `closeouts`.

| Join | Relationship and rule |
| --- | --- |
| Metadata → all tables | `game_data.gameId`; retain game in every derived key |
| Possessions → chances | `chances.possessionId` → `possessions.id`; one possession may have several chances |
| Chances → events | `event.chanceId` → `chances.id`; verify foreign keys rather than assuming perfect markings |
| Touches → action/shot | `event.touchId` → `touches.id`; `off_ball_screens.scrTouchId` also identifies the screener's touch |
| Shots → fouls/free throws/rebounds | `shotId` → `shots.id`; free throws also carry `foulId`; optional/null references remain optional |
| Rebounds → next chance | `rebounds.nextChanceId` identifies the ensuing chance |
| Rosters → event players | Flatten home/away rosters to `(gameId, playerId, teamId)`; join contextual actor/defender IDs |
| Matchups → frame/event | Join within game/chance and the recorded start/end interval; check overlaps and endpoint conventions |
| Events → tracking | Use explicit frame and game; intervals require temporal matching, not a join on chance alone |
| Aggregates → identities | Canonicalize raw `player_id` with the alias map while retaining the raw ID |

Event identifiers are contextual strings. Keep event IDs as strings and normalize numeric/string representations of game/player IDs in dedicated cleaned columns. Do not match players by name. A given person has one ID within a game, but can have different IDs across games.

A possession is continuous team control; an offensive rebound creates another chance within that possession. Define the denominator before reporting efficiency. `offPlayerIds`/`defPlayerIds` at possession level may include more than five people because of substitutions. They are not necessarily the simultaneous lineup at a frame. Use chance participation plus tracking/intervals for time-specific lineup questions.

Many events or matchups can belong to one chance or touch. Aggregate or select them with an explicit temporal rule before merging into a one-row-per-shot table. Verify that shot row counts and IDs survive joins without duplication. Closest defender, assigned matchup defender, and actual contesting defender are distinct concepts; do not silently substitute them.

The full schemas preserve `PBP derived` flags where supplied. PBP-derived fields come from official play-by-play; many contextual fields come from tracking models. A flag identifies origin, not the time at which a feature becomes knowable.

## Shot analysis and feature timing

`shots.outcome` supplies made/missed labels. `shots.startFrame` is release, `endFrame` is the later end of the shot. `location`, `distance`, `closestDefDist`, and `closestDefId` refer to release. `releaseTime` is touch-start-to-release in seconds; `dribblesBefore` is available. `three` supplies shot value. Use these existing fields before attempting to redetect every shot from ball trajectories.

`shotQuality` is a vendor score on a 0–100 scale with some nulls. The docs do not establish that dividing by 100 gives a calibrated make probability or disclose its training/features. It can be a clearly labeled reference or descriptive target, but validation against make/miss is necessary before probabilistic interpretation. Predicting the vendor score measures agreement with that score, not independently demonstrated basketball value.

For a model of release-time shot environment, use only context available at/before release. Exclude the outcome, made-dependent `assisted`, later shot/rebound fields, future `bhrOutcomes`/`scrOutcomes`, and `direct` labels that encode later actions. `contestLevel = blocked` and `contested` can encode the eventual block; justify their availability or construct a pre-release contest feature. Use vendor `shotQuality` as a separate comparison, not as an unexplained input to a new make model.

`touches.numDribbles`, `touchTime`, `defenderId` fallback, and outcomes can summarize the whole touch; cut them at release for a release-time model. In particular, the fallback defender may use average proximity over the full touch. Likewise, a detected pick/drive category can depend on a later interval: audit timing before treating it as an earlier decision-time feature.

`catchAndShoot` uses release ≤1.5 seconds or `complexShotType = catchAndShoot`. `contested` groups average/plus/blocked contest levels. Simple and complex shot types differ; event camelCase values and aggregate snake_case suffixes are not interchangeable. The complete enums appear in the appendix.

Define the modeled population separately from official FGA. Raw shot events include fouled misses. A useful make model must state whether it models recorded attempts or box-score-eligible shots; including fouled misses changes the estimand. Keep and-one makes when implementing the documented missed-foul exclusion, and reconcile the documentation conflict below.

## Aggregates and player identity

The three aggregate tables are offense-only, with one row per player-team-season, plus all-team total rows for traded players. Every CSV has five rows with empty `team_id` in this snapshot. Choose per-team rows or a player-total strategy; never sum both for the same player. Canonicalize aliases before comparing players across tables, while preserving team splits and provenance.

Count columns can be combined across disjoint player/team buckets. Recompute rates from their proper numerators/denominators; do not average percentages unweighted. Shot zone splits and combined zone families overlap, so summing all pivot columns double-counts events. Respect `_at_` and `_vs_` bucket denominators. Null conditional rates for zero attempts are not zero performance.

`games_played` measures on-court presence in covered games, not games with an event or official full-season appearances. `possessions_played` counts on-court participation and can exceed five times team possessions because of substitutions; it is not minutes played and should not be forced to reconcile to team totals.

Shots: use the full attempt/make/points family definitions below. `total_points` includes made and-one free throws; it is not always `2 × two_mades + 3 × three_mades`. Drives/picks exclude free-throw points from their `points` metrics and report free throws separately. Do not compare these point denominators as if they were identical.

Picks: aggregate counts use `direct = true`, about 22,080 of 42,156 season pick events. Handler and screener coverage vocabularies differ. Role totals include `none` coverage with no corresponding `_vs_none` bucket. Five documented columns are wholly null in this release; retain that fact rather than inventing observations.

The appendix includes the full metric-family reference and an exact, ordered header inventory for all **1,063 CSV columns**, including repeated identity columns. Do not generate nonexistent columns by taking a Cartesian product of metric names and buckets.

## Known issues and conflicting documentation

The complete upstream issue list appears below. Apply these rules to analysis:

| Issue | Consequence and treatment |
| --- | --- |
| Nine people have duplicate IDs | Use the supplied alias map; retain original IDs and join counts |
| `chances.offTeamId` may mislabel mixed-team scoring | Compute team scores from shot/free-throw rows and their team IDs |
| Season events are not always complete | Published 10-game final scores reconcile, but about 5% of season team-games are 1–5 points short |
| `passes.toReceiverId` | It identifies the intercepting defender, not the intended receiver |
| Assists/rebounds | Tracking attribution may differ from official scorer judgments |
| Noisy markings | 91 self-passes, 38 assisted shots without matching assist opportunity, 29 misses without rebounds, 21 zero-clock chances, 3 reversed chance intervals across the 10 games |
| `closeouts.touchWallClock` | Actually a string; cast safely before arithmetic, despite its table's integer label |
| `chances` key types | Some documented types conflict with observed string possession IDs/integer game IDs; validate actual local values |
| `possessions.outcome` | Documented as list, observed as string in the checked sample; do not blindly explode strings |
| Fouled FGA wording | Known-issues shorthand says exclude `fouled`; primer/aggregate reference say exclude **missed** fouled shots. Preserve and-one makes; verify the intended count locally |
| Spatial wording | Primer's attack-relative convention and tracking's camera-view wording need a frame-level alignment check |
| `chance_players.id` prose | Calls it a touch ID even though this is a participation table; treat it as that table's row ID |

The checked sample game `114243` contains 159 shot events, including 12 fouled misses and 4 fouled makes. This demonstrates why dropping every fouled row loses made baskets. It is a one-game inspection, not a new official statistic or a full-season audit.

Reject or flag reversed intervals before deriving durations. Decide explicitly how to handle zero-duration and unmatched records. Preserve nulls and confidence flags; report losses by reason instead of silently dropping difficult plays. Small known marking errors do not justify abandoning otherwise useful data.

## Required data audit

1. Confirm the 10 expected match folders, their three files, gzip/LFS materialization, metadata IDs, and all 20 dynamic-event keys. Compare local aggregate shape and exact headers with the appendix. Record local revision and file changes.
2. Flatten rosters; check raw/canonical player IDs, uniqueness, optional fields, actual types, foreign-key coverage, and merge cardinality. Validate aliases idempotently: applying the map twice must not change canonical IDs.
3. Reconcile shot/free-throw points with `matches.json` final scores. Define FGA with explicit foul handling. Do not expect the 10 games to reconstruct season aggregates. Validate score effects before discarding anomalous event references.
4. Check frame monotonicity, clock agreement, release-frame joins, court orientation, interval validity, spatial completeness, `isDetected`, `predError`, and chance `qualityIndex`/`usable` (`usable` means quality index ≥3). Treat quality filtering as a documented design choice and report exclusions.
5. Produce an audit table by game and event family, with counts, usable shot windows, quality/missingness, and failed joins. Save it under `outputs/audit/` and record conclusions in `docs/project/data_audit.md` before model fitting.

For outcome models, split by game before learning imputation, scaling, feature selection, or tuning. The 10-game tracking sample limits generalization; report game-wise performance and uncertainty that respects game clustering. Frames are repeated observations within shots and games, not independent make/miss labels. Do not use full-season player outcomes from the same season as a pre-shot skill predictor without a split/time design that prevents leakage.

## Project roadmap

The roadmap below keeps the agreed priority and dates. Data details above supersede the earlier unverified assumptions about release timing, outcomes, and aggregate coverage. Keep NFL and SkillCorner data/models separate; generic utilities and lessons can transfer.

### Purpose and research direction

Starting question: **Does the way a shot develops explain shot quality beyond the court state at release?**

The owner has already built EPAA and a GAM/XGBoost shot model with player effects. This project should use new tracking analysis to answer a question those projects could not answer. Existing modeling experience can guide the work, but NBA data and previously completed analyses do not belong in the competition dataset or submission.

Candidate focus: separation created during the one to two seconds before release and the timing of the defender's contest. Compare a static-context baseline with the same baseline plus a small set of movement-history features. The intended basketball use is to distinguish shots with similar release spacing that developed through different offensive and defensive actions.

Choose one primary question after inspecting event timing and usable tracking coverage. Possible features include shooter speed, defender closing velocity, separation change, help position, spacing, and pick/drive context. They are candidates, not required columns. Prefer one reliable basketball concept over a broad collection of weak features.

### Dates and shared time budget

The owner is also entering NFL Big Data Bowl while working full time and studying part time. Give SkillCorner the larger share through its deadline while preserving weekly NFL progress. Percentages refer to available competition hours; do not assume an hourly commitment.

| Period | SkillCorner | NFL | SkillCorner milestone |
| --- | --- | --- | --- |
| October 8–25, 2026 | 60% | 40% | Audit tracking and write a one-page research specification |
| October 26–November 22, 2026 | 70% | 30% | Complete a baseline, one novel feature concept, and initial validation |
| November 23–December 11, 2026 | 80% | 20% | Freeze scope and finish the analysis |
| December 12–18, 2026 | 95% | 5% | Package and submit; internal target December 17 |
| December 19, 2026–January 5, 2027 | 5% | 95% | Preserve the submission and handle essential follow-up |

If workload threatens both entries, finish SkillCorner and narrow NFL scope. Do not move unfinished SkillCorner research into the NFL refinement period.

### Phase 1 October 8–25

1. Inspect schemas, units, frame timing, event IDs, player identities, attack direction, possession boundaries, and tracking missingness. Use `shots.startFrame` as the documented release frame and audit its alignment with `tracking.frameIdx`.
2. Link shots to tracking and dynamic events in the 10 tracked games. Count usable and excluded shots by game, player, and shot type. Define a release-alignment tolerance and report failed joins.
3. Replay representative possessions and shot windows to check geometry. Confirm the closest defender and whether defender identity changes within the window. Do not confuse a changing minimum distance with the closing speed of one defender.
4. Build only reliable features available at or before release. Check simple relationships between shot location, defensive distance, and outcomes using the supplied `shots.outcome` label. Do not use make/miss-dependent frames or later actions as shot-quality inputs.
5. Write `docs/project/research_spec.md` with the basketball decision, population, outcome, release definition, history window, static baseline, movement concept, splits, and minimum viable result.

Exit condition: a feasible question with audited event alignment and enough usable shots. If supplied make/miss labels or release frames fail the local audit for the selected sample, narrow to a defensible permitted-data analysis of shot creation; do not invent labels or obtain external data.

### Phase 2 October 26–November 22

1. Build a reproducible pipeline from the supplied files to a shot-level analysis table. Cache derived windows and retain raw data unchanged.
2. Establish a simple static baseline using available location, shot value/type, release spacing, and context. Add one movement concept on the same eligible shots and validation folds.
3. Use game-held-out evaluation as the primary check when feasible. With only 10 tracked games, report results by held-out game as well as pooled results. Fit imputation, scaling, feature selection, and tuning within training folds.
4. Evaluate probability models with log loss, Brier score, and calibration; treat AUC as secondary. Quantify the paired improvement of movement features over the baseline with uncertainty that respects game clustering. Player-held-out checks are useful sensitivity analyses when feasible, not a guaranteed design.
5. Produce a minimum viable analysis with an interpretable effect or model comparison, a tracking visual, and a short basketball explanation. Show the result even if movement features provide little improvement.

Exit condition: a complete comparison and a feature definition another analyst can reproduce. Avoid declaring many tracking frames to be independent shot outcomes. Do not treat the 10 tracked games as representative of the full league without evidence.

### Phase 3 November 23–December 11

Freeze the main question by November 23 and finish the analysis by December 11. Spend remaining research time on validation, interpretation, and visuals. Do not start an unrelated model, a broad player leaderboard, or a new dashboard.

Check sensitivity to release alignment, tracking gaps, defender identity, smoothing choices, and the length of the movement window. Separate evidence about the 10 tracked games from any aggregate findings about the 327-game season release. Compare plausible alternative definitions and identify what the data cannot distinguish.

Fit models that suit the shot count and question. A GAM, regularized model, or compact boosting model may be enough. Use hierarchical player effects only if they address a clear sampling problem and the exposure supports them. Keep skill effects distinct from shot environment; do not claim that predicted make probability is shooter-neutral shot quality unless the method supports that interpretation.

Explain associations as associations. Defender movement and offensive spacing reflect choices and game context, so a predictive coefficient or feature attribution does not establish a causal effect. Every numerical claim should trace to a saved result and a defined sample.

Plan two submission visuals: one clear tracking example explaining the metric and one compact results figure or table showing its value and uncertainty. An animation may be useful in the pitch, but verify how the organizers count composite and animated figures before using them to meet the README limit.

### Phase 4 December 12–18

1. Freeze the analysis and target a 900–950-word `README.md`, allowing editing room within the 1,000-word limit. Keep the README to at most two combined figures/tables.
2. Finish the public repository with `LICENSE.md`, all required code, environment/dependency instructions, and a documented way to obtain permitted data. Exclude the competition datasets from the repository. Run the project in a clean environment and reproduce the reported results.
3. Draft `docs/project/pitch_script.md`, then prepare a YouTube pitch lasting at most 60 seconds. The owner or teammate must present and voice it. Allocate roughly 10 seconds to the question, 20 to the method/visual, 20 to the result, and 10 to its basketball use.
4. Check registration, region, attendance feasibility, repository visibility, license, README counts, video access, and the submission form. Publishing and submitting remain owner-directed actions.
5. Complete submission by the internal December 17 target once the owner authorizes submission, then record the confirmation and submitted version. Keep December 18 for genuine corrections permitted by the rules.

Exit condition: a submitted, reproducible entry with working public links and saved confirmation. If the owner has not yet published or submitted, report that status plainly; completed files do not establish submission.

### Phase 5 December 19–January 5 and finalist follow-up

Give NFL almost all competition time. Preserve the SkillCorner entry, handle essential organizer queries, and record any rule changes. Do not start another SkillCorner analysis during the NFL final sprint.

After the January 8 finalist announcement, prepare the Boston presentation if selected. Additional finalist data may arrive under a separate EULA: read its terms and validate the existing method before expanding it. If not selected, retain the reproducible public project and prepare a brief explanation of its findings for the sports analytics community.

### Project files and working method

Use the existing repository layout if present. Keep new implementation in `src/`, exploratory work in `notebooks/`, figures in `outputs/figures/`, and planning records in `docs/project/`; retain upstream `data/` and `docs/` paths. File paths here are proposed destinations, not a claim that those files already exist. Keep SkillCorner data, models, and fitted results separate from NFL; only generic utilities and lessons may transfer.

Maintain `docs/project/progress.md` for the phase, completed deliverables, next action, blockers, and milestone status. Keep `docs/project/research_spec.md` for the fixed question and definitions, `docs/project/decision_log.md` for changes and evidence, and `docs/project/submission_checklist.md` for current rules and final checks. Update these after meaningful work without adding duplicate planning files.

Use the project's existing language and dependency tools. When writing R, keep the function and opening parenthesis on the first line, align subsequent arguments, and close the call at the end of the final argument line. Never put an opening or closing parenthesis on its own line.

At each session, read the progress and decision records, complete the next milestone task, and report the completed work, validation, and unresolved issue. Finish a useful and clear analysis before adding complexity.

## Complete upstream reference

The following 27 source documents are reproduced under the upstream MIT license, retained at the end of this file. They include **all 22 table dictionaries**, every documented field/type/definition and enum, PBP flags where supplied, the primer, all known issues, the aggregate family reference, and the repository overview. `passes`, `handoffs`, and `rebounds` are included even though they were not separately listed in the request.

Source wording is preserved, including upstream inconsistencies identified above. Only heading depth and relative link targets change so this combined document works at the repository root. Do not read an inconsistent dictionary cell as a stronger rule than the audited local schema. These appendices are reference material, not evidence that this project has run any model.

| Source | Local file | Embedded reference |
| --- | --- | --- |
| `README.md` | [README.md](README.md) | [Open](#reference-readme-md) |
| `docs/PRIMER.md` | [docs/PRIMER.md](docs/PRIMER.md) | [Open](#reference-docs-primer-md) |
| `docs/KNOWN_ISSUES.md` | [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | [Open](#reference-docs-known-issues-md) |
| `docs/aggregates_columns.md` | [docs/aggregates_columns.md](docs/aggregates_columns.md) | [Open](#reference-docs-aggregates-columns-md) |
| `docs/data_dictionary/README.md` | [docs/data_dictionary/README.md](docs/data_dictionary/README.md) | [Open](#reference-docs-data-dictionary-readme-md) |
| `docs/data_dictionary/game_data.md` | [docs/data_dictionary/game_data.md](docs/data_dictionary/game_data.md) | [Open](#reference-docs-data-dictionary-game-data-md) |
| `docs/data_dictionary/tracking_data.md` | [docs/data_dictionary/tracking_data.md](docs/data_dictionary/tracking_data.md) | [Open](#reference-docs-data-dictionary-tracking-data-md) |
| `docs/data_dictionary/possessions.md` | [docs/data_dictionary/possessions.md](docs/data_dictionary/possessions.md) | [Open](#reference-docs-data-dictionary-possessions-md) |
| `docs/data_dictionary/chances.md` | [docs/data_dictionary/chances.md](docs/data_dictionary/chances.md) | [Open](#reference-docs-data-dictionary-chances-md) |
| `docs/data_dictionary/chance_players.md` | [docs/data_dictionary/chance_players.md](docs/data_dictionary/chance_players.md) | [Open](#reference-docs-data-dictionary-chance-players-md) |
| `docs/data_dictionary/matchups.md` | [docs/data_dictionary/matchups.md](docs/data_dictionary/matchups.md) | [Open](#reference-docs-data-dictionary-matchups-md) |
| `docs/data_dictionary/shots.md` | [docs/data_dictionary/shots.md](docs/data_dictionary/shots.md) | [Open](#reference-docs-data-dictionary-shots-md) |
| `docs/data_dictionary/free_throws.md` | [docs/data_dictionary/free_throws.md](docs/data_dictionary/free_throws.md) | [Open](#reference-docs-data-dictionary-free-throws-md) |
| `docs/data_dictionary/rebounds.md` | [docs/data_dictionary/rebounds.md](docs/data_dictionary/rebounds.md) | [Open](#reference-docs-data-dictionary-rebounds-md) |
| `docs/data_dictionary/turnovers.md` | [docs/data_dictionary/turnovers.md](docs/data_dictionary/turnovers.md) | [Open](#reference-docs-data-dictionary-turnovers-md) |
| `docs/data_dictionary/fouls.md` | [docs/data_dictionary/fouls.md](docs/data_dictionary/fouls.md) | [Open](#reference-docs-data-dictionary-fouls-md) |
| `docs/data_dictionary/timeouts.md` | [docs/data_dictionary/timeouts.md](docs/data_dictionary/timeouts.md) | [Open](#reference-docs-data-dictionary-timeouts-md) |
| `docs/data_dictionary/passes.md` | [docs/data_dictionary/passes.md](docs/data_dictionary/passes.md) | [Open](#reference-docs-data-dictionary-passes-md) |
| `docs/data_dictionary/touches.md` | [docs/data_dictionary/touches.md](docs/data_dictionary/touches.md) | [Open](#reference-docs-data-dictionary-touches-md) |
| `docs/data_dictionary/dribbles.md` | [docs/data_dictionary/dribbles.md](docs/data_dictionary/dribbles.md) | [Open](#reference-docs-data-dictionary-dribbles-md) |
| `docs/data_dictionary/picks.md` | [docs/data_dictionary/picks.md](docs/data_dictionary/picks.md) | [Open](#reference-docs-data-dictionary-picks-md) |
| `docs/data_dictionary/handoffs.md` | [docs/data_dictionary/handoffs.md](docs/data_dictionary/handoffs.md) | [Open](#reference-docs-data-dictionary-handoffs-md) |
| `docs/data_dictionary/off_ball_screens.md` | [docs/data_dictionary/off_ball_screens.md](docs/data_dictionary/off_ball_screens.md) | [Open](#reference-docs-data-dictionary-off-ball-screens-md) |
| `docs/data_dictionary/drives.md` | [docs/data_dictionary/drives.md](docs/data_dictionary/drives.md) | [Open](#reference-docs-data-dictionary-drives-md) |
| `docs/data_dictionary/isolations.md` | [docs/data_dictionary/isolations.md](docs/data_dictionary/isolations.md) | [Open](#reference-docs-data-dictionary-isolations-md) |
| `docs/data_dictionary/posts.md` | [docs/data_dictionary/posts.md](docs/data_dictionary/posts.md) | [Open](#reference-docs-data-dictionary-posts-md) |
| `docs/data_dictionary/closeouts.md` | [docs/data_dictionary/closeouts.md](docs/data_dictionary/closeouts.md) | [Open](#reference-docs-data-dictionary-closeouts-md) |

### reference-readme-md

Local: [README.md](README.md) · Upstream: [README.md](https://github.com/SkillCorner/opendata-basketball/blob/main/README.md)

#### SkillCorner Open Data — Basketball

##### About this repo

###### Description

This repo contains broadcast tracking data collected by [SkillCorner](https://skillcorner.com) for 10 games of the Spanish Liga ACB 2025-2026 season, the derived Dynamic Events (Game Intelligence) for those same games, and season-level offensive aggregates (shots, drives, picks) for 293 ACB 2025-2026 games.

Broadcast tracking data is tracking data collected through computer vision and machine learning out of the broadcast video, with no on-court hardware and no dependency on a venue's own camera system.

###### Motivation

This data is open sourced to:
* Provide access to basketball tracking data to researchers and the sports analytics community.
* Increase awareness of broadcast tracking data and how it can benefit clubs, media and the betting industry.
* Allow SkillCorner prospects to access data easily, parse our data format and get started building on top of it.
* Offer two entry points: full-season aggregates for quick analysis, and raw tracking plus events for those who want to build from the ground up.

If you use the data, we kindly ask that you credit SkillCorner and notify us on [Twitter](https://twitter.com/skillcorner) so we can follow the work being done with it.

##### Documentation

Start with the [primer](docs/PRIMER.md) for an overview of what this data is, the coordinate system, units, frame rate and clock conventions, and how the aggregates are computed. Field-by-field reference for every table lives in [`docs/data_dictionary/`](docs/data_dictionary/README.md); the aggregate CSV columns are documented separately in [`docs/aggregates_columns.md`](docs/aggregates_columns.md).

There are no tutorial notebooks in this repo — the primer and data dictionary are written to be read directly by both analysts and LLMs; most people will get further asking an LLM to work with the data using these docs as context than following a fixed notebook.

###### Data Structure

The `data` directory contains:

* `aggregates/` — three CSVs with season-level, offense-only aggregated Dynamic Events for 293 of the 327 games of ACB 2025-2026 (regular season and playoffs); the missing games are mostly the playoffs plus a few regular-season fixtures:
  * `acb_shotsaggregates_20252026.csv`
  * `acb_drivesaggregates_20252026.csv`
  * `acb_picksaggregates_20252026.csv`
  * See [`docs/aggregates_columns.md`](docs/aggregates_columns.md) for the full column reference.
* `player_id_aliases.csv` — maps the few duplicate `player_id` values to one canonical id per player (see [Known data issues](README.md#known-data-issues)).
* `matches/` — one folder per game (named with its `gameId`), for the 10 sample games. Each folder has exactly three files:
  * `{gameId}_game_data.json` — game metadata and both team rosters. See [`docs/data_dictionary/game_data.md`](docs/data_dictionary/game_data.md).
  * `{gameId}_dynamic_events.json` — a single JSON object with one array per event family (chances, possessions, shots, picks, drives, passes, touches, dribbles, free_throws, fouls, rebounds, turnovers, timeouts, isolations, handoffs, posts, off_ball_screens, closeouts, chance_players, matchups — see the exact key names in [`docs/data_dictionary/README.md`](docs/data_dictionary/README.md)). Every record carries `id`, `gameId`, `season`, `period` and the `chanceId`/`possessionId` it belongs to, so the file is a relational bundle you can load and join in one pass.
  * `{gameId}_tracking_data.jsonl.gz` — gzip-compressed JSON Lines, one video frame per line at 25 fps (player and ball positions). Roughly 30-46 MB per game. Tracked with Git LFS. Decompress with `gzip -d {gameId}_tracking_data.jsonl.gz`, or read directly without decompressing first: `pandas.read_json("{gameId}_tracking_data.jsonl.gz", lines=True, compression="gzip")`. See [`docs/data_dictionary/tracking_data.md`](docs/data_dictionary/tracking_data.md) for the frame schema.

The 10 sample games (ACB 2025-2026):

| gameId | Date | Home | Away | Score |
|---|---|---|---|---|
| 114243 | 2025-10-11 | BAXI Manresa | Coviran Granada | 83-68 |
| 114234 | 2025-10-18 | Casademont Zaragoza | Leche Rio Breogan | 84-88 |
| 114169 | 2025-12-14 | CB UCAM Murcia | Club Joventut Badalona | 80-77 |
| 114099 | 2026-01-31 | Basquet Girona | San Pablo Burgos | 77-71 |
| 114086 | 2026-02-08 | Dreamland Gran Canaria | Bitci Baskonia | 75-97 |
| 178442 | 2026-03-21 | BC MoraBanc Andorra | Bilbao Basket | 98-102 |
| 179612 | 2026-04-12 | Malaga | Valencia BC | 89-96 |
| 184439 | 2026-04-19 | Real Madrid | Lenovo Tenerife | 90-95 |
| 188630 | 2026-05-03 | BC Barcelona | Dreamland Gran Canaria | 91-69 |
| 191313 | 2026-05-29 | Leche Rio Breogan | Casademont Zaragoza | 94-95 |

See `data/matches.json` for the same list as structured data (team ids, `competition_id`/`competition_edition_id`/`season_id`, final scores). Its `date_time` is the official ACB scheduled tip-off in UTC, and matches the `date` field inside each `{gameId}_game_data.json`; tracking may start slightly before or after that instant.

###### 📍 Tracking Data

Player and ball positions at 25 frames per second, in feet, origin at the center of the court. See [`docs/data_dictionary/tracking_data.md`](docs/data_dictionary/tracking_data.md) for the full field list and [`docs/PRIMER.md`](docs/PRIMER.md#coordinate-system-and-units) for the coordinate system.

###### ⚡ Dynamic Events (Game Intelligence)

Every touch, pass, dribble, shot, foul, rebound, turnover, timeout, and named action (pick-and-roll, hand-off, off-ball screen, drive, isolation, post-up, closeout) SkillCorner's Game Intelligence models detect from the tracking data, each carrying both play-by-play facts (who, what, outcome) and tracking-derived context (defender identity and distance, coverage type, exact location) that a manually scored feed does not have. See [`docs/data_dictionary/README.md`](docs/data_dictionary/README.md) for the full event catalog, how the tables join, and which columns carry tracking context.

###### 📊 Season Aggregates (Shots, Drives, Picks)

Player-season, offense-only roll-ups of the shot, drive and pick events across 293 ACB 2025-2026 games, pivoted by court zone, contest level, shot type, defensive coverage and more. See [`docs/aggregates_columns.md`](docs/aggregates_columns.md) for the full column reference and [`docs/PRIMER.md`](docs/PRIMER.md#how-the-season-aggregates-are-computed) for how they're built.

##### ⚠️ Limitations

TRACKING
* ~76-83% of player positions per game are directly detected on screen (`isDetected`); the remainder are extrapolated. Mean `predError` across all positions is ~1.5-1.9 ft per game (95th percentile ~4.9-6.3 ft); extrapolated positions alone average ~4.4-5.2 ft.
* Some speed or acceleration smoothing and control should be applied to the raw tracking data before use.

AGGREGATES
* The season aggregates are offense-only; there is no defensive-side data in this release.
* 293 of the 327 games of the 2025-2026 season (regular season and playoffs) are included; the missing games are mostly the playoffs plus a few regular-season fixtures. The 10 sample games are part of those 293, but the aggregates cannot be reproduced from the 10 per-game event files alone.
* Rows are per player-team-season; traded players also get a season-total row (`team_name` = "total"). See [`docs/aggregates_columns.md`](docs/aggregates_columns.md).

###### Known data issues

Short version; details in [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md).

* A few players carry two `player_id` values across the season. Use `data/player_id_aliases.csv` to merge them.
* Compute team scores from `shots` and `free_throws`, not from `chances.ptsScored`.
* `shots` includes fouled misses (not counted as attempts in box scores); picks aggregates count direct picks only.
* Some event fields are noisy (e.g. `passes.toReceiverId` holds the intercepting defender). Scores are unaffected.

##### 🏗️ Repository Structure & Contributing

* **`data/`**: strictly for datasets. `data/matches/` for raw per-game tracking and event data, `data/aggregates/` for the season-level aggregate CSVs.
* **`docs/`**: the primer, the data dictionary, and the aggregate column reference.

##### Contact us

* If you have feedback or research you'd like to conduct with this data, reach us on [our website](https://skillcorner.com/#contact-section) or on [Twitter](https://twitter.com/skillcorner).
* If you're interested in our product and want commercial information, contact us on [our website](https://skillcorner.com/#contact-section).

### reference-docs-primer-md

Local: [docs/PRIMER.md](docs/PRIMER.md) · Upstream: [docs/PRIMER.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/PRIMER.md)

#### Primer: SkillCorner basketball data

##### What this data is

SkillCorner extracts player and ball positions from broadcast video using computer vision, at 25 frames per second, with no on-court hardware and no dependency on a venue's own camera system. That raw tracking is the input; everything else in this dataset is derived from it in a pipeline with three layers:

1. **Tracking data** (`tracking_data`, one file per game): x/y/z coordinates for every player and the ball, frame by frame.
2. **Dynamic Events / markings** (`chances`, `possessions`, `shots`, `picks`, `drives`, ... one file per game): a Game Intelligence model reads the tracking data and produces a structured play-by-play — every touch, pass, dribble, shot, foul, rebound, turnover, timeout, and every named action (pick-and-roll, hand-off, off-ball screen, drive, isolation, post-up, closeout), each carrying both the box-score facts (who, what, outcome) and tracking-derived context (defender identity, distance, coverage type, location) that a manual scorer's feed does not have.
3. **Season aggregates** (`data/aggregates/*.csv`): per player-season roll-ups of the Dynamic Events, offense only, built from the shots, drives and picks event tables.

For the full field list at each layer, see the [data dictionary](docs/data_dictionary/README.md).

##### Coordinate system and units

All locations (`location`, `endLoc`, `xyz`, etc., across `tracking_data` and every event table) are in **feet**, with the origin `(0, 0)` at the **center of the court**. The offensive hoop for a given event is on the negative x side, the defensive hoop on the positive x side; when a team is attacking, its left is positive y and its right is negative y. Player and ball height (`z`) is included in `tracking_data`; players are currently always tracked at `z = 0` (kept on the ground), ball `z` is positive.

Beyond raw coordinates, most events also carry a named court **region** (`left corner three`, `right wing two`, `key`, `ra`, `backcourt`, etc.) — see the full list in the [data dictionary README](docs/data_dictionary/README.md#markings--coordinate-system).

Speeds in `tracking_data` are in feet per second. Distances derived from tracking (`distance`, `closestDefDist`, drive/closeout distances) are in feet.

##### Frame rate, clocks and periods

* **Frame rate:** 25 fps. `frameIdx` (in `tracking_data`) and `frame` / `startFrame` / `endFrame` (in the event tables) all count frames at 25fps since the start of the game video, on the same index — an event's `frame` is directly the `frameIdx` of the tracking frame it happened in.
* **`period`:** starts at 1, so the first quarter is period 1 (this generalizes across competitions that play quarters vs. halves).
* **`gameClock`:** seconds remaining in the period; 0 means the period has ended.
* **`shotClock`:** seconds remaining on the shot clock at that instant.
* **`wallClock`:** elapsed time in milliseconds since the start of the game video, on the same origin in every event table and in `tracking_data` (an event's `wallClock` equals the tracking `wallClock` at its `frame`). It runs through dead time and period breaks; use `gameClock` + `period` for in-game time.

##### How the season aggregates are computed

The three aggregate files (`data/aggregates/acb_shotsaggregates_20252026.csv`, `acb_drivesaggregates_20252026.csv`, `acb_picksaggregates_20252026.csv`) are player-season roll-ups built directly from the `shots`, `drives` and `picks` Dynamic Events tables, for every ACB game processed for the 2025-2026 season — not just the 10 games whose raw event files are included here. They are **offense-only**: every row is a player's own shooting, driving or ball-handling-in-a-pick production, not what they allowed on defense.

Each table pivots its underlying events by the dimensions that matter for that action — shots by court zone, shot type and contest level; drives by how they were created and how they ended; picks by defensive coverage faced. See [`aggregates_columns.md`](docs/aggregates_columns.md) for the full column reference, and the [data dictionary](docs/data_dictionary/README.md) pages for `shots.md` / `drives.md` / `picks.md` for the event-level fields each metric is built from.

##### Typical gotchas

* **A possession is not a chance.** An offensive rebound keeps the same `possessionId` alive but starts a new `chanceId`. If you're counting "possessions" for an efficiency stat, decide up front whether you mean `possessions` or `chances` — most points-per-possession style stats in basketball analytics actually mean `chances` (each shot attempt / turnover is its own scoring opportunity).
* **Two clocks measure different things.** `gameClock` counts down within a period and stops on every whistle; `wallClock` is elapsed video time from the start of the game and never stops. Use `wallClock` (or `frame`) to line events up with tracking frames, and `gameClock` + `period` for anything that should ignore dead time.
* **Region and location both describe position but at different resolution.** `location` is exact feet; `region` is a coarse, discrete label. They can disagree slightly at zone boundaries.
* **Not every field is present for every table.** `pbp_derived` fields (see the "PBP derived" column in the data dictionary, where present) come from official play-by-play rather than tracking — most fields do not carry that flag and are computed purely from tracking data.
* **`touchId` is the connective tissue.** Many action markings (picks, drives, handoffs, ...) reference a `touchId`; go to `touches` for duration, dribble count and the assigned defender if the marking table itself doesn't have the field you need.
* **Aggregates cover the full season; raw events cover 10 games.** The season aggregate totals are built over 293 games, so they cannot be reproduced from the 10 per-game event files. The 10 published games are part of those 293, and their shot, drive and pick events are the same events the aggregates were computed from, so a player's events in these games are a strict subset of their season row.
* **Picks aggregates count direct picks only.** The `picks` aggregate table only counts pick events where `direct = true` (the ball handler or screener shot, assisted, or was fouled directly after the pick) — in ACB 2025-2026 that's about 52% of all pick events (22,080 of 42,156). Counting raw `picks` event rows gives roughly double `handler_total_picks`; filter on `direct` first.
* **Aggregate rows are per player-team-season, not per player-season.** A player traded mid-season gets one row per team plus an extra season-total row (`team_id` empty, `team_name` = `"total"`). Sum the wrong subset of rows and you'll double-count traded players. See [`aggregates_columns.md`](docs/aggregates_columns.md#grain-and-identity-columns-all-three-tables).
* **`attempts` (shots aggregate) is a box-score number, not a raw event count.** It follows FIBA convention and excludes field goal attempts missed while the shooter was fouled (those are free throw trips, not field goal attempts) — the underlying `shots` event table includes them, so raw event counts run higher than `attempts`. `total_points` includes free throws made on and-one plays, so it isn't simply points from made field goals.
* **`games_played` counts on-court presence, not tracked activity.** It's the number of games the player was on court for at least one chance (from `chance_players`), not the number of games with a tracked shot, drive or pick — a row can have `games_played > 0` and zero attempts. It also reflects SkillCorner's delivered data, not official appearances: 293 of 327 games of the 2025-2026 season (regular season and playoffs) are included, with the missing games mostly playoffs plus a few regular-season fixtures, so teams range from 31 to 34 games in the 293-game set.

### reference-docs-known-issues-md

Local: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) · Upstream: [docs/KNOWN_ISSUES.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/KNOWN_ISSUES.md)

#### Known data issues

Details behind the short list in the main README. Nothing here affects the final scores of the 10 published games.

* **Player identity.** 9 players in the ACB 2025-2026 season appear under two different `player_id` values (usually with a slightly different name spelling) across games — within a single game a given person always has one id, but their id can change between games. The aggregates therefore contain two separate rows for each of these 9 players. `data/player_id_aliases.csv` maps every affected `player_id` to one canonical id; merge on it if you want a single row per person.
* **Team scores from `chances`.** Summing `chances.ptsScored` by `offTeamId` does not reproduce the official team score in about half of all games. The cause is that a chance's `offTeamId` can be mislabelled when both teams score within the same chance — most often technical or unsportsmanlike-foul free throws, occasionally an ordinary field goal. Compute team points from `shots` and `free_throws` instead, which carry the correct team on every row. In the 10 published games, team scores from `chances.ptsScored` close exactly; the only two events attached to an opponent's chance (in game 184439) are missed free throws.
* **Event completeness vs. official box scores.** Team points computed from `shots` + `free_throws` match the official ACB box score exactly in about 95% of team-games over the season; the remaining cases are 1-5 points short. All 10 published games match the official final score exactly, and free throws match 100% in the published games.
* **Shot attempts convention.** The `shots` table records attempts where the shooter was fouled and missed; official box scores (FIBA convention) do not count these as field goal attempts. To reproduce box-score FGA, exclude shots where `fouled` is true — see [`docs/data_dictionary/shots.md`](docs/data_dictionary/shots.md).
* **Picks convention.** The picks aggregates count only "direct" picks (`direct` = true on the `picks` event table: the ball handler or screener shot, was assisted, or was fouled directly after the pick) — about 52% of all pick events in ACB 2025-2026 (22,080 of 42,156). Filter raw `picks` events on `direct` before comparing counts to `handler_total_picks` / `screener_total_picks`, or you'll get roughly double the aggregate's count.
* **`passes.toReceiverId` holds the defender, not the intended receiver.** Despite its name, the field holds the id of the defender who intercepted the pass, not an intended receiver — verified on every non-null row across the season and on all 89 such rows in the 10 published games. Use it accordingly, not as a "who the pass was meant for" field.
* **Low-level marking noise you may meet in the per-game files.** None of this affects scores or the aggregates; treat it as noise in the event markings, not as a data-quality blocker. Counts are over the 10 published games: about 9 passes per game where `passerId` equals the receiver id (91 total), 38 shots flagged `assisted` without a matching `assistOpp`, 29 missed field goals with no corresponding `rebounds` row, 21 chances with zero elapsed game clock, and 3 chances where the end frame comes before the start frame.
* **Assists and rebounds** are tracking-derived judgment calls (who gets credit) and differ from official scorer decisions more often than shots and free throws do.

### reference-docs-aggregates-columns-md

Local: [docs/aggregates_columns.md](docs/aggregates_columns.md) · Upstream: [docs/aggregates_columns.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/aggregates_columns.md)

#### Aggregate table column reference

Column reference for the three season-level aggregate files in `data/aggregates/`: `acb_shotsaggregates_20252026.csv`, `acb_drivesaggregates_20252026.csv`, `acb_picksaggregates_20252026.csv`. Each is a player-season roll-up, offense only, built from the `shots`, `drives` and `picks` Dynamic Events tables described in the [data dictionary](docs/data_dictionary/README.md). See the [primer](docs/PRIMER.md#how-the-season-aggregates-are-computed) for how these fit into the wider pipeline.

Every column family below has been checked against the published CSVs; column counts and bucket values are as delivered.

##### Grain and identity columns (all three tables)

**Grain: one row per player, per team, per season.** A player who was traded mid-season gets one row per team they played for, PLUS an extra season-total row with `team_id` empty and `team_name` = `"total"` that aggregates across all their teams. Summing a metric column straight down the file double-counts anyone who has a total row — filter to either the per-team rows or the total rows before aggregating across players, don't mix both for the same player.

Row counts for ACB 2025-2026 (18 teams): `acb_shotsaggregates_20252026.csv` has 326 rows / 316 distinct players, `acb_drivesaggregates_20252026.csv` has 301 rows, `acb_picksaggregates_20252026.csv` has 319 rows. Row counts differ across the three files because a player only gets a row in a given file if they recorded at least one event of that type (e.g. a player with zero tracked picks has no row in the picks file).

Column order in the CSVs: `competition_id`, `competition_name`, `season_id`, `season_name`, `player_id`, `player_name`, `team_id`, `team_name`, `games_played`, then the metric columns verbatim from the pipeline (families documented per table below).

| Column | Type | Definition |
|---|---|---|
| `competition_id` | INT64 | Competition (league) identifier. |
| `competition_name` | STRING | Competition (league) display name, e.g. 'ACB'. |
| `season_id` | INT64 | Season identifier. |
| `season_name` | STRING | Season label formatted as 'start_year-end_year', e.g. '2025-2026'. |
| `player_id` | INT64 | Player identifier (integer SkillCorner player id), joins to `game_data` player ids. |
| `player_name` | STRING | Player display name. |
| `team_id` | INT64 | Team the row belongs to. Empty marks the all-teams season TOTAL row for a player who changed teams mid-season (see grain note above). |
| `team_name` | STRING | Team display name. `'total'` on the all-teams season row. |
| `games_played` | INT64 | Number of games in which the player was on court for at least one chance (derived from `chance_players`, split by team). This is on-court presence only — it is **not** a count of games with a tracked shot, drive or pick, so a player can have `games_played > 0` with zero attempts in that same aggregate row. 293 of the 327 games of the 2025-2026 season (regular season and playoffs) are included in the source data; the missing games are mostly the playoffs plus a few regular-season fixtures, so `games_played` tops out at whatever number of those 293 games that player's team is covered for (teams range from 31 to 34 games in the 293-game set). |
| `possessions_played` | INT64 | Offensive possessions the player was on court for (on-court presence, not possessions with a tracked event). Counts a player on court at any point in the possession, so mid-possession substitutions push this ~3% above 5 × possessions — it will not reconcile against a team-level total. |

##### shots aggregates (`acb_shotsaggregates_20252026.csv`)

Player-season shot attempts, makes and points, pivoted by court zone, contest level, and shot type. Every count/rate below is offense — a player's own shooting.

* **Totals** — `attempts`, `made_baskets` (renamed `mades` in some columns), `total_points`/`points`, `assisted_mades` (makes assisted by a teammate), `blocked_on_attempts`, `fouled_fg_attempts`/`fouled_fg_mades` (and-ones), `avg_attempts_distance` (average feet to the hoop across attempts). `attempts` follows FIBA box-score convention and **excludes field goal attempts missed while the shooter was fouled** (these are scored as free throw trips, not field goal attempts) — the underlying `shots` event table is broader and includes those events (41,684 shot events vs. 38,029 `attempts` league-wide in ACB 2025-2026), so don't expect `attempts` to reconcile against a raw count of `shots` rows. `total_points` includes free throw points scored on and-one plays (a made basket plus a made bonus free throw), so it is not simply `2 × fg2_mades + 3 × fg3_mades`.
* **Derived rates** — `fg_percentage`, `efg_percentage` (effective FG%, weights 3s at 1.5x), `points_per_shot`.
* **By contest level** (`cl_*`, 5 buckets × 7 metrics = 35 columns) — `cl_open_*`, `cl_light_*`, `cl_average_*`, `cl_plus_*`, `cl_blocked_*`, each with `_attempts`, `_mades`, `_misses`, `_attempt_rate`, `_fg_percentage`, `_points_per_shot`, `_total_points`. Matches the `contestLevel` values on the `shots` event table: open, light, average, plus, blocked.
* **By court zone** (`zone_*`, 71 columns) — `_attempts`/`_mades`/`_misses`/`_total_points` per zone, plus `_attempt_rate`/`_fg_percentage`/`_points_per_shot` for the split 3-point zones. Two-point zones: `restricted_area`, `paint_non_ra` (paint outside the restricted area), `mid_range`. Three-point zones: `corner_3` (also split into `corner_3_left` / `corner_3_right`), `wing_3_left` / `wing_3_right`, `top_3`, `above_break_3` (wings + top combined), and `three` (all 3-point attempts, with `_attempt_rate` / `_fg_percentage`). Catch-all zones: `backcourt`, `far`, `other`. This zone vocabulary is coarser than the `region` strings on the event tables (see [data dictionary README](docs/data_dictionary/README.md#markings--coordinate-system)).
* **By zone family** (12 columns) — three two-point families with `_attempts`/`_mades`/`_fg_percentage`/`_attempt_rate`: `rim` (= `zone_restricted_area_*`), `short_midrange_paint` (= `zone_paint_non_ra_*`), `long_midrange` (= `zone_mid_range_*`). Three-point attempts and the `backcourt`/`far`/`other` zones belong to no family, so the three families sum to slightly less than `two_attempts`.
* **By shot type** (`cst_*`, complex shot type, 98 columns) — 14 shot types × 7 metrics: `catch_and_shoot`, `dribble_pull_up`, `dunk`, `floater`, `heave`, `hook`, `layup`, `leaner`, `lob`, `off_move`, `post_fadeaway`, `shake_and_raise`, `stepback`, `tip`. Matches `complexShotType` on the `shots` event table.
* **Catch-and-shoot / off-dribble** (`cns_*` / `od_*`, 30 columns) — a coarser 2-way split (catch-and-shoot vs. off-the-dribble) than the full shot-type breakdown, each with `_attempts`, `_mades`, `_fg_percentage`, `_efg_percentage`, `_points_per_shot`, `_total_points`, plus a 2pt/3pt split (`_two_*`, `_three_*`) and free throws drawn on that shot type (`_ft_attempts`, `_ft_mades`). Matches the `catchAndShoot` boolean on the `shots` event table (catch-and-shoot = release ≤ 1.5s or `complexShotType = catchAndShoot`).
* **Contested / uncontested** (30 columns, same shape as catch-and-shoot / off-dribble) — a coarser 2-way split of contest level than the 5-bucket `cl_*` breakdown. Matches the `contested` boolean on the `shots` event table (contested = `contestLevel` in average/plus/blocked).

##### drives aggregates (`acb_drivesaggregates_20252026.csv`)

Player-season drive volume and outcomes, pivoted by how the drive started, how it ended, its direction and its origin court zone.

* **Totals** (16 columns) — `total_drives`, `successful_drives` / `unsuccessful_drives` (successful = basket made, assist, or foul drawn), `made_baskets`, `assists` (drive led to a teammate scoring off the ball handler's pass), `potential_assists` (pass could have led to a score but was missed/turned over), `fouls` (drew a shooting/non-shooting foul), `fga_in_drive`, `field_points_in_drive`, `ft_attempts_in_drive`/`ft_mades_in_drive`, `points` (own FG points + assisted FG points, excludes free throws), `points_per_shot_in_drive`.
* **Derived rates** — the totals above as a share of `total_drives`: `successful_drives_rate`, `unsuccessful_drives_rate`, `made_baskets_rate`, `assists_rate`, `potential_assists_rate`, `fouls_rate`, `points_per_drive`.
* **By play category** (`category_*`, 12 columns) — how the drive was created: `pick`, `handoff`, `off_ball_screen`, `iso`, `closeout`, `miscellaneous` (doesn't fit the other tracked origins). Each with `_count` and `_rate`. Matches the `category` field on the `drives` event table.
* **By end type** (`end_type_*`, 14 columns) — how the drive ended: `kickout` (pass out), `pullout` (reset without continuing), `pullup` (pull-up jumper), `interior_pass`, `shot_near_basket`, `turnover`, `stoppage` (whistle/dead ball, no other end type). Each with `_count` and `_rate`. Matches `endType` on the `drives` event table.
* **By direction** (4 columns) — `direction_left_*` / `direction_right_*` (which way the ball handler drove), count and rate.
* **By court zone** (6 columns) — origin zone of the drive, limited to `above_break_3`, `corner_3`, `mid_range` in the sample schema (drives don't usually originate in the restricted area/paint by definition, so rim-adjacent zones are not broken out here).
* **Drive type** — `blowby_count`/`blowby_rate` (defender beaten on the drive), `dribble_through_count`/`dribble_through_rate` (drove all the way through the paint), `direct_drives_count` (drive classified as ending directly in a shot/foul/turnover, vs. an indirect drive that reset into something else).

##### picks aggregates (`acb_picksaggregates_20252026.csv`)

Player-season pick-and-roll production, tracked separately for each of the two roles a player can occupy on a pick: **ball-handler** (`handler_*` columns) and **screener** (`screener_*` columns). Every metric exists once per role, and is further split by defensive coverage and by screen location — this is the largest of the three files by column count (684 in the full offense schema).

**Direct picks only.** The picks aggregates count only picks where the raw event's `direct` field is true (the ball handler or screener shot, was assisted, or was fouled directly after the pick — see `direct` on the [`picks`](docs/data_dictionary/picks.md) event table). In ACB 2025-2026 that's 22,080 of 42,156 total pick events (~52%). Counting rows in the raw `picks` event table therefore gives roughly double `handler_total_picks`; filter on `direct = true` before comparing raw event counts to these aggregates.

* **Shared identity/totals** — the common identity block plus `possessions_played`, `team_id`, `team_name` (one set, not duplicated per role).
* **Role totals** (`handler_*` / `screener_*`, 35 columns per role) — `_total_picks`, `_successful_pick` / `_unsuccessful_pick` (successful = score, assist, or foul drawn), `_score` (own make, split `_score_2pt`/`_score_3pt`), `_miss` (own miss, split 2pt/3pt), `_assist` (assisted a teammate, split `_to_screener` vs `_to_other`), `_assist_opportunity` (pass created a scoring chance whether converted or not, same to_screener/to_other split), `_pass` (split `_pass_to_screener`/`_pass_to_other`), `_only_pass_pick` (passed with no shot/assist), `_no_outcome_pick`, `_turnover`, `_foul` (drew a foul), `_block` (shot blocked), `_shot_taken`, `_fga_in_pick`, `_field_points_in_pick`, `_ft_attempts_in_pick`/`_ft_mades_in_pick`, `_points`, `_points_per_shot_in_pick`, `_ppp` (points per pick).
* **Role derived rates** (20-21 columns per role) — the totals above as a share of `_total_picks` (`_pct` or `_rate` suffix; both are used inconsistently in the schema — treat them as synonyms), plus `_fg2_pct` / `_fg3_pct` (make percentage conditional on a 2pt/3pt attempt being taken, not a share of total picks).
* **By defensive coverage** (`_vs_<coverage>`, 245 columns per role) — every role-totals and role-derived-rate metric repeated once per defensive coverage the player faced. Ball-handler buckets (`handler_*_vs_*`, matching `bhrDefType` on the `picks` event table): `blitz`, `ice`, `over`, `switch`, `under`. Screener buckets (`screener_*_vs_*`, matching `scrDefType`): `blitz`, `ice`, `show`, `soft`, `switch`. The two vocabularies differ by role; picks with no coverage called (`none`) are counted in the role totals but have no `_vs_` bucket of their own.
* **By screen location** (`_at_<location>`, 36 columns per role) — every role metric repeated once per pick location: `middle`, `stepUp`, `wing`, `unknown` (unclassified). Matches `locationType` on the `picks` event table.

**Always empty in this release** — five columns are 100% null across all of ACB 2025-2026 (no player recorded an event in the `unknown`-location bucket combined with these particular metrics): `handler_fg2_pct_vs_blitz`, `handler_ppp_at_unknown`, `handler_score_rate_at_unknown`, `screener_ppp_at_unknown`, `screener_score_rate_at_unknown`. Don't treat a null in these five as missing data — it reflects zero underlying events for that combination.

##### Notes on reading these columns

* `_rate` and `_pct` columns are always a share of that role's `_total_picks` / `total_drives` / shot attempts within the same pivot bucket (e.g. `handler_score_rate_at_middle` divides by `handler_picks_at_middle`, not by the player's overall `handler_total_picks`) — read the bucket suffix carefully before comparing rates across buckets.
* `points` on `drives` and `picks` excludes free throw points; free throws are broken out separately (`ft_attempts_in_drive`/`ft_mades_in_drive`, `_ft_attempts_in_pick`/`_ft_mades_in_pick`).
* A player with a `team_id` of NULL and `team_name` of `'total'` is the season-total row for a player who changed teams mid-season; don't double count them against their per-team rows.

### reference-docs-data-dictionary-readme-md

Local: [docs/data_dictionary/README.md](docs/data_dictionary/README.md) · Upstream: [docs/data_dictionary/README.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/README.md)

#### Data dictionary

Field-level reference for every table in this dataset. One file per table:

**Match context**

* [`game_data`](docs/data_dictionary/game_data.md) — game, competition, season identifiers and team rosters.
* [`tracking_data`](docs/data_dictionary/tracking_data.md) — broadcast optical tracking, 25fps, per-game.

**Core play-by-play structure**

* [`possessions`](docs/data_dictionary/possessions.md) — one continuous span of team control of the ball.
* [`chances`](docs/data_dictionary/chances.md) — one continuous scoring opportunity within a possession (a possession spans several chances when the offense keeps the ball alive off an offensive rebound).
* [`chance_players`](docs/data_dictionary/chance_players.md) — on-court participation, one row per player per chance.
* [`matchups`](docs/data_dictionary/matchups.md) — who is guarding whom, as time intervals within a chance.

**Outcome events** (every made/missed shot, turnover, foul etc. belongs to exactly one chance)

* [`shots`](docs/data_dictionary/shots.md), [`free_throws`](docs/data_dictionary/free_throws.md), [`rebounds`](docs/data_dictionary/rebounds.md), [`turnovers`](docs/data_dictionary/turnovers.md), [`fouls`](docs/data_dictionary/fouls.md), [`timeouts`](docs/data_dictionary/timeouts.md)

**Ball-movement events** (the mechanics of how a chance developed)

* [`passes`](docs/data_dictionary/passes.md), [`touches`](docs/data_dictionary/touches.md), [`dribbles`](docs/data_dictionary/dribbles.md)

**Action markings** (named actions a team runs, each carrying tracking-derived defensive context)

* [`picks`](docs/data_dictionary/picks.md), [`handoffs`](docs/data_dictionary/handoffs.md), [`off_ball_screens`](docs/data_dictionary/off_ball_screens.md), [`drives`](docs/data_dictionary/drives.md), [`isolations`](docs/data_dictionary/isolations.md), [`posts`](docs/data_dictionary/posts.md), [`closeouts`](docs/data_dictionary/closeouts.md)

##### How the tables join

Everything hangs off four keys:

* **`gameId`** — every table carries it; joins any table to [`game_data`](docs/data_dictionary/game_data.md) for date, competition, season and rosters.
* **`possessionId`** — the parent [`possessions`](docs/data_dictionary/possessions.md) row for a chance or event.
* **`chanceId`** — the parent [`chances`](docs/data_dictionary/chances.md) row for an event. A chance is the unit almost everything else hangs off: `offPlayerIds` / `defPlayerIds` on `chances` give the on-court lineup, `startType` / `outcome` give how it began and ended, `qualityIndex` / `usable` flag tracking-data confidence.
* **Player ids** — every table uses integer SkillCorner player ids (named contextually: `shooterId`, `ballhandlerId`, `screenerId`, `passerId`, `rebounderId`, `foulerId`, `defPlayerId`, ...). All of them join to `homeTeam.players[i].playerId` / `awayTeam.players[i].playerId` in [`game_data`](docs/data_dictionary/game_data.md).

A secondary key, **`touchId`**, links an action marking (a pick, a drive, a shot, ...) back to the [`touches`](docs/data_dictionary/touches.md) row it happened within — useful for pulling touch-level context (duration, dribble count, defender at catch) for any event.

Region and shot-zone strings are shared across tables and use the same court-region vocabulary — see the region list below.

##### Event families

* **Core events** — `possessions`, `chances`, `shots`, `free_throws`, `rebounds`, `turnovers`, `fouls`, `timeouts`, `passes`, `touches`, `dribbles`. These record what happened and to whom, independent of tracking data.
* **Action markings** — `picks`, `handoffs`, `off_ball_screens`, `drives`, `isolations`, `posts`, `closeouts`. These are named plays SkillCorner's Game Intelligence models detect from the tracking data: a pick-and-roll, a dribble hand-off, an off-ball screen for a cutter, a drive, an isolation, a post-up, a defensive closeout. They all carry two players (the primary actor and, where relevant, a screener/setter/cutter) plus each player's defender and the defensive coverage called.
* **Player tracking-derived context** — `chance_players` (on-court presence, matchups, shot/rim/rebound locations, minutes played) and `matchups` (defensive assignment over time). These are what makes it possible to say who was guarding whom for any given event.
* **Game context** — `game_data` (game/competition/season identity, rosters) and `tracking_data` (raw player and ball positions at 25fps).

##### Columns that carry tracking context

These are the fields that make this dataset different from a plain play-by-play feed — they come from the optical tracking, not from a scorer's keyboard:

* **`picks` / `handoffs` / `off_ball_screens`**: `ballhandlerDefId` / `screenerDefId` / `cutterDefId` / `setterDefId` (who was guarding whom, tracked through any switch), `bhrDefType` / `scrDefType` / `receiverDefType` / `setterDefType` / `cutterDefType` / `screenerDefType` (defensive coverage: e.g. `ice`, `switch`, `blitz`, `drop`-style `soft`/`show`, `trail`, `whip`, `ride`, `top lock`, `jam`), `location` / `region` / `locationType` (where on the court, in feet and in named regions).
* **`shots`**: `closestDefDist` / `closestDefId` (distance to and identity of the nearest defender at release, in feet), `contestLevel` / `contested` (`open`, `light`, `average`, `plus`, `blocked`), `distance` (shooter-to-hoop distance at release), `releaseTime` (seconds from touch start to release).
* **`closeouts`**: `startDistance` / `touchDistance` / `endDistance` (ball handler-to-defender distance at three checkpoints of the closeout) and each checkpoint's `startLoc` / `touchLoc` / `endLoc`.
* **`touches`**: `closestDefLoc` / `endClosestDefLoc` (defender position at the start and end of the touch), `defenderId` (assigned matchup defender, or nearest defender if no rotation exists).
* **`chance_players`**: `startMatchupId` / `endMatchupId` (tracked defensive assignment at the start/end of the chance), `shotLoc` / `rimLoc` / `reboundLoc` (player position at three tracked moments).
* **`drives`**: `blowby` (whether the driver beat their defender), `direction`, `dribbleThrough`.

##### Markings / coordinate system

Location is delivered as `[x, y]` in feet, `(0, 0)` at the center of the court. The offensive hoop is at negative x, the defensive hoop at positive x. When attacking, the left side of the court is positive y, the right side is negative y. This convention is shared by every `location` / `endLoc` / `passerLoc` / `receiverLoc` field across the event tables, and is the same coordinate system used by `tracking_data`.

Region strings (used in `region`, `passerRegion`, `receiverRegion`, etc.) take one of: `left corner three`, `left corner two`, `left wing three`, `left wing two`, `backcourt`, `far`, `middle three`, `middle two`, `key`, `ra` (restricted area), `right wing three`, `right wing two`, `right corner three`, `right corner two`.

Markings data (everything except `tracking_data` and `game_data`) is delivered as a single JSON file per game (`{gameId}_dynamic_events.json`), keyed by marking type — exactly these 20 keys: `possessions`, `chances`, `chance_players`, `matchups`, `shots`, `free_throws`, `rebounds`, `turnovers`, `fouls`, `timeouts`, `passes`, `touches`, `dribbles`, `picks`, `handoffs`, `off_ball_screens`, `drives`, `isolations`, `posts`, `closeouts` (the `matchups` key holds the table documented in [`matchups.md`](docs/data_dictionary/matchups.md)); each key's value is the list of that marking type's events for the game, with the fields documented on its own page above.

##### Known type quirks

* **`closeouts.touchWallClock`** is delivered as a **string** (e.g. `"97080"`), while the sibling `startWallClock` / `endWallClock` on the same table are integers. Cast it before doing arithmetic on it.

### reference-docs-data-dictionary-game-data-md

Local: [docs/data_dictionary/game_data.md](docs/data_dictionary/game_data.md) · Upstream: [docs/data_dictionary/game_data.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/game_data.md)

#### game_data

Per-game metadata: identifiers for the game, competition, edition and season, tip-off time, last processing timestamps for tracking, Dynamic Events and physical data, and the home/away team rosters. Delivered as `{gameId}_game_data.json`, a single JSON object of roughly 2 KB. One `game_data` record exists per game and is the anchor every other table's `gameId` points back to.

**Grain:** one row per game. **Join key:** `gameId` joins to every other table's `gameId` field. `homeTeam.players[i].playerId` / `awayTeam.players[i].playerId` join to the player id fields used across the event tables (`shooterId`, `ballhandlerId`, `playerId`, etc.).

| Field | Type | Definition |
|---|---|---|
| `gameId` | integer | SkillCorner Game ID. |
| `date` | datetime | Official scheduled tip-off in UTC (format: `YYYY-MM-DDTHH:MM:SSZ`). Same value as `date_time` in `data/matches.json`. Tracking may start slightly before or after this instant. |
| `competitionEditionId` | integer | SkillCorner CompetitionEdition ID. |
| `competitionId` | integer | SkillCorner Competition ID. |
| `competitionName` | string | SkillCorner Competition Name. |
| `seasonId` | integer | SkillCorner Season ID. |
| `seasonName` | string | SkillCorner Season Name. |
| `trackingLastProcessingDate` | datetime | Last processing datetime of the tracking data, in UTC (format: `YYYY-MM-DDTHH:MM:SSZ`). |
| `dynamicEventsLastProcessingDate` | datetime | Last processing datetime of the Dynamic Events, in UTC (format: `YYYY-MM-DDTHH:MM:SSZ`). |
| `physicalLastProcessingDate` | datetime | Last processing datetime of the physical (speed/load) data, in UTC (format: `YYYY-MM-DDTHH:MM:SSZ`). |
| `homeTeam.teamId` | integer | SkillCorner home team ID. |
| `homeTeam.teamName` | string | Home team name. |
| `homeTeam.players` | list[object] | List of the home team's players, see "Player object" below. |
| `awayTeam.teamId` | integer | SkillCorner away team ID. |
| `awayTeam.teamName` | string | Away team name. |
| `awayTeam.players` | list[object] | List of the away team's players, see "Player object" below. |

##### Player object (`homeTeam.players[i]` / `awayTeam.players[i]` entries)

| Field | Type | Definition |
|---|---|---|
| `playerId` | integer | SkillCorner Player ID. |
| `firstName` | string | Player first name. |
| `lastName` | string | Player last name. |
| `jersey` | string | Jersey number of the player. |

Player position is not published in `game_data.json`.

### reference-docs-data-dictionary-tracking-data-md

Local: [docs/data_dictionary/tracking_data.md](docs/data_dictionary/tracking_data.md) · Upstream: [docs/data_dictionary/tracking_data.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/tracking_data.md)

#### tracking_data

Broadcast optical tracking data for one game, delivered as `{gameId}_tracking_data.jsonl.gz` (gzip-compressed JSON Lines, one JSON object per "frame" of video). Each line gives the position of every tracked player and the ball at 25 frames per second, plus the game clock, shot clock and period at that instant. This is the raw spatial signal all Dynamic Events (chances, shots, picks, drives, etc.) are derived from.

**Grain:** one row per frame per game. **Join key:** `frameIdx` / `wallClock` / `gameClock` + `period` line up with the `frame` / `wallClock` / `gameClock` fields used across the event tables (picks, shots, drives, ...) to locate the tracking context of an event.

**Coordinate system:** all `xyz` coordinates are in feet, origin `(0, 0)` at the center of the court. See [Markings](docs/data_dictionary/README.md#markings--coordinate-system) for the shared court coordinate convention (also used by every `location` / `endLoc` field in the event tables).

**Dead time:** roughly half of all frames in a game (dead ball, warmups, breaks) carry empty `homePlayers`/`awayPlayers` arrays and an empty `ball` object, `{}`. Clock fields (`gameClock`, `shotClock`, `gameClockStopped`, `period`) stay populated on these rows, so the frame timeline itself is continuous even though player/ball data is not — don't assume every row has 10 players and a ball.

##### Top-level fields

| Field | Type | Definition |
|---|---|---|
| `frameIdx` | integer | Frame count (at 25fps) since the start of the video. |
| `wallClock` | integer | Time in ms since the start of the video. |
| `gameClock` | float | Game clock in seconds. 0 means the period is finished. |
| `gameClockStopped` | boolean | `true` if the game clock is stopped, `false` if the game clock is running. |
| `period` | integer | Number of the period (starts at 1, so the first quarter/period is 1). |
| `homePlayers` | list[object] | List of player positions at this frame for the home team. Empty on dead-time frames. See "Player object" below. |
| `awayPlayers` | list[object] | List of player positions at this frame for the away team. Empty on dead-time frames. See "Player object" below. |
| `ball` | object | Ball position at this frame. `{}` (empty object) on dead-time frames. See "Ball object" below. |
| `shotClock` | float | Shot clock in seconds. Can be `null` (e.g. before the first frontcourt possession of a period). |

##### Player object (`homePlayers` / `awayPlayers` entries)

| Field | Type | Definition |
|---|---|---|
| `xyz` | list[float] | Coordinate of the player in feet: x along the length of the court (left to right from the camera's point of view, 0 at court center); y along the width of the court (bottom to top from the camera's point of view, 0 at court center); z is height, currently always 0 (players are kept on the ground). |
| `speed` | float | Player speed in feet per second. |
| `jersey` | string | Jersey number of the player. |
| `playerId` | integer | SkillCorner Player ID. |
| `isDetected` | integer (0 or 1) | `1` if the player is on screen and detected by computer vision, `0` if the position is extrapolated. (Note the ball object below delivers the same flag as a float.) |
| `predError` | float | Expected error for the player's coordinate, in feet. In 90% of cases the tracking is within `predError` feet of ground truth. Across the 10 published games the mean is ~1.5-1.9 ft over all positions (95th percentile ~4.9-6.3 ft); detected positions average ~0.9 ft, extrapolated positions ~4.4-5.2 ft. |

##### Ball object

| Field | Type | Definition |
|---|---|---|
| `xyz` | list[float] | Coordinate of the ball in feet, same convention as the player `xyz` above; z (height) is a real height and can go slightly negative near the floor (calibration noise), not always positive. |
| `speed` | float | Ball speed in feet per second. |
| `isDetected` | float (0.0 or 1.0) | `1.0` if the ball is on screen and detected by computer vision, `0.0` if the position is extrapolated. Same meaning as the player-object `isDetected`, but delivered as a float here instead of an integer — normalize both to boolean on ingest if you need a consistent type. |
| `predError` | float | Expected error for the ball's coordinate, in feet. Ball calibration is not as accurate as player calibration. |

Delivered as gzip-compressed JSON Lines: each line of the decompressed file is one frame. Decompress with `gzip -d`, or read directly with `pandas.read_json(path, lines=True, compression="gzip")`.

### reference-docs-data-dictionary-possessions-md

Local: [docs/data_dictionary/possessions.md](docs/data_dictionary/possessions.md) · Upstream: [docs/data_dictionary/possessions.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/possessions.md)

#### possessions

A possession is the full continuous span of team control of the ball, from the moment a team gains it to the moment the other team gains it (a made or dead-ball turnover, defensive rebound, end of period). A possession can contain multiple `chances` when the offense grabs an offensive rebound and keeps the ball alive.

Join keys: `id` (primary key), `gameId`. `offPlayerIds` / `defPlayerIds` can include more than 5 players per team if there were in-possession substitutions.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the possession. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the possession. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the possession. | No |
| `startWallClock` | integer | Time in ms between the start of the possession and the start of the video. | No |
| `endWallClock` | integer | Time in ms between the end of the possession and the start of the video. | No |
| `startGameClock` | float | Game clock in seconds at the start of the possession. | No |
| `endGameClock` | float | Game clock in seconds at the end of the possession. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | Yes |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | Yes |
| `startType` | string | Event that starts the chance. One of<br>        - DEFOB: Defensive Out of Bounds<br>        - FGDRB: Field Goal Defensive RB<br>        - FGORB: Field Goal Offensive RB<br>        - FTDRB: Free Throw Defensive RB<br>        - FTORB: Free Throw Offensive RB<br>        - JMP: Jump Ball<br>        - TO: Live Ball Turnover<br>        - FTM: Free Throw Made<br>        - FGM: Field Goal Made | Yes |
| `outcome` | list[string] | Event that ends the chance. One of<br>        - FGM: Any made field goal<br>        - FGM3: Made 3 pointer<br>        - FGX: Any missed field goal<br>        - FGX3: Missed 3 pointer<br>        - TO: Turnover<br>        - VIO: Violation<br>        - JMP: Jump Ball<br>        - Out of Bounds<br>        - FOU: Foul<br>        - EPD: End of period | Yes |
| `offPlayerIds` | list[integer] | List of SkillCorner Player ID, for all players from the offensive team, on court at any time during the possession.<br>Can be more than 5 players if there are substitutions within the possession. | Yes |
| `defPlayerIds` | list[integer] | List of SkillCorner Player ID, for all players from the defensive team, on court at any time during the possession.<br>Can be more than 5 players if there are substitutions within the possession. | Yes |
| `homeStartScore` | integer | Home team score at the start of the possession. | Yes |
| `awayStartScore` | integer | Away team score at the start of the possession. | Yes |
| `ptsScored` | integer | Points scored in the possession. | Yes |
| `ballInPaint` | boolean | Boolean that determines if a player possess the ball in paint - either through dribbling, rebound or touch. | No |
| `endLoc` | list[float] | x, y location of the end of the possession. | No |
| `leftHoop` | boolean | True if the offensive team is shooting at the left broadcast hoop | No |

### reference-docs-data-dictionary-chances-md

Local: [docs/data_dictionary/chances.md](docs/data_dictionary/chances.md) · Upstream: [docs/data_dictionary/chances.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/chances.md)

#### chances

A chance is one continuous stretch of offense by a team that ends in a shot attempt, a turnover, a shooting foul, an end-of-period, or a jump ball. A new chance starts after an offensive rebound even though the ball did not change teams, so a single possession can contain several chances. This is the finest-grained scoring unit in the data: every shot, foul, turnover and rebound belongs to exactly one chance.

Join keys: `id` (primary key), `gameId`, `possessionId` (parent possession). `offPlayerIds` / `defPlayerIds` list the on-court roster for the chance and join to `game_data` player ids.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the chance. | No |
| `possessionId` | integer | SkillCorner id of the associated possession. | No |
| `gameId` | string | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the chance. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the chance. | No |
| `startWallClock` | integer | Time in ms between the start of the chance and the start of the video. | No |
| `endWallClock` | integer | Time in ms between the end of the chance and the start of the video. | No |
| `startGameClock` | float | Game clock in seconds at the start of the chance. | No |
| `endGameClock` | float | Game clock in seconds at the end of the chance. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | Yes |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | Yes |
| `startType` | string | Event that starts the chance. One of<br>        - DEFOB: Defensive Out of Bounds<br>        - FGDRB: Field Goal Defensive RB<br>        - FGORB: Field Goal Offensive RB<br>        - FTDRB: Free Throw Defensive RB<br>        - FTORB: Free Throw Offensive RB<br>        - JMP: Jump Ball<br>        - TO: Live Ball Turnover<br>        - FTM: Free Throw Made<br>        - FGM: Field Goal Made | Yes |
| `outcome` | string | Event that ends the chance. One of<br>        - FGM: Any made field goal<br>        - FGM3: Made 3 pointer<br>        - FGX: Any missed field goal<br>        - FGX3: Missed 3 pointer<br>        - TO: Turnover<br>        - VIO: Violation<br>        - JMP: Jump Ball<br>        - Out of Bounds<br>        - FOU: Foul<br>        - EPD: End of period | Yes |
| `offPlayerIds` | list[integer] | List of SkillCorner Player ID, for all players from the offensive team, on court during the chance. | Yes |
| `defPlayerIds` | list[integer] | List of SkillCorner Player ID, for all players from the defensive team, on court during the chance. | Yes |
| `homeStartScore` | integer | Home team score at the start of the chance. | Yes |
| `awayStartScore` | integer | Away team score at the start of the chance. | Yes |
| `ptsScored` | integer | Points scored in the chance. | Yes |
| `startShotClock` | float | Shot clock in seconds at the start of the chance. | No |
| `endShotClock` | float | Shot clock in seconds at the end of the chance. | No |
| `ballInPaint` | boolean | Boolean that determines if a player possess the ball in paint - either through dribbling, rebound or touch. | No |
| `endOfPossession` | boolean | True if the chance is the last one of the possession. False otherwise. | Yes |
| `endLoc` | list[float] | x, y location of the end of the chance. | No |
| `frontcourtFrame` | integer | First frame during the chance where the ball is possessed in the front court. | No |
| `transition` | boolean | True if the chance is a transition. False otherwise. | No |
| `lastChanceId` | string | SkillCorner chance ID of the previous chance. | No |
| `qualityIndex` | integer | SkillCorner quality index of the chance. Number between 0 (lowest quality) and 5 (highest quality). | No |
| `usable` | boolean | Boolean that is equal to true if qualityIndex is greater or equal to 3. | No |

### reference-docs-data-dictionary-chance-players-md

Local: [docs/data_dictionary/chance_players.md](docs/data_dictionary/chance_players.md) · Upstream: [docs/data_dictionary/chance_players.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/chance_players.md)

#### chance_players

One row per player per chance, recording whether the player was on offense or defense, their assigned matchup at the start and end of the chance, their location at shot release / at the rim / at the rebound (when applicable), and their cumulative minutes played entering the chance. This is the table to use for on-court participation and for joining tracking-derived matchup data to a chance.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`. `playerId`, `startMatchupId`, `endMatchupId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the touch. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | Yes |
| `possessionId` | string | SkillCorner id of the associated possession. | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `playerId` | integer | SkillCorner Player ID. | Yes |
| `offense` | boolean | 1 if player is in offense, 0 otherwise. | Yes |
| `startMatchupId` | integer | SkillCorner Player ID of the matchup player at the start of the chance (from the rotation). | No |
| `endMatchupId` | integer | SkillCorner Player ID of the matchup player at the end of the chance (from the rotation). | No |
| `shotLoc` | list[float] | x, y coordinate of the player at release of the shot. | No |
| `rimLoc` | list[float] | x, y coordinate of the player when the ball reaches the rim.  Null if no shot occurs. | No |
| `reboundLoc` | list[float] | x, y coordinate of the player at rebound. | No |
| `minutesPlayedBefore` | float | Minutes played by the player at the start of the chance | No |

### reference-docs-data-dictionary-matchups-md

Local: [docs/data_dictionary/matchups.md](docs/data_dictionary/matchups.md) · Upstream: [docs/data_dictionary/matchups.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/matchups.md)

#### matchups

Defensive matchup assignments over time: which defender is assigned to guard which offensive player, as a series of time intervals (`startFrame`/`endFrame`) within a chance. Multiple rows per chance when matchups switch mid-chance (e.g. after a screen).

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`. `defPlayerId`, `offPlayerId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the rotation. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `startGameClock` | float | Game clock in seconds at the start of the rotation. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the rotation. | No |
| `startWallClock` | integer | Time in ms between the start of the rotation and the start of the video. | No |
| `endGameClock` | float | Game clock in seconds at the end of the rotation. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the rotation. | No |
| `endWallClock` | integer | Time in ms between the end of the rotation and the start of the video. | No |
| `shotClock` | float | Number of seconds left on shot clock. | No |
| `defPlayerId` | integer | SkillCorner Defensive Player ID. | No |
| `offPlayerId` | integer | SkillCorner Offensive Player ID. | No |

### reference-docs-data-dictionary-shots-md

Local: [docs/data_dictionary/shots.md](docs/data_dictionary/shots.md) · Upstream: [docs/data_dictionary/shots.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/shots.md)

#### shots

Every field goal attempt, with the shooter's location and shot zone at release, the type of shot (catch-and-shoot, off-dribble, post, etc.), the contest level and closest defender, and the outcome (made/missed, assisted, blocked, fouled).

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId` (the touch the shot was taken from). `shooterId`, `passerId`, `blockerId`, `closestDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the shot. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of video of the release of the shot. | No |
| `startWallClock` | integer | Time in ms between the release of the shot and the start of the video. | No |
| `startGameClock` | float | Game clock in seconds at the release of the shot. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the shot. | No |
| `endWallClock` | integer | Time in ms between the end of the shot and the start of the video. | No |
| `endGameClock` | float | Game clock in seconds at the end of the shot. | No |
| `location` | list[float] | x, y coordinate of the shooter at the release of the shot. | No |
| `region` | string | Region of the shooter at the release of the shot. | No |
| `shotClock` | float | Number of seconds left on shot clock | No |
| `shooterId` | integer | SkillCorner Shooter Player ID. | Yes |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | Yes |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | Yes |
| `three` | boolean | true if the shot is a 3 points shot, false if it's a 2 point shot. | Yes |
| `outcome` | boolean | true if the shot is scored, false if it's missed. | Yes |
| `fouled` | boolean | true if the shot is fouled, false otherwise. | Yes |
| `foulId` | string | Skillcorner Foul ID if the shot has been fouled. | No |
| `assisted` | boolean | true if the shot is assisted, false otherwise. | Yes |
| `assistOpp` | boolean | true if the shot is assisted or is taken less than 3s after the reception of a pass, false otherwise. | No |
| `passerId` | string | SkillCorner Player ID of the player that passed to the shooter. Null if no passer before the shot. | Yes |
| `blocked` | boolean | true if the shot is blocked, false otherwise. | Yes |
| `blockerId` | integer | SkillCorner Blocker Player ID. | Yes |
| `distance` | float | Distance between the shooter and the hoop at time of release, in feet. | No |
| `dribblesBefore` | integer | Number of dribbles before the shot | No |
| `shotType` | string | Simple breakdown of the shot. <br>Possible values are: jumper, floater, layup, post, heave. | No |
| `complexShotType` | string | Advanced breakdown of the shot. <br>Possible values : floater,layup,heave,catchAndShoot,offMove,dribblePullUp,shakeAndRaise,stepback,leaner,postFadeaway,hook,lob,tip,dunk | No |
| `catchAndShoot` | boolean | true if releaseTime <= 1.5s OR complexShotType = 'catchAndShoot' | No |
| `createdFromPaint` | boolean | true if the shot comes directly from a touch in the paint or a dribble into paint and shoot or a pass from paint to shoot | No |
| `contested` | boolean | true if the shot has a contestLevel equal to average, plus or blocked | No |
| `contestLevel` | string | Defines the level of contest of a shot.<br>Possible values: open,light,average,plus,blocked | No |
| `releaseTime` | float | Number of seconds from the start of the touch to the shooter’s release | No |
| `shotQuality` | float | SkillCorner shot quality score for the attempt, on a 0-100 scale. Null on a small number of attempts the model could not score. | No |
| `closestDefDist` | float | Distance between the shooter and its closest defender at time of release, in feet. | No |
| `closestDefId` | string | SkillCorner Closest Defender Player ID. | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-free-throws-md

Local: [docs/data_dictionary/free_throws.md](docs/data_dictionary/free_throws.md) · Upstream: [docs/data_dictionary/free_throws.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/free_throws.md)

#### free_throws

Every free throw attempt, linked to the foul (and, if applicable, the shot) that awarded it, with the shooter and the make/miss outcome.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `foulId`, `shotId`. `shooterId` joins to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the free throw. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the free throw. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the free throw. | No |
| `wallClock` | integer | Time in ms between the free throw and the start of the video. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | Yes |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | Yes |
| `shooterId` | integer | SkillCorner Shooter Player ID. | Yes |
| `outcome` | boolean | 1 if the free throw is scored, 0 if it's missed. | Yes |
| `foulId` | string | SkillCorner Foul ID associated to this free_throw. | No |
| `shotId` | string | SkillCorner Shot ID if this free throw is associated to a foul on a shot. | No |

### reference-docs-data-dictionary-rebounds-md

Local: [docs/data_dictionary/rebounds.md](docs/data_dictionary/rebounds.md) · Upstream: [docs/data_dictionary/rebounds.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/rebounds.md)

#### rebounds

Every rebound opportunity following a missed field goal or free throw, flagging whether it was grabbed by a player or went out as a team rebound, and whether it was offensive or defensive.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `shotId`, `touchId`. `rebounderId` joins to player ids in `game_data`. `nextChanceId` points to the chance the rebound started (usable mainly for offensive rebounds).

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner Rebound ID. | No |
| `shotId` | string | SkillCorner Shot ID of the associated shot. | Yes |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the rebound. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the rebound. | No |
| `wallClock` | integer | Time in ms between the rebound and the start of the video. | No |
| `teamId` | integer | SkillCorner Team ID of the rebounder's team. | Yes |
| `rebounderId` | integer | SkillCorner Rebounder Player ID. | Yes |
| `fgReb` | boolean | 1 if the rebound comes after a shot, 0 if it comes after a free throw. | Yes |
| `rebounded` | boolean | 1 if the rebound was taken by a player, 0 if it's a team rebound (after a shot out of bound for instance) | Yes |
| `defensive` | boolean | 1 if defensive rebound. 0 if offensive. | Yes |
| `location` | list[float] | x, y coordinate of the rebounder. | No |
| `region` | string | Region of the rebounder. | No |
| `nextChanceId` | string | SkillCorner Chance ID of the next chance following the rebound. | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-turnovers-md

Local: [docs/data_dictionary/turnovers.md](docs/data_dictionary/turnovers.md) · Upstream: [docs/data_dictionary/turnovers.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/turnovers.md)

#### turnovers

Every live-ball and dead-ball turnover (steals, offensive fouls counted separately in `fouls`, shot-clock/backcourt/other violations), with the player who lost the ball and, for steals, the player who took it.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `turnedOverId`, `stealerId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the turnover. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `gameClock` | float | Game clock in seconds at the turnover. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the turnover. | No |
| `wallClock` | integer | Time in ms between the turnover and the start of the video. | No |
| `offTeamId` | integer | SkillCorner Team ID of the offensive team (the team that turn over the ball). | Yes |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | Yes |
| `turnedOverId` | integer | SkillCorner Player ID of the player who turned over the ball. | Yes |
| `stealerId` | string | SkillCorner Player ID of the player that steal the ball if it's a steal. | Yes |
| `teamId` | integer | SkillCorner Team ID of the team that turn over the ball. | Yes |
| `teamTo` | boolean | 1 if it's a team turnover (24s violation for instance). 0 otherwise. | Yes |
| `location` | list[float] | x, y coordinate of the stealer if it's a steal, otherwise x, y of the player that turnover the ball. | No |
| `region` | string | Region of the stealer if it's a steal, otherwise of the player that turnover the ball. | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-fouls-md

Local: [docs/data_dictionary/fouls.md](docs/data_dictionary/fouls.md) · Upstream: [docs/data_dictionary/fouls.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/fouls.md)

#### fouls

Every personal, technical, offensive and flagrant foul, with the fouler and the fouled player, whether it happened on a shot, whether the fouled team was in the bonus, and the foul type.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`, `shotId`. `foulerId`, `fouledId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the foul. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the foul. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the foul. | No |
| `wallClock` | integer | Time in ms between the foul and the start of the video. | No |
| `foulerId` | integer | SkillCorner Player ID of the player that has committed the foul. | Yes |
| `fouledId` | integer | SkillCorner Player ID of the player that has been fouled. | Yes |
| `foulerTeamId` | integer | SkillCorner Team ID of the team of the player that has committed the foul. | Yes |
| `fouledTeamId` | integer | SkillCorner Team ID of the team of player that has been fouled. | Yes |
| `shooting` | boolean | 1 if the foul happens during a shot, 0 otherwise. | Yes |
| `location` | list[float] | x, y coordinate of the fouler. | No |
| `region` | string | Region of the fouler. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | Yes |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | Yes |
| `foulType` | string | Define the foul type. | Yes |
| `isBonus` | boolean | Define if the opposing team is a bonus situation. | Yes |
| `isTeam` | boolean | Define if the foul is a team foul. | Yes |
| `isTechnical` | boolean | Define if the foul is a technical foul. | Yes |
| `touchId` | string | SkillCorner Touch ID. | No |
| `shotId` | string | SkillCorner Shot ID if foul associated foul happened during a shot. | No |

### reference-docs-data-dictionary-timeouts-md

Local: [docs/data_dictionary/timeouts.md](docs/data_dictionary/timeouts.md) · Upstream: [docs/data_dictionary/timeouts.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/timeouts.md)

#### timeouts

Every timeout called, with the team and the game clock at the time.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`. `teamId` joins to the team ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the timeout. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the timeout. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the timeout. | No |
| `wallClock` | integer | Time in ms between the timeout and the start of the video. | No |
| `teamId` | string | SkillCorner Team ID of the team that calls the timeout. | Yes |

### reference-docs-data-dictionary-passes-md

Local: [docs/data_dictionary/passes.md](docs/data_dictionary/passes.md) · Upstream: [docs/data_dictionary/passes.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/passes.md)

#### passes

Every pass attempt, complete or not, with the passer's and receiver's (or intended receiver's) location and court region at release, whether it led to a shot or an assist opportunity, and whether it was a turnover.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `passerId`, `receiverId` / `toReceiverId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the pass. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the release of the pass. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the reception of the pass. | No |
| `startWallClock` | integer | Time in ms between the release of the pass and the start of the video. | No |
| `endWallClock` | integer | Time in ms between the reception of the pass and the start of the video. | No |
| `startGameClock` | float | Game clock in seconds at the release of the pass. | No |
| `endGameClock` | float | Game clock in seconds at the reception of the pass. | No |
| `shotClock` | float | Number of seconds left on shot clock. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `passerId` | integer | SkillCorner Passer Player ID. | No |
| `receiverId` | integer | SkillCorner Player ID of the receiver if the pass is not turned over. | No |
| `toReceiverId` | integer | SkillCorner Player ID of the **defender who intercepted the pass**, populated only when the pass is turned over (null otherwise). Despite the name, it is not the intended receiver — treat it as "who took the ball away", not "who the pass was meant for". | No |
| `complete` | boolean | 1 if the pass is complete, 0 otherwise. | No |
| `turnover` | boolean | 1 if the pass is turned over, 0 otherwise. | No |
| `ledToShot` | boolean | 1 if the receiver takes a shot in the touch following the pass. | No |
| `assistOpp` | boolean | 1 if the receiver takes a shot in the touch following the pass and within 3s after the reception. | No |
| `inbounds` | boolean | 1 if the pass is a throw-in from a game clock stopped, 0 otherwise. | No |
| `backcourt` | boolean | 1 if the passer is backcourt when releasing the pass, 0 otherwise. | No |
| `passerLoc` | list[float] | x, y coordinate of the passer at the release of the pass. | No |
| `receiverLoc` | list[float] | x, y coordinate of the receiver at the release of the pass. | No |
| `passerRegion` | string | Region of the passer at the release of the pass. | No |
| `receiverRegion` | string | Region of the receiver at the release of the pass. | No |
| `distance` | float | Distance in feet between passerLoc and receiverLoc | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-touches-md

Local: [docs/data_dictionary/touches.md](docs/data_dictionary/touches.md) · Upstream: [docs/data_dictionary/touches.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/touches.md)

#### touches

Every continuous ball possession by a single player (from gaining control to losing it), with duration, number of dribbles, start/end location, the defender assigned at the start of the touch, and a list of `outcomes` (pass, shot made/missed, assist, foul, turnover, timeout, etc.). Touches are the reference event for the `outcomes` / `bhrOutcomes` / `scrOutcomes` enum used across picks, drives, handoffs, isolations, posts, off-ball screens and closeouts.

Join keys: `id` (primary key, referenced as `touchId` elsewhere), `gameId`, `chanceId`, `possessionId`. `playerId`, `defenderId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the touch. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the touch. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the touch. | No |
| `startWallClock` | integer | Time in ms between the start of the touch and the start of the video. | No |
| `endWallClock` | integer | Time in ms between the end of the touch and the start of the video. | No |
| `startGameClock` | float | Game clock in seconds at the start of the touch. | No |
| `endGameClock` | float | Game clock in seconds at the end of the touch. | No |
| `shotClock` | float | Number of seconds left on shot clock. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `playerId` | integer | SkillCorner Player ID. | No |
| `defenderId` | integer | SkillCorner Defender Player ID. <br>Defender is the player assigned to the player in the rotation at the start if a rotation exist (ball is frontcourt).<br>Otherwise, it's the closest player in average for the duration of the touch. | No |
| `closestDefLoc` | list[float] | x, y coordinate of the defender at the start of the touch. | No |
| `location` | list[float] | x, y coordinate of the player at the start of the touch. | No |
| `endLoc` | list[float] | x, y coordinate of the player at the end of the touch. | No |
| `numDribbles` | integer | Number of dribbles occuring during the touch | No |
| `ledToShot` | boolean | 1 if the player has taken a shot within the touch, 0 otherwise. | No |
| `touchTime` | float | Duration of the touch in seconds. | No |
| `outcomes` | list[string] | Outcome by the ballhandler. List of items from:<br>- PASS: Pass<br>- PASS_SCR: Pass to screener (on picks & handoffs)<br>- FGM: Field goal made<br>- FGM3: Made 3 pointer<br>- FGX: Missed field goal<br>- FGX3: Missed 3 pointer<br>- BLK: Blocked shot<br>- FOUL: Foul<br>- AST: Assist (pass made to a teammate who took the shot within one dribble)<br>- AST3: Assist for a three pointer<br>- AST2: Assist for a two pointer<br>- AST0: Assist opportunity missed by the teammate<br>- ASTF: Assist opportunity ending with teammate fouled during shot<br>- TO: Turnover<br>- FOUL: Any foul<br>- FOU_S: Shooting Foul<br>- FOU_T: Technical foul<br>- FOU_F: Flagrant Foul<br>- FOU_B: Foul in the bonus<br>- FOU_N: Personal foul that is neither shooting nor in the bonus<br>- FOU_O: Offensive Foul<br>- TMO: Timeout | No |
| `regionsIn` | list[string] | List of the region of the player during the touch. | No |
| `endClosestDefLoc` | list[float] | x, y coordinate of the defender at the end of the touch. | No |
| `direct` | boolean | True if the ballhandler shoots, is fouled and shoots free throws, turns the ball over, or if they pass to another player who shoots within one dribble of receiving the ball. | No |

### reference-docs-data-dictionary-dribbles-md

Local: [docs/data_dictionary/dribbles.md](docs/data_dictionary/dribbles.md) · Upstream: [docs/data_dictionary/dribbles.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/dribbles.md)

#### dribbles

Individual dribble events, one row per dribble, nested inside a `touches` row. Gives the ball handler's location and court region at each dribble.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `ballhandlerId` joins to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the dribble | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the dribble. | No |
| `frame` | integer | Frame (at 25fps) of the dribble | No |
| `wallClock` | integer | Time in ms between the dribble and the start of the video. | No |
| `ballhandlerId` | integer | SkillCorner Ball Handler Player ID. | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `location` | list[float] | x, y coordinate of the ball handler. | No |
| `region` | string | Region of the ball handler. | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-picks-md

Local: [docs/data_dictionary/picks.md](docs/data_dictionary/picks.md) · Upstream: [docs/data_dictionary/picks.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/picks.md)

#### picks

On-ball screen (pick-and-roll / pick-and-pop) events: the ball handler, the screener, both of their defenders, the defensive coverage called on each (e.g. `ice`, `switch`, `blitz`, `drop`-equivalent `scrDefType` values), and the outcome for both players after the pick.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `ballhandlerId`, `screenerId`, `ballhandlerDefId`, `screenerDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the pick. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the pick. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the pick. | No |
| `wallClock` | integer | Time in ms between the pick and the start of the video. | No |
| `direct` | boolean | 1 if ball handler or screener shot, assist or is fouled directly after the pick. 0 otherwise. | No |
| `location` | list[float] | x, y coordinate of the screener. | No |
| `region` | string | Region of the screener. | No |
| `shotClock` | float | Number of seconds left on shot clock | No |
| `ballhandlerId` | integer | SkillCorner Ball Handler Player ID. | No |
| `screenerId` | integer | SkillCorner Screener Player ID. | No |
| `ballhandlerDefId` | integer | SkillCorner Player ID of the ballhandler's defender (the one before the pick if there's a switch). | No |
| `screenerDefId` | integer | SkillCorner Player ID of the screener's defender (the one before the pick if there's a switch). | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `locationType` | string | Locaiton type of the pick. Can be wing, middle, stepUp | No |
| `bhrDefType` | string | Defense type on ball handler. One of none, ice, switch, over, blitz, under. | No |
| `scrDefType` | string | Defense type on screener. One of none, ice, soft, switch, blitz, show. | No |
| `bhrOutcomes` | list[string] | List of actions involving the ball handler following the pick, within the same chance. See outcomes definitions in touches. | No |
| `scrOutcomes` | list[string] | List of actions involving the screener following the pick, within the same chance. See outcomes definitions in touches. | No |
| `handoffPick` | boolean | Boolean assessing if the event was a combination of a handoff and a pick | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-handoffs-md

Local: [docs/data_dictionary/handoffs.md](docs/data_dictionary/handoffs.md) · Upstream: [docs/data_dictionary/handoffs.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/handoffs.md)

#### handoffs

Dribble hand-off events between a setter (who hands the ball off) and a receiver, mirroring the structure of `picks` (defensive coverage on each player, location type, whether it combined with a pick).

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `setterId`, `receiverId`, `setterDefId`, `receiverDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the handoff. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | No |
| `gameClock` | float | Game clock in seconds at the handoff. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the handoff. | No |
| `wallClock` | integer | Time in ms between the handoff and the start of the video. | No |
| `direct` | boolean | 1 if receiver or setter shot, assist or is fouled directly after the handoff. 0 otherwise. | No |
| `location` | list[float] | x, y coordinate of the setter. | No |
| `region` | string | Region of the setter. | No |
| `shotClock` | float | Number of seconds left on shot clock | No |
| `receiverId` | integer | SkillCorner Receiver Player ID. | No |
| `setterId` | integer | SkillCorner Setter Player ID. | No |
| `receiverDefId` | integer | SkillCorner Player ID of the receiver's defender (the one before the handoff if there's a switch). | No |
| `setterDefId` | integer | SkillCorner Player ID of the setter's defender (the one before the handoff if there's a switch). | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `locationType` | string | Locaiton type of the handoff. Can be wing, middle, stepUp | No |
| `receiverDefType` | string | Defense type on receiver. One of over, ice, under, switch. | No |
| `setterDefType` | string | Defense type on setter. One of none, ice, soft, switch. | No |
| `bhrOutcomes` | list[string] | List of actions involving the receiver following the handoff, within the same chance. See outcomes definitions in touches. | No |
| `handoffPick` | boolean | Boolean assessing if the event was a combination of a handoff and a pick | No |
| `touchId` | string | SkillCorner Touch ID | No |

### reference-docs-data-dictionary-off-ball-screens-md

Local: [docs/data_dictionary/off_ball_screens.md](docs/data_dictionary/off_ball_screens.md) · Upstream: [docs/data_dictionary/off_ball_screens.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/off_ball_screens.md)

#### off_ball_screens

Screens set away from the ball to free a cutter, mirroring the structure of `picks` (screener, cutter, both defenders, defensive coverage on each, and outcomes for both players).

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`. `touchId` links to the cutter's touch, `scrTouchId` to the screener's touch. `cutterId`, `screenerId`, `cutterDefId`, `screenerDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the off ball screen. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `gameClock` | float | Game clock in seconds at the off ball screen. | No |
| `frame` | integer | Frame (at 25fps) since the start of the video of the off ball screen. | No |
| `wallClock` | integer | Time in ms between the off ball screen and the start of the video. | No |
| `direct` | boolean | 1 if cutter or screener shot, assist or is fouled directly after the screen. 0 otherwise. | No |
| `location` | list[float] | x, y coordinate of the screener. | No |
| `region` | string | Region of the screener. | No |
| `shotClock` | float | Number of seconds left on shot clock | No |
| `cutterId` | integer | SkillCorner Cutter Player ID. | No |
| `screenerId` | integer | SkillCorner Screener Player ID. | No |
| `cutterDefId` | integer | SkillCorner Player ID of the cutter's defender (the one before the screen if there's a switch). | No |
| `screenerDefId` | integer | SkillCorner Player ID of the screener's defender (the one before the screen if there's a switch). | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `cutterDefType` | string | Defense type on cutter. One of none, trail, switch, whip, ride, top lock. | No |
| `screenerDefType` | string | Defense type on screener. One of none, switch, drop, show, jam. | No |
| `outcomes` | list[string] | List of actions involving the cutter following the screen, within the same chance. See outcomes definitions in touches. | No |
| `ledToTouch` | boolean | 1 if the cutter has a touch less than 4 seconds after the screen, 0 otherwise. | No |
| `ledToShot` | boolean | 1 if the cutter takes a shot less than 6 seconds after the screen, 0 otherwise. | No |
| `scrOutcomes` | list[string] | List of actions involving the screener following the pick, within the same chance. See outcomes definitions in touches. | No |
| `touchId` | string | SkillCorner Touch ID | No |
| `scrTouchId` | string | SkillCorner Screener Touch ID | No |

### reference-docs-data-dictionary-drives-md

Local: [docs/data_dictionary/drives.md](docs/data_dictionary/drives.md) · Upstream: [docs/data_dictionary/drives.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/drives.md)

#### drives

Dribble-drive events toward the basket: how the drive was created (`category`: off a pick, handoff, off-ball screen, isolation, closeout, or miscellaneous), the direction taken, whether the ball handler blew by the defender, and how the drive ended (`endType`: kick-out, pull-up, interior pass, shot near the basket, turnover, pull-out).

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `ballhandlerId`, `ballhandlerDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the drive | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `startGameClock` | float | Game clock in seconds at the start of the drive. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the drive. | No |
| `startWallClock` | integer | Time in ms between the start of the drive and the start of the video. | No |
| `endGameClock` | float | Game clock in seconds at the end of the drive. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the drive. | No |
| `endWallClock` | integer | Time in ms between the end of the drive and the start of the video. | No |
| `direct` | boolean | True if the drive ends with a shoot, a foul, a turnover or a direct shoot following a pass from the driver | No |
| `location` | list | Location of the start of the drive | No |
| `region` | string | Region of the drive at the start of the drive | No |
| `endLoc` | list | Location at the end of the drive | No |
| `shotClock` | float | Shot clock in seconds at the start of the drive. | No |
| `ballhandlerId` | integer | SkillCorner Ball Handler Player ID. | No |
| `ballhandlerDefId` | integer | SkillCorner Player ID of the ball handler's defender | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `category` | string | Defines how the drives started.<br>Possible values: pick, handoff, offBallScreen, iso, closeout, miscellaneous | No |
| `blowby` | boolean | Boolean stating if the driver blew by his defender | No |
| `endType` | string | Define how the drive ended. Possible values: kickout,turnover,pullout,pullup,interiorPass,shotNearBasket | No |
| `direction` | string | Direction the driver took, left or right. | No |
| `bhrOutcomes` | list | Outcomes achieved by the Ball Handler. See outcomes definitions in touches. | No |
| `dribbleThrough` | boolean | Boolean. True if the driver dribbles through the key. | No |
| `touchId` | string | SkillCorner ID of the associated touch | No |

### reference-docs-data-dictionary-isolations-md

Local: [docs/data_dictionary/isolations.md](docs/data_dictionary/isolations.md) · Upstream: [docs/data_dictionary/isolations.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/isolations.md)

#### isolations

One-on-one isolation plays: a ball handler attacking their primary defender without a screen, with start/end location and the outcome achieved by the ball handler.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `ballhandlerId`, `ballhandlerDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the isolation | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1} | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `startGameClock` | float | Game clock in seconds at the start of the isolation. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the isolation. | No |
| `startWallClock` | integer | Time in ms between the start of the isolation and the start of the video. | No |
| `endGameClock` | float | Game clock in seconds at the end of the isolation. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the isolation. | No |
| `endWallClock` | integer | Time in ms between the end of the isolation and the start of the video. | No |
| `direct` | boolean | True if the isolation ends with a shoot, a foul, a turnover or a direct shoot following a pass from the ball handler | No |
| `location` | list | Location of the start of the isolation. | No |
| `region` | string | Region at the start of the isolation. | No |
| `endLoc` | list | Location at the end of the isolation. | No |
| `shotClock` | float | Shot clock in seconds at the start of the isolation. | No |
| `ballhandlerId` | integer | SkillCorner Ball Handler Player ID. | No |
| `ballhandlerDefId` | integer | SkillCorner Player ID of the ball handler's defender | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `bhrOutcomes` | list | Outcomes achieved by the Ball Handler. See outcomes definitions in touches. | No |
| `touchId` | string | SkillCorner ID of the associated touch | No |

### reference-docs-data-dictionary-posts-md

Local: [docs/data_dictionary/posts.md](docs/data_dictionary/posts.md) · Upstream: [docs/data_dictionary/posts.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/posts.md)

#### posts

Post-up plays: a ball handler establishing and working from the post, with the court section (left, middle, right), whether they dribbled into the post-up versus caught it near the block, and the outcome.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `ballhandlerId`, `ballhandlerDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the post. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1}. | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `startGameClock` | float | Game clock in seconds at the start of the post. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the post. | No |
| `startWallClock` | integer | Time in ms between the start of the post and the start of the video. | No |
| `endGameClock` | float | Game clock in seconds at the end of the post. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the post. | No |
| `endWallClock` | integer | Time in ms between the end of the post and the start of the video. | No |
| `direct` | boolean | True if the post ends with a shoot, a foul, a turnover or a direct shoot following a pass from the ball handler | No |
| `location` | list | Location of the start of the post. | No |
| `region` | string | Region at the start of the post. | No |
| `endLoc` | list | Location at the end of the post. | No |
| `shotClock` | float | Shot clock in seconds at the start of the post. | No |
| `ballhandlerId` | integer | SkillCorner Ball Handler Player ID. | No |
| `ballhandlerDefId` | integer | SkillCorner Player ID of the ball handler's defender | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `bhrOutcomes` | list | Outcomes achieved by the Ball Handler. See outcomes definitions in touches. | No |
| `section` | string | Section of the court where the post occured. Possible values : left, middle, right | No |
| `dribbledInto` | boolean | True if the ball handler dribbles into the postup instead of catching near the block | No |
| `touchId` | string | SkillCorner ID of the associated touch | No |

### reference-docs-data-dictionary-closeouts-md

Local: [docs/data_dictionary/closeouts.md](docs/data_dictionary/closeouts.md) · Upstream: [docs/data_dictionary/closeouts.md](https://github.com/SkillCorner/opendata-basketball/blob/main/docs/data_dictionary/closeouts.md)

#### closeouts

Defensive closeout events: a defender running out to contest a ball handler who just caught the ball, with the defender's location and the ball handler-defender distance at three checkpoints (start of the touch, start of the closeout, end of the closeout), and what the ball handler did after the catch.

Join keys: `id` (primary key), `gameId`, `chanceId`, `possessionId`, `touchId`. `ballhandlerId`, `ballhandlerDefId` join to player ids in `game_data`.

| Field | Type | Definition | PBP derived |
|---|---|---|---|
| `id` | string | SkillCorner id of the closeout. | No |
| `gameId` | integer | SkillCorner Game ID. | Yes |
| `season` | string | Season depending on format of the competition, either {year} or {year}-{year+1}. | Yes |
| `chanceId` | string | SkillCorner id of the associated chance. | No |
| `possessionId` | string | SkillCorner id of the associated possession. | No |
| `period` | integer | Number of the period (starts at 1 so the first quarter/period is 1). | Yes |
| `touchGameClock` | float | Game clock in seconds at the start of the touch. | No |
| `touchFrame` | integer | Frame (at 25fps) since the start of the video of the start of the touch. | No |
| `touchWallClock` | integer | Time in ms between the start of the touch and the start of the video. | No |
| `startGameClock` | float | Game clock in seconds at the start of the closeout. | No |
| `startFrame` | integer | Frame (at 25fps) since the start of the video of the start of the closeout. | No |
| `startWallClock` | integer | Time in ms between the start of the closeout and the start of the video. | No |
| `endGameClock` | float | Game clock in seconds at the end of the closeout. | No |
| `endFrame` | integer | Frame (at 25fps) since the start of the video of the end of the closeout. | No |
| `endWallClock` | integer | Time in ms between the end of the closeout and the start of the video. | No |
| `direct` | boolean | True if the closeout ends with a shoot, a foul, a turnover or a direct shoot following a pass from the ball handler | No |
| `location` | list | Location of the ball handler at the start of the touch. | No |
| `region` | string | Region at the start of the touch. | No |
| `startLoc` | list | Defender's location at the start of the closeout. | No |
| `endLoc` | list | Defender's location at the end of the closeout. | No |
| `touchLoc` | list | Defender's location at the start of the touch. | No |
| `startDistance` | float | Distance between the ball handler and his defender at the start of the closeout. | No |
| `touchDistance` | float | Distance between the ball handler and his defender at the start of the touch. | No |
| `endDistance` | float | Distance between the ball handler and his defender at the end of the closeout. | No |
| `ballhandlerId` | integer | SkillCorner Ball Handler Player ID. | No |
| `ballhandlerDefId` | integer | SkillCorner Player ID of the ball handler's defender | No |
| `offTeamId` | integer | SkillCorner Offensive Team ID. | No |
| `defTeamId` | integer | SkillCorner Defensive Team ID. | No |
| `bhrOutcomes` | list | Outcomes achieved by the Ball Handler. See outcomes definitions in touches. | No |
| `bhrAction` | string | Ball handler action after the catch. Possible values: shot, drive, pass, other. | No |
| `touchId` | string | SkillCorner ID of the associated touch. | No |

## Exact aggregate column inventory

These are the complete published CSV headers in delivered order, not inferred column names. Counts were checked against the CSVs at the reviewed upstream commit. Descriptions, metric families, rate denominators, role/zone/coverage mappings, and always-null columns appear in the full aggregate reference above. On a changed local release, compare headers and document the difference.


### acb_shotsaggregates_20252026.csv

Local: `data/aggregates/acb_shotsaggregates_20252026.csv`. 326 rows; 308 columns. One column name per line, in file order.

```text
competition_id
competition_name
season_id
season_name
player_id
player_name
team_id
team_name
games_played
attempts
three_attempts
two_attempts
mades
three_mades
two_mades
fouled_fg_attempts
fouled_fg_mades
total_points
assisted_mades
blocked_on_attempts
avg_attempts_distance
cns_attempts
cns_three_attempts
cns_two_attempts
cns_mades
cns_three_mades
cns_two_mades
cns_total_points
od_attempts
od_three_attempts
od_two_attempts
od_mades
od_three_mades
od_two_mades
od_total_points
contested_attempts
contested_three_attempts
contested_two_attempts
contested_mades
contested_three_mades
contested_two_mades
contested_total_points
uncontested_attempts
uncontested_three_attempts
uncontested_two_attempts
uncontested_mades
uncontested_three_mades
uncontested_two_mades
uncontested_total_points
zone_restricted_area_attempts
zone_restricted_area_mades
zone_restricted_area_misses
zone_restricted_area_total_points
zone_paint_non_ra_attempts
zone_paint_non_ra_mades
zone_paint_non_ra_misses
zone_paint_non_ra_total_points
zone_mid_range_attempts
zone_mid_range_mades
zone_mid_range_misses
zone_mid_range_total_points
zone_corner_3_attempts
zone_corner_3_mades
zone_corner_3_misses
zone_corner_3_total_points
zone_above_break_3_attempts
zone_above_break_3_mades
zone_above_break_3_misses
zone_above_break_3_total_points
zone_backcourt_attempts
zone_backcourt_mades
zone_backcourt_misses
zone_backcourt_total_points
zone_far_attempts
zone_far_mades
zone_far_misses
zone_far_total_points
zone_other_attempts
zone_other_mades
zone_other_misses
zone_other_total_points
cl_average_attempts
cl_average_mades
cl_average_misses
cl_average_total_points
cl_blocked_attempts
cl_blocked_mades
cl_blocked_misses
cl_blocked_total_points
cl_light_attempts
cl_light_mades
cl_light_misses
cl_light_total_points
cl_open_attempts
cl_open_mades
cl_open_misses
cl_open_total_points
cl_plus_attempts
cl_plus_mades
cl_plus_misses
cl_plus_total_points
cst_catch_and_shoot_attempts
cst_catch_and_shoot_mades
cst_catch_and_shoot_misses
cst_catch_and_shoot_total_points
cst_dribble_pull_up_attempts
cst_dribble_pull_up_mades
cst_dribble_pull_up_misses
cst_dribble_pull_up_total_points
cst_dunk_attempts
cst_dunk_mades
cst_dunk_misses
cst_dunk_total_points
cst_floater_attempts
cst_floater_mades
cst_floater_misses
cst_floater_total_points
cst_heave_attempts
cst_heave_mades
cst_heave_misses
cst_heave_total_points
cst_hook_attempts
cst_hook_mades
cst_hook_misses
cst_hook_total_points
cst_layup_attempts
cst_layup_mades
cst_layup_misses
cst_layup_total_points
cst_leaner_attempts
cst_leaner_mades
cst_leaner_misses
cst_leaner_total_points
cst_lob_attempts
cst_lob_mades
cst_lob_misses
cst_lob_total_points
cst_off_move_attempts
cst_off_move_mades
cst_off_move_misses
cst_off_move_total_points
cst_post_fadeaway_attempts
cst_post_fadeaway_mades
cst_post_fadeaway_misses
cst_post_fadeaway_total_points
cst_shake_and_raise_attempts
cst_shake_and_raise_mades
cst_shake_and_raise_misses
cst_shake_and_raise_total_points
cst_stepback_attempts
cst_stepback_mades
cst_stepback_misses
cst_stepback_total_points
cst_tip_attempts
cst_tip_mades
cst_tip_misses
cst_tip_total_points
ft_attempts
ft_mades
cns_ft_attempts
cns_ft_mades
od_ft_attempts
od_ft_mades
contested_ft_attempts
contested_ft_mades
uncontested_ft_attempts
uncontested_ft_mades
fg_percentage
two_pt_percentage
three_pt_percentage
ft_percentage
efg_percentage
fouled_fg_percentage
points_per_shot
three_pa_rate
cns_fg_percentage
cns_two_fg_percentage
cns_three_fg_percentage
cns_efg_percentage
cns_points_per_shot
cns_attempt_rate
od_fg_percentage
od_two_fg_percentage
od_three_fg_percentage
od_efg_percentage
od_points_per_shot
od_attempt_rate
contested_fg_percentage
contested_two_fg_percentage
contested_three_fg_percentage
contested_efg_percentage
contested_points_per_shot
contested_attempt_rate
uncontested_fg_percentage
uncontested_two_fg_percentage
uncontested_three_fg_percentage
uncontested_efg_percentage
uncontested_points_per_shot
uncontested_attempt_rate
cl_average_fg_percentage
cl_average_attempt_rate
cl_average_points_per_shot
cl_blocked_fg_percentage
cl_blocked_attempt_rate
cl_blocked_points_per_shot
cl_light_fg_percentage
cl_light_attempt_rate
cl_light_points_per_shot
cl_open_fg_percentage
cl_open_attempt_rate
cl_open_points_per_shot
cl_plus_fg_percentage
cl_plus_attempt_rate
cl_plus_points_per_shot
cst_catch_and_shoot_fg_percentage
cst_catch_and_shoot_attempt_rate
cst_catch_and_shoot_points_per_shot
cst_dribble_pull_up_fg_percentage
cst_dribble_pull_up_attempt_rate
cst_dribble_pull_up_points_per_shot
cst_dunk_fg_percentage
cst_dunk_attempt_rate
cst_dunk_points_per_shot
cst_floater_fg_percentage
cst_floater_attempt_rate
cst_floater_points_per_shot
cst_heave_fg_percentage
cst_heave_attempt_rate
cst_heave_points_per_shot
cst_hook_fg_percentage
cst_hook_attempt_rate
cst_hook_points_per_shot
cst_layup_fg_percentage
cst_layup_attempt_rate
cst_layup_points_per_shot
cst_leaner_fg_percentage
cst_leaner_attempt_rate
cst_leaner_points_per_shot
cst_lob_fg_percentage
cst_lob_attempt_rate
cst_lob_points_per_shot
cst_off_move_fg_percentage
cst_off_move_attempt_rate
cst_off_move_points_per_shot
cst_post_fadeaway_fg_percentage
cst_post_fadeaway_attempt_rate
cst_post_fadeaway_points_per_shot
cst_shake_and_raise_fg_percentage
cst_shake_and_raise_attempt_rate
cst_shake_and_raise_points_per_shot
cst_stepback_fg_percentage
cst_stepback_attempt_rate
cst_stepback_points_per_shot
cst_tip_fg_percentage
cst_tip_attempt_rate
cst_tip_points_per_shot
rim_attempts
rim_mades
rim_fg_percentage
rim_attempt_rate
short_midrange_paint_attempts
short_midrange_paint_mades
short_midrange_paint_fg_percentage
short_midrange_paint_attempt_rate
long_midrange_attempts
long_midrange_mades
long_midrange_fg_percentage
long_midrange_attempt_rate
zone_three_attempts
zone_three_mades
zone_three_fg_percentage
zone_three_attempt_rate
zone_corner_3_left_attempts
zone_corner_3_left_mades
zone_corner_3_left_misses
zone_corner_3_left_total_points
zone_corner_3_left_fg_percentage
zone_corner_3_left_attempt_rate
zone_corner_3_left_points_per_shot
zone_corner_3_right_attempts
zone_corner_3_right_mades
zone_corner_3_right_misses
zone_corner_3_right_total_points
zone_corner_3_right_fg_percentage
zone_corner_3_right_attempt_rate
zone_corner_3_right_points_per_shot
zone_top_3_attempts
zone_top_3_mades
zone_top_3_misses
zone_top_3_total_points
zone_top_3_fg_percentage
zone_top_3_attempt_rate
zone_top_3_points_per_shot
zone_wing_3_left_attempts
zone_wing_3_left_mades
zone_wing_3_left_misses
zone_wing_3_left_total_points
zone_wing_3_left_fg_percentage
zone_wing_3_left_attempt_rate
zone_wing_3_left_points_per_shot
zone_wing_3_right_attempts
zone_wing_3_right_mades
zone_wing_3_right_misses
zone_wing_3_right_total_points
zone_wing_3_right_fg_percentage
zone_wing_3_right_attempt_rate
zone_wing_3_right_points_per_shot
possessions_played
```

### acb_drivesaggregates_20252026.csv

Local: `data/aggregates/acb_drivesaggregates_20252026.csv`. 301 rows; 71 columns. One column name per line, in file order.

```text
competition_id
competition_name
season_id
season_name
player_id
player_name
team_id
team_name
games_played
total_drives
direct_drives_count
blowby_count
dribble_through_count
end_type_kickout_count
end_type_turnover_count
end_type_pullout_count
end_type_pullup_count
end_type_interior_pass_count
end_type_stoppage_count
end_type_shot_near_basket_count
zone_mid_range_count
zone_corner_3_count
zone_above_break_3_count
direction_left_count
direction_right_count
category_iso_count
category_off_ball_screen_count
category_pick_count
category_handoff_count
category_closeout_count
category_miscellaneous_count
points
made_baskets
assists
potential_assists
fouls
successful_drives
unsuccessful_drives
field_points_in_drive
fga_in_drive
ft_attempts_in_drive
ft_mades_in_drive
blowby_rate
dribble_through_rate
end_type_kickout_rate
end_type_turnover_rate
end_type_pullout_rate
end_type_pullup_rate
end_type_interior_pass_rate
end_type_stoppage_rate
end_type_shot_near_basket_rate
zone_mid_range_rate
zone_corner_3_rate
zone_above_break_3_rate
direction_left_rate
direction_right_rate
category_iso_rate
category_off_ball_screen_rate
category_pick_rate
category_handoff_rate
category_closeout_rate
category_miscellaneous_rate
points_per_drive
made_baskets_rate
assists_rate
potential_assists_rate
fouls_rate
successful_drives_rate
unsuccessful_drives_rate
points_per_shot_in_drive
possessions_played
```

### acb_picksaggregates_20252026.csv

Local: `data/aggregates/acb_picksaggregates_20252026.csv`. 319 rows; 684 columns. One column name per line, in file order.

```text
competition_id
competition_name
season_id
season_name
player_id
player_name
team_id
team_name
games_played
handler_total_picks
handler_score
handler_score_2pt
handler_score_3pt
handler_miss
handler_miss_2pt
handler_miss_3pt
handler_assist
handler_assist_2pt
handler_assist_3pt
handler_assist_to_screener
handler_assist_to_other
handler_assist_opportunity
handler_assist_opportunity_to_screener
handler_assist_opportunity_to_other
handler_turnover
handler_foul
handler_block
handler_pass
handler_pass_to_screener
handler_pass_to_other
handler_successful_pick
handler_unsuccessful_pick
handler_shot_taken
handler_only_pass_pick
handler_no_outcome_pick
handler_points
handler_score_vs_blitz
handler_score_vs_ice
handler_score_vs_over
handler_score_vs_switch
handler_score_vs_under
handler_score_2pt_vs_blitz
handler_score_2pt_vs_ice
handler_score_2pt_vs_over
handler_score_2pt_vs_switch
handler_score_2pt_vs_under
handler_score_3pt_vs_blitz
handler_score_3pt_vs_ice
handler_score_3pt_vs_over
handler_score_3pt_vs_switch
handler_score_3pt_vs_under
handler_miss_vs_blitz
handler_miss_vs_ice
handler_miss_vs_over
handler_miss_vs_switch
handler_miss_vs_under
handler_miss_2pt_vs_blitz
handler_miss_2pt_vs_ice
handler_miss_2pt_vs_over
handler_miss_2pt_vs_switch
handler_miss_2pt_vs_under
handler_miss_3pt_vs_blitz
handler_miss_3pt_vs_ice
handler_miss_3pt_vs_over
handler_miss_3pt_vs_switch
handler_miss_3pt_vs_under
handler_assist_vs_blitz
handler_assist_vs_ice
handler_assist_vs_over
handler_assist_vs_switch
handler_assist_vs_under
handler_assist_2pt_vs_blitz
handler_assist_2pt_vs_ice
handler_assist_2pt_vs_over
handler_assist_2pt_vs_switch
handler_assist_2pt_vs_under
handler_assist_3pt_vs_blitz
handler_assist_3pt_vs_ice
handler_assist_3pt_vs_over
handler_assist_3pt_vs_switch
handler_assist_3pt_vs_under
handler_assist_to_screener_vs_blitz
handler_assist_to_screener_vs_ice
handler_assist_to_screener_vs_over
handler_assist_to_screener_vs_switch
handler_assist_to_screener_vs_under
handler_assist_to_other_vs_blitz
handler_assist_to_other_vs_ice
handler_assist_to_other_vs_over
handler_assist_to_other_vs_switch
handler_assist_to_other_vs_under
handler_assist_opportunity_vs_blitz
handler_assist_opportunity_vs_ice
handler_assist_opportunity_vs_over
handler_assist_opportunity_vs_switch
handler_assist_opportunity_vs_under
handler_assist_opportunity_to_screener_vs_blitz
handler_assist_opportunity_to_screener_vs_ice
handler_assist_opportunity_to_screener_vs_over
handler_assist_opportunity_to_screener_vs_switch
handler_assist_opportunity_to_screener_vs_under
handler_assist_opportunity_to_other_vs_blitz
handler_assist_opportunity_to_other_vs_ice
handler_assist_opportunity_to_other_vs_over
handler_assist_opportunity_to_other_vs_switch
handler_assist_opportunity_to_other_vs_under
handler_turnover_vs_blitz
handler_turnover_vs_ice
handler_turnover_vs_over
handler_turnover_vs_switch
handler_turnover_vs_under
handler_foul_vs_blitz
handler_foul_vs_ice
handler_foul_vs_over
handler_foul_vs_switch
handler_foul_vs_under
handler_block_vs_blitz
handler_block_vs_ice
handler_block_vs_over
handler_block_vs_switch
handler_block_vs_under
handler_pass_vs_blitz
handler_pass_vs_ice
handler_pass_vs_over
handler_pass_vs_switch
handler_pass_vs_under
handler_pass_to_screener_vs_blitz
handler_pass_to_screener_vs_ice
handler_pass_to_screener_vs_over
handler_pass_to_screener_vs_switch
handler_pass_to_screener_vs_under
handler_pass_to_other_vs_blitz
handler_pass_to_other_vs_ice
handler_pass_to_other_vs_over
handler_pass_to_other_vs_switch
handler_pass_to_other_vs_under
handler_successful_pick_vs_blitz
handler_successful_pick_vs_ice
handler_successful_pick_vs_over
handler_successful_pick_vs_switch
handler_successful_pick_vs_under
handler_unsuccessful_pick_vs_blitz
handler_unsuccessful_pick_vs_ice
handler_unsuccessful_pick_vs_over
handler_unsuccessful_pick_vs_switch
handler_unsuccessful_pick_vs_under
handler_shot_taken_vs_blitz
handler_shot_taken_vs_ice
handler_shot_taken_vs_over
handler_shot_taken_vs_switch
handler_shot_taken_vs_under
handler_only_pass_pick_vs_blitz
handler_only_pass_pick_vs_ice
handler_only_pass_pick_vs_over
handler_only_pass_pick_vs_switch
handler_only_pass_pick_vs_under
handler_no_outcome_pick_vs_blitz
handler_no_outcome_pick_vs_ice
handler_no_outcome_pick_vs_over
handler_no_outcome_pick_vs_switch
handler_no_outcome_pick_vs_under
handler_points_vs_blitz
handler_points_vs_ice
handler_points_vs_over
handler_points_vs_switch
handler_points_vs_under
handler_picks_vs_blitz
handler_picks_vs_ice
handler_picks_vs_over
handler_picks_vs_switch
handler_picks_vs_under
handler_score_at_middle
handler_score_at_stepUp
handler_score_at_unknown
handler_score_at_wing
handler_points_at_middle
handler_points_at_stepUp
handler_points_at_unknown
handler_points_at_wing
handler_miss_at_middle
handler_miss_at_stepUp
handler_miss_at_unknown
handler_miss_at_wing
handler_assist_at_middle
handler_assist_at_stepUp
handler_assist_at_unknown
handler_assist_at_wing
handler_turnover_at_middle
handler_turnover_at_stepUp
handler_turnover_at_unknown
handler_turnover_at_wing
handler_picks_at_middle
handler_picks_at_stepUp
handler_picks_at_unknown
handler_picks_at_wing
handler_field_points_in_pick
handler_fga_in_pick
handler_ft_attempts_in_pick
handler_ft_mades_in_pick
screener_total_picks
screener_score
screener_score_2pt
screener_score_3pt
screener_miss
screener_miss_2pt
screener_miss_3pt
screener_assist
screener_assist_2pt
screener_assist_3pt
screener_assist_to_screener
screener_assist_to_other
screener_assist_opportunity
screener_assist_opportunity_to_screener
screener_assist_opportunity_to_other
screener_turnover
screener_foul
screener_block
screener_pass
screener_pass_to_screener
screener_pass_to_other
screener_successful_pick
screener_unsuccessful_pick
screener_shot_taken
screener_only_pass_pick
screener_no_outcome_pick
screener_points
screener_score_vs_blitz
screener_score_vs_ice
screener_score_vs_show
screener_score_vs_soft
screener_score_vs_switch
screener_score_2pt_vs_blitz
screener_score_2pt_vs_ice
screener_score_2pt_vs_show
screener_score_2pt_vs_soft
screener_score_2pt_vs_switch
screener_score_3pt_vs_blitz
screener_score_3pt_vs_ice
screener_score_3pt_vs_show
screener_score_3pt_vs_soft
screener_score_3pt_vs_switch
screener_miss_vs_blitz
screener_miss_vs_ice
screener_miss_vs_show
screener_miss_vs_soft
screener_miss_vs_switch
screener_miss_2pt_vs_blitz
screener_miss_2pt_vs_ice
screener_miss_2pt_vs_show
screener_miss_2pt_vs_soft
screener_miss_2pt_vs_switch
screener_miss_3pt_vs_blitz
screener_miss_3pt_vs_ice
screener_miss_3pt_vs_show
screener_miss_3pt_vs_soft
screener_miss_3pt_vs_switch
screener_assist_vs_blitz
screener_assist_vs_ice
screener_assist_vs_show
screener_assist_vs_soft
screener_assist_vs_switch
screener_assist_2pt_vs_blitz
screener_assist_2pt_vs_ice
screener_assist_2pt_vs_show
screener_assist_2pt_vs_soft
screener_assist_2pt_vs_switch
screener_assist_3pt_vs_blitz
screener_assist_3pt_vs_ice
screener_assist_3pt_vs_show
screener_assist_3pt_vs_soft
screener_assist_3pt_vs_switch
screener_assist_to_screener_vs_blitz
screener_assist_to_screener_vs_ice
screener_assist_to_screener_vs_show
screener_assist_to_screener_vs_soft
screener_assist_to_screener_vs_switch
screener_assist_to_other_vs_blitz
screener_assist_to_other_vs_ice
screener_assist_to_other_vs_show
screener_assist_to_other_vs_soft
screener_assist_to_other_vs_switch
screener_assist_opportunity_vs_blitz
screener_assist_opportunity_vs_ice
screener_assist_opportunity_vs_show
screener_assist_opportunity_vs_soft
screener_assist_opportunity_vs_switch
screener_assist_opportunity_to_screener_vs_blitz
screener_assist_opportunity_to_screener_vs_ice
screener_assist_opportunity_to_screener_vs_show
screener_assist_opportunity_to_screener_vs_soft
screener_assist_opportunity_to_screener_vs_switch
screener_assist_opportunity_to_other_vs_blitz
screener_assist_opportunity_to_other_vs_ice
screener_assist_opportunity_to_other_vs_show
screener_assist_opportunity_to_other_vs_soft
screener_assist_opportunity_to_other_vs_switch
screener_turnover_vs_blitz
screener_turnover_vs_ice
screener_turnover_vs_show
screener_turnover_vs_soft
screener_turnover_vs_switch
screener_foul_vs_blitz
screener_foul_vs_ice
screener_foul_vs_show
screener_foul_vs_soft
screener_foul_vs_switch
screener_block_vs_blitz
screener_block_vs_ice
screener_block_vs_show
screener_block_vs_soft
screener_block_vs_switch
screener_pass_vs_blitz
screener_pass_vs_ice
screener_pass_vs_show
screener_pass_vs_soft
screener_pass_vs_switch
screener_pass_to_screener_vs_blitz
screener_pass_to_screener_vs_ice
screener_pass_to_screener_vs_show
screener_pass_to_screener_vs_soft
screener_pass_to_screener_vs_switch
screener_pass_to_other_vs_blitz
screener_pass_to_other_vs_ice
screener_pass_to_other_vs_show
screener_pass_to_other_vs_soft
screener_pass_to_other_vs_switch
screener_successful_pick_vs_blitz
screener_successful_pick_vs_ice
screener_successful_pick_vs_show
screener_successful_pick_vs_soft
screener_successful_pick_vs_switch
screener_unsuccessful_pick_vs_blitz
screener_unsuccessful_pick_vs_ice
screener_unsuccessful_pick_vs_show
screener_unsuccessful_pick_vs_soft
screener_unsuccessful_pick_vs_switch
screener_shot_taken_vs_blitz
screener_shot_taken_vs_ice
screener_shot_taken_vs_show
screener_shot_taken_vs_soft
screener_shot_taken_vs_switch
screener_only_pass_pick_vs_blitz
screener_only_pass_pick_vs_ice
screener_only_pass_pick_vs_show
screener_only_pass_pick_vs_soft
screener_only_pass_pick_vs_switch
screener_no_outcome_pick_vs_blitz
screener_no_outcome_pick_vs_ice
screener_no_outcome_pick_vs_show
screener_no_outcome_pick_vs_soft
screener_no_outcome_pick_vs_switch
screener_points_vs_blitz
screener_points_vs_ice
screener_points_vs_show
screener_points_vs_soft
screener_points_vs_switch
screener_picks_vs_blitz
screener_picks_vs_ice
screener_picks_vs_show
screener_picks_vs_soft
screener_picks_vs_switch
screener_score_at_middle
screener_score_at_stepUp
screener_score_at_unknown
screener_score_at_wing
screener_points_at_middle
screener_points_at_stepUp
screener_points_at_unknown
screener_points_at_wing
screener_miss_at_middle
screener_miss_at_stepUp
screener_miss_at_unknown
screener_miss_at_wing
screener_assist_at_middle
screener_assist_at_stepUp
screener_assist_at_unknown
screener_assist_at_wing
screener_turnover_at_middle
screener_turnover_at_stepUp
screener_turnover_at_unknown
screener_turnover_at_wing
screener_picks_at_middle
screener_picks_at_stepUp
screener_picks_at_unknown
screener_picks_at_wing
screener_field_points_in_pick
screener_fga_in_pick
screener_ft_attempts_in_pick
screener_ft_mades_in_pick
handler_ppp
handler_score_rate
handler_turnover_rate
handler_assist_rate
handler_points_per_pick_vs_blitz
handler_points_per_pick_vs_ice
handler_points_per_pick_vs_over
handler_points_per_pick_vs_switch
handler_points_per_pick_vs_under
handler_score_rate_vs_blitz
handler_score_rate_vs_ice
handler_score_rate_vs_over
handler_score_rate_vs_switch
handler_score_rate_vs_under
handler_ppp_at_middle
handler_ppp_at_stepUp
handler_ppp_at_unknown
handler_ppp_at_wing
handler_score_rate_at_middle
handler_score_rate_at_stepUp
handler_score_rate_at_unknown
handler_score_rate_at_wing
handler_pick_rate_at_middle
handler_pick_rate_at_stepUp
handler_pick_rate_at_unknown
handler_pick_rate_at_wing
handler_points_per_shot_in_pick
screener_ppp
screener_score_rate
screener_turnover_rate
screener_assist_rate
screener_points_per_pick_vs_blitz
screener_points_per_pick_vs_ice
screener_points_per_pick_vs_show
screener_points_per_pick_vs_soft
screener_points_per_pick_vs_switch
screener_score_rate_vs_blitz
screener_score_rate_vs_ice
screener_score_rate_vs_show
screener_score_rate_vs_soft
screener_score_rate_vs_switch
screener_ppp_at_middle
screener_ppp_at_stepUp
screener_ppp_at_unknown
screener_ppp_at_wing
screener_score_rate_at_middle
screener_score_rate_at_stepUp
screener_score_rate_at_unknown
screener_score_rate_at_wing
screener_pick_rate_at_middle
screener_pick_rate_at_stepUp
screener_pick_rate_at_unknown
screener_pick_rate_at_wing
screener_points_per_shot_in_pick
handler_success_rate
handler_assist_rate_vs_blitz
handler_assist_rate_vs_ice
handler_assist_rate_vs_over
handler_assist_rate_vs_switch
handler_assist_rate_vs_under
screener_success_rate
screener_assist_rate_vs_blitz
screener_assist_rate_vs_ice
screener_assist_rate_vs_show
screener_assist_rate_vs_soft
screener_assist_rate_vs_switch
handler_assist_2pt_pct
handler_assist_3pt_pct
handler_assist_opportunity_pct
handler_assist_opportunity_rate
handler_assist_to_other_pct
handler_assist_to_screener_pct
handler_block_pct
handler_foul_pct
handler_no_outcome_pick_pct
handler_only_pass_pick_pct
handler_pass_to_other_pct
handler_pass_to_screener_pct
handler_shot_taken_pct
handler_successful_pick_pct
handler_unsuccessful_pick_pct
handler_turnover_rate_vs_blitz
handler_turnover_rate_vs_ice
handler_turnover_rate_vs_over
handler_turnover_rate_vs_switch
handler_turnover_rate_vs_under
handler_assist_2pt_pct_vs_blitz
handler_assist_2pt_pct_vs_ice
handler_assist_2pt_pct_vs_over
handler_assist_2pt_pct_vs_switch
handler_assist_2pt_pct_vs_under
handler_assist_3pt_pct_vs_blitz
handler_assist_3pt_pct_vs_ice
handler_assist_3pt_pct_vs_over
handler_assist_3pt_pct_vs_switch
handler_assist_3pt_pct_vs_under
handler_assist_opportunity_pct_vs_blitz
handler_assist_opportunity_pct_vs_ice
handler_assist_opportunity_pct_vs_over
handler_assist_opportunity_pct_vs_switch
handler_assist_opportunity_pct_vs_under
handler_assist_to_other_pct_vs_blitz
handler_assist_to_other_pct_vs_ice
handler_assist_to_other_pct_vs_over
handler_assist_to_other_pct_vs_switch
handler_assist_to_other_pct_vs_under
handler_assist_to_screener_pct_vs_blitz
handler_assist_to_screener_pct_vs_ice
handler_assist_to_screener_pct_vs_over
handler_assist_to_screener_pct_vs_switch
handler_assist_to_screener_pct_vs_under
handler_block_pct_vs_blitz
handler_block_pct_vs_ice
handler_block_pct_vs_over
handler_block_pct_vs_switch
handler_block_pct_vs_under
handler_foul_pct_vs_blitz
handler_foul_pct_vs_ice
handler_foul_pct_vs_over
handler_foul_pct_vs_switch
handler_foul_pct_vs_under
handler_no_outcome_pick_pct_vs_blitz
handler_no_outcome_pick_pct_vs_ice
handler_no_outcome_pick_pct_vs_over
handler_no_outcome_pick_pct_vs_switch
handler_no_outcome_pick_pct_vs_under
handler_only_pass_pick_pct_vs_blitz
handler_only_pass_pick_pct_vs_ice
handler_only_pass_pick_pct_vs_over
handler_only_pass_pick_pct_vs_switch
handler_only_pass_pick_pct_vs_under
handler_pass_to_other_pct_vs_blitz
handler_pass_to_other_pct_vs_ice
handler_pass_to_other_pct_vs_over
handler_pass_to_other_pct_vs_switch
handler_pass_to_other_pct_vs_under
handler_pass_to_screener_pct_vs_blitz
handler_pass_to_screener_pct_vs_ice
handler_pass_to_screener_pct_vs_over
handler_pass_to_screener_pct_vs_switch
handler_pass_to_screener_pct_vs_under
handler_shot_taken_pct_vs_blitz
handler_shot_taken_pct_vs_ice
handler_shot_taken_pct_vs_over
handler_shot_taken_pct_vs_switch
handler_shot_taken_pct_vs_under
handler_successful_pick_pct_vs_blitz
handler_successful_pick_pct_vs_ice
handler_successful_pick_pct_vs_over
handler_successful_pick_pct_vs_switch
handler_successful_pick_pct_vs_under
handler_unsuccessful_pick_pct_vs_blitz
handler_unsuccessful_pick_pct_vs_ice
handler_unsuccessful_pick_pct_vs_over
handler_unsuccessful_pick_pct_vs_switch
handler_unsuccessful_pick_pct_vs_under
screener_assist_2pt_pct
screener_assist_3pt_pct
screener_assist_opportunity_pct
screener_assist_opportunity_rate
screener_assist_to_other_pct
screener_assist_to_screener_pct
screener_block_pct
screener_foul_pct
screener_no_outcome_pick_pct
screener_only_pass_pick_pct
screener_pass_to_other_pct
screener_pass_to_screener_pct
screener_shot_taken_pct
screener_successful_pick_pct
screener_unsuccessful_pick_pct
screener_turnover_rate_vs_blitz
screener_turnover_rate_vs_ice
screener_turnover_rate_vs_show
screener_turnover_rate_vs_soft
screener_turnover_rate_vs_switch
screener_assist_2pt_pct_vs_blitz
screener_assist_2pt_pct_vs_ice
screener_assist_2pt_pct_vs_show
screener_assist_2pt_pct_vs_soft
screener_assist_2pt_pct_vs_switch
screener_assist_3pt_pct_vs_blitz
screener_assist_3pt_pct_vs_ice
screener_assist_3pt_pct_vs_show
screener_assist_3pt_pct_vs_soft
screener_assist_3pt_pct_vs_switch
screener_assist_opportunity_pct_vs_blitz
screener_assist_opportunity_pct_vs_ice
screener_assist_opportunity_pct_vs_show
screener_assist_opportunity_pct_vs_soft
screener_assist_opportunity_pct_vs_switch
screener_assist_to_other_pct_vs_blitz
screener_assist_to_other_pct_vs_ice
screener_assist_to_other_pct_vs_show
screener_assist_to_other_pct_vs_soft
screener_assist_to_other_pct_vs_switch
screener_assist_to_screener_pct_vs_blitz
screener_assist_to_screener_pct_vs_ice
screener_assist_to_screener_pct_vs_show
screener_assist_to_screener_pct_vs_soft
screener_assist_to_screener_pct_vs_switch
screener_block_pct_vs_blitz
screener_block_pct_vs_ice
screener_block_pct_vs_show
screener_block_pct_vs_soft
screener_block_pct_vs_switch
screener_foul_pct_vs_blitz
screener_foul_pct_vs_ice
screener_foul_pct_vs_show
screener_foul_pct_vs_soft
screener_foul_pct_vs_switch
screener_no_outcome_pick_pct_vs_blitz
screener_no_outcome_pick_pct_vs_ice
screener_no_outcome_pick_pct_vs_show
screener_no_outcome_pick_pct_vs_soft
screener_no_outcome_pick_pct_vs_switch
screener_only_pass_pick_pct_vs_blitz
screener_only_pass_pick_pct_vs_ice
screener_only_pass_pick_pct_vs_show
screener_only_pass_pick_pct_vs_soft
screener_only_pass_pick_pct_vs_switch
screener_pass_to_other_pct_vs_blitz
screener_pass_to_other_pct_vs_ice
screener_pass_to_other_pct_vs_show
screener_pass_to_other_pct_vs_soft
screener_pass_to_other_pct_vs_switch
screener_pass_to_screener_pct_vs_blitz
screener_pass_to_screener_pct_vs_ice
screener_pass_to_screener_pct_vs_show
screener_pass_to_screener_pct_vs_soft
screener_pass_to_screener_pct_vs_switch
screener_shot_taken_pct_vs_blitz
screener_shot_taken_pct_vs_ice
screener_shot_taken_pct_vs_show
screener_shot_taken_pct_vs_soft
screener_shot_taken_pct_vs_switch
screener_successful_pick_pct_vs_blitz
screener_successful_pick_pct_vs_ice
screener_successful_pick_pct_vs_show
screener_successful_pick_pct_vs_soft
screener_successful_pick_pct_vs_switch
screener_unsuccessful_pick_pct_vs_blitz
screener_unsuccessful_pick_pct_vs_ice
screener_unsuccessful_pick_pct_vs_show
screener_unsuccessful_pick_pct_vs_soft
screener_unsuccessful_pick_pct_vs_switch
handler_fg2_pct
handler_fg2_pct_vs_blitz
handler_fg2_pct_vs_ice
handler_fg2_pct_vs_over
handler_fg2_pct_vs_switch
handler_fg2_pct_vs_under
handler_fg3_pct
handler_fg3_pct_vs_blitz
handler_fg3_pct_vs_ice
handler_fg3_pct_vs_over
handler_fg3_pct_vs_switch
handler_fg3_pct_vs_under
handler_shot_rate_2pt
handler_shot_rate_2pt_vs_blitz
handler_shot_rate_2pt_vs_ice
handler_shot_rate_2pt_vs_over
handler_shot_rate_2pt_vs_switch
handler_shot_rate_2pt_vs_under
handler_shot_rate_3pt
handler_shot_rate_3pt_vs_blitz
handler_shot_rate_3pt_vs_ice
handler_shot_rate_3pt_vs_over
handler_shot_rate_3pt_vs_switch
handler_shot_rate_3pt_vs_under
screener_fg2_pct
screener_fg2_pct_vs_blitz
screener_fg2_pct_vs_ice
screener_fg2_pct_vs_show
screener_fg2_pct_vs_soft
screener_fg2_pct_vs_switch
screener_fg3_pct
screener_fg3_pct_vs_blitz
screener_fg3_pct_vs_ice
screener_fg3_pct_vs_show
screener_fg3_pct_vs_soft
screener_fg3_pct_vs_switch
screener_shot_rate_2pt
screener_shot_rate_2pt_vs_blitz
screener_shot_rate_2pt_vs_ice
screener_shot_rate_2pt_vs_show
screener_shot_rate_2pt_vs_soft
screener_shot_rate_2pt_vs_switch
screener_shot_rate_3pt
screener_shot_rate_3pt_vs_blitz
screener_shot_rate_3pt_vs_ice
screener_shot_rate_3pt_vs_show
screener_shot_rate_3pt_vs_soft
screener_shot_rate_3pt_vs_switch
possessions_played
```

## Match manifest and alias map

These small supplied reference files identify the sample games and player aliases. They are included as metadata/schema references; leave source files unchanged. `matches.json` uses snake_case metadata keys, whereas per-game metadata uses camelCase. `id` in the match list maps to `gameId` elsewhere; nested team `id` maps to roster `teamId`. An `acb_player_id` in the alias map is supplied metadata, not an instruction to fetch external data.

### matches.json

Local: [data/matches.json](data/matches.json).

```json
[
  {
    "id": 114243,
    "date_time": "2025-10-11T19:00:00Z",
    "home_team": {
      "id": 1330,
      "name": "BAXI Manresa"
    },
    "away_team": {
      "id": 1319,
      "name": "Coviran Granada"
    },
    "home_score": 83,
    "away_score": 68,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 114234,
    "date_time": "2025-10-18T19:00:00Z",
    "home_team": {
      "id": 1331,
      "name": "Casademont Zaragoza"
    },
    "away_team": {
      "id": 1322,
      "name": "Leche Rio Breogan"
    },
    "home_score": 84,
    "away_score": 88,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 114169,
    "date_time": "2025-12-14T11:30:00Z",
    "home_team": {
      "id": 1334,
      "name": "CB UCAM Murcia"
    },
    "away_team": {
      "id": 1336,
      "name": "Club Joventut Badalona"
    },
    "home_score": 80,
    "away_score": 77,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 114099,
    "date_time": "2026-01-31T20:00:00Z",
    "home_team": {
      "id": 1315,
      "name": "Basquet Girona"
    },
    "away_team": {
      "id": 1316,
      "name": "San Pablo Burgos"
    },
    "home_score": 77,
    "away_score": 71,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 114086,
    "date_time": "2026-02-08T17:00:00Z",
    "home_team": {
      "id": 1328,
      "name": "Dreamland Gran Canaria"
    },
    "away_team": {
      "id": 1326,
      "name": "Bitci Baskonia"
    },
    "home_score": 75,
    "away_score": 97,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 178442,
    "date_time": "2026-03-21T18:00:00Z",
    "home_team": {
      "id": 1332,
      "name": "BC MoraBanc Andorra"
    },
    "away_team": {
      "id": 1335,
      "name": "Bilbao Basket"
    },
    "home_score": 98,
    "away_score": 102,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 179612,
    "date_time": "2026-04-12T10:30:00Z",
    "home_team": {
      "id": 1339,
      "name": "Malaga"
    },
    "away_team": {
      "id": 1325,
      "name": "Valencia BC"
    },
    "home_score": 89,
    "away_score": 96,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 184439,
    "date_time": "2026-04-19T17:00:00Z",
    "home_team": {
      "id": 1338,
      "name": "Real Madrid"
    },
    "away_team": {
      "id": 1333,
      "name": "Lenovo Tenerife"
    },
    "home_score": 90,
    "away_score": 95,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 188630,
    "date_time": "2026-05-03T17:00:00Z",
    "home_team": {
      "id": 1340,
      "name": "BC Barcelona"
    },
    "away_team": {
      "id": 1328,
      "name": "Dreamland Gran Canaria"
    },
    "home_score": 91,
    "away_score": 69,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  },
  {
    "id": 191313,
    "date_time": "2026-05-29T18:30:00Z",
    "home_team": {
      "id": 1322,
      "name": "Leche Rio Breogan"
    },
    "away_team": {
      "id": 1331,
      "name": "Casademont Zaragoza"
    },
    "home_score": 94,
    "away_score": 95,
    "competition_id": 8,
    "competition_name": "Liga ACB",
    "season_id": 51,
    "competition_edition_id": 211,
    "season": "2025-2026",
    "status": "closed"
  }
]
```

### player_id_aliases.csv

Local: [data/player_id_aliases.csv](data/player_id_aliases.csv).

```csv
player_id,player_name,canonical_player_id,canonical_player_name,acb_player_id
59129,Nihad Djedovic,59129,Nihad Djedovic,20202039
59237,Nihad Dedovic,59129,Nihad Djedovic,20202039
92815,Alejandro REYES,59180,Alex Reyes,20204133
59180,Alex Reyes,59180,Alex Reyes,20204133
32852,Ruben Lopez,32852,Ruben Lopez,30000132
59094,De La Torre Ruben Lopez,32852,Ruben Lopez,30000132
27976,Christ Koumadje,27976,Christ Koumadje,30000550
94602,Khalifa KOUMADJE,27976,Christ Koumadje,30000550
11247,Kameron Milton Allante Taylor,11247,Kameron Milton Allante Taylor,30001981
446,Kameron Taylor,11247,Kameron Milton Allante Taylor,30001981
58436,Derek Ryan Needham,58436,Derek Ryan Needham,30003946
58625,Derek Needham,58436,Derek Ryan Needham,30003946
84394,Pepe Vildoza,59187,Jose Ignacio Vildoza,30003990
59187,Jose Ignacio Vildoza,59187,Jose Ignacio Vildoza,30003990
83339,Josep Perez,35554,Jassel Perez,30005191
35554,Jassel Perez,35554,Jassel Perez,30005191
22915,Isaiah Washington,22915,Isaiah Washington,30005207
84388,Dandre Washington,22915,Isaiah Washington,30005207
```

## Upstream attribution and license

Documentation, schemas, and supplied reference metadata in the preceding appendices come from SkillCorner's open basketball repository at the reviewed commit. Credit SkillCorner in project materials. Preserve its copyright and permission notice when reusing substantial portions of the documentation/code. The competition submission must exclude the competition datasets, regardless of the upstream repository being public.

The repository contains `LICENSE`; the submission asks for `LICENSE.md`. Preserve the upstream notice and provide a clearly scoped license for new project code when packaging the submission. Do not imply that a code license overrides competition data restrictions or a later finalist EULA.

Local upstream license: [LICENSE](LICENSE). Upstream: [LICENSE](https://github.com/SkillCorner/opendata-basketball/blob/main/LICENSE).

```text
The MIT License

Copyright (c) 2026 SkillCorner. https://skillcorner.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
