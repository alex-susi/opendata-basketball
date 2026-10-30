# Step 02: contact-state labels and their reliability

Rebounding manual, Step 02 ("Label tip chains, first contact, controlled possession, and catch height"), run
2026-10-29. Code `src/rebounding/R/contact_states.R` (labeler) and `src/rebounding/run_step02.R` (phases); rubric
`docs/project/ANNOTATION_RUBRIC.md`; thresholds `src/rebounding/config/experiment.yaml` (`step02`); evidence
`outputs/rebounding/step02/`; contract file `outputs/rebounding/annotations/contact_events.csv`; status record
`outputs/rebounding/gate_results/02_contact_states.json`.

**Gate 02: BLOCKED.** No label type met every criterion fixed before the held-aside subset was opened. As the manual
directs, Steps 03–09 use the **final credited rebounder only**; tip physics, controlled-catch and securing models stay
blocked. The automated labels stay in the contract file for description, each row carrying `gate_status`.

## What was built

| Piece | What it does |
| --- | --- |
| State vocabulary | `released → airborne → rim / board → airborne → player touch (tip) … → controlled → credited rebound`, plus `block`, `floor`, `out_of_bounds`, `rim_or_board`, `unknown` |
| Labeler (`auto_v1`) | A contact is a departure of the measured ball track from a short ballistic arc fitted to the measured frames before it (x, y linear; z with the track's own 28.3 ft/s² curvature). Each departure is named by where it happens: rim or board zone, low and falling (floor), within 3 ft of a player and below 12.5 ft (touch; actor unknown if the second player is within 1 ft), otherwise unknown. Control is the first run of 6 frames with the ball within 2.5 ft of one player, below 9 ft and moving with him, starting with the ball not falling fast. A touch followed within 8 frames by the same player's control is a catch, otherwise a tip. Interpolated ball frames are never fitted |
| Break threshold | 0.65 ft: 99th percentile of one-step prediction residuals on made-shot flights (311 of 346; 35 excluded as carried or jumpy, see deviations). Median residual 0.12 ft |
| Review sample | 7 strata (blocked, airball/no contact, backboard first, team award, offensive player rebound, low tracking quality, ordinary defensive rebound) × 4, plus 2 random, for each of two disjoint subsets: development (30) and held-aside (30). Seed 20261029 |
| Workflow | Development pages (with automated marks) were used to fix the labeler; the labeler was then frozen (checksums in `detector_freeze.json`); only then were the held-aside pages drawn, **without** the automated marks or the credited rebounder, labelled once by reviewer 1 and scored once |

Development changes before freezing, all recorded in the config: control height 10.5 → 9 ft (slow balls at the apex
were taken as control); the vertical-speed test only where control starts (a catch followed by a dribble failed it);
a shared ball needs the second player within 0.5 ft for 80% of the run (1 ft for half gave 155 held balls); the first
break in the rim zone is the rim contact whoever stands below; a block must be a defender's touch before both the rim
contact and `endFrame` (before this, 262 "blocks" against 49 official ones); the rim zone widened to 3.4 ft from the
calibrated hoop and 3 ft above the ring, because clear first contacts read 1–2.5 ft high and up to 2.7 ft off-centre.

## Automated labels, all 703 eligible misses

| | Count |
| --- | --- |
| First contact: rim / rim or board / board / none / unknown | 374 / 233 / 4 / 60 / 32 |
| First player contact: catch / tip / block / unknown player / none | 334 / 149 / 13 / 150 / 57 |
| Episodes with at least one tip before control | 304 |
| Terminal: control / held ball / out of bounds / unresolved | 519 / 42 / 40 / 102 |
| Time-order problems (contact before release, control before first touch, …) | 0 |
| Named controller = credited rebounder (player rebounds with a named controller) | 383 of 492 (78%) |
| Official blocked shots labelled as a block | 6 of 49 |

## Agreement on the held-aside subset (30 episodes)

Labelers: the frozen labeler and reviewer 1 (blind). Tolerances: ±2 frames (0.08 s) for the rim contact, ±3 frames
(0.12 s) for touches and control. A measure on fewer than 15 jointly resolved episodes cannot pass. 95% Wilson
intervals.

| Type | Measure | Result | Target | Met |
| --- | --- | --- | --- | --- |
| Contact | both resolve contact vs none | 24/30 (80%) | ≥ 70% | yes |
| Contact | contact vs none, Cohen's kappa | 0.00 (raw 23/24) | ≥ 0.6 | **no** |
| Contact | frame within ±2 | 20/23 (87%, 0.68–0.95) | ≥ 80% | yes |
| First touch | both name the player | 15/30 (50%, 0.33–0.67) | ≥ 60% | **no** |
| First touch | same player | 13/15 (87%, 0.62–0.96) | ≥ 80% | yes |
| First touch | frame within ±3 | 13/27 (48%, 0.31–0.66) | ≥ 75% | **no** |
| Touch type | tip vs catch, kappa | 0.79 (raw 17/19) | ≥ 0.5 | yes, but describes a first touch that failed |
| Control | both name the controller | 14/30 (47%, 0.30–0.64) | ≥ 70% | **no** |
| Control | same controller | 14/14 (100%, 0.78–1.00) | ≥ 85% on ≥ 15 | **no** (14 < 15) |
| Control | frame within ±3 | 10/20 (50%, 0.30–0.70) | ≥ 75% | **no** |
| Tip chain | same count 0 / 1 / 2+ | 16/30 (53%, 0.36–0.70) | ≥ 75% | **no** |
| Rim vs board (not gated) | where both name one | 11/11 | – | – |
| Terminal state (not gated) | same | 21/30 (70%) | – | – |

What the numbers say:

- **Where both labelers name a player, they name the same one** (first touch 13/15, controller 14/14). The failures are
  coverage and timing: each labeler leaves a different half of the episodes unnamed (crowds within the 1 ft margin,
  shared balls), and they place soft events differently in time. The reviewer puts a catch where the ball stops
  falling; the labeler puts it where the track first leaves the arc or where its control run starts. The labeler's
  control starts 11–15 frames before the reviewer's in 5 of 20 episodes (median difference −1.5 frames); first-touch
  differences have a median of 0 but a long tail, mostly with the labeler earlier (the largest, 61 frames, is the
  false-positive block below). Rim-contact differences run from −7 to +5 frames, 20 of 23 within ±2
  (`heldout_comparison.csv`).
- **The rim contact is timed consistently** (87% within ±2 frames), but the contact-vs-none criterion fails on its
  kappa: the subset has a single "none" both labelers resolved (item 14, an arc past the hoop the labeler calls a rim
  contact), so kappa carries no information. The prespecified rule is kept as written; this is reported, not
  re-scored.
- **Blocks are not identified**: the labeler finds 6 of the 49 official blocks, and its one held-aside "block" (item
  8, a kink in the rising shot next to the contesting defender) is the false positive below.
- **Rim vs board** cannot be told apart reliably once the rim zone is widened (233 `rim_or_board`, 4 `board`).

20 of the 30 held-aside episodes have at least one disagreement beyond tolerance; every one is listed with both
labels in `outputs/rebounding/step02/heldout_comparison.csv`. No consensus labels were written: with one reviewer and
one algorithm there is no third view to reconcile against.

## Ball height at the first touch and at control

Ball-centre height from the track (`ball_height_by_touch_type.csv`, all episodes, automated frames; the held-aside
reviewer frames in `ball_height_heldout_reviewer1.csv`). Player z is always 0, so these are ball heights, not hand or
jump heights, and they are read at labels that did not pass.

| Moment | Actor | n | Median ft | 5th–95th |
| --- | --- | --- | --- | --- |
| Tip | detected | 137 | 8.5 | 3.0–10.4 |
| Tip | extrapolated | 12 | 8.5 | 4.0–10.2 |
| Catch (first touch) | detected | 315 | 7.5 | 3.0–9.1 |
| Catch (first touch) | extrapolated | 19 | 8.8 | 3.8–9.0 |
| Control | detected | 524 | 5.3 | 2.4–9.0 |
| Control | extrapolated | 37 | 8.2 | 2.9–9.0 |

At the reviewer's frames: tips median 8.6 ft (n 9), catches 5.2 ft (n 14), control 4.1 ft (n 24, highest 10.0 ft).
Two cautions: control heights are **cut at 9 ft by the labeler's own control rule**, so they are not a measurement
of how high rebounds are caught; and near the rim the track reads the ball 1–2.5 ft high. Any catch-height envelope
for Step 08 must be a broad distribution with these biases stated, not these quantiles.

## Example cases (tracking frames)

- `figures/false_positive.png` — held-aside item 8 (shot-114086-2-43): the labeler calls a block by D9138 at release +
  8 frames, a kink in the rising shot while the defender contests; the reviewer sees a high rim-or-board contact at
  +33 and a catch by D4268 at +69 after a floor bounce. The labeler also ends with D4268's control, so its later
  sequence agrees.
- `figures/ambiguous.png` — held-aside item 9 (shot-114234-4-131): the ball sits on the ring for about 20 frames, is
  taken off at about +49 with D5222 and D3482 equally close, and is held near rim height. The reviewer names no first
  toucher or controller; the labeler names D5222. The official credit is an **offensive** rebound by O9110, who puts
  the ball back up at about +78: tracking alone cannot settle who secured it.

## Deviations (owner to confirm)

1. **Break threshold rule.** Prespecified: the 99.5th percentile of residuals on misses before the Step 01 contact
   proxy. It gave 2.20 ft because 11% of those segments are not free flight (blocked shots and airballs already low or
   held, jumpy tracks); made shots without trimming gave 2.25 ft for the same reason (carried layups). Replaced, before
   any label was reviewed, by made-shot flights without a residual above 1 ft, 99th percentile: 0.65 ft.
2. **Second reviewer.** The manual asks for one "where practical"; none was available. Reliability was measured
   between the frozen labeler and a blind reviewer. Both read the same tracking, and the reviewer (Claude) wrote the
   labeler, so this measures consistency of tracking-based judgements, not accuracy. `review/reviewer2_heldout.csv` is
   a blank sheet for a human reviewer; rerunning `--phase=score` and `--phase=gate` adds reviewer-to-reviewer agreement
   and judges the gate on it.
3. **Contact kind.** The prespecified kappa over rim / board / none became contact vs none before freezing, because
   the widened rim zone overlaps the board zone; rim vs board is reported only.

## Limits

No video ships with the data and outside video is not allowed, so no label here is checked against what happened. 30
held-aside episodes give wide intervals. The page plots show distances to the five players who come nearest, so a
player who stays further away cannot be named from a page (held-aside item 18).
