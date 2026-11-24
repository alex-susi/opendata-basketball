# Screen coverage · Phase 4 timing audit, episodes and eligibility

Coverage product plan, Phase 4. Written 2026-11-23, updated 2026-11-24 with the owner's choices. No model is changed. Every rule below was fixed before any score was looked at.

- **Owner's choices, 2026-11-24**
  - The forecast window ends at +1.5 s (1.52 s, 38 frames)
  - A pass by the handler stops the screen's forecast
  - These are episode rules version 2. Version 1 (no pass stop) figures are kept below for the record

- **Scripts**
  - `screen_coverage/01_scripts/37_audit_timing.R` · timing, episode stops, switch timing, eligibility. Outputs in `screen_coverage/03_outputs/timing_audit/`
  - `screen_coverage/01_scripts/R/episode_eligibility.R` · the episode and per-time eligibility rules. Rows cached in `screen_coverage/02_cache/eligibility_rows.rds`
  - `screen_coverage/01_scripts/38_availability_sensitivity.R` · availability sensitivities on the logistic baseline. Outputs in `screen_coverage/03_outputs/availability/`
- **Screens** · 1,520 on-ball screens in the ten games. 1,496 have one of the five coverages, 24 are ice, blitz or none. The old scored cohort is 1,463
- **Two kinds of result**
  - Diagnostics may look past the moment they describe. They describe plays and help choose rules, never feed a model
  - Online rules use only what has happened by the frame

## Key terms

| Term | Meaning |
| --- | --- |
| Pick marker | `picks.frame`, time 0 |
| Closest point | The frame the handler and screener are nearest, searched within a span around the pick marker. Called "contact" in older outputs |
| Episode | One screen's forecast, identified by its pick id, from −2 s until its stop or the +1.5 s window end |
| Stop | The first observable new action after the pick marker · a pass by the handler, another screen or hand-off in the possession, a dead ball (clock stopped for 0.2 s) or the end of the chance |
| Eligible | A (screen, frame) row that may carry a forecast under the rules below |

## Closest handler-screener point

A diagnostic anchor. The old ±0.48 s search clipped it too often.

| Search span | On the span edge | Median | Middle half | 90th percentile | Screens that move from ±0.48 s |
| --- | --- | --- | --- | --- | --- |
| ±0.48 s | 172 of 1,463 (11.8%) | +0.24 s | +0.12 to +0.32 | +0.48 | — |
| ±1 s | 34 (2.3%) | +0.24 s | +0.12 to +0.32 | +0.51 | 167 |
| ±2 s | 39 (2.7%) | +0.24 s | +0.12 to +0.32 | +0.52 | 239 |

- **Use ±1 s for diagnostics from now on** · it removes most edge hits and leaves the median at +0.24 s
- **The closest point sits near the reviewed engagement** · the owner's "Screen engaged" stamp is a median 0.08 s earlier, within 0.2 s in 35 of 49 reviewed plays
- **It does not time engagement play by play** · the two barely move together (correlation −0.03). Fine as a typical anchor, poor as a per-play clock
- **The live model keeps its own past-only "closest-approach memory"** · that input never used the retrospective search and is unchanged

## Approach and censoring

When the pair came within 15 ft and 10 ft and stayed there until the closest point.

| Coverage | Screens | Within 15 ft found | Censored | Median found |
| --- | --- | --- | --- | --- |
| Over + drop | 496 | 422 | 74 | −0.84 s |
| Over + show | 502 | 422 | 80 | −0.84 s |
| Switch | 218 | 172 | 43 | −0.88 s |
| Under + drop | 167 | 145 | 21 | −0.80 s |
| Under + show | 113 | 92 | 20 | −0.76 s |
| Ice, blitz or none | 24 | 17 | 7 | −0.96 s |

- **Censored** · the tracking or the −3 s edge runs out while the pair is still within 15 ft. 245 of 1,520 screens (16%)
- **Never within** · 5 screens never came within 15 ft at the closest point, 24 never within 10 ft
- **Censoring varies by game** · 10 to 41 screens per game at 15 ft. Game 184439 is the worst (41 of 177)
- **Within 10 ft** · found in 1,443, median −0.40 s, censored in 53

## Episode stops

Where an episode ends on events alone. Version 2 counts the handler's first pass after the pick marker (its release frame). Self-passes, where the passer is also the receiver, are marking noise and do not count. Incomplete passes do.

| Stops before | Version 2 (with pass) | Version 1 (no pass) | Handler's touch end |
| --- | --- | --- | --- |
| +1 s | 214 of 1,520 (14%) | 67 (4.4%) | 179 (12%) |
| +1.5 s | 476 (31%) | 102 (6.7%) | 462 (30%) |
| +2 s | 655 (43%) | 135 (8.9%) | 688 (45%) |
| Median stop | +2.2 s | +4.2 s | — |

- **The pass is now the usual stop** · of the 214 stops before +1 s, 149 are a handler pass, 40 another screen or hand-off, 13 a chance end, 12 a dead ball. None at or before the pick marker
- **The pass and the touch end are nearly the same moment** · 1,077 screens have a handler pass after the marker. In 96% it falls on the frame the touch ends
- **Stops before +1.5 s by coverage** · over + show 192 of 502 (38%), under + drop 56 of 167 (34%), over + drop 149 of 496 (30%), switch 47 of 218 (22%), under + show 23 of 113 (20%)
- **Against the owner's Pass 1 review**
  - The reviewer's touch end sits within 0.2 s of the event pass in 36 plays
  - The reviewer's "new action" stamp came after the pass in 34 of the 38 plays with one, a median 2.1 s later. Within 0.2 s of the version 2 stop in 3 of 50 plays (version 1, 11 of 50)
  - "Coverage still matters after a pass" was no in 16 plays, yes in 10, unclear in 8 and no pass in 16
  - The version 2 stop comes before the reviewer's "decision open until" stamp in 10 of 48 plays (version 1, 1), before "exchange done" in 4 of 22 and before "coverage clear" in 2 of 50
- **What the pass stop gives up** · the stretch after a pass where the defense is still dealing with the screen, such as a switch mismatch attacked off the pass or the roller the show left open. The review saw that in about 10 of 34 passes

## Switch timing

Whether positions alone can confirm an exchange as it happens.

| Measure | Kind | Recorded switches by +2 s | Other coverages by +2 s | Median time |
| --- | --- | --- | --- | --- |
| Matchups table, handler side | Retrospective | 152 of 218 (70%) | 90 of 1,278 (7%) | +0.92 s |
| Matchups table, both sides | Retrospective | 116 (53%) | 11 (0.9%) | +1.20 s |
| Geometry, both sides, held 0.2 s | Online | 104 (48%) | 267 (21%) | +0.80 s |
| Geometry, both sides, held 0.4 s | Online | 89 (41%) | 208 (16%) | +1.04 s |
| Geometry, handler side, held 0.2 s | Online | 134 (61%) | 413 (32%) | +0.82 s |
| Geometry, handler side, held 0.4 s | Online | 128 (59%) | 372 (29%) | +1.02 s |

- **Geometry rule** · the screener's defender within 6 ft of the handler and nearer than the handler's own defender, and for both sides the handler's defender within 6 ft of the screener and nearer than the screener's defender. The alert fires when the run is complete, never backdated
- **The online rule is not a usable switch confirmation** · with six times as many other screens, only about 3 in 10 alerts by +2 s are switches (both sides, 0.4 s)
- **Shows cause most false alerts** · 101 of 502 over + shows and 25 of 113 under + shows trip the both-sides alert by +2 s. Same pattern the review saw: the defenders swap for a moment and go back
- **The matchups table is specific and late** · both sides fires on under 1% of other coverages but finds only 53% of switches by +2 s, and the review saw exchanges it missed. It stays a diagnostic
- **Against the review** · in 17 plays where the reviewer saw both defenders take the other's man, the geometry alert fired in 7 and the matchups table in 9. In the 33 others, geometry fired in 8 and the table in none
- **Consequence** · the switch read stays the model's forecast. No online switch alert is built from these rules

## Per-time eligibility

The rules in `R/episode_eligibility.R`, checked in order.

1. **Domain** · from −2 s to +1.5 s (the owner's end). +1 s and +2 s are kept as comparison columns
2. **Possession** · the frame is inside the screen's possession
3. **Stop** · the frame is before the episode stop (version 2, with the handler's pass)
4. **Players** · all four screen players have a position at the frame (or up to 0.08 s before)
5. **History** · all four are present at 7 or more of the 9 history moments (now, 0.2 s ago … 1.6 s ago)

Version 2, five-coverage screens.

| End | Rows | Eligible | Screens with a forecast | Not eligible · after stop | · short history | · players missing | · other possession |
| --- | --- | --- | --- | --- | --- | --- | --- |
| +1 s | 113,696 | 110,038 | 1,496 | 2,145 | 1,161 | 196 | 156 |
| **+1.5 s (chosen)** | 133,144 | 124,664 | 1,496 | 6,915 | 1,161 | 196 | 208 |
| +2 s | 151,096 | 135,572 | 1,496 | 13,880 | 1,161 | 196 | 287 |

- **Version 1 for the record** · 111,410 eligible rows at +1 s, 129,684 at +1.5 s and 146,140 at +2 s
- **Old cohort** · 1,463 screens × 76 frames = 111,188 rows, every frame tracked from −2 s to +1 s. Kept for reproducing past results
- **Every five-coverage screen gets some forecast** · the 33 screens left out for incomplete tracking gain 1,519 eligible rows up to +1.5 s
- **Old-cohort rows that drop out** · 2,094 come after an episode stop (in 239 screens) and 274 have short history near −2 s
- **Screens still eligible** · 84% at +1 s, 67% at +1.5 s and 54% at +2 s. Nearly every stopped screen stopped on the handler's pass
- **Each forecast's identity** · pick id plus frame. Every row keeps its reason, the touch-ended flag and how many history moments it had
- **Rows are cached** · `screen_coverage/02_cache/eligibility_rows.rds`, with the chosen-end reason in `reason`

## Availability sensitivities

The logistic baseline refitted under each assumption, held out by game. Joint log loss, lower is better. Differences are against the live rule, with a 95% interval from resampling whole games. The live-rule refit reproduces `01_logistic_baseline.R` exactly (flat 1.1869).

### When an earlier coverage counts

| Earlier coverage counts from | Main curve | Change | 95% interval | −1 s to the pick marker | Change |
| --- | --- | --- | --- | --- | --- |
| Its pick marker | 1.1924 | 0.0000 | −0.0006 to +0.0007 | 1.2363 | 0.0000 |
| 1 s after (live) | 1.1924 | — | — | 1.2363 | — |
| 2 s after | 1.1924 | 0.0000 | −0.0005 to +0.0006 | 1.2363 | 0.0000 |
| 3 s after | 1.1925 | +0.0001 | −0.0010 to +0.0014 | 1.2363 | 0.0000 |
| Its episode stop (version 2) | 1.1926 | +0.0002 | −0.0005 to +0.0009 | 1.2365 | +0.0002 |
| Never (no earlier coverages) | 1.2215 | +0.0291 | +0.0059 to +0.0527 | 1.2679 | +0.0316 |

- **The delay does not matter** · from 0 s to 3 s or the episode stop, every change is under 0.001
- **The earlier coverages themselves do** · dropping them costs 0.029, worse in 7 of 10 games
- **Keep the live 1 s rule** · it is safe for a bench that learns a coverage after the play and costs nothing

### Pick marker moved

1,459 of the 1,463 screens are tracked over the widest shift. The window, time weights and earlier coverages all follow the moved marker.

| Pick marker moved | Main curve | Change | 95% interval | −1 s to the pick marker | Change |
| --- | --- | --- | --- | --- | --- |
| −0.24 s | 1.2631 | +0.0697 | +0.0644 to +0.0757 | 1.3005 | +0.0631 |
| −0.16 s | 1.2416 | +0.0482 | +0.0446 to +0.0523 | 1.2834 | +0.0460 |
| −0.08 s | 1.2182 | +0.0248 | +0.0230 to +0.0269 | 1.2624 | +0.0250 |
| None | 1.1934 | — | — | 1.2374 | — |
| +0.08 s | 1.1676 | −0.0257 | −0.0277 to −0.0239 | 1.2081 | −0.0293 |
| +0.16 s | 1.1415 | −0.0518 | −0.0559 to −0.0483 | 1.1750 | −0.0624 |
| +0.24 s | 1.1154 | −0.0780 | −0.0839 to −0.0728 | 1.1385 | −0.0989 |

- **A later marker scores better only because the window moves later** · the forecast at "−0.4 s" is then a forecast 0.32 s before the true marker, closer to when the coverage shows. It says nothing about which marker is right. No shift is adopted
- **The scores are very sensitive to where time 0 sits** · moving it by 0.08 s (two frames) shifts the main-curve score by about 0.025. That is larger than every model change tested so far (hoop speed +0.002, roll lanes −0.004, position groups +0.003)
- **Consequence for Phase 5** · every comparison must use the same pick markers and windows. Scores stated "at −0.4 s" carry whatever error the provider's marker has, which this data cannot measure

## What Phase 4 settles

- **Stable event identity** · every forecast is a pick id and a frame. The display already pins the screen
- **Available-past inputs** · unchanged from the frozen model. Its past-only test still holds. New rows follow the same rules
- **Explicit eligibility** · every row has a reason under episode rules version 2. Old cohort kept for reproduction
- **Retrospective against online** · the closest point, approach and matchups hand-over are diagnostics. Episode stops, eligibility and the geometry alert are online

## Settled by the owner, 2026-11-24

- **Window end** · +1.5 s. It keeps most decisions the review saw still open after +1 s and most late switch exchanges
- **New action** · a pass by the handler stops the episode. The forecast reads the screen until the ball leaves the handler
- **Switch alert** · none is built. The switch read stays the forecast
- **Still open before Phase 5** · the primary score and the "Forecast helpful from" wording
