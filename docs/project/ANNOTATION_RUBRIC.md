# Contact-state annotation rubric (rebounding manual, Step 02)

Written 2026-10-29 before any Step 02 label was drawn or scored. Thresholds are in
`src/rebounding/config/experiment.yaml` (`step02`). **Do not change this rubric after the held-aside subset has been
scored**; a change after that point makes a new rubric version and needs a new held-aside subset.

## What is labelled and from what

Each missed, non-fouled field goal in the Step 01 episode table (`outputs/rebounding/step01/rebound_episodes.csv`),
from release to the credited rebound frame + 1 s. The only evidence is the SkillCorner tracking: ball x, y, z at 25 Hz
and player x, y on the floor. No video ships with the data and outside video is not allowed, so:

- ball `isDetected` is 0 on every frame; the vendor measures the ball on about every other frame and fills single
  frames with the exact midpoint of their neighbours. Dots on the review pages mark measured frames; a lone frame
  between two dots is filled in;
- player z is always 0, so no label says how high a hand was; ball height is the ball's centre;
- players are tracked on the floor plane. At rim height the ball sits about 1 ft from where players' coordinates put
  it (`bundle.R`, `to_player_frame()`), so player distances use the ball shifted to the player frame.

## State vocabulary

`released → airborne → rim / board contact → airborne → player touch (tip) … → controlled → credited rebound`, with
repeats. Other states: `block` (a player touch before any rim or board contact), `floor` (bounce), `out_of_bounds`,
`rim_or_board` (contact at the back of the rim where the two cannot be told apart), `unknown` (the track changes
course and no cause can be named).

## Fields (one row per episode on the review sheet)

| Field | Rule |
| --- | --- |
| `first_rim_or_board_frame` | Last frame on the incoming arc before the ball visibly changes course in the rim or board zone. `none` for an airball or a shot blocked away before reaching the rim. `UNKNOWN` if the course change cannot be placed within ±2 frames. |
| `contact_kind` | `rim`, `board`, `rim_or_board`, `none`, `UNKNOWN`. Board: the ball reverses x while above rim height in front of the board face; rim: the change happens at the ring (within about 2 ft of the hoop centre horizontally, near 10 ft). |
| `first_player_contact_frame` | First frame after release (blocks) or after the first rim/board contact where the ball changes course or stops **and** a player is within reach. `none` if the ball goes out or the window ends untouched. |
| `first_contact_player_id` | That player. `UNKNOWN` when two players are about equally close (within 1 ft of each other's distance to the ball) or the nearest player's position is extrapolated far from the ball. |
| `first_contact_type` | `catch` if the same player holds the ball from that touch (control starts within 8 frames); `tip` if the ball flies on, free, after it; `block` before the rim; `UNKNOWN`. |
| `tip_frames_and_players` | Every touch before control that does not become control: `frame:player;frame:player`. Empty if none. Write `?` for a player that cannot be named. |
| `first_control_frame` | First frame of a run where the ball stays with one player (within about 2.5 ft, no free fall) for at least 6 frames. A dribble keeps control. `none` if the ball goes out of bounds or the window ends first. |
| `controller_id` | The player in control. `UNKNOWN` if two players share the ball (held ball, tie-up). |
| `terminal` | `control`, `out_of_bounds`, `held_ball`, `unresolved`. |
| `label_confidence` | `high`: every field above is resolved and its frame is within the tolerance; `medium`: one field uncertain; `low`: the sequence is a guess. |
| `note` | Free text: tracking swaps, a ball that jumps, a missing player. |

Ball height at the first touch and at control are read from the track at those frames, not labelled.

## Do not

- Infer a touch only because the ball passes near a player. There must be a course change, a stop, or the ball
  staying with the player.
- Use the credited rebounder to decide the first touch or the controller (the held-aside pages do not show it).
- Call every course change near the rim a rim contact when a player stands under it within reach: use `UNKNOWN`
  (or name the player) and note it.
- Call a course change the floor unless the ball is low (about 2 ft) and was falling.
- Fill a field to make the sequence look complete. `UNKNOWN` and `none` are valid answers.
- Treat a player touch location as where the ball "would have landed". These labels are observed first contacts,
  never the unimpeded landing point.

## Reconciliation

Disagreements on the held-aside subset are not edited away. Each is listed in
`outputs/rebounding/reports/02_annotation_reliability.md` with the pages, and a consensus label is recorded
separately (`review_status = consensus`) without changing either labeler's original entry.
