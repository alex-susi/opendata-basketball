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
     - The panel names the case's screen (screen N of M, handler, screener, pick marker time). Other screens in the possession are context only
     - If the card's ‹ › moves to another screen, the panel warns and offers to pin the case's screen again
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
| First readable sign | The first moment you could tell how the defense is playing the screen · the screener's defender dropping low, holding at the level or showing high, the ball handler's defender starting over or under, or the two defenders starting to swap. About the defense only. The handler's movement counts only where it shows you the defense's choice |
| Coverage clear | The coverage is clear and stays clear |
| Pressure starts / ends | The screener's defender steps toward the handler, then stops |
| Return to screener | The screener's defender moves back toward the screener |
| Exchange done | Both defenders have taken the other's man |
| Decision open until | The last moment the handler could still make the choice picked under User decision and have it work (examples under User decision below). A forecast helps only if it arrives before this. If the choice is gone before the defense is readable, say so in the notes |
| Handler's touch ends | Pass, shot or turnover by the handler |
| New action | A new screen, dead ball or possession change |
| Forecast helpful from | After reveal · the first moment the forecast would have helped |

### Choices recorded

- Screener's defender depth · low, at level, high, unclear
- Ball defender's route · over, under, not engaged, unclear
- Each side of an exchange · yes, no, unclear
- Tracking, roles, review confidence
- After reveal · whether the recorded coverage matches, whether the forecast misled, how useful it was
- The four below have an explanation for each option

#### Pattern

What the two screen defenders did, in order. A review tag for finding and grouping plays. It never becomes a model class.

| Option | Meaning |
| --- | --- |
| pressure return | The screener's defender steps up toward the handler (a show or hedge) to slow him, then goes back to the screener once the ball handler's defender recovers. No exchange |
| containment return | The screener's defender stays back or at the screen's level and contains the handler without stepping up (drop or flat), then goes back to the screener |
| pressure exchange | The screener's defender steps up to the handler and stays with him, and the ball handler's defender takes the screener. A switch that starts with pressure |
| at level emergency exchange | The screener's defender holds at the level as if to contain, then late in the play the two defenders swap (the video's emergency switch, 9:17–9:42) |
| denial countered | The defense tries to keep the handler off the screen (sideline or middle denial, below) and the handler gets round it anyway |
| other | A sequence none of these fit. Describe it in the notes. A plain switch at the screen with no pressure or hold first goes here for now |
| unclear | The tracking does not show it well enough |

#### Defensive denial

Did the defense try to keep the handler from using the screen?

| Option | Meaning |
| --- | --- |
| none | The defense lets the handler come off the screen |
| sideline (ice-like) | The ball handler's defender jumps to the screen side and pushes the handler toward the sideline, away from the screen, with the screener's defender waiting below. Usually on the wing |
| middle (weak-like) | The same push in the middle of the floor. The data has no handedness, so this records the direction forced, never weak-hand intent |
| trap | Both defenders go to the ball (a blitz or double team) |
| unclear | Cannot tell |

#### Handler's answer

What the handler did, recorded apart from what the defense tried. A handler beating a denial does not change what the defense attempted.

| Option | Meaning |
| --- | --- |
| used screen | Comes off the screen the way it was set |
| rejected | Goes away from the screen before reaching it |
| snaked | Comes off the screen, then cuts back across the screener's defender |
| split | Dribbles between the two screen defenders |
| reached middle | Gets to the middle of the floor despite a denial |
| passed early | Gives the ball up before using the screen |
| other | Anything else. Describe it in the notes |
| unclear | Cannot tell |

#### User decision

The main choice the handler faces on this screen. The Decision open until stamp is its deadline.

| Option | Meaning | Decision open until is |
| --- | --- | --- |
| use or reject the screen | Go off the screen or away from it | The last moment he could still go away, before he is committed to coming off it |
| attack the screener's defender | Go at the big when he is caught high, switched onto the handler or out of position (drive, pull-up, isolation) | The last moment the big is still exposed, before he recovers or help arrives |
| find the roller or popper | Pass to the screener rolling or popping while his defender is pulled away | The last moment the pass is still open, before help or the screener's defender gets back |
| reset | Pull the ball out and start again | The last moment a reset is still the better play |
| other | Anything else. Describe it in the notes | As described in the notes |

#### Coverage still matters after a pass

When the handler gives the ball up, is the defense still dealing with this screen's coverage? This decides where the read for this screen should stop (a Phase 4 rule). Right now it runs to +1 s after the pick marker whatever happens.

| Option | Meaning |
| --- | --- |
| yes | The pass plays off the coverage. A pass to the roller, a pass to the popper the show left open, or a switch mismatch still being attacked after the ball moves |
| no | The pass starts a new action and this screen's coverage no longer matters |
| no pass | The handler kept the ball through the play (shot, turnover, still dribbling) |
| unclear | Cannot tell |

### Not observable in this tracking

- Hand contact, body facing, collisions and verbal calls. Leave them to the notes as what film would show, and never infer them from positions
