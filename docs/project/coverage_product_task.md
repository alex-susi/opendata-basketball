# Screen coverage product · first task and play review

Coverage product plan, Phase 3. Written 2026-11-21. Provisional until the owner's play review is done.

## First useful task

- **User** · a coach or scout reviewing film of an on-ball screen
- **Question** · before the screen is used, which coverage are the two screen defenders likely to play, and how sure is the read
- **Workflow** · open a possession, pick the screen, pause before the pick marker, read the forecast, step or play through, then reveal the recorded coverage
- **What the forecast is** · the live model's probability of the screen's single recorded coverage (five coverages), from tracking up to the current frame
- **What it is not** · a label for every moment of the play. A switch can be favored while the screener's defender is still holding at the level
- **Recorded coverage** · SkillCorner's label for the whole screen, written after the play, hidden until the user reveals it

## Provisional timing criteria

The play review replaces these with measured intervals.

| Term | Provisional definition |
| --- | --- |
| Pick marker | `picks.frame`, the data's reference frame for the screen. Not proven contact |
| Before pick marker | Any frame from −2 s up to the pick marker |
| Play unfolding | The pick marker to +1 s |
| Outside prediction range | Outside −2 s to +1 s. The panel says so and shows no forecast |
| Screen being read | The pinned screen, or else the earliest screen whose −2 s to +1 s window holds the frame |
| Favored | The leading coverage has at least 45% and leads the next by at least 10 points. Otherwise "No clear favorite" |
| Pause points | −2.0, −1.5, −1.0 and −0.5 s before the pick marker. No single best pause point is claimed |

- The 45% and 10-point rule is a display choice. Phase 5 sets it on validation games only
- The earliest-window rule keeps one screen's read through a re-screen until its window ends. The panel names the other screen and offers to switch to it
- Probabilities are the exported whole percents. A higher-precision export belongs to the Phase 7 export contract

## Usability task list

A reviewer should manage each without help.

1. Find a screen · open a possession and step through its screens with ‹ ›
2. Keep the screen · scrub back and forth and see the same screen stay selected (Pinned)
3. Pause before it · choose a pause point and press Go
4. Explain the forecast · say which coverage is favored, or that there is no clear favorite, and what each defender's numbers mean
5. Advance one step · press +0.2 s and say what changed in the forecast and on the court
6. Reveal · press Reveal recorded coverage and compare it with the forecast trace
7. Same on a phone · do 1–6 at 390 px wide, where the panel sits under the court

## Leakage checks in the viewer

In Predict mode a pick's recorded coverage is hidden at its source until revealed. Checked places:

- The Screen Coverage Read card (no automatic right or wrong marks)
- Screen tags on the court (Defensive Context)
- The trace panel's hover card for a pick
- Season and tracked points per pick against the coverage (hover card lines)
- The time trace stops at the current frame until reveal

Not covered by the hiding, because they show the present or the past only:

- Matchup lines and switch marks (SW) drawn at the current frame
- Model attention, which is a model output

## Play review

- **Sample** · 50 screens from `screen_coverage/01_scripts/35_review_sample.R`, drawn before looking at any prediction
  - Switches split by when the matchups table hands the handler to the screener's defender (early, late, none by +3 s)
  - The four other coverages, each with some temporary-show or help controls
  - 5 screens outside the five coverages (4 ice, 1 blitz) and 3 left out for incomplete tracking
  - Hard cases drawn more often · 14 re-screens, 7 closest approaches at the search edge, 2 low-quality chances
  - 12 cases marked for the blind repeat (Pass 2)
  - A sample for diagnosis. It says nothing about how common anything is
- **Do not open** `screen_coverage/03_outputs/product_review/review_sample_strata.csv` before reviewing (it lists each case's coverage)
- **Open the panel** · the play viewer with `?review` in the address, for example `http://localhost:5173/?review`
- **Per case**
  1. Open case · loads the possession, pins the screen, pauses 2 s before the pick marker
  2. Blind stage · the forecast and the recorded coverage stay hidden. Click a moment's name to stamp the frame on the court. None means it did not happen in the clip, ? marks an unsure stamp, a blank stays not recorded
  3. Pick what the defenders and the handler did, add notes, then Finish blind stage
  4. After reveal · the forecast trace and the recorded coverage show. Stamp when the forecast would have helped and judge it
  5. Done
- **Save** · answers stay in the browser. Export CSV and save it as `screen_coverage/03_outputs/product_review/review_cases.csv`
- **Pass 2** · a few days later, switch to Pass 2 and review the 12 marked cases again without looking at Pass 1

### Moments stamped

| Moment | Meaning |
| --- | --- |
| Approach starts | Handler and screener start coming together |
| Screen engaged | The screen is plausibly being used |
| First readable sign | The first moment the guard's route or an exchange could be read |
| Coverage clear | The coverage is clear and stays clear |
| Pressure starts / ends | The screener's defender steps toward the handler, then stops |
| Return to screener | The screener's defender moves back toward the screener |
| Exchange done | Both defenders have taken the other's man |
| Decision open until | The last moment the user's decision was still available |
| Handler's touch ends | Pass, shot or turnover by the handler |
| New action | A new screen, dead ball or possession change |
| Forecast helpful from | After reveal · the first moment the forecast would have helped |

### Choices recorded

- Screener's defender depth · low, at level, high, unclear
- Ball defender's route · over, under, not engaged, unclear
- Each side of an exchange · yes, no, unclear
- Pattern (a review tag, never a model class) · pressure and return, containment and return, pressure and exchange, at-level emergency exchange, denial countered, other, unclear
- Defensive denial, the handler's answer, the user decision, whether the coverage still matters after a pass
- Tracking, roles, review confidence
- After reveal · whether the recorded coverage matches, whether the forecast misled, how useful it was

### Not observable in this tracking

- Hand contact, body facing, collisions and verbal calls. Leave them to the notes as what film would show, and never infer them from positions
