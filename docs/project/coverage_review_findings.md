# Screen coverage play review · Pass 1 findings

Coverage product plan, Phase 3 wrap-up. Written 2026-11-23 from the owner's review of all 50 sampled screens.

- **Source** · `screen_coverage/03_outputs/product_review/review_cases.csv` (Pass 1, 50 of 50 done)
- **Summary script** · `screen_coverage/01_scripts/36_review_summary.R`, writing `review_moments.csv`, `review_timing_checks.csv`, `review_choices.csv` and `review_component_check.csv` next to it
- **Sample** · drawn for diagnosis with hard cases drawn more often. Counts say what showed up in these 50, never how common it is across the season
- **Times** · seconds from the pick marker (`picks.frame`)
- **Still to come** · Pass 2, the blind repeat of the 12 marked cases, due a few days after Pass 1 (about 2026-11-26). The same script then adds `review_pass_agreement.csv`
- **Keep Pass 2 blind** · `review_component_check.csv` lists each case's coverage. Leave it closed until Pass 2 is done. Nothing below names a Pass 2 case

## Key terms

| Term | Meaning |
| --- | --- |
| Pick marker | `picks.frame`, the data's reference frame for the screen |
| Current window | The forecast runs from −2 s to +1 s around the pick marker |
| Middle half | The 25th to 75th percentile of the stamps |
| Component check | The recorded label compared with the blind answers (exchange, route, depth), made before the label was shown |

## When things happen

What the 50 stamps say about the timing of a screen.

| Moment | Stamped | Unsure | Median | Middle half | After +1 s |
| --- | --- | --- | --- | --- | --- |
| Approach starts | 50 | 14 | −1.30 | −1.79 to −0.84 | 0 |
| Screen engaged | 49 | 20 | +0.20 | +0.08 to +0.32 | 0 |
| First readable sign | 49 | 19 | +0.04 | −0.08 to +0.16 | 0 |
| Pressure starts | 35 | 5 | +0.08 | −0.10 to +0.38 | 0 |
| Coverage clear | 50 | 12 | +0.44 | +0.24 to +0.59 | 2 |
| Decision open until | 48 | 31 | +0.54 | +0.24 to +1.05 | 13 |
| Exchange done | 22 | 5 | +0.90 | +0.69 to +1.18 | 9 |
| Pressure ends | 16 | 4 | +1.70 | +1.23 to +2.14 | 14 |
| Handler's touch ends | 50 | 0 | +1.94 | +1.24 to +2.50 | 44 |
| Return to screener | 14 | 2 | +2.26 | +1.70 to +2.80 | 13 |
| New action | 50 | 0 | +3.34 | +2.32 to +5.37 | 50 |
| Forecast helpful from | 28 | 18 | −0.08 | −0.17 to +0.04 | 0 |

- **The pick marker sits just before the screen is used** · screen engaged at a median +0.20 s, the first readable sign at +0.04 s, and 19 of 49 first signs come before the marker
- **The −2 s start covers the approach** · 7 of 50 approaches start earlier than −2 s
- **Coverage is clear by +1 s in 48 of 50** · median +0.44 s. Switches take longest (+0.56 s) against shows (+0.36 s) and drops (+0.32 s)
- **The exchange often lands after the window** · in recorded switches the exchange is done at a median +1.02 s, after +1 s in 7 of 14
- **The deadline is the hardest stamp** · 31 of 48 decision stamps are marked unsure, the highest share of any moment

## The handler's decision

The moment a forecast has to beat.

- **Main choice** · use or reject the screen 36, find the roller or popper 6, reset 5, attack the screener's defender 1, other 2
- **The decision often closes before the coverage is clear** · 19 of 48 plays. In those the handler has to commit on a read, which is where a forecast earns its place
- **It rarely closes before anything is readable** · 2 of 47 plays
- **It is still open after +1 s in 13 of 48** · 90th percentile +1.25 s. Shows stay open longest (median +0.88 s), then switches (+0.50 s) and drops (+0.28 s)
- **When the forecast helped, it helped in time** · helpful before the decision closed in 24 of 26 plays with both stamps, and by the first readable sign in 19 of 28
- **Useful forecast stretch** · helpful from about −0.3 s (10th percentile) to the median deadline at +0.54 s. That stretch matters for the primary score the owner picks before Phase 5

## Recorded labels against what was seen

The component check, made from the blind answers.

| Group | Fits | Open | Conflicts |
| --- | --- | --- | --- |
| Switch (16) | 13 | 2 | 1 |
| Show (15) | 4 | 7 | 4 |
| Drop (14) | 7 | 5 | 2 |
| Ice or blitz (5) | 3 | 0 | 2 |

- **Switch labels hold up** · both defenders took the other's man in 13 of 16 recorded switches
- **Show is the shaky label** · 4 of 15 conflict and 7 more stay open
  - 3 shows had both defenders take the other's man for a moment and then go back
  - 2 shows had the ball defender go under where the label says over
- **At level is where show and drop blur** · the screener's defender was at the level in 6 of 15 shows and 5 of 14 drops. Depth alone cannot split them there
- **The matchups table misses visible exchanges** · in the 5 switches where the table never hands the handler over by +3 s, both defenders took the other's man in 3 and the screener's defender took the handler in 4
- **The after-reveal label question was read two ways** · in 9 of the 27 cases whose label fits the blind answers it was answered "no", often with notes about the forecast. The component check replaces it for Pass 1. The panel question now reads "Recorded coverage matches the play" and says to judge the label only

## How the forecast did

The owner's after-reveal judgments, by recorded coverage.

| Recorded coverage | Cases | Misleading | Useful | Partly | Not useful |
| --- | --- | --- | --- | --- | --- |
| Over + drop | 7 | 0 | 6 | 1 | 0 |
| Under + drop | 6 | 3 | 2 | 3 | 1 |
| Over + show | 8 | 1 | 2 | 5 | 1 |
| Under + show | 6 | 3 | 0 | 5 | 1 |
| Switch | 15 | 7 | 2 | 11 | 2 |
| Ice or blitz | 5 | 0 | 0 | 0 | 5 |
| Left out for tracking | 3 | 0 | 1 | 0 | 2 |

- **Over + drop is the one coverage the forecast reads well** · useful in 6 of 7, never misleading
- **Switch and under + show are the weak spots** · misleading in 7 of 15 switches and 3 of 6 under + shows. Same weak spots as the model's scores
- **Ice, blitz and left-out screens have no forecast** · the panel said why only in general terms. After Reveal it now names the reason ("Ice is outside the five coverages the model reads", "Left out of the model for incomplete tracking around the screen"). Before Reveal it stays general so it gives nothing away
- **The forecast keeps moving after the coverage is clear** · several notes describe a confident read that swings to another coverage after the screen is used (over to under at +0.6 s in one show)
- **Early switch leans from personnel** · a switch can be favored before the play shows anything when no big is in the screen. Noted for the "Forecast helpful from" wording, still open with the owner

## After the handler gives the ball up

Whether the coverage still mattered after a pass.

| Recorded coverage | Yes | No | No pass | Unclear |
| --- | --- | --- | --- | --- |
| Show (14) | 1 | 9 | 3 | 1 |
| Drop (13) | 1 | 3 | 7 | 2 |
| Switch (15) | 5 | 3 | 4 | 3 |
| Ice or blitz (5) | 3 | 1 | 0 | 1 |

- A show's coverage stops mattering once the ball moves in 9 of 14
- A switch's mismatch is still being attacked after the pass in 5 of 15

## Episode-boundary rules for Phase 4

Candidates from the review. Phase 4 checks each against all screens before any is adopted.

- **Keep the earliest-window owner through +1 s** · no new action came before +1 s in any of the 50 plays, re-screens included (14). Only 4 of 50 came before +2 s
- **Test a later end, about +1.5 s** · the decision is still open after +1 s in 13 of 48 and half the switch exchanges finish after +1 s (latest +1.64 s)
- **Stop at a new action** · the observable stop for any later end
- **Handler's touch end is a costly stop** · it comes before +1 s in 6 of 50 and before +2 s in 26 of 50. A stop there cuts switches most, since their mismatch outlives the pass. The stop rule cannot depend on the coverage, which is the thing being forecast
- **Do not anchor exchange timing on the matchups table** · it missed exchanges the film shows

## Ambiguous cases

Kinds of play a reviewer and the label disagree on, or that no option fits well.

- **At-level screener's defender** · show or drop (11 of 29 show and drop screens)
- **Exchange and return** · both defenders swap for about a second and go back. Labelled show, looks like a switch while it lasts
- **Late switch after a show** · pressure first, the exchange after +1 s. The "at level emergency exchange" pattern was never picked. Switches were "pressure exchange" in 13 of 15
- **Switch with no hand-over in the matchups table** · the film often shows one anyway
- **Ghost screen or early pass** · the screener runs through, or the handler passes before the ball defender commits over or under
- **Coverages outside the five** · ice and blitz get no forecast by design

## Gallery

Eight Pass 1 cases that show the findings, none from the Pass 2 set. Open the possession in the viewer (`http://localhost:5173/#/play/<possession>`), turn on Screen Coverage Read and pick the screen with ‹ ›.

| Case | Game | Possession | Recorded | What it shows |
| --- | --- | --- | --- | --- |
| 18 | RMA–TEN | `possession-184439-1-1` | Under + drop | A clean drop read, useful just before the first readable sign |
| 30 | BRE–ZAR | `possession-191313-1-26` | Switch | Pressure then exchange with a sideline push. Switch forecast useful from −1.3 s, pass to the roller |
| 13 | MAN–GRA | `possession-114243-2-41` | Over + show | Right read, then it swings to under at +0.6 s after the screen is used |
| 32 | AND–BIL | `possession-178442-2-65` | Over + show | Both defenders swap, then go back to their own men |
| 37 | RMA–TEN | `possession-184439-3-80` | Under + show | The forecast calls switch during a swap that returns |
| 26 | ZAR–BRE | `possession-114234-1-9` | Switch | Looks like over + show with a late switch the matchups table never shows |
| 43 | MAL–VAL | `possession-179612-3-103` | Switch | Late switch, forecast very confident in over + show |
| 6 | AND–BIL | `possession-178442-2-61` | Over + show | A ghost screen into a pop. Forecast confident in switch |

## What this settles for Phase 3

- **Decision moments** · the handler's choice closes at a median +0.54 s and before the coverage is clear in about 2 of 5 plays. The forecast helped in time when it helped
- **Ambiguous cases** · listed above, with show the least reliable label
- **Episode-boundary rules** · candidates above, for Phase 4
- **Open** · Pass 2 agreement, the primary score (owner), the "Forecast helpful from" wording (owner)
