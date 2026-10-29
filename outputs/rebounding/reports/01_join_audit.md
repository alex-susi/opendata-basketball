# Step 01: join audit of the rebound episode table

Rebounding manual revision 2026-10-29, Step 01. Run 2026-10-29 with `Rscript src/rebounding/run_step01.R`.
Decision: **PASS**, with two checks changed after the first run (listed under Deviations). Machine-readable record:
`outputs/rebounding/gate_results/01_episodes.json`. Every number below comes from a file in `outputs/rebounding/step01/`.

## What the table is

`rebound_episodes.csv` has one row per non-fouled missed field goal (742), keyed by `episode_id` (the shot id).
703 are eligible. The target is the credited rebound of the miss, in 12 classes: the ten players on court, or a team
award to the offence or to the defence. The estimand is conditional on the miss. Each row carries:

- the release, endFrame, contact-proxy, touch-proxy, control-proxy and rebound frames, and the game clock at release
  and at the rebound;
- the attack direction (`left_hoop`, `flip`) and the credited outcome, with the rebound's side taken from `teamId`
  (`side_by_flag` keeps the delivered `defensive` flag for comparison);
- the ten tracked players at release and at the rebound frame, with their roster and chance checks;
- ball and player coverage over release to rebound, order flags, `identity_suspect`, and the exclusion reason.

The frame-by-entity tracking table of the episode windows (`tracking_frames.csv.gz`, camera frame, one row per frame,
entity and quality field) and a frame index of every tracking line (`frame_index.csv.gz`) are written to
`outputs/cache/rebounding/processed/`. They are git-ignored because they are the supplied tracking data. Gzip CSV
stands in for the manual's parquet: an arrow build for R 4.4 cannot be restored from CRAN binaries.

## Joins and keys

| Check | Result |
| --- | --- |
| `episode_id` unique; `(game_id, rebound_event_id)` unique | 0 duplicates each |
| Eligible episodes with a rebound row | 703 of 703 |
| Rebound rows pointing at a made or fouled shot; shots with two rebound rows | 0; 0 |
| Event frames without a tracking line; wallClock or period mismatches at the frame | 0; 0; 0 |
| Largest event-vs-tracking gameClock gap | 0.0005 s (events keep milliseconds) |

The event-level enumeration behind these numbers (1,459 shots, 768 rebound rows, free-throw rebounds outside the
population, and 14 team awards where the delivered `defensive` flag is wrong) is the earlier Gate 0 audit
(`outputs/rebounding/gate0/`). Step 01 reuses it rather than repeating it.

## Timing order

No eligible episode has its rebound at or before release. The four rows that do are tip sequences, where the rebound of
the previous miss is linked to the tip; they are excluded. The flags below are kept on eligible episodes:

| Flag | Eligible episodes |
| --- | --- |
| `no_contact_found` (no rim or board contact in the track) | 76 |
| `rebound_before_shot_end` (blocks, quick rebounds at the rim) | 21 |
| `rebound_before_contact_proxy` | 12 |
| `contact_not_after_release` (contact proxy within a frame of release) | 4 |

## Identity

All 703 eligible episodes have 5 + 5 tracked players at release. None is off the roster or on the wrong team, and all
703 match the chance's `chance_players`. All 630 credited player rebounders are tracked on court at the rebound frame.
No eligible window has a substitution between release and rebound. Slot lists come only from tracking rows: game
178442's shot 4-138, which is excluded, keeps its 9 tracked players and is not padded to ten. 33 player rebounds are
flagged `identity_suspect` (the credited player never comes within 3 ft of the ball) and kept, because the official
credit is the target.

## Orientation

One 180° rotation per shot, chosen from `possessions.leftHoop`, is applied to the ball and all ten players. Applying
it twice restores the camera coordinates exactly (largest error 0 ft over every window row).

| Evidence (`orientation.csv`) | Attacks camera-right (flip +1) | Attacks camera-left (flip −1) |
| --- | --- | --- |
| Misses with a tracked ball at endFrame | 376 | 364 |
| Ball comes nearer the attacked hoop than the other hoop | 100% | 100% |
| Median shooter gap to −`shots.location` at release | 0.0 ft | 0.0 ft |
| Defenders in the attacked half at release (mean of 5) | 4.97 | 4.92 |
| Ball at endFrame within 6 ft of the attacked hoop (prespecified, superseded) | 96.3% | 94.5% |

## Quality by stage

Retained episodes, pooled over the ten games (`quality_by_game_stage.csv` has each game).

| Stage | Ball keyframes (0.015 ft rule) | Ball keyframes (0.001 ft rule) | Ball predError (ft) | Players detected | Player predError detected / extrapolated (ft) |
| --- | --- | --- | --- | --- | --- |
| 1 s before release | 57.2% | 60.1% | 1.50 | 95.4% | 0.89 / 3.88 |
| Flight | 57.4% | 60.8% | 1.42 | 95.3% | 0.87 / 2.88 |
| Contact to rebound | 54.3% | 60.5% | 1.65 | 89.3% | 0.95 / 2.71 |
| 1 s after rebound | 54.4% | 60.0% | 1.31 | 86.7% | 0.94 / 2.94 |

The ball is present on every frame, but its `isDetected` is 0 everywhere, so keyframes (frames that are not exact
midpoints of their neighbours) are the only proxy for direct observation. Player detection falls after contact, when
players crowd the rim: the per-game range is 80–95% from contact to rebound, against 93–97% before it.

## Clock coverage

This check is reported, not gated, because the windows themselves have no missing frames. Across 41 periods, running
clock frames cover at least 89.7% of 25 × period length. One period falls short: game 178442, period 4, where tracking
starts 62 s into the quarter.

## Exclusions and outcomes

| Exclusion | Episodes |
| --- | --- |
| Eligible | 703 |
| No rebound row, unexplained | 16 |
| No rebound row, end of period | 11 |
| Ball coverage under 80% or a gap over 12 frames | 5 |
| Rebound row at or before release (tip sequence) | 4 |
| No rebound row, foul | 2 |
| Ball not tracked | 1 |

Eligible outcomes: defensive player 457, offensive player 173, offensive team award 37, defensive team award 36.
Team awards keep no rebounder id and are never assigned to a nearby player.

## Edge cases drawn

`figures/edge_cases_01.png` to `_04.png` (list in `figures/edge_cases.csv`). Each case is drawn twice: in the camera
frame with both hoops labelled and the attacked one ringed, and in the attack frame. The cases are two shots at each
end, two end-of-period misses, one team award to each side, two rebounds before endFrame, and two episodes whose
tracked players differ from `chance_players` (both excluded: one has no tracking, the other only nine players). No
eligible episode has a substitution, so none is drawn.

## Deviations

1. **Orientation check replaced after the first run.** The prespecified check required the ball at `shots.endFrame` to
   be within 6 ft of the attacked hoop for at least 98% of misses in each direction. It reached 96.3% and 94.5%. All 34
   outliers (`orientation_endframe_outliers.csv`) are blocked shots (14), airballs or heaves (12), or rim and board
   shots whose endFrame is not at the rim (8: the ball is still in flight, or has already dropped away). The check therefore measured the meaning of endFrame, not
   the orientation. It was replaced with a check that does not use endFrame (the ball comes nearer the attacked hoop
   than the other, same 98% share), which scores 100% in both directions. The failed check stays in `checks.csv`.
   **Owner to confirm.**
2. **gameClock tolerance.** The first run compared event and tracking gameClock with a 1e-6 s tolerance, written into
   the code without a reason. The largest gap was 0.0005 s, so the tolerance is now 0.001 s.

## Not established here

- Who physically touched or secured the ball: contact, touch and control frames are automated proxies (Step 02).
- Review reliability: one reviewer, tracking plots only (Gate 0's 72-rebound review). No video ships with the data,
  and outside video is not allowed.
