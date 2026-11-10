# Decision log

## 2026-10-10 — Expected possession value (EPV) model, version 1

Status: exploration. Intended as a possible backbone for the competition entry (for example, how closeouts
change EPV). Not yet the entry's research question; no research spec has been written for it.

Code: `src/epv/` (features, models, build script). Prices: `outputs/cache/epv/` (git-ignored).
Validation tables: `outputs/epv/validation_summary.csv` and `validation_by_game.csv`.
Viewer: `src/play_viewer/` shows the prices as an overlay.

### Definitions

- **Priced frames.** Every third tracking frame (about 8 Hz) with the game clock running and an identified
  ball holder, up to and including a shot's release: 171,317 frames across the ten games. Frames after a
  release are not priced until the next touch starts. Offense is rotated to attack +x using `possessions.leftHoop`.
- **Holder.** The offensive player of the current touch; he stays holder for up to 1.5 s after the touch
  ends (ball in the air). The pass's destination is never used, so nothing leaks from the future.
- **Velocity.** Backward difference over 0.24 s, clipped at 30 ft/s. No look-ahead.
- **Shot value** of a player at a frame (shooter-neutral):
  `(1 - pFoul) * (xFG * pts + (1 - xFG) * pOREB * V_orb) + pFoul * (and1 * (pts + FT%) + (1 - and1) * pts * FT%)`
  with `pts` 2 or 3 from court geometry. xFG is trained on unfouled attempts. `pOREB` is the training-fold
  offensive-rebound rate for twos or for threes (a base rate, not a model). `V_orb` (points scored in the rest
  of a possession after an offensive rebound), `FT%` and the and-one rate are training-fold constants.
  Teammates are priced as catch-and-shoot (0 dribbles, 0 s held).
- **Pass turnover probability.** From passing-lane geometry at release: each defender's distance from the
  ball's path when the ball passes, less the ground a defender covers at 12 ft/s in that time (`lane_margin`),
  plus pass length, pressure on the passer and on the receiver at arrival.
- **Pass value** = `(1 - pTurnover) * V(receiver at arrival)`. Receiver and defenders are moved along their
  velocity for the flight time (capped at 0.6 s); flight time is `0.02 s + 0.021 s/ft`, fitted to completed passes.
- **Turnover risk (2 s)**: probability of a turnover event within 50 frames. **Cumulative turnover risk** is
  one minus the running product of survival over the possession's priced frames.
- **Turnover, rest of possession**: probability the possession ends in a turnover.
- **EPV** `V`: expected points in the rest of the possession (made shots plus made free throws by frame).

### Model form

Each component is two-stage, as chosen by the owner: a GAM on the structural part (court location, shot
clock, lane geometry), then gradient boosting (xgboost, depth 3, eta 0.08, monotone constraints on defender
distances and shot values) started from the GAM's linear predictor. Boosting rounds (0, 40, 120 or 300) are
picked by three-way game-grouped validation inside the training games; 0 means the GAM alone.

### Validation (leave-one-game-out, every prediction from a model that never saw that game)

Loss is log loss, except EPV which is squared error. "Gain" is the mean per-game improvement over the
training base rate, with its standard error across the ten games.

| Component | n | Events | Base | GAM | Full | AUC | Gain ± SE | Games better |
|---|---|---|---|---|---|---|---|---|
| Shot make (xFG) | 1,278 | 563 | 0.688 | 0.662 | 0.650 | 0.64 | 0.037 ± 0.007 | 9 |
| Foul on shot | 1,421 | 143 | 0.327 | 0.298 | 0.288 | 0.76 | 0.038 ± 0.009 | 9 |
| Offensive rebound (rate by two/three) | 698 | 220 | 0.624 | – | 0.621 | 0.55 | 0.002 ± 0.003 | 6 |
| Pass turnover | 3,705 | 75 | 0.099 | 0.079 | 0.079 | 0.85 | 0.021 ± 0.004 | 10 |
| Turnover within 2 s | 171,317 | 3,712 | 0.105 | 0.095 | 0.092 | 0.79 | 0.012 ± 0.002 | 10 |
| Turnover, rest of possession | 171,317 | 27,783 | 0.444 | 0.444 | 0.444 | 0.53 | 0.000 ± 0.001 | 3 |
| EPV (squared error) | 171,317 | – | 1.386 | 1.383 | 1.383 | – | 0.004 ± 0.002 | 8 |

Calibration on held-out games: EPV deciles run from 0.94 predicted (1.01 scored) to 1.26 predicted (1.21
scored). The 2-second turnover risk is well calibrated across deciles (0.2% to 9.6% predicted against 0.2% to
8.5% observed). Nearest-defender distance at release from this pipeline correlates 0.95 with the vendor's
`closestDefDist`.

### What the numbers do not support

- **Rest-of-possession turnover** has no demonstrated skill; it is close to a base rate.
- **EPV is barely better than a constant.** It explains about 0.3% of the variance in possession points, the
  gain is under two standard errors, and the GAM alone is chosen (zero boosting rounds).
- **"Shot now" does not predict possession points.** Held-out frames grouped by the holder's shot value (from
  0.5 to 1.57) all scored between 1.05 and 1.10 points. Shot value is calibrated on shots that were taken; it
  is not evidence about what would happen if the holder shot at an arbitrary moment.
- **Pass turnover AUC is flattered.** The intended receiver of an intercepted pass is not recorded, so it is
  inferred as the teammate best aligned with where the interceptor took the ball. That makes intercepted
  passes look more "in the lane" than completed ones by construction. Only 75 interceptions enter the model.
- **Hypothetical options are extrapolations.** Shots and passes are observed only when players chose them.
  "Shot now" values (median 1.07 for the holder, 1.18 for teammates) often sit above EPV because off-ball
  defenders sag and the model does not move them during the catch and release.
- **Best pass is optimistic.** It is the maximum of four noisy values; in half-court frames it exceeds
  current EPV by 0.05 or more 35% of the time, and in 2% of them it points to a man beyond 35 ft.
- Frames within a possession share one outcome, so the frame counts overstate the independent sample
  (1,520 possessions).

### Changes during the build

- Added "defense set" features (`ahead`: defenders nearer the hoop than the player; `def_spread`) after the
  first fit priced backward passes to an open man near midcourt too highly. Share of half-court frames whose
  best pass went 8+ ft further from the hoop and was priced 0.05+ above EPV fell from 15.9% to 10.8%; EPV
  gain rose from 0.014 ± 0.004 to 0.015 ± 0.003.

- **Correction (same day): frames after a shot release were being priced.** The shooter stayed "holder" for
  1.5 s after release, and for those frames the points label excluded the shot in the air. The EPV model
  learned that an open shooter with the ball scores little: held-out frames with shot value above 1.5 showed
  0.87 points scored against 1.08 for shot value under 0.6. It also inflated EPV's apparent skill (reported
  gain 0.015 ± 0.003, 10 of 10 games). After excluding those frames the gain is 0.004 ± 0.002 (8 of 10) and
  the backwards relationship is gone. Found when the owner questioned EPV 0.91 beside shot 1.49 at a release.
- **Rebound model replaced by a base rate** (owner's decision). The fitted model had no held-out skill yet
  moved the second-chance term between 0.15 and 0.30 points.

### Open choices for a later version

- Whether the entry uses this model, and for which question.
- Attack and relocation space maps, per-defender steal and block rates, shell tracking (deferred).
- Shooter-adjusted shot value (deferred; season aggregates include these ten games, so it needs a leak-safe design).
- Fixed assumptions to test for sensitivity: 12 ft/s lane-closing speed, 0.6 s projection cap, 1.5 s
  ball-in-air window, 2 s turnover horizon.

## 2026-10-10 — Playstyle archetypes, version 1

Status: exploration, at the owner's direction. A different question from the shot-quality direction in the
roadmap; whether it becomes the entry (or context for it) is undecided. Inspired by BBall Index's offensive
and defensive roles; no external data is used.

Code: `src/archetypes/` (`build_features.R`, then `cluster_archetypes.R`). Tables: `outputs/archetypes/`.
Per-game counts are cached in `outputs/cache/archetypes/` (git-ignored).

### Decisions (owner)

- Features are tendencies only: what a player does and where he is. No makes, points, percentages, assists,
  turnovers, fouls drawn, blocks, steals or rebounds collected. Blow-by rate is excluded as a result.
- How opponents treat a player (pick coverage faced) is kept as context, not as a clustering input. Contest
  mix on shots is in, as one feature on non-blocked attempts.
- Offense and defense are tabled and clustered separately.
- Every player gets a probability of every cluster: all 310 aggregate players on offense, the 205 tracked
  players on defense (there is no defensive data for anyone else).

### Definitions

- **Two tiers.** Season features come from the three aggregate files (293 games); tracked features from the
  ten games' events and tracking. A traded player's "total" row is used, never with his team rows; aliased ids
  are merged. The shots file has 308 canonical players; two more appear only in the drives or picks files.
- **Feature = numerator / denominator** over counts (`R/spec.R`, 130 features: 93 offense, 37 defense).
  `outputs/archetypes/feature_dictionary.csv` has every definition.
- **Tracking-derived events** (thresholds in `R/tracked.R`, not validated against video):
  roll = screener within 10 ft of the hoop, or 6 ft closer, 2.5 s after the screen; pop = no roll and 20+ ft
  out; cut = off the ball 18+ ft out and within 8 ft 2 s later, before the shot, not within 4 s of setting a
  pick; on the glass = within 8 ft, or 4 ft closer, when the ball reaches the rim; help = 8+ ft from an
  off-ball assignment. "Set" frames are half-court offense up to the shot's release, transition excluded.
- **Noise and shrinkage.** raw = true + noise, Var(noise) = sigma2 / denominator. sigma2 is binomial for
  season features and measured from odd versus even chances for tracked ones. Reliability =
  den / (den + sigma2 / tau2); the shrunk value moves the raw one toward the league mean by one minus that.
- **Screen.** A feature enters the clustering if its median reliability among the fit players is at least 0.7.
  Fit players: 40+ tracked chances on that side of the ball (and 50+ season attempts for offense): 127 on
  offense, 139 on defense. 45 offensive features (26 season, 19 tracked) and 20 defensive ones pass.
- **Clustering.** Features scaled by (value - league mean) / tau, principal components keeping 80% of the
  variance (7 on offense, 3 on defense), Gaussian mixture with one shared diagonal covariance (mclust EII or
  EEI), number of clusters by BIC. Every player is then assigned from his raw values with his own noise added
  to the cluster covariance and missing features left out.

### Results

- **Offense: 9 clusters** (EEI). Names are a reading of the profiles: off-screen scorer, stretch forward,
  pull-up lead guard, pick-and-roll orchestrator, iso and post forward, post scorer, roll and cut big,
  stationary spacer, slashing guard. Players per cluster (all / fit): 49/26, 40/19, 35/14, 8/6, 17/8, 5/2,
  62/18, 65/22, 29/12.
- **Defense: 4 clusters** (EII): point of attack 37/29, perimeter chaser 47/32, anchor big 50/28, helper 71/50.
- Mean top probability: 0.92 for the 204 players with tracked offensive data, 0.80 for the 106 with season
  data only; 14 players are under 0.5. Defense: 0.83 to 0.98 by cluster.

### What the numbers do not support

- **The nine offensive clusters are only moderately stable.** Refitting on bootstrap resamples of the fit
  players and reassigning them gives a median adjusted Rand index of 0.59 (1 = identical). BIC is nearly flat
  from 5 to 10 clusters; 5 clusters score 0.76. "Post scorer" rests on two fit players. Defense: 0.77 at four
  clusters, 0.98 at three.
- **Several requested features failed the screen** and are in the tables but not in the clustering: shooter
  speed by zone (reliability 0.10 to 0.40), roll and pop share (0.53, 0.55), cuts (0.49), handoffs (0.62,
  0.69), isolations (0.62), post-ups (0.67), and what follows an off-ball screen (0.13 to 0.31).
- **Mobile and anchor bigs cannot be separated.** Coverage played as the screener's defender and his depth
  have reliability 0.15 to 0.38 (about three screens per player).
- **Odd/even reliability is within a game.** For the 25 players with two tracked games, position features
  repeat across games (r 0.7 to 0.9) but defensive speed (0.15), chasing (0.20), off-ball gap (0.37) and help
  share (0.42) do not, so they may describe the opponent or game plan more than the player.
- **Probabilities are optimistic about season-long role** for tracked features, since their noise is measured
  within games. For players with a handful of attempts the normal approximation is rough.
- Season pick features count direct picks only, which filters on what happened after the screen.
- Tracking speeds use a 0.24 s backward difference without smoothing; "standing still" (under 2 ft/s) is a
  relative measure.

### Revision (same day): number of components and mixture types

Asked by the owner to confirm the PCA step, interpret the components and try more mixture types
(VVI, VEI, EEI, VEV, VVV alongside EII and VII). This supersedes the nine- and four-cluster results above.

- **Components are now chosen by parallel analysis**, not by an 80% variance rule: keep the leading
  components whose variance beats the 95th percentile of the same component in column-shuffled data
  (500 shuffles). Offense keeps 4 (74% of variance; the fifth has 1.49 against a threshold of 1.68),
  defense keeps 2 (77%). The earlier nine offensive clusters leaned on components 5 to 7.
- **Offense components:** 1 (42%) on-ball creator against off-ball screener and finisher; 2 (20%) perimeter
  spacer against interior scorer; 3 (7%) high-volume jump-shot scorer against low-usage rim attacker;
  4 (6%) isolation and off-screen wing scorer against organiser. **Defense:** 1 (59%) interior against
  on-ball perimeter; 2 (17%) sagging helper against defender engaged in screening actions.
  Loadings: `outputs/archetypes/{offense,defense}_component_loadings.csv`.
- **Best BIC across the seven types is three clusters on each side**: offense VEV 3 (BIC -2103; ball handler,
  floor spacer, interior big), defense VVV 3 (-1124; perimeter defender, helper, anchor big). Full-covariance
  models win because the players lie along a continuum; three stretched groups describe it better than more
  round ones. These are the untagged output files.
- **Finer alternative kept beside it** (`*_fine.csv`): offense EII 6 (BIC -2134, the best with more than four
  clusters: lead guard, slashing guard, off-screen scorer, floor spacer, attacking forward, interior big),
  defense EEI 4 (-1135: point of attack, perimeter chaser, helper, anchor big). BIC is 31 and 11 points
  worse than the three-cluster fits.
- **Bootstrap stability** (30 resamples, so good to about +/-0.1): offense VEV 3 0.67 to 0.75, EII 6 0.72 to
  0.73; defense VVV 3 0.67 to 0.78, EEI 4 0.88 to 0.90. On seven components the variable-volume models
  could not be refitted on 60% to 97% of resamples.
- `cluster_archetypes.R` takes `--{offense,defense}-{k,model,pcs}` and `--tag`.

### Working solution chosen (owner, same day)

Offense EII with 7 clusters, defense EEI with 4, on the parallel-analysis components (4 and 2). These are
now the script's defaults (`CHOSEN` in `cluster_archetypes.R`; `--bic` gives the best-BIC three-cluster fits
instead) and the untagged files in `outputs/archetypes/`. The `_fine` files were removed.

- Offense (all players / fit players): lead guard 44/20, stretch shooter 63/26, attacking forward 40/17,
  interior big 70/20, corner wing 18/7, slashing guard 29/12, off-screen scorer 46/25. BIC -2152 against
  -2103 for the best fit; stability 0.71 to 0.73.
- Defense: point of attack 35/27, helper 75/54, perimeter chaser 46/31, anchor big 49/27. BIC -1135 against
  -1124; stability 0.88 to 0.90.
- Past seven offensive clusters every new group has 2 to 6 fit players and stability falls to about 0.66.
  At seven or more, EII and EEI beat VEI, VVI, VEV and VVV on BIC and stability; the full-covariance types
  cannot be refitted on 10% to 93% of resamples.
- Each cluster's centre on the components is in `{offense,defense}_cluster_components.csv`.

### Working solution revised (owner, same day)

Offense is now EII with 6 clusters on 4 components (was 7); defense stays EEI with 4 on 2 components.
`CHOSEN` in `cluster_archetypes.R` and the untagged files in `outputs/archetypes/` reflect this.

- Offense (all players / fit players): lead guard 44/20, slashing guard 29/12, off-screen scorer 47/27,
  attacking forward 38/13, floor spacer 83/35, interior big 69/20. BIC -2134; stability 0.72 to 0.75;
  mean top probability 0.93 with tracked data, 0.82 season only; 15 players under 0.5.
- Reason: against 7 clusters it fits better (18 BIC points), labels are about 0.04 more certain and the
  smallest cluster has 12 fit players instead of 7. The cost is losing the stretch-shooter / corner-wing split.
- Also examined: components 5 to 10 (5, 7 and 8 read as basketball but none beats the shuffled-data
  threshold; rebounding position rides on component 1 and, independently, on component 8), and a
  five-component six-cluster fit (stability 0.78; separates six pick-and-roll orchestrators but merges
  slashing guards into lead guards), kept as `*_pc5k6.csv`.

### Archetype names and the play viewer (owner, 2026-10-10)

- Renamed by the owner. Offense: Primary Ball Handler (was lead guard), Slasher (slashing guard), Secondary
  Ball Handler (off-screen scorer), Athletic Finisher (attacking forward), Floor Spacer, Roll & Cut Big
  (interior big). Defense: Point of Attack, Chaser (perimeter chaser), Helper, Anchor Big. The clusters are
  unchanged; the membership columns are now `p_primary_ball_handler` and so on. "Roll & Cut Big" names the
  role: roll and cut counts were too noisy to be clustering inputs.
- The play viewer shows each player's archetype beside his name (offensive archetype for the team with the
  ball, defensive role for the other) and has a second tab, Archetypes, that explains the method, defines each
  archetype and component, and reads its counts, scores, loadings, fit and stability from `outputs/archetypes/`.
  The basketball wording is in `src/play_viewer/R/archetype_page.R`; tag labels and colours are
  `ARCHETYPE_TAGS` in `src/play_viewer/R/data.R`.
- The static site in `web/` (what GitHub Pages serves) carries the same tags and Archetypes tab. Its export
  writes each player's archetype into the period files and the Shiny page as `public/data/archetypes.html`, so
  the wording is edited in one place. The site only redeploys when a push touches `web/`.

## 2026-10-11 — Play viewer: possession windows, team colours, layout

Prompted by possession-191313-4-152 (Zaragoza, Q4 0:04), listed as a made three by Spissu but ending on a
free-throw rebound. Checked across all 1,564 delivered possessions in the ten games.

### What the delivered data does

- **A possession's `endFrame` can stop before the possession does.** In 72 possessions the last chance or the
  last shot ends after `endFrame`, in 44 of them by more than a second. Three patterns: 27 possessions,
  mostly the last of a period, are delivered with `startFrame == endFrame` while their one chance holds the
  real span (up to 3,528 frames); a possession with several chances can end where its last chance starts (the
  case above, which also has a chance with reversed frames); and 14 possessions end on the shot's release frame.
- **Result:** 24 possessions were left out of the viewer as "under 25 live frames" although they are real:
  15 with a shot (six makes) and 9 that run out the period. 44 more stopped early.
- **36 action markings carry the wrong `possessionId`:** 27 off-ball screens, 5 closeouts, 2 drives and 2
  isolations are filed under their period's last possession though their frame lies in an earlier one, up to a
  whole quarter earlier. Shots, picks, handoffs, posts and fouls are all filed correctly.
- One possession (178442, first of Q4) is delivered with a start frame 58 seconds inside Q3.
- Not errors: 19 rebounds fall after their possession's window (a defensive rebound belongs to the shot's
  possession and happens at the start of the next), and possession outcomes agree with their last shot and last
  chance in every case.

### Decisions

- The viewer plays each possession over a **viewing window**, `view_start` to `view_end` in the play index:
  `view_end` is the latest of the delivered end, the end of the possession's last chance and the end of its
  last shot; both ends are clipped to the tracking frames of the possession's own period. `start_frame` and
  `end_frame` are kept as delivered. The viewer now lists 1,557 possessions (was 1,533); 7 stay out (zero or
  near-zero length with nothing in them).
- Action markings filed under the wrong possession are moved to the possession whose window holds their frame
  (`rehome()` in `src/play_viewer/R/data.R`). Play-type tags changed on 22 possessions.
- **Not changed: EPV and the archetype features.** Both read `start_frame`/`end_frame` from the play index, so
  the added tails and the 24 added possessions have no prices yet, and their frames are not in the tracked
  features. The 24 additions are now rows of the index, so a rebuild of either would pick them up as
  zero-length possessions. Whether the models should use the viewing window is open.
- Seven possessions have no running-clock frame in their window (stuck or unread clock in 178442 Q4, and
  whistle-to-whistle plays). With "Skip dead ball" on the viewer shows them whole, as before.

### Viewer changes

- Teams are drawn in club colours whichever end they play (`TEAM_COLORS` in `data.R`, entered by hand: primary
  and secondary). Dot fill and hull use the primary, the ring the secondary; where two primaries are too alike
  the away team swaps (Granada at Manresa). Colours are presentation only.
- Quarter, shot clock, game clock and score moved from the canvas to the page header, and the EPV readout to
  the side panel, so the court fills the stage. A recorded video draws them on the canvas again, since it
  captures the canvas alone.
- Later the same day: the score spans both header lines with the game clock over the quarter and shot clock to
  its right; the EPV readout always shows when a play has prices ("Show/hide all" only switches the labels on
  the court); a "Player archetypes" toggle rings each player on the court in his archetype's colour; the
  "Mark extrapolated positions" toggle was removed (the detected flags are still exported, unused).
- The site's data requests carry the export's stamp (`web/vite.config.ts`, `web/src/lib/data.ts`). Without it a
  browser paired a new build with data files cached from the previous export and drew nothing.
- Timeline captions: a tick with room keeps a flat caption; where ticks crowd, captions tilt 24 degrees from
  anchors spread along the rail, each joined to its tick by a leader line, so every event is captioned (before,
  a third overlapping caption was dropped). `layoutTimeline` in `web/src/lib/sequence.ts`, mirrored in `player.js`.
- The court's layout margin went from 4 ft to 1.5 ft outside the lines; players up to 4 ft out are still drawn.
  A team's hull area is always reported, whether or not the hull is drawn.

## 2026-10-11 — EPV: xFG restructured by location and zone

Status: exploration. Supersedes the xFG, rebound and three-point definitions in the 2026-10-10 EPV entry.
The other components and the EPV model's form are unchanged. Code: `src/epv/R/models.R` (`fit_xfg`,
`predict_xfg`, `shot_value`), `src/epv/R/features.R`, `src/epv/build_epv.R`.

### Decisions (owner)

- xFG starts with a location GAM, `made ~ s(x, y)`, on unfouled attempts. Its probability (`loc_xfg`) is
  then an input to a context model beside `def1`, `def2`, `n6`, `between`, `rim_def`, `closing`, `speed`,
  `sc`, `held` and `drib`. Distance and the three-point flag are not inputs to the context model.
- The context model is fitted separately for rim, midrange and three-point attempts.
- The offensive-rebound rate is one constant (0.314 over the ten games) until it is modelled spatially.
- EPV is to be improved and is not meant to stay a separate GAM-plus-boosting fit. Its replacement is not
  yet specified; see "Open choices".

### Definitions added

- **Zones.** Three = the scorer's flag for real shots, court geometry otherwise. Rim = a two within 6 ft of
  the hoop (the cut already used in `src/archetypes`; make rate falls from about 0.60 to 0.36 between 6 and
  7 ft). Midrange = every other two. Unfouled attempts: 431 rim, 340 midrange, 506 three.
- **Geometric three-point flag** now has a 1 ft margin (`ARC_MARGIN`): beyond 21.15 ft from the hoop or
  20.65 ft from the centre line. Tracked release positions sit inside the painted line; with no margin 83 of
  1,421 real shots disagreed with the scorer (74 threes read as twos), with the margin 40 do (21 and 19).
- **Location model.** `s(x, y, k = 30)`, signed y, about 11 effective degrees of freedom. Folding the court
  (`|y|`) scored the same on held-out games (0.656 against 0.655), so the signed form was kept as specified.
  Backcourt positions are evaluated at the half-court line.
- **Zone context model.** Boosting (same settings and round selection as every other component) that starts
  from the zone's training make rate, monotone increasing in `loc_xfg`, `def1`, `def2` and decreasing in
  `n6`, `between`.
- **Shot range.** No shot value is given beyond 30 ft (`SHOT_RANGE`; the value is 0). Only 8 of the 1,278
  unfouled attempts came from further out, and 59% of priced frames have the holder beyond it. Added because
  the three-point zone has a constant xFG (below), which priced a backcourt heave at 1.24 points.
- Signed `y` was added to the context columns; `angle` was dropped (no model uses it now).

### Validation (leave-one-game-out)

| Component | n | Zone or base rate | Location GAM alone | Full | Gain ± SE | Games better | Rounds |
|---|---|---|---|---|---|---|---|
| xFG, all unfouled | 1,277 | 0.688 | 0.665 | 0.649 | 0.039 ± 0.005 | 10 | – |
| xFG, rim | 431 | 0.670 | 0.673 | 0.638 | 0.030 ± 0.009 | 9 | 40 in all folds |
| xFG, midrange | 340 | 0.662 | 0.679 | 0.670 | −0.007 ± 0.005 | 0 | 40 in 2 folds, 0 in 8 |
| xFG, three | 506 | 0.643 | 0.650 | 0.643 | 0 | 0 | 0 in all folds |
| EPV (squared error) | 171,245 | 1.387 | – | 1.383 | 0.003 ± 0.002 | 8 | 0 in all folds |

The all-shots row is scored against the overall make rate; zone rows against the zone's own make rate.
The previous xFG scored 0.650 (0.037 ± 0.007, 9 games). Foul, pass and turnover components moved only in
the third decimal. Counts are slightly lower than on 2026-10-10 (171,245 frames, 1,420 shots, 3,700
passes); the play index was rebuilt after that build and the feature change does not alter row selection.

In a shots-only test with three seeds: three zone make rates alone 0.657; the previous model 0.651;
context models started from the location model's prediction 0.655; started from the zone make rate 0.646
(better than starting from the location model in 9 of 10 games, 0.009 ± 0.002). The second form was adopted.

### What the numbers do not support

- **The location smooth alone is worse than three make rates** (0.665 against 0.657). One smooth with about
  11 degrees of freedom blurs the step in make rate at the edge of the rim area.
- **Outside the rim nothing beats the zone's make rate.** For threes the context model is empty in every
  fold; for midrange it is empty in eight folds and worse in the other two. On 846 unfouled jump shots
  neither location nor any defender feature separates makes from misses on held-out games. The previous
  pooled model was no better in those zones (three 0.654, midrange 0.661).
- **Perimeter shot value is therefore nearly flat** (xFG 0.34, value 1.24 to 1.26 for every three in range)
  and what variation is left comes from the foul model, which rises with defensive pressure. Among holders
  in range, the top quartile of shot value (mean 1.34) scored 0.97 points in the rest of the possession,
  against 1.06 to 1.12 for the other three. Shot value does not rank perimeter options by openness.
- **EPV is unchanged**: held-out quintiles run from 0.97 predicted (1.02 scored) to 1.20 predicted (1.15
  scored). Its spread is about twice what the outcomes support at the extremes.
- **Training EPV on the shot model's value of the possession's next shot instead of on points did not help**
  (same five GAM terms; scratch test run before the shot-range rule): squared error against realized points
  1.3836 against 1.3831, paired difference −0.0006 ± 0.0019. The label's variance falls from 1.38 to 0.26,
  so target noise is not what limits EPV; the inputs carry little information about how the possession ends.

### Open choices

- The form of EPV (owner). The possession-level composition "shot value at the shot × survival" can be
  computed now from the cached shot value and cumulative turnover risk; a per-frame value still needs some
  forecast of the eventual shot.
- Whether to impose an openness effect on jump shots as an assumption (fixed boosting rounds under the
  monotone constraints) when held-out games do not show one.
- `SHOT_RANGE`, `RIM_ZONE` and `ARC_MARGIN` are fixed assumptions to test for sensitivity.
- The static site in `web/` still carries the 2026-10-10 prices; it was not re-exported.

## 2026-10-11 — Play viewer: the steps behind a shot's xFG, beside the half court

Asked for by the owner: in half-court view, list the location-only xFG, every feature the context model
used at the release, how much each one moves xFG, and the total. The panel is hidden in full-court view.

Code: `explain_xfg()` in `src/epv/R/models.R`; `build_epv.R` saves it per held-out game as `shots` in
`outputs/cache/epv/epv_{gameId}.rds`; `shot_payload()` in `src/play_viewer/R/data.R` sends it with each play.
Shiny: `www/player.js` (shot panel). Site: `web/src/lib/shots.ts`, `web/src/components/ShotPanel.svelte`.

### Definitions

- **Rows.** All 1,420 tracked attempts (143 fouled), each from the fold that held its game out: the ten
  context features at release, `loc_xfg`, the zone, the zone's training make rate, the context model's
  boosting rounds, xFG. A fouled shot is listed with the xFG of an unfouled attempt and a note.
- **Effect of a feature.** Its Shapley contribution to the zone context model's log-odds (xgboost
  `predcontrib`), multiplied by `(xfg - base) / (sum of contributions)` so that a shot's effects add up
  exactly to `xfg - base` in percentage points. The multiplier is positive, so signs are kept.
- **Baseline** (`base`). The context model's average prediction over its training shots: the zone's make
  rate plus the mean of the trees. It is within 0.5 points of the make rate (rim), 0.2 (midrange); for a zone
  whose model has no trees it is the make rate and every effect is zero.
- **Which shot is shown.** The latest shot released at the playback position, or the possession's first shot
  before any release. Numbered buttons (two or more shots) and "Go to release" stop playback on a release frame.

### What the saved effects show

- **Rim (519 shots, trees in all ten folds).** Mean absolute effect in points of xFG: closest defender 6.2,
  rim protector 5.4, time on the ball 4.2, second defender 3.2, location xFG 2.5, shooter speed 1.9,
  dribbles 1.1, shot clock 1.0, closing speed 0.5, defenders in the path 0.1, defenders within 6 ft 0.0.
  Closest defender by distance: under 2 ft about -8 points (155 shots), 2 to 3 ft -1.7, 3 to 4 ft +3.9,
  4 ft or more about +11 (96 shots).
- **Midrange (387).** Effects exist only for the 85 shots of the two games whose fold kept 40 rounds
  (114243, 178442); the other 302 are zero.
- **Three (514).** Zero for every shot: no fold kept a tree.

### What the numbers do not support

- **Effects describe the model, not the play.** They are attributions of a fitted model's prediction, not
  estimates of what would have happened with the defender elsewhere.
- **For jump shots there is nothing to show.** A closest defender 2 ft from a three-point shooter moves xFG
  by 0.0 because the held-out games gave no support for any context effect there (xFG entry above). The
  panel says so under the table; it does not mean openness is irrelevant to threes.
- **The two midrange folds with trees scored worse than the make rate on their held-out game**, so the
  effects shown for those 85 shots are not validated.
- **The rim-protector effect is not monotone** (defender nearest the hoop 0 to 2 ft from it +0.6, 2 to 4 ft
  -5.8, 4 to 6 ft +6.6, further +10): `rim_def` has no monotone constraint. Time on the ball switches sign
  at 2 s (+4 to +5 below, -3.5 above).
- 68 shots have no time on the ball or dribble count (the shooter was not the tracked holder at release);
  the trees send them down their default branch, which carries an effect (-4.2 points at the rim).

### Checks

- The refit that added `shots` reproduced the prices: every game's `frames` and `players` tables equal the
  previous cache and both validation tables are byte-identical. No model, feature or price changed.
- Effects sum to `xfg - base` to 1e-16 before rounding; the site's test allows 0.001 after rounding to four
  decimals and checks that the site's feature list is the model's.
- The static site was re-exported, so it now carries the 2026-10-11 prices (closing that open item above).
- A recorded video captures the canvas only; the panel is not in it.

### Follow-up (same day): why jump shots show no context effect, and a pending change

Asked by the owner, who expects defender distance to matter on midrange and three-point shots and asked why
the location xFG is not at least the starting point there. Scratch checks on the 846 unfouled jump shots.

- **Pending (owner):** `rim_def` is not to be a feature for midrange and three-point shots. To be removed at
  the next refit; nothing was refitted here.
- **The direction is the expected one, the sample cannot size it.** Make rate on threes by closest defender:
  2 to 4 ft 29.8% (114 shots), 4 to 6 ft 34.3% (169), 6 to 8 ft 35.5% (107), 8 ft or more 36.0% (100), each
  with a standard error of 4 to 5 points. Logistic slope: +0.8 points of xFG per foot on threes (95% interval
  -1.0 to +2.6), +1.8 on midrange (-0.8 to +4.5).
- **A one-parameter model does not beat the make rate on held-out games either.** Leave-one-game-out log
  loss, logistic in defender distance alone: threes 0.6448 against 0.6432 (gain -0.002 +/- 0.002, better in
  5 games of 10); midrange 0.6627 against 0.6622 (0.000 +/- 0.004, 6 of 10). Adding a catch-and-shoot flag:
  midrange 0.6579 (+0.005 +/- 0.010), threes 0.6471.
- **Location is worse than the make rate inside both zones**: midrange 0.6794 against 0.6622 (better in 2
  games of 10), threes 0.6496 against 0.6432 (1 of 10); refitted to each zone it is still worse (0.6675,
  0.6560). The location model's gain over the overall make rate comes from telling the zones apart.
- **The season aggregates do show the effect** (per-team rows, 293 games): uncontested threes 38.3% of 4,694,
  contested 33.9% of 10,872, a gap of 4.4 +/- 0.9 points; twos 72.8% against 47.6%. "Contested" is the
  vendor's label (average, plus or blocked), so it includes blocked shots, and these games include the ten
  tracked ones. With about 500 tracked threes a gap of that size has a standard error near 4.5 points.
- Not decided: whether jump-shot xFG should carry a defender-distance effect set by assumption or by the
  season aggregates instead of chosen by held-out log loss.
- The rim zone ends at 6 ft, so a layup released from 6.8 ft is priced as midrange (make rate 58.5% at 5 to
  6 ft, 35.8% at 6 to 7 ft on 53 shots).

### Follow-up (same day): midrange and three pooled into one jump-shot context model (scratch test)

Proposed by the owner: keep the one location GAM, then two context models, rim (unchanged) and jump shots
(every non-rim attempt). Tested on the shots alone, leave-one-game-out, three seeds, same boosting settings
and round selection. Not adopted or rejected; no model code or price changed.

Held-out log loss on the 846 unfouled jump shots:

| Prediction | Log loss | Per-game gain over the two make rates ± SE | Games better |
|---|---|---|---|
| One jump-shot make rate | 0.6500 | +0.0008 ± 0.0008 | 5 |
| Midrange and three-point make rates | 0.6508 | – | – |
| Location GAM alone | 0.6616 | −0.0105 ± 0.0035 | 2 |
| Current: separate midrange and three context models | 0.6521 | −0.0012 ± 0.0013 | 2 |
| Pooled jump-shot context model, started from the jump make rate | 0.6522 | −0.0013 ± 0.0024 | 5 |
| Same without `rim_def` | 0.6524 | −0.0016 ± 0.0027 | 5 |
| Same, started from the two make rates | 0.6519 | −0.0011 ± 0.0011 | 2 |
| Same, started from the location model | 0.6649 | −0.0138 ± 0.0027 | 1 |

- The pooled model kept no trees in 28 of 30 fits (40 rounds in the other two), so on most folds it is the
  jump-shot make rate. All unfouled shots: 0.6464 pooled against 0.6463 current.
- One logistic slope on closest-defender distance over the pooled jump shots, with the two/three flag:
  +1.1 points of xFG per foot (95% interval −0.4 to +2.6; positive in 95% of 2,000 game-level bootstrap
  draws). Held out it scores 0.6506 against 0.6508 (gain 0.0000 ± 0.0018, better in 7 games of 10).
- Reading: an effect of about a point per foot would lower log loss by roughly 0.001, which is smaller than
  the fold-to-fold noise of the comparison (about 0.002). Held-out log loss cannot confirm or reject an
  effect of that size on 846 shots, pooled or not.

## 2026-10-11 — xFG: jump shots pooled, closest-defender slope set from the season aggregates

Status: adopted by the owner. Supersedes the zone context models of the "xFG restructured by location and
zone" entry for midrange and three-point shots; the location GAM and the rim model are unchanged in form.
Code: `fit_xfg`, `xfg_start`, `predict_xfg`, `explain_xfg` in `src/epv/R/models.R`; `src/epv/R/season.R`;
`src/epv/build_epv.R`. The slope and the counts behind it: `outputs/epv/jump_fixed_effects.csv`.

### Decisions (owner)

- Two context models: rim (as before) and jump shots (every non-rim attempt, midrange and three together).
- Jump shots carry a closest-defender slope that is fixed, not chosen by held-out log loss.
- `rim_def` is not an input for jump shots. It stays in the rim model.

### Choices made in the implementation (for the owner to confirm or change)

- **Level.** The jump model starts from the make rate of twos or of threes (two levels fitted on the
  training games with the slope in place), not from one jump-shot rate. With one level the slope
  under-predicts midrange shots, whose defenders stand closer (0.33 predicted against 0.37 made).
- **Shape.** Linear in log-odds per foot of closest-defender distance up to 10 ft (`DEF_CAP`), flat beyond.
  Capping at 8 or 6 ft scored worse on held-out games in a scratch test (jump shots 0.6504 and 0.6543 against 0.6498).
- **Source.** The slope is a line through two points: season threes labelled uncontested and contested.
  It is applied to midrange shots too; the aggregates have no contested split for midrange alone.
- **One slope for all ten folds.** It uses season outcomes from outside the tracked games, plus labels and
  positions (no outcomes) of the tracked games.
- Boosting still runs on top for jump shots, on the same features less `rim_def`, with rounds chosen by
  inner validation. It kept no trees in any of the ten folds.

### Definitions

- **Slope.** Season threes with the ten tracked games' box-score attempts taken out (283 games): uncontested
  (vendor level open or light) 38.4% of 4,543, contested (average, plus or blocked) 34.0% of 10,510, a
  log-odds gap of 0.192 (se 0.037). On tracked threes the closest defender is 7.71 ft away on average when
  the vendor says uncontested and 4.91 ft when contested, capped at 10 ft: 2.80 ft apart. Slope =
  0.192 / 2.80 = 0.0686 log-odds per foot, about +1.6 points of xFG per foot near 35%.
- **Jump-shot xFG.** `plogis(level[two or three] + 0.0686 * min(def1, 10))`, then trees if any are kept.
- **Panel.** The baseline of a jump shot is the model's xFG at the average defender distance of training
  twos (3.7 ft) or threes (5.7 ft); the closest-defender effect is measured from there. Jump shots no
  longer list the rim protector. The panel says the slope comes from the season and was not fitted.
- Shots saved per game now carry `zone` (rim or jump), `area` (rim, mid, three) and `fixed`.

### Validation (leave-one-game-out), against the previous model and the make rates

| Shots | n | Make rate(s) | Location GAM | Previous model | This model | Gain over previous ± SE | Games better |
|---|---|---|---|---|---|---|---|
| All unfouled | 1,277 | 0.6876 | 0.6655 | 0.6486 | 0.6447 | 0.0036 ± 0.0019 | 8 |
| Rim | 431 | 0.6701 | 0.6730 | 0.6379 | 0.6349 | 0.0032 ± 0.0024 | 5 |
| Jump | 846 | 0.6508 | 0.6616 | 0.6540 | 0.6497 | 0.0038 ± 0.0031 | 7 |
| Midrange | 340 | 0.6622 | 0.6794 | 0.6701 | 0.6594 | 0.0107 ± 0.0037 | 8 |
| Three | 506 | 0.6432 | 0.6496 | 0.6432 | 0.6431 | −0.0003 ± 0.0035 | 3 |

The make-rate column is the overall rate for all shots, the midrange and three-point rates for jump shots.
Against the make rates this model gains 0.0008 ± 0.0022 on jump shots (better in 6 games), 0.0032 ± 0.0037
on midrange (6) and −0.0003 ± 0.0035 on threes (3). Other components: EPV squared error 1.3831 to 1.3816
(0.0015 ± 0.0005, 8 games; gain over the base rate now 0.005 ± 0.002); foul 0.2872 to 0.2907; pass
turnover 0.0791 to 0.0787; turnover within 2 s unchanged.

### What the numbers do not support

- **The slope is not shown to improve prediction.** On jump shots the gain over the make rates is a third
  of its standard error, and on threes it is nil. The model is adopted on the season evidence and the
  owner's judgment, not on held-out log loss.
- **Most of the gain over the previous model is the previous model's own damage.** Its midrange trees, kept
  in two folds, scored worse than the make rate (0.6701 against 0.6622).
- **The rim row moved without the rim model changing.** The xFG stage now has one boosting fit fewer per
  fold, so every later fit draws different random numbers. Rim (0.003) and foul (0.004) shifted for that
  reason alone, which is as large as the changes being measured. A fixed seed per component would stop it.
- **The ends of the line are extrapolation.** The two season points sit near 4.9 and 7.7 ft. Held out,
  threes with a defender under 2 ft were priced at 27.7% and made 37.5% (16 unfouled shots); midrange shots with
  8 ft or more of room were priced at 46% and made 60% (15 unfouled shots). xFG on jump shots now runs from 26% to 49%.
- **"Contested" includes blocked shots**, which always miss, and the season percentages count and-one makes
  as attempts while xFG is fitted to unfouled attempts. Both are small for threes (5 of 362 tracked
  contested threes were blocked) and neither was corrected.
- Shot value on the perimeter now rises with openness, so pass values to open teammates rise with it. The
  earlier cautions about hypothetical options (defenders are not moved during a catch) apply with more force.

### Other effects the season aggregates could supply (not adopted)

- **Catch-and-shoot against off the dribble.** Season threes, tracked games out: 36.8% of 10,327 against
  32.2% of 4,778 (log-odds gap 0.203, se 0.037). Time on the ball of 1.5 s or less matches the vendor's
  flag on 96% of tracked threes. Because catch-and-shoot threes are also more open, the two season gaps were
  solved together: defender 0.072 per foot, catch-and-shoot 0.09 (about +2 points). Held out it changes
  nothing measurable (jump shots 0.6498 with or without; midrange 0.6584 against 0.6594, threes 0.6440
  against 0.6434).
- **Corner against above the break.** 37.9% of 3,320 against 35.1% of 11,477 (gap 0.119, se 0.041). Not tested.
- Not usable for jump shots: contested and catch-and-shoot splits of twos, and the five contest levels,
  because they mix rim attempts with jump shots; shot-type splits, which describe the shot after the fact.
- Zone make rates themselves (midrange 40.6% of 4,017 in the season against 36.8% of 340 tracked) could set
  the levels, but the vendor's zones are not the model's and the season counts include and-one makes.

### Revision (same day): catch-and-shoot effect added to the jump-shot model

Decided by the owner after the entry above. Jump shots now carry two fixed effects, solved together from the
season aggregates (`season_jump_effects()` in `src/epv/R/season.R`, `jump_fixed()` in `R/models.R`). This
changes the defender slope given above; the numbers here are the current ones.

- **Catch-and-shoot** in the model is 1.5 s or less on the ball at release (`CATCH_SECONDS`), the vendor's
  rule on its own release time. A shooter with no tracked touch is not one. On tracked threes the flag is 1
  for 99% of the vendor's catch-and-shoot attempts and 5% of its off-the-dribble ones. Teammates priced as
  hypothetical shooters have 0 s on the ball, so they are catch-and-shoot.
- **Season gaps** (threes, tracked games out): uncontested 38.4% of 4,543 against contested 34.0% of 10,510
  (log-odds 0.192, se 0.037); catch-and-shoot 36.8% of 10,331 against off the dribble 32.2% of 4,796
  (0.204, se 0.037). Shots the vendor left unlabelled are in neither side of a split.
- **Solved together**, because catch-and-shoot threes are also more open (closest defender 6.3 ft against
  4.7 ft; 77% of uncontested threes are catch-and-shoot against 62% of contested ones). The pair that
  reproduces both gaps: **0.0631 log-odds per foot** of closest-defender distance (about +1.4 points of xFG
  per foot near 35%) and **0.108 for a catch-and-shoot attempt** (about +2.4 points). Alone, the defender
  slope was 0.0686 and the catch-and-shoot gap 0.204.
- **Panel.** The catch-and-shoot effect is shown on the Time on the ball row, measured from the share of
  catch-and-shoot attempts among training twos (22%) or threes (66%): about +0.8 points for a
  catch-and-shoot three and −1.5 for one off the dribble.

Held-out log loss, against the model with the defender slope alone (rim and every other component are
identical between the two runs, so these differences are the effect itself):

| Shots | n | Make rate(s) | Defender slope only | With catch-and-shoot | Gain ± SE | Games better |
|---|---|---|---|---|---|---|
| Jump | 846 | 0.6508 | 0.6497 | 0.6496 | 0.0000 ± 0.0009 | 4 |
| Midrange | 340 | 0.6622 | 0.6594 | 0.6584 | 0.0007 ± 0.0013 | 6 |
| Three | 506 | 0.6432 | 0.6431 | 0.6437 | −0.0006 ± 0.0011 | 4 |
| All unfouled | 1,277 | 0.6876 | 0.6447 | 0.6447 | 0.0000 ± 0.0006 | 4 |

EPV squared error 1.3816 to 1.3815. Against the original three-zone model: all shots 0.6486 to 0.6447
(0.0036 ± 0.0020), jump shots 0.6540 to 0.6496 (0.0038 ± 0.0032), EPV 1.3831 to 1.3815 (0.0016 ± 0.0005).

- **The ten tracked games do not show the catch-and-shoot effect on threes.** Unfouled catch-and-shoot
  threes made 34.0% (332) and the rest 33.9% (174); the model prices them at 35.6% and 30.8%. On midrange
  shots the tracked gap is larger than the model's (43.2% of 81 against 34.7% of 259; priced 39.5% and
  35.9%). Like the defender slope, the effect is adopted on the season's evidence, not on these games.
- It is the three-point effect applied to midrange shots as well, by the same assumption as the slope.
- xFG on jump shots now runs from 26% to 49%.

## 2026-10-12 — Search for twelve archetypes resembling BBall Index's offensive roles

Status: exploration. The working solution (offense EII, 6 clusters, 4 components) is unchanged; the best
twelve-cluster candidate is saved beside it as `outputs/archetypes/offense_*_bbi12.csv`.

- **Search.** 504 twelve-cluster fits: 4 to 12 principal components, all 14 mclust covariance types, two
  feature sets (reliability bar 0.7 with 45 features, 0.5 with 63) and two fit sets (40+ tracked chances and
  50+ season attempts, 127 players; 25+ and 30+, 169 players). 339 could be fitted.
- **Scoring.** Each BBall Index role was written as target values (standard deviations from the average fit
  player) on the descriptors its published description mentions; each cluster centre's root-mean-square
  distance from each target was computed and clusters were matched one-to-one to roles. The targets are my
  reading of the descriptions. Shuffled labels score about 0.75; the fits score 0.43 to 0.60.
- **Result.** No setting recovers all twelve. The closest fits put 9 or 10 roles within 0.6. The guard and
  wing roles come out consistently (off-screen, stationary and movement shooters, shot creator, slasher,
  ball handlers, athletic finisher) and so do post scorer and roll and cut big. Stretch big never separates
  from movement shooter, versatile big appears only as post-and-isolation forwards who do not shoot threes,
  and there is no low-initiation secondary ball handler: the data gives two kinds of lead guard instead.
- **Stability falls.** Twelve clusters score 0.56 at best against 0.73 for six. The closest fit of all (EEV,
  9 components, 0.43) scores 0.29. The variable-volume types (VII, VEI, VEV, EVI) cannot be refitted on 40%
  to 100% of resamples.
- **Candidate kept.** EII, 9 components, bar 0.5, 169 fit players: distance 0.46, stability 0.52, no failed
  refits, smallest cluster 6 fit players, mean top probability 0.85. Eleven clusters carry a BBall Index name
  and one ("Combo Wing") has no counterpart. BIC prefers far fewer clusters on these components.
- `cluster_archetypes.R` gained `--offense-bar`, `--offense-fit-chances` and `--offense-fit-attempts`.
- **Second candidate written for comparison** (owner's request): EEI on the four components that beat the noise
  test, same features and fit players, as `outputs/archetypes/offense_*_bbi12_eei4.csv`. Stability 0.56 against
  0.52, mean top probability 0.79 against 0.85, 32 players under 0.5 against 20. It also carries eleven BBall
  Index names; its twelfth cluster is pull-up lead guards. Its shot creator is six isolation specialists
  (mean top probability 0.69) and its post scorer is a broad group of 27 bigs. The two candidates agree at an
  adjusted Rand index of 0.46. `offense_membership_bbi12_compare.csv` has every player's label under the
  default and both candidates.

### Search extended to 8 to 12 clusters (owner's request, 2026-10-12)

- 2,520 fits: 8 to 12 clusters, 4 to 12 components, all 14 mclust types, both feature bars and both fit sets;
  1,922 could be fitted. Stability (20 resamples) was measured on 146 of them: the closest fits at each count,
  and every EII and EEI fit on 4 to 8 components with 169 fit players. Each cluster was matched to a different
  BBall Index role. Full table: `outputs/archetypes/search_8_to_12_clusters.csv`.
- The closest fit at every count is a many-component EEV or EEE model with stability 0.25 to 0.40, or a
  variable-volume model that cannot be refitted. Among models that always refit, the best are EII or EEI on
  four components.
- Best balanced fit per count (169 fit players; distance, roles within 0.6, stability): 8 clusters EII bar 0.7
  (0.37, 8 of 8, 0.68); 9 EII bar 0.5 (0.43, 8 of 9, 0.66); 10 EII bar 0.7 (0.42, 9 of 10, 0.63); 11 EEI
  bar 0.7 (0.45, 10 of 11, 0.58); 12 EEI bar 0.5 (0.47, 10 of 12, 0.58).
- Roles appear in this order as clusters are added: at 8, primary ball handler, slasher, off-screen shooter,
  stationary shooter, movement shooter, athletic finisher, versatile big, roll and cut big; at 9 a secondary
  ball handler (scoring guards) splits from the off-screen shooters; at 10 post scorer splits from the bigs;
  11 and 12 add a small pull-up guard group and four isolation specialists. Stretch big never appears.
- Reading: ten clusters is the last count that adds a clearly recognisable role before stability drops
  below 0.6. Nothing has been adopted; the working solution is still six clusters.

### Working offensive solution changed to ten archetypes (owner, 2026-10-12)

- Offense is now EII with 10 clusters on 4 components, the same 45 features (bar 0.7), with the fit players
  widened to 25+ tracked chances and 30+ season attempts (169 players). Defense is unchanged. These are the
  defaults in `cluster_archetypes.R` (`CHOSEN`) and the untagged files in `outputs/archetypes/`.
- Clusters (all players / fit players): primary ball handler 45/26, secondary ball handler 30/18, slasher
  29/13, off screen shooter 20/15, movement shooter 52/26, stationary shooter 21/11, athletic finisher 36/22,
  versatile big 12/7, post scorer 29/15, roll and cut big 36/16.
- Stability 0.62 (30 resamples), against about 0.73 for the six-cluster solution it replaces. Mean top
  probability 0.83 with tracked data and 0.70 season only; 24 of 310 players under 0.5.
- Viewer and site: each roster tag is the archetype's name in an outlined pill of its colour (Primary BH,
  Secondary BH and R&C Big shortened, the rest in full), ten offensive colours, and the right-hand column
  widened from 260 to 330 px to fit the tags. Defensive roles borrow the colour of the offensive archetype
  most of their players have: point of attack from primary ball handler, chaser from secondary ball handler,
  helper from movement shooter, anchor big from roll and cut big. The Archetypes page wording was rewritten
  for the ten archetypes. The `_bbi12` and `_bbi12_eei4` candidate files are left in place.

## 2026-10-16 — Court control model and its overlay in the play viewer

Status: exploration, at the owner's direction. Adapts soccer's pitch control (Spearman 2016, 2017; the
"relevant" and scoring-opportunity layers of Spearman 2018; Fernandez and Bornn 2018) to the court. When a
shot is in the air the surface becomes the offensive-rebound chance given the shot's spot and the ten players.
Code: `src/court_control/` (`R/data.R`, `R/control.R`, `build_control.R`). Outputs: `outputs/court_control/`
(parameters, validation and calibration tables). Cache: `outputs/cache/court_control/` (git-ignored).
Site: `web/src/lib/control.ts` (the model, run live in the browser), `web/src/lib/controlLayer.ts` (drawing),
"Court control" panel in `SidePanel.svelte`; `web/tests/control.test.ts` checks the site against R.

### Decisions (owner)

- The overlay is on the static site only, not the Shiny app.
- Three live-ball layers: control, relevant control, scoring opportunity.
- While a shot is in the air the rebound surface replaces the layer and is recomputed every frame as players
  move; the chance at release is shown beside the current one.
- The rebound model replaces EPV's constant offensive-rebound rate only if it beats the base rate on held-out
  games. **Not done yet**: see "Open choices".

### Definitions

- **Physics (both modes).** A player keeps his velocity for a reaction time, then runs straight to the spot at
  top speed (18.1 ft/s, the 99th percentile of tracked speed). His chance of having arrived by time t is
  logistic in t minus that time, with spread sigma. From the moment the ball reaches the spot, an arrived
  player takes control at rate lambda while it is free (Spearman's integration, 0.04 s steps, up to 6 s or
  99% controlled). Shown: offense share of control. Velocities: 0.24 s backward difference, as in EPV.
- **Live ball.** Ball travel time to a spot is a pass's flight time for that length (0.016 s + 0.020 s per
  foot, fitted on completed passes). Grid: 2 ft over the whole court.
- **Rebound.** Ball time to a spot = rest of the shot's flight (0.44 s + 0.035 s per foot of shot distance,
  from release to the event's end frame) + bounce (0.60 s + 0.046 s per foot from the hoop, from end frame
  to the rebound frame). Landing density: distance from the hoop gamma-shaped (shape 2, mean 4.1 ft + 0.20 ft
  per foot of shot distance), direction a von Mises bump toward the shooter's side (concentration 1.28) over a
  uniform floor (0.37). Fitted by maximum likelihood on where the 629 player rebounds were taken (the
  rebounder's tracked position at the rebound frame). P(OREB) = (1 − team share) × Σ density × offense
  control + team share × offensive rate of team rebounds (9.8% of misses are team rebounds, 65% of them
  offensive). Grid: 1.5 ft, offensive half within 35 ft of the hoop. Only unfouled misses (697 with a state).
- **Rebound physics** fitted by maximum likelihood on which team took each rebound, at the spot it was
  taken, from every 0.2 s sample between release and the rim (3,866 samples): reaction 1.0 s, sigma 0.17 s,
  lambda 113 per s, and defenders' rate × 1.58 (the box-out advantage). Fitted on nine games per fold.
- **Live-ball physics** chosen on passes (3,708 live passes, 66 intercepted): at release, offense control at
  the spot the ball was next taken (receiver's or interceptor's position at the pass's end frame). Passers pick
  safe passes, so raw control is not a completion chance; the grid point (reaction 0.2/0.4/0.7 s × sigma
  0.15 to 0.45 s × lambda 8 to 100) is chosen by log loss after a two-parameter logistic on logit(control),
  fitted on the training games. The court shows raw control. Chosen in every fold: **reaction 0.4 s, sigma
  0.15 s, lambda 100** — the sharp corner of the grid, close to a deterministic time-to-arrive model.
- **Relevance.** Where the ball is 1.44 s later (36 frames; the 3-frame state grid), as a distribution over
  the grid: Gaussian around the ball (spread 10.1 ft), times control^0.19, times exp(−1.06 × feet from the
  hoop / 10). Fitted on 5,000 live frames with a holder (500 per game).
- **Scoring opportunity** = Σ control × relevance × value, where value is the location xFG GAM
  (`s(x, y, k = 30)` on all unfouled shots of the ten games) × 2 or 3 (the EPV arc rule), 0 beyond 30 ft.
- Rebound reference case and every layer are computed identically in R and TypeScript; the site's test
  compares them to 6 decimals.

### Validation (leave-one-game-out)

| Check | n | Base | Model | AUC | Gain ± SE | Games better |
|---|---|---|---|---|---|---|
| P(OREB) at release | 697 | 0.6228 | 0.6101 | 0.59 | 0.013 ± 0.007 | 7 |
| P(OREB) halfway to the rim | 697 | 0.6228 | 0.5984 | 0.63 | 0.024 ± 0.007 | 9 |
| P(OREB) as the ball reaches the rim | 697 | 0.6228 | 0.6075 | 0.60 | 0.017 ± 0.011 | 8 |
| Team at the spot the rebound was taken, from release | 629 | 0.5921 | 0.5665 | 0.63 | 0.024 ± 0.012 | 6 |
| Pass completed, recalibrated control at its spot | 3,708 | 0.0896 | 0.0620 | 0.93 | 0.028 ± 0.005 | 10 |
| Relevance, log density per sample vs distance-only | 5,000 | – | – | – | 0.311 ± 0.009 | 10 |

Base is the training games' rate. Calibration of P(OREB) (`calibration_rebound.csv`) is close in every band
with more than ten shots; predictions run from about 0.15 to 0.55.

### What the numbers do not support

- **The rebound chance at release is a small gain**: 0.013 ± 0.007, under two standard errors, better in 7
  of 10 games. It is clearer halfway through the flight (9 of 10) than at release or at the rim.
- **Rebound "landing" is where the ball was secured**, which depends on where players are, not where it
  first bounced. The density is therefore partly a model of players, and the control term counts them again.
- **Raw live-ball control is not a probability of anything observed.** It is ranked well by pass outcomes
  (AUC 0.93) but its level is only checked after recalibration. The chosen physics sits at the edge of the
  searched grid; sharper values were not tried. The ball handler's own spot is offense-controlled on 85% of
  frames.
- **Scoring opportunity does not predict points.** Held-in frames by quintile of its total scored 1.03 to
  1.08 points in the rest of the possession, with no trend (`check_scoring_opportunity.csv`). Like EPV, it
  describes space, not outcomes.
- The value surface and the relevance model use all ten games (the relevance folds use control grids from
  the all-game physics); neither is used to score outcomes held out.
- Velocities are unsmoothed backward differences; positions extrapolated off screen are used like detected ones.
- The overlay colours are fixed (blue offense, orange defense), not the clubs', because two clubs often share
  a primary colour.

### Open choices

- **EPV.** By the owner's rule ("only if it beats the base rate on held-out games") the rebound chance at
  release qualified on its mean gain, narrowly, and the owner said go ahead. See the EPV result below.
- Whether the box-out advantage should differ by shot distance or zone; a sharper live-ball grid; smoothed
  velocities; down-weighting extrapolated positions.

### EPV with the spatial rebound chance (same day)

At the owner's go-ahead, `shot_value()` now takes each row's spatial P(OREB) (`poreb_spatial`) in place of
the training-fold constant (0.314), falling back to the constant where a row has none.

- **Pricing.** `src/court_control/price_rebounds.R` prices every offensive player on every row EPV prices,
  within 35 ft of the hoop: 604,000 shooter-frames, about 30 minutes. Each game uses rebound parameters fitted
  without it (`outputs/cache/court_control/params_{gameId}.rds`, saved by `build_control.R`). Training games'
  rows in an EPV fold therefore carry parameters that saw the held-out game's rebounds; the held-out game's
  never do. Every shooter row within 30 ft got a value (mean 0.316 against the constant 0.314). A pass
  receiver takes his chance at the pass's pricing frame, from where he stands then, not where he catches.
- **Result (leave-one-game-out, `build_epv.R --refit`).** xFG, foul, pass and turnover components are
  unchanged (they do not use the rebound rate). **EPV is worse**: squared error 1.3827 against 1.3815 with the
  constant, a paired change of +0.0012 ± 0.0003 per game, worse in 9 of 10 games; its gain over the base
  rate falls from 0.0051 ± 0.0022 to 0.0039 ± 0.0022. The value model still keeps no boosting rounds.
- **Reading.** The spatial chance has a little skill for the rebound itself (0.013 ± 0.007 at release), but it
  moves shot value by roughly ±0.07 points from frame to frame, and that variation does not track possession
  points. It makes the value model's main input noisier.
- **Decision (owner): keep the spatial rate** despite the held-out loss. The EPV caches, `outputs/epv/` and
  the site's period files hold the spatial version; the site was re-exported (stamp 2026-10-16T17:25:28Z)
  with a new parity reference, and its 38 tests pass. `build_epv.R --refit --constant-oreb` restores the
  constant rate.
- **Rebuild order now:** `build_epv.R` (feature tables; stops if rebound prices are missing), then
  `src/court_control/build_control.R`, `src/court_control/price_rebounds.R`, `build_epv.R --refit`,
  `web/scripts/export_data.R`, `web/scripts/parity_reference.R`.

## 2026-10-27 — Rebounding models from the physics-informed framework

Status: exploration at the owner's direction, built from "Physics-informed rebounding: research and model framework"
(2026-10-27). Not the entry's question. Code `src/rebounding/`, record and rerun order `docs/project/rebounding.md`,
tables `outputs/rebounding/`, site: Rebounding tab and a rebounding panel beside the court.

### Audit findings that changed the design

- All 17 event counts in the framework's section 2 reproduce exactly. 707 non-fouled misses are eligible (rebound row,
  ball track over 80% of the episode, no gap over 12 frames); 5 are out for poor ball coverage, 1 untracked, 29 have no
  rebound row and stay out of every likelihood.
- **Tracking files skip `frameIdx` values** (1,760 to 5,844 in five games). Reading lines by position silently shifted
  255 windows; lines are now matched on `frameIdx`.
- **Ball `isDetected` is 0 on every frame of every game**, and 44% of ball positions are the exact midpoint of their
  neighbours (about 12.5 Hz keyframes, interpolated). Filters read keyframes only; no strict real-time claim.
- **The ball frame is offset from the player frame at height**: made shots cross rim height 1.1 to 1.7 ft short of the
  nominal hoop at the camera's right end and 0.6 to 1.1 ft past it at the left. Ball physics runs relative to each game
  end's calibrated hoop (from that game's made shots); ball positions are shifted to the player frame in proportion to height.
- **Effective floor 0.98 ft** (bounce minima), not the 0.40 ft ball radius; restitution 0.89.
- The recorded rebound frame falls between the first possible touch (median 0.3 s earlier) and a held-ball proxy
  (0.36 s later), so collection is scored on who got the ball, not when.

### Models and held-out results (leave one game out)

- **Flight**: launch prior (40 nearest tracked attempts, made or missed) → particle filter (400 particles, Student-t
  keyframe likelihood) with a torus rim, backboard and floor; restitution range, normal jitter and observation scale
  picked per fold by multi-step predictive score; miss scenarios only. Just before contact, 0.2 s ahead: error 1.6 ft
  against 2.8 ft without contacts, 90% coverage 97% (Kalman 56%). From contact + 0.2 s: 90% coverage 92% at 0.4 s, 36%
  at 1.0 s. **Untouched landing is not validated**: on about 31 naturally untouched bounces errors are 11–13 ft and
  coverage 39–59%.
- **First build was overconfident**: with the observation scale fixed at its one-step-likelihood floor (0.2 ft),
  post-contact 90% coverage was 11–64%. The scale is now part of the contact grid (0.8 ft chosen in every fold, the
  grid's edge; restitution 0.75–0.9 and jitter also at edges in several folds).
- **Collection** (competing risks over 0.08 s steps, 48 paths, access from reaction + 18.1 ft/s + 10.5 ft reach,
  information policy picked per fold): individual log loss (12 outcomes) at release 2.148 vs team prior 2.375, gain
  0.232 ± 0.034, 10 of 10 games; geometry classifier 2.173. Just before the rim 2.084 vs 2.368 (geometry classifier
  2.063). Team log loss 0.611 (release), 0.591 (rim) vs 0.626 / 0.621. Obstruction adds 0.006–0.011.
- **Fix during the build**: a player 400 ft away kept a 0.44% chance through the floor in log(access). Players with
  access below 1e-4 at a step are now excluded from it and outcomes get a 0.1% uniform floor; all opportunity, skills and
  site outputs were refitted. All eight scenario checks pass (`outputs/rebounding/checks/scenario_checks.csv`).
- **Anticipation reference policy replaced**: role-matched moves without momentum predicted held-out movement worse
  than damped velocity (2.04 vs 0.90 ft). Now damped momentum plus role-matched residuals (0.84 ft), though its spread
  is too wide (98% inside its 80% region).

### What is not supported

- **No player effect passes its identification test, so the site shows the population model only.** Anticipation:
  player sd 0.6 points of probability, significant within games (LR 349) but cross-game r 0.24 for the 25 two-game
  players. Box-outs (spatial proxy): sd 0.32 on the logit, cross-game r −0.47, no held-out gain. Collection: held-out
  gain on seen rebounders −0.0001, simulated recovery r 0.45 at a true sd of 0.3.
- Box-out labels and contact/touch/control timings are automated rules, not reviewed video; 60 episodes are listed for
  review in `outputs/rebounding/audit/review_sample.csv`.
- Maintaining an established box-out is barely predictable (best log loss 0.678 vs 0.692 base, 7 of 10 games).
- Replay mode only: no dragging players, no hypothetical misses of made shots, no transition value.

### Open choices

- Whether to review the 60-episode sample against the viewer; whether to widen the contact/observation grid past its edges.
- Whether rebound collection should replace EPV's constant offensive-rebound rate (not attempted here).

## 2026-10-27 (later) — Rebounding site clean-up and the EDA walkthrough

At the owner's request after reviewing the first version.

- **Court control while a shot is in the air** no longer fades out away from the old empirical landing density: it
  shows control with rebound timing everywhere near the basket, a little lighter so the rebounding overlay reads over
  it. Its stale "OREB if missed / OREB now" readout (the 2026-10-16 court control model) is removed; the rebounding
  panel's forecast replaces it.
- **Team colours**: court control shades with each club's colours (from the play's de-clashed kits, falling back to
  blue/orange only when no pair separates on the floor); collection chances on the court and every mark in the
  rebounding panel wear the team kit (primary fill, secondary edge), like the player dots.
- **Landing forecast** is drawn as a density (kernel 2 ft over all ~400 simulated landings, on a 1.5 ft grid
  exported per forecast) by default, with Dots and Off as alternatives. It stays labelled as not validated. The black
  X (mean of the first reachable points) is gone: it was the centre of a possibly two-sided cloud and invited misreading.
- **Collected vs awarded** is explained in the panel: collected = a player secures the ball; awarded = nobody does
  and a team gets it (team rebound; usually out of bounds). The panel also states the share of simulated misses that
  would first land out of bounds.
- **Rebounding tab rewritten as a walkthrough** (`src/rebounding/run_eda.R` → `outputs/rebounding/eda/`): for each
  stage, what the data show, the decision that follows, and how it was checked. EDA findings worth keeping:
  rebound distance grows with shot range (median 3.2 / 5.7 / 6.5 ft); rebounds stay on the shooter's side (0–30° most
  common for every range); the offensive rate barely moves with shot distance (25–37%, intervals overlap the 32%
  overall); the rebounder is the nearest player to the rebound spot 60% of the time just before the rim but the nearest
  to the hoop only 23%, and the nearest player's team wins 79% (67% at release); crowd and box-out counts move the
  offensive rate little; players carry 85% of their momentum over 0.48 s.
- **Not used as a feature**: the audit's "putback or tip" kind is defined by the offense getting the ball (100% by
  construction). No model uses it; the tab says so.

## 2026-10-27 (evening) — Shot ranges for description, smoothed rebound maps, court labels

At the owner's request.

- **Shot ranges in the EDA and on the site** are now rim (under 5 ft), midrange (every other two) and three, by
  `shot_range()` in `src/rebounding/R/audit.R`. They replace the 10/22 ft split and the 4 ft distance bins wherever the
  data are described (offensive rate by range, rebound distance and angle by range, the per-shot label in the viewer;
  the episode files are relabelled at export, so cached forecasts needed no refit). **At this point the models still used the old
  10/22 ft `range` as a covariate** (empirical-density benchmark, anticipation and box-out GAMs); superseded by the refit below; switching them meant
  refitting run_opportunity.R and run_skills.R. With the new ranges: offensive rate 36% at the rim, 33% midrange, 30%
  on threes (every interval includes the 32% overall); median rebound distance 3.2 / 4.3 / 6.2 ft.
- **Where misses go** is drawn as smoothed densities (Gaussian kernel, sd 1.5 ft, 0.5 ft grid) on one shared colour
  scale, on a neutral floor (the blue ramp turned grey over the viewer's tan). A new click-a-shot map weights every
  real miss by how alike its shot is (Gaussian in shot position, width chosen by the reader, 2–8 ft), optionally
  mirrored left/right, and reports the effective sample size. Mirroring is an assumption: sides differ by noise-level
  amounts here (47% vs 56% of side-shot rebounds on the shooter's half, 156 and 126 misses). The readout uses
  "within 30° of the shot's line" rather than "shooter's half", since most rebounds come back along the line near the
  middle of the floor.
- **Court labels**: a player's collection chance is a small kit-coloured superscript on his dot; his archetype is an
  abbreviated subscript pill in the roster tag's colour, replacing the archetype ring.

## 2026-10-27 (night) — The play viewer draws plays in the camera's view

At the owner's request: the end of one possession and the start of the next should line up.

- Plays stay stored with the offense attacking +x (every model and overlay assumes it); the site now rotates a play
  180° back to the broadcast camera's view when its offense attacks the left hoop (`possessions.leftHoop`), at draw
  time only (`Layout.f`, `px()`/`py()` in `web/src/lib/court.ts`). Court control, the landing heatmap, hulls and
  labels turn with the players; text stays upright. The half-court view shows the half the offense attacks, left or
  right. Checked: in game 114243, period 1, the ball's position at the last frame of each possession equals the first
  frame of the next.
- `export_data.R` writes `leftHoop` in each play header; the existing export was patched with it (the headers are
  otherwise byte-identical) and its `generated` stamp moved so browsers fetch the new headers. The parity reference
  carries the same stamp. The Shiny app is unchanged and still draws every offense attacking right.

## 2026-10-28 — Models refit without the 10/22 ft shot range

At the owner's request. The 10/22 ft split was an untested choice made while building (22 ft is roughly the arc; 10
ft had no basis) and the framework never asked for it. It entered three models; none of the physics did.

- **Empirical density + Voronoi benchmark** (`fit_voronoi()`): densities now by rim / midrange / three. Held-out log
  loss 2.475 → 2.478 at release and 2.171 → 2.179 just before the rim: slightly worse, most likely because the
  under-5-ft group is small (about 120 secured rebounds per training fold) and its density noisier. Still the weakest
  model at release (better than the prior in 2 of 10 games) and behind every physics model at the rim. Every other
  model on the ladder is unchanged (largest log-loss change 5e-10: refit from the same cached scenes).
- **Anticipation and box-out GAMs** (`run_skills.R`): `range` replaced by `s(shot_dist, k = 5) + three`. Box-out
  maintenance, held out by game: geometry model log loss 0.678 → 0.682 (gain over the base rate 0.012 → 0.009, better
  in 7 of 10 games either way); with player effects 0.679 → 0.683. Identification: anticipation LR 349 → 352, player sd
  0.0063 → 0.0064, cross-game r 0.24 → 0.23; box-out LR 29.7 → 28.9, cross-game r −0.47 → −0.46. Neither passes, as
  before. Player effects barely move (Spearman r 0.999 anticipation, 0.997 box-out).
- **Conclusion**: the binning was harmless; no result or site decision depended on it. The continuous form is kept
  because it has no arbitrary cut points, and the old split remains only to stratify the label-review sample. Before
  and after tables were compared in place; the opportunity folds took about 19 minutes in parallel.

## 2026-10-28 — Late forecasts: a collection model for the moments after the rim

At the owner's request, after asking why Samuels had only 32% just before securing a miss (shot-114099-1-19).

- **Diagnosis.** The site reused the rim-checkpoint fit for every forecast after the rim. Fitted where the bounce is
  still unknown, its access weight was weak (10x the access gave 2.4x the pull); players drifted 0.5 s before reacting;
  access said only whether a player could reach the ball, not whether he would be first; and the untouched 3.2 s horizon
  let far players catch up. Given the true ball path it still gave Samuels 35%: the ball forecast was not the limit.
- **Model** (`src/rebounding/R/late.R`, `run_late.R`; C++ `arrival_margin`, `crt_objective`, `crt_predict`). Scenes at
  0, 0.2, 0.4, 0.6, 0.8, 1.0 and 1.4 s after the ball reached the rim, while still loose (2,712 scenes from 636 misses
  over the held-out folds). One pooled competing-risks fit with the baseline and the access weight linear in tau, plus
  an arrival-margin term (arrival time minus the fastest other player's, capped at ±1 s, its weight also linear in tau).
  Reaction time (0.05–0.5 s) and information policy (0, 1, 2) chosen per fold on a 700-scene training subsample; ties go
  to the longest reaction time, because under the drift policy nothing shorter than the ~0.25 s to see the next bounce
  changes the model. The all-games fit: drift policy, 0.25 s; b_acc 0.50 + 0.47 tau, b_first 3.38 − 1.10 tau.
- **When the rim is known.** `contact_seen()` reads it from the track seen so far (the audit's contact zones, or the
  ball below 6 ft; interpolated frames used only up to the last keyframe seen). It matches the audit's rim time to the
  frame for 77% of misses (86% within 0.08 s) and is known within 0.04 s for 90%; a scenario check confirms cutting the
  track changes nothing. The old switch used the recorded rim time (hindsight). The site now uses the release model
  until the rim is known, then the late model; the old rim model is no longer used on the site.
- **Held-out results** (leave one game out, late scenes only, log loss per scene): late model 1.821; reused rim model
  1.937 (gain 0.113 ± 0.011, better in 10 of 10 games); geometry classifier refit on late scenes 1.928; team prior
  2.401. Ablation: refitting the same model on late moments gives 0.094 of the gain, time-varying weights 0.003, the
  arrival margin 0.016. At tau = 0 the two are close (2.028 vs 2.005); the gain builds over the next half second. The
  eventual collector's average chance rises from 19% to 24%; the median top player from 24% to 31%. Calibration: the old
  model's 30–40% calls came true 51% of the time; the late model's 38%, and it tracks across the range.
- **The Samuels miss**: 25% → 40% at 1.6 s and 32% → 60% at 1.8 s (the held-out fit, without this game, gives the same).
- **Limits**: nothing is learned after 1.4 s (later forecasts use the 1.4 s weights); scenes are weighted equally, so
  long scrambles count a little more; many rebounds stay contested, so the typical top player is still near a third.

## 2026-10-28 (later) — Late model: fitted reach height, height-gated margin, player effects retested

At the owner's request.

- **Reach height fitted.** The access height gate (half reachable at z_reach, fall-off z_scale) was fixed at 10.5 and
  0.35 ft. It is now chosen per fold from 9.5/10.5/11.5 × 0.2/0.35/0.7 ft on the 700-scene training subsample, with the
  access settings already chosen. The all-games fit picks 11.5 ft and 0.35 ft; seven of ten folds pick 11.5 ft. 11.5 ft
  is the top of the grid, so the best value may be higher; it is reported as a boundary, not a measured reach
  (jumps, tips and ball-height calibration could all make tracked balls at 11 ft grabbable). Still one reach for every
  player: no player heights in the data and player z is always zero.
- **Height-gated arrival margin** (`arrival_margin(..., gate = TRUE)`): each margin scaled by the height gate, so who
  gets there first counts only while the ball is low enough to grab (mean |margin| falls 13%).
- **Held out** (log loss per scene against the fixed-height late model): fitted height alone +0.0006 ± 0.0006 (better
  in 6 of 10 games); with the gated margin +0.0019 ± 0.0011 (7 of 10). That passes the adoption rule (better on
  average and in at least 6 of 10 games), so the site's late model is now `late_height` (1.819 against 1.937 for the
  reused rim model, gain 0.115 ± 0.010, 10 of 10). The improvement is real but small.
- **Player collection effects retested on the late model**, by the rim test's rule: effects with prior sd 0.3 on top
  of the late model (theta held fixed), each miss weighted once because its moments share one outcome (new per-scene
  weights in `crt_objective`). Held-out change where the rebounder was seen in training: −0.009 per scene (worse;
  better in 1 of 10 games). Recovery of planted effects (sd 0.3, one simulated outcome per miss, players on court for
  20+ misses): r = 0.40 on average over three replicates (needs 0.5). Fails; the site stays population-only. The
  export would use late effects for the talent-aware chances if they ever pass.

## 2026-10-28 (evening) — Gated roadmap, Gate 0: rebound event audit and data contract: PASS

At the owner's request, from "Rebound Probability Modeling: Original Response and Implementation Roadmap" (Part III).
Code `src/rebounding/run_gate0.R`, `run_gate0_review.R`, `R/gate0.R`; evidence `outputs/rebounding/gate0/`
(`gate_decision.csv` lists each check); record in `rebounding.md`. Thresholds were fixed in `GATE0` before the first
run; the landmark fallback (5 frames) and the 3 ft identity flag were added after it and are labelled as such.

- **Target fixed for the gated work**: the credited outcome of a non-fouled missed field goal, 12 classes (ten players,
  a team award to either side), conditional on the miss. Free-throw rebounds are outside it: their 55 rows point to
  `free_throws` ids (49 of 52 live free-throw misses have one), so no separate join is needed to exclude them.
- **Enumeration**: 1,459 shots, 768 rebound rows (713 field goal, 55 free throw). No duplicate links, none to a made or
  fouled shot, no rebounder off the roster or on the wrong team, `rebounded`/`defensive` never null, wallClock =
  40 × frameIdx on every tracking line, and every shot and rebound wallClock and period equals the tracking line at its
  frame. The rebound and shot locations are the tracked positions turned 180° (median gap 0 ft).
- **Found: the `defensive` flag is wrong on 14 team awards** (games 178442 onward): teamId and the next chance's
  offence both give the defence. Corrected by teamId; team awards become 37 offensive and 36 defensive among the
  retained, not 51 / 22. **The existing models used the flag** (`classify_episodes()` in `audit.R`), so the 14 sit in
  the wrong class in every rebounding fit and on the site. `episode_audit()` now sides by teamId (see the next entry);
  the models and the site have not been refitted.
- **Found: 4 rebound rows at or before their own shot's release**, all tip or put-back sequences: the rebound of the
  previous miss is linked to the tip (e.g. shot-191313-2-70; its previous miss 2-69 has no row). Excluded. 21 more
  fall after release but before `endFrame` (blocks, quick rebounds at the rim); kept.
- **Semantics.** `shots.endFrame` is when the ball reaches the rim zone (median 11.2 ft high, 1.3 ft from the
  calibrated hoop; contact proxy at 0 frames median; made shots cross rim height 3 frames later), never more than 40
  frames after release. `rebounds.frame` is a median 0.88 s after `endFrame`, between the first-touch proxy (0.28 s
  earlier) and the control proxy (0.36 s later), with the ball at a median 9.0 ft and the rebounder 2.5 ft away (within
  6 ft 96% of the time, nearest player 64%).
- **Population**: 742 non-fouled misses, 703 retained. Out: 29 without a rebound row (11 end of period, 2 foul, 16 not
  explained: heaves at the buzzer, held balls, offence keeping the ball out of bounds; 4 have a matching rebound row
  with no shotId and `fgReb` false, resolvable by time but left out), 6 for ball coverage, 4 rebound-before-release.
- **Quality in retained shot-to-rebound windows**: ball present on every frame, keyframes on 55.8% (ball `isDetected`
  is 0 everywhere, so keyframes are the only direct-observation proxy); players detected 92.2% (`predError` 0.90 ft
  detected, 3.48 ft extrapolated, 95th percentile 10.6 ft); no index gaps, dead frames, period changes or clock
  reversals inside any retained window; 10 tracked players with a complete roster match on every landmark.
- **Landmarks** (release, late flight, contact + 0.2 s, pre-touch): usable ball 99.7 / 94.7 / 95.7 / 92.9%; with the
  fallback 100 / 100 / 100 / 99.7% (2 abstain). 76 misses have no post-contact landmark (no contact found).
- **Review**: 72 rebounds (10% of 713) from all ten games, unusual cases oversampled, plus 4 misses without a row,
  against tracking plots (`review/page_*.png`, verdicts in `review_log.csv`). 56 agree, 9 disagree, 7 unclear. The 4
  timing and link disagreements are the excluded rebound-before-release rows. In 5 of 64 retained rebounds the
  credited player never reaches the ball, while a teammate does (tip-outs or tracking swaps; the team always agrees).
  The 7 unclear are mostly team awards that look like held balls or collectable balls. The `identity_suspect` rule
  (never within 3 ft) catches 4 of the 5, wrongly flags 1 of the 52 agreed rebounds, and flags 33 of 630 retained
  player rebounds.
- **What this does not support**: who physically collected the ball (5 of 64 reviewed credits look wrong in tracking),
  first touch or tip attribution (Gate 1), or reliability of the review (one reviewer, no video).

### Open choices

- Whether to fix the 14 team-award sides in `classify_episodes()` and refit the opportunity, late and skills models
  and the site export.
- Whether to recover the 4 time-matched rebound rows without a shotId, and whether `identity_suspect` rebounds should
  be dropped in a Gate 2 sensitivity fit.

## 2026-10-28 (night) — Gate 0 rerun clean, rebound side fixed, checks before Gate 1

At the owner's request ("run step 1 and 3"). Code `src/rebounding/run_gate1_prereq.R`, `R/gate1_prereq.R`, the fix in
`R/audit.R`; tables `outputs/rebounding/gate1_prereq/`.

- **Reproducible.** All ten games' tracking windows were re-extracted from the raw files into a scratch cache: identical
  to the cached ones. Rerunning `run_audit.R`, `run_gate0.R`, `run_gate0_review.R` and `run_gate0.R` reproduced every
  audit and Gate 0 output byte for byte, review pages included.
- **Rebound side fixed at the source.** `episode_audit()` keeps the delivered flag as `defensive_flag` and sets
  `defensive` from teamId. Exactly the 14 team awards changed (`episodes.csv`: `defensive` and `outcome`, 14 rows each);
  eligible team awards are now 37 offensive and 36 defensive. `counts.csv` lists both the delivered-flag counts (which
  match the framework's 54 / 24) and the teamId counts (40 / 38). Gate 0's outputs did not change (it reads the events
  itself). **The cached bundles, scenes and fits, and the site, still carry the old classes** until the opportunity,
  late and skills stages are rebuilt.
- **Free-flight curvature is not gravity.** Fitted downward acceleration is a median 28.3 ft/s² (p10 20.6, p90 31.8;
  868 segments of at least 0.4 s), 12% below 32.2. Every game and end agrees (medians 27.0–29.3), and so do made and
  missed shots. It falls with flight length (about 30 under 0.8 s, 28.7 for 0.8–1 s, 27.7 over 1 s), and the leftover
  scatter grows with it. So a single parabola fits long flights worse. With g fixed at 32.2 the height scatter doubles
  (median 0.10 → 0.21 ft) and is more than twice as large on half the shots. The cause can't be told apart from here
  (height scale, smoothing or drag). **`flight.R` fixes g at 32.2** in its launch prior, Kalman filter and floor fit;
  their held-out coverage already absorbs this, but the models are misspecified. Sideways acceleration is small
  (−0.7 ft/s² toward the hoop, +0.5 across), and the two ends barely differ.
- **The track is smooth; `predError` is not its noise.** Around a fitted arc the leftover scatter has sd 0.19 / 0.10 /
  0.28 ft (x / y / z), median 0.10 ft, p90 0.38 ft (larger under 8 ft, just after release). `predError` averages 1.44
  ft, so 96% of positions fall inside it. A departure of about 1 ft is therefore well above the scatter. How far the
  smooth track is from the true ball is not measured here.
- **The interpolation tolerance is too loose.** Exact midpoints (deviation < 0.0001 ft) are 40.7% of tracked frames.
  The next 0.0001–0.005 ft band is nearly empty (0.3%), but the audit's 0.015 ft cut also takes the 4.6% between 0.005
  and 0.015 ft. A real frame in free flight sits about 0.022 ft off the midpoint from curvature alone, so those are real
  measurements of slow or held balls. At 0.015 ft, 473 of 703 windows show a gap of more than 2 frames between
  measured positions (up to 20). At 0.001 ft only 6 do (up to 5): the vendor measures every other frame, consecutive
  frames in a third of cases, and fills single midpoints. y agrees with x and z on 98% of flagged frames. The audit,
  the models' "keyframes" and Gate 0's landmark usability all use 0.015 ft, so landmark usability is probably
  understated. Not changed here.
- **Ball to rebounder.** Shifting the ball to the player frame barely moves the distances (median at the rebound frame
  2.45 → 2.59 ft; closest approach 1.26 → 1.28 ft). But the 2.5 ft touch rule fires on a different frame in 43% of
  misses (−2 to +3 frames, 10th–90th percentile). 85% of credited rebounders come within 2.5 ft of the ball (90% within
  2.8 ft). The ball's height at that closest approach is a median 6.9 ft, p95 11.3 ft, and above the 11 ft reach in
  7.7%, consistent with the late model picking 11.5 ft at the top of its grid.
- **Floor.** The lowest measured frame of each bounce (471, dribbles included) is a median 1.52 ft (p10 1.18, p90
  2.10), with every game between 1.45 and 1.58 and 1.3% below zero. So no game needs its own floor. Sampled minima sit
  above the contact because a bounce falls between measured frames; the arc intersection of `fit_floor()` (0.98 ft)
  is the better estimate, though it also fixes g at 32.2.

### Open choices

- Whether to change the interpolation tolerance to 0.001 ft in `ball_track()` (affects the audit proxies, the models'
  keyframes and Gate 0's landmark rates).
- Whether `flight.R` should use a fitted vertical acceleration instead of 32.2 ft/s².
- When to rebuild the cached bundles and refit with the corrected rebound sides.

## 2026-10-29 — Sequential rebounding manual, Steps 00 and 01: Step 01 PASS, Step 00 waits on a commit

At the owner's request ("proceed with steps 0 and 1, skipping things if already completed"), from "Dynamic Basketball
Rebounding Model — Sequential Implementation Manual" (revision 2026-10-29), which replaces the earlier gated roadmap.
Code `src/rebounding/run_step00.R`, `run_step01.R`, `fetch_sources.R`, `check_fresh_checkout.R`, `run_tests.R`,
`R/step00.R`, `R/step01.R`, `config/`, `tests/`, `renv.lock`; register `docs/project/SOURCE_REGISTER.md`; evidence
`outputs/rebounding/gate_results/`, `outputs/rebounding/step01/`, report `outputs/rebounding/reports/01_join_audit.md`;
how to run in `rebounding.md`.

- **Layout decision.** The manual's Python tree is mapped onto the existing R project rather than a new one (CLAUDE.md:
  existing language and layout; `data/` holds only supplied files). The table is in `rebounding.md`.
- **Sources.** Ten repositories are pinned in `external/` (git-ignored). Four have a licence (filterpy, LaurieOnTracking
  and TrueImpactShotCharts MIT; the Kalman book, text CC BY 4.0 and code MIT). Six have none (ReboundingPrediction,
  tracking-study, ShotQuality, basketball-shot, ReboundingImpact, Charlychee): ideas only, no code copied or run. This
  overrides the manual's "port `resolve_collisions` if the licence permits", since basketball-shot has no licence.
  ReboundingPrediction bundles 3.6 GB of NBA SportVU games; a sparse checkout keeps them out (no outside data).
- **Step 00 evidence.** Every `data/` file equals upstream `4bbed2e`, and each tracking `.jsonl` equals the upstream
  `.gz` decompressed (checked against the LFS objects still in `.git/lfs`). The 35-package lockfile restores into an
  empty library in about 3 minutes, and the unit and Step 00 tests pass there. A clean copy of the repository, with
  its sources fetched again from GitHub and only the lockfile library, reproduced every judged criterion. The one
  unmet criterion is "under version control": none of these files is committed yet. The clean-copy check ran before
  the Step 01 files existed; rerun it after the commit.
- **Contract format.** Gzip CSV instead of parquet: R 4.4's CRAN binaries no longer include the installed arrow
  (24.0.0) or data.table (1.18.4), and a source build of arrow is not practical. data.table builds from source in
  30 s, so it stays.
- **Step 01: PASS.** 742 non-fouled misses, 703 eligible. Joins, keys, ordering, identity, orientation, quality by game
  and stage, clock coverage and exclusions are all documented (`01_join_audit.md`). Findings Gate 0 did not have:
  - The ball comes nearer the attacked hoop than the other hoop on every one of 740 tracked misses, in both
    directions; the median shooter gap to `-shots.location` is 0 ft.
  - Player detection drops from 93–97% before contact to 80–95% between contact and the rebound.
  - The stricter 0.001 ft rule finds ball keyframes on about 60% of frames, against 54–57% with the audit's 0.015 ft.
  - Game 178442's fourth quarter starts 62 s late in the tracking; every other period is covered from its start.
  - No eligible window has a substitution between release and rebound.
- **Deviations (owner to confirm).**
  1. The prespecified orientation check (ball at `shots.endFrame` within 6 ft of the attacked hoop, at least 98% per
     direction) failed: 96.3% and 94.5%. Its 34 outliers are blocked shots, airballs or heaves, and shots whose
     endFrame is not at the rim, so it tested endFrame's meaning rather than orientation. It was replaced after the
     first run by the endFrame-free check above. The failure stays in `checks.csv`.
  2. The gameClock join tolerance was 1e-6 s, set in code without a reason; it is now 0.001 s, since events keep
     milliseconds and the largest gap is 0.0005 s.

### Open choices

- Commit the Step 00/01 files, then rerun `check_fresh_checkout.R` and `run_step00.R` so Gate 00 can pass. Commit the
  gate records they rewrite as well.
- Whether to accept the orientation deviation, or to keep Step 01 blocked until a check fixed in advance is rerun.
- Step 02 needs a second reviewer for contact and tip labels. Without one, its gate can pass only for event types
  with a stated reliability target that a single reviewer can meet.

## 2026-10-29 (afternoon) — Sequential rebounding manual, Step 02: contact-state labels: BLOCKED

At the owner's request ("proceed with step 2"). Code `src/rebounding/R/contact_states.R`, `run_step02.R`,
`tests/unit/test_contact_states.R`, `tests/gates/test_step_02.R`; rubric `docs/project/ANNOTATION_RUBRIC.md`;
thresholds `config/experiment.yaml` (`step02`, fixed before any label was reviewed); evidence
`outputs/rebounding/step02/`, `outputs/rebounding/annotations/contact_events.csv`; report
`outputs/rebounding/reports/02_annotation_reliability.md`; record `gate_results/02_contact_states.json`. The Three
Dimensions of Rebounding PDF in `research/` is password-protected and could not be read; its opportunity / pursuit /
conversion split is used only as the reason the labels separate touch, tip and control.

- **Labeler.** Contacts are departures of the measured ball track from a short ballistic arc (break threshold
  0.65 ft), named by where they happen; control is a 6-frame run of the ball staying with one player. All 703 eligible
  misses are labelled with no time-order problem; the named controller is the credited rebounder in 78% of player
  rebounds; 6 of 49 official blocks are found.
- **Review.** Two disjoint stratified subsets of 30. The development subset shaped six labeler revisions (each in the
  config); the labeler was then frozen by checksum, and only then were the held-aside pages drawn, without the
  automated marks or the credited rebounder. Reviewer 1 labelled them once; they were scored once.
- **Result: no label type passed.** Where both labelers name a player they agree (first touch 13/15, controller
  14/14), and the rim contact is timed within ±2 frames in 20/23. But each labeler leaves about half the touches and
  controls unnamed, soft events are placed differently in time (first touch within ±3 frames 13/27, control 10/20),
  tip counts agree in 16/30, and the contact-vs-none kappa is 0 because the subset holds a single "none".
  Consequence (manual): Steps 03–09 use the final credited rebounder only; tip physics, controlled-catch and securing
  models stay blocked; Step 08's first-contact validation will be blocked unless these labels are improved.
- **Ball heights** (descriptive, at unvalidated labels): tips median 8.5 ft, catches 7.5 ft, control 5.3 ft; control is
  truncated at 9 ft by the labeler's own rule, and the track reads the ball 1–2.5 ft high near the rim.
- **Deviations (owner to confirm).**
  1. Break threshold: the prespecified rule (99.5th percentile on misses before the contact proxy) gave 2.20 ft
     because 11% of those segments are not free flight; made shots gave 2.25 ft for the same reason. Replaced before
     any review by made-shot flights without a residual above 1 ft (311 of 346), 99th percentile.
  2. No second human reviewer: reliability is the frozen labeler against a blind reviewer who also wrote it. This is
     consistency between two tracking-based judgements, not accuracy.
  3. The contact-kind kappa became contact vs none (rim vs board reported only) before freezing.

### Open choices

- Whether the owner (or another person) fills `step02/review/reviewer2_heldout.csv`; `score` and `gate` then judge the
  gate on reviewer-to-reviewer agreement.
- Whether to accept the three deviations above.
- Whether to try a second labeler version (e.g. catch at the point the ball stops falling, a narrower actor margin)
  on a **new** held-aside subset, or to proceed to Step 03 with the credited rebounder only.

## 2026-10-29 (evening) — Step 02 labeler v2 (hidden Markov model): owner design decisions, nothing fitted

Labeler v1 stays frozen and its held-aside subset keeps rubric v1; reviewer 2 is filling
`step02/review/reviewer2_heldout.csv` (1 of 30 rows). Owner decisions for a v2 labeler, made before any v2 code:

- **Model.** A hidden Markov model over per-frame tracking features (R package `depmixS4` 1.5.4, CRAN, installed
  today). States are regimes (flight, on rim, held, low and loose) plus short impact states; events are read from
  state changes; the player is still the nearest one, with the crowd rule, so v2 targets timing rather than identity.
- **Time grid: 25 Hz**, with the vendor's filled-in (midpoint) ball frames treated as missing, not as observations.
- **Fit population.** A new held-aside subset of 30 is drawn first, with a new seed, and left out of the fit; the
  60 episodes labelled under v1 (development and the spent held-aside) become v2 development data.
- **Rubric v2.** A catch is defined by sight (the ball never flies free between the touch and the hold), not by the
  8-frame window; the sample must hold at least 3 shots with no rim or board contact so contact-vs-none kappa is
  informative (v1 had 1).
- **Gate criteria: reused** from v1 unchanged (`step02.agreement`).
- **Why the 8-frame catch window goes.** It was a judgement, not a measurement. Among the 359 automated episodes
  whose first toucher is also the controller, the touch-to-control gap falls off smoothly (0 frames: 169; 1–2: 70;
  3–4: 39; 5–6: 23; 7–8: 18; 9–10: 15; 11–12: 13; 13–16: 11; 31+: 1) with no dip at 8, and rubric v1 copied the
  same window, so v1 tip-vs-catch agreement partly measured a shared rule.

### Open choices

- Impact states: one, tip vs rim/board, or rim / board / tip separately.
- Direction-change features (change in velocity across a frame, turning angle, speed ratio, velocity toward the hoop).
- Smoothing window, allowed transitions, EM restarts, minimum held length.
- **Owner decision (same evening): impact states.** Three short impact states, rim, board and tip, started from court
  geometry; rim and board are merged into `rim_or_board` if the development labels cannot tell them apart (the reused
  gate tests only contact vs none). **Features:** add the five direction-change features (size of the velocity change
  across the frame, turning angle, speed ratio after/before, velocity toward the hoop, signed distance to the board
  face) to the eight per-frame features.
- **First v2 fit (development, not a result).** New held-aside v2 subset drawn first (`step02_v2/review/sample.csv`,
  30 episodes, seed 20261030, 4 with no contact by the Step 01 proxy); features for all 703 episodes (60% of window
  frames have a measured ball); EM on the 673 episodes outside it, 5 restarts (4 reach the same log-likelihood,
  -567,384), about 12 minutes. **The states did not take the intended meanings:** the impact states became long
  regimes (self-transition 0.75–0.96, not about 0.3), "impact_rim" is the incoming shot near its apex, the near-hoop
  bouncing regime landed in "impact_board", and "impact_tip" is the slow, near-player regime (the catch/hold), while
  "held" is the ball falling away from the rim. Not decoded or scored. State means, spreads and transitions moved to
  `outputs/rebounding/step02_v2/fit1/`.
- **Owner decision: fit 2.** Impact self-transitions fixed at 0.3; flight split into `flight_in` (release to the
  first contact; leaves only to a contact, a hold or the floor) and `flight_out` (after a contact; never returns to
  `flight_in`). 8 states. depmixS4 can hold a parameter fixed only by switching from EM to a general optimizer
  (Rsolnp), impractical with about 240 parameters, so the fit uses a short EM written for this (`R/hmm_em.R`): same
  model and missing-data rule, exact constrained M-step. Checked in `tests/unit/test_hmm_em.R`: its log-likelihood for
  the fit-1 parameters equals depmixS4's (-567,384.42), and it recovers a simulated model with a fixed stay. The 24
  depmixS4 warnings in fit 1 were `nobs` notices about missing values, not fitting problems.
- **Fit 2 result (development, not a result).** 5 restarts, about 30 s each, best log-likelihood -569,803 (2
  restarts at -569,805). `flight_in` is the incoming shot (toward the hoop at 18 ft/s) and `flight_out` the ball
  leaving the rim, as intended. The fixed stay stopped single impact runs from lasting, but **pairs of states now
  alternate to form regimes**: rim and board impacts bounce between each other (0.62 and 0.56) for the rattle on the
  ring, and `held` alternates with `impact_tip` (0.32 and 0.61), so dribbles and gathers read as repeated touches.
  `impact_board` sits about 1 ft from the hoop centre, not at the board. Decoded labels (all 703): rim contact in 701,
  board first in none, no-contact in 2 (v1: 60), first touch a catch in 566, no tip as a first touch.
- **Fit 2 against reviewer 1 on the 30 development episodes** (`step02_v2/dev_comparison.csv`; v1 / v2): rim
  contact within 2 frames 20/23 / 5/23; first touch both named 15/30 / 7/30, same player 13/15 / 7/7, within 3
  frames 13/27 / 8/25; tip vs catch 17/19 / 13/20; controller both named 14/30 / 16/30, same 14/14 / 12/16, within 3
  frames 10/20 / 0/19; tip count 16/30 / 20/30; terminal 21/30 / 20/30. **v2 fit 2 is worse than v1 on timing.**
  Causes seen in the decoded paths: (1) an "impact" 2–4 frames after release, where the shot leaves the hand, ends
  `flight_in` early, so the rim contact comes 4 frames (median) to 28 frames early and the real arc is decoded as
  `flight_out`; (2) `held` includes the ball still falling into the hands (mean vertical speed -8.6 ft/s), so control
  starts a median 13 frames before the reviewer's. v2 tip-count agreement is higher only because it finds almost no
  tips (634 of 703 episodes have none).
- **Rim/board merge condition met.** Reviewer 1 named no board contact among the 30 development episodes (rim 20,
  rim or board 3, none 3, unknown 4): fewer than the 3 the owner's rule requires, so rim and board impacts are to be
  merged in the next fit.
- **Owner decision: fit 3.** Rim and board impacts merged into `impact_rim_board` (7 states), and geometric masks: rim
  states only inside the v1 rim zone, `held`/`impact_tip` only with the nearest player within `touch_ft` and the ball
  below `reach_max_z_ft`, no impact state before release + 6 frames (reviewer 1's earliest contact: +7 touch, +8 rim;
  fit 2's false impact: +2 to +4). A first run applied the masks on measured frames only, and the release impact moved
  onto the unmeasured frames; corrected so the guard holds on every frame and the geometry is interpolated between
  measured frames. Only the corrected run is reported. Fit 2 outputs are kept in `step02_v2/fit2/`.
- **Fit 3 result.** 5 restarts reach the same log-likelihood (-579,903), about 15 s each. Decoded (703): contact 626,
  none 77 (v1: 60); first touch a catch 495, block 8, tip 4, none 196. Against reviewer 1 (v1 / v2 fit 3): rim within
  2 frames 20/23 / 7/22; first touch both named 15/30 / 5/30, same 13/15 / 5/5, within 3 frames 13/27 / 5/21; tip vs
  catch 17/19 / 13/17; controller both named 14/30 / 13/30, same 14/14 / 11/13, within 3 frames 10/20 / 1/16; tip count
  16/30 / 18/30; terminal 21/30 / 18/30.
- **Why v2 still misses: its errors are systematic offsets, not noise.** The rim contact is 2–4 frames early in 14 of
  22 episodes (the before/after velocity windows span 3 measured frames, about 6 frames, so the change shows before the
  break); control is a median 13 frames early, because `held` starts when the falling ball passes within reach
  (mean vertical speed -8.5 ft/s) while reviewer 1 marks the ball at rest. `held` and `impact_tip` still alternate
  through gathers and dribbles (0.32 / 0.60), so almost no tips are found. The release "impact" now decodes as a
  2-frame `low_loose` run, which reroutes the incoming arc to `flight_out`. **v2 does not address v1's actual failure**
  (coverage: each labeler leaves about half the touches and controllers unnamed); v2 names fewer.

## 2026-10-30 — Sequential rebounding manual, Step 03: evaluation design, reference baselines, scoring: PASS

At the owner's request ("proceed with step 3"). Step 02 is BLOCKED (labeler v2 was explored but not frozen or
scored), so Step 03 is built for the credited outcome only. Code `src/rebounding/R/folds.R`, `R/metrics.R`,
`R/reference_baselines.R`, `run_step03.R`, `tests/unit/test_evaluation.R`, `tests/gates/test_step_03.R`; settings
`config/experiment.yaml` (`step03`, written before any baseline was computed); evidence `outputs/rebounding/step03/`;
report `outputs/rebounding/reports/03_evaluation_design.md`; record `gate_results/03_evaluation.json`. Upstream
`eval/split.py`, `metrics.py`, `baseline.py` and `models/baselines.py` of ReboundingPrediction and tracking-study's
coverage gate were read for ideas only (no licence): split by game, per-shot ranks with ties counted against the
model, priors fitted on training games only, same-time comparisons, exclusions reported by game.

- **Design (frozen).** Leave one game out, fold k = k-th game by date; inner leave-one-game-out for tuning only. Choice
  set: the ten players tracked at release (the credited rebounder is always one of them) plus `team_off`, `team_def`.
  Information rule: frames up to t; ball frame f usable at f + 1 (its midpoint status needs the next frame); nominal
  hoop (the calibrated hoops use the test game's own later made shots). Time points: release, and 0–1.4 s after a
  causal rim-arrival trigger; a point exists only while the ball is loose.
- **Pre-contact replaced.** No causal pre-contact time exists here: the contact frames are after-the-fact proxies and
  Step 02's labels failed, and choosing t by them would leak when the ball reaches the rim. The trigger (first measured
  ball frame ≥ 6 frames after release, within 4.5 ft of the hoop, 7–14 ft high, below an earlier high point) fired in
  679 of 703 episodes, a median 1.04 s after release and 2 frames before the Step 01 contact proxy (quartiles −4 and
  +1 frames). Of the 24 it misses, 18 are blocked shots and 5 airballs. It is an arrival time, not a validated contact.
- **Baselines at release (703 held-out episodes, 12-class log loss / top-1 / top-3):** uniform 2.472 / 0 / 0; side
  prior 2.379; role prior (side × hoop-distance rank) 2.274 / 12.7% / 48.2%; nearest to hoop 2.263 / 18.2% / 45.7%;
  inside rule 2.385 / 9.2% / 36.3%. Nearest to hoop has the lowest inner log loss in all ten folds, so it is the
  selected reference at release, and C1's bar for Step 04 is 2.263. Against uniform it gains 0.210 nats (conservative
  interval −0.283 to −0.146, better in 10 of 10 games). At rim + 0.2 s (650 episodes): nearest 2.174 / 21.7%, role
  2.180. From rim + 0.4 s the role prior is selected in most folds.
- **OREB.** Constant rate (training share, 0.299 held out) scores binary log loss 0.610 at release. The rank-only
  baselines ignore side and put P(OREB) at 0.377 (nearest) and 0.392 (inside), so their binary scores are worse
  (0.620, 0.625); side and role priors are calibrated (0.299, 0.300).
- **Checks, all passed:** folds (703 episodes in exactly one test fold, no test game in training or inner folds),
  baseline fits use exactly the training episodes, predictions unchanged when test labels are altered, a planted label
  leak and a planted future feature are both caught, future-frame poisoning (50 episodes, every point) changes nothing,
  every table valid, same episodes for every model, reruns reproduce predictions and intervals exactly. 68 unit and
  195 gate expectations pass.
- **Decision rules for later steps:** superiority = conservative upper bound (wider of game bootstrap and per-game t
  interval) below 0 and every drop-one-game mean below 0; non-inferiority margin 0.02 nats; calibration margins in the
  config. Confirmatory: C1 static logit vs selected reference (release), C2 OREB model vs constant rate (release), C3a/b
  dynamic vs same-time static (release non-inferiority, rim + 0.2 s superiority). All else exploratory.
- **Limits.** Leave one game out trains on later games (season drift untested); teams recur across games; vendor
  smoothing of player tracks may use later frames; the loose-ball rule uses the credited rebound frame to decide
  whether a late point exists (same for every model).

### Open choices

- Whether to accept the causal rim-arrival trigger in place of the manual's pre-contact point.
- Step 04 (static conditional logit and OREB model) is next; it is scored against these baselines under C1 and C2.

### Config v2 (same day): baselines fitted per shot range

Owner decision after the v1 scores were seen: add the role prior and nearest-to-hoop tables fitted separately for
each shot range (rim under 5 ft, other twos, threes), with smoothed per-range outcome-type shares, as extra
candidates. `config_version` 2, `model_version` baseline_v2; the v1 freeze is kept as
`step03/design_freeze_v1.json`. The five v1 baselines' predictions are unchanged (244,680 rows, largest difference 0).
All checks and tests pass (77 unit expectations).

- **Why the third-closest player led.** On rim misses the shooter is the closest or second-closest player at release
  in 86% of cases, and the third-closest gets 34.8% of the player rebounds (closest 14.4%). On other twos the
  closest leads (21.5%); on threes ranks 1 and 3 tie (17.6%).
- **Release, held-out log loss:** role prior by range 2.261 (v1 role prior 2.274), nearest by range 2.268 (v1 nearest
  2.263). Splitting helps the side-aware table slightly and hurts the rank-only one.
- **The selected reference got weaker.** Inner cross-validation now picks nearest (5 folds), role by range (4) and
  nearest by range (1) at release, and the fold-by-fold mix scores 2.278, worse than any of the three on its own
  (selection noise between candidates 0.01 nats apart). C1's bar at release drops from 2.263 to 2.278. At rim + 0.2 s
  nearest is still chosen in all ten folds (2.174).

### Open choice

- Whether C1 should require Step 04's model to beat every fixed baseline, not only the selected reference. That rule
  is stricter and does not depend on which baseline looked best on held-out games.

### Config v3 (same day): C1 must beat every baseline

Owner decision on the open choice above: C1 (Step 04's static conditional logit at release) now needs superiority over
each of the seven baselines and the selected reference, tested one by one with the same rule (`decide_against()` in
`R/metrics.R`). The binding comparisons are the three strong baselines (2.261–2.268). Reasons: the selected reference
had become weaker than its best members, and the stricter rule does not depend on which baseline looked best on
held-out games. Cost: less power, so a real gain of about 0.01 nats will probably not show with ten games; if C1 fails,
Step 04 is BLOCKED and the best baseline stays the shipped model, as the manual says. C2, C3a and C3b are unchanged.
Baseline predictions are unchanged from v2; the v2 freeze is kept as `step03/design_freeze_v2.json`.

## 2026-10-30 — Sequential rebounding manual, Step 04: static conditional logit PASS (C1), OREB model BLOCKED (C2)

At the owner's request ("Start Step 04"). Code `src/rebounding/R/static_geometry.R`, `R/conditional_choice.R`,
`R/team_rebound.R`, `run_step04.R`, `tests/unit/test_static_model.R`, `tests/gates/test_step_04.R`; settings
`config/experiment.yaml` (`step04`, written before any fit); evidence `outputs/rebounding/step04/`; report
`outputs/rebounding/reports/04_static_model.md`; record `gate_results/04_static.json` (status PASS). Ideas from
ReboundingPrediction `data/derived.py` and `models/conditional_logit.py`, and the ShotQuality notebook (box-out
matchups); no code copied (no licences). The run checks that Step 03's freeze is in force before fitting.

- **Model.** One softmax over the 12 outcomes: 13 player features from the ten positions at t (distance to the hoop,
  distance minus the ten's mean, nearest opponent, inside gap, opponents and teammates nearer the hoop, angle from the
  shooter's line, offence, shooter, distance × shot distance, shooter on a rim shot, players within 6 ft, closeness
  share); team awards are alternatives with a constant and a shot-distance slope. Standardised and L2-penalised on
  each fold's nine training games; lambda by inner leave-one-game-out (3 in all ten folds at release).
- **C1 passes.** Release, 703 held-out misses: log loss 2.200, top-1 23.5%, top-3 50.8%, against 2.261 for the best
  baseline (role prior by range). Superior to all eight references under the frozen rule; the smallest gain is 0.061
  nats over role prior by range (conservative interval −0.100 to −0.030, every drop-one mean negative). Class-wise ECE
  0.0047 against 0.0075 for the selected reference.
- **Exploratory, rim + 0.2 s** (650 misses, positions at that time): 2.085 against 2.174 for nearest to hoop, superior
  to every baseline. This is the same-time static reference for Step 09's C3b.
- **Where.** Gains are largest on rim shots (−0.14 nats against the selected reference) and on defensive player
  rebounds (−0.13); it is worse on offensive player rebounds (+0.04 at release, +0.20 at rim + 0.2 s) and on offensive
  team awards. Top-1 on offensive player rebounds is 11.6%.
- **Coefficients** (all ten games, per standard deviation; stable in sign across folds unless noted): nearer the hoop
  and nearer than the ten's mean are likelier; more space to the nearest opponent +0.36; each opponent nearer the hoop
  −0.23; each teammate nearer +0.19; shooter −0.19; distance × shot distance +0.41 (long shots favour players further
  out). `dist_hoop` and `dist_minus_mean` are not separately identified (they differ by a per-shot constant). Inside
  gap, shooter on a rim shot, the offensive team-award constant and its shot slope change sign across folds.
- **C2 blocked.** The binary OREB model scores 0.6021 against 0.6102 for the constant rate (difference −0.0082, better
  in 8 of 10 games) but the conservative interval reaches +0.0076, so the constant training rate stays the OREB
  reference. Exploratory: the conditional logit's implied P(OREB) scores 0.5942 (−0.016, interval −0.032 to −0.0003,
  every drop-one mean negative). It would pass C2's rule, but C2 named the binary model, so this is not a confirmatory
  result.
- **Checks, all passed:** Step 03 freeze in force; valid predictions; one credited outcome per choice set; same
  episodes as the baselines; scalers and fits use exactly the training games; every fit converged; predictions
  unchanged when test labels are altered; planted label leak caught; reordering players (largest change 3e-16),
  metres instead of feet (7e-9) and a mirrored court (0) change nothing; reruns reproduce every prediction. 56 unit and
  28 gate expectations pass. Boosted challenger not run (optional).

### Open choices

- Whether to make the logit's implied P(OREB) the OREB model in later steps (it would need its own prespecified test).
- Step 05 (release-time spatial distribution of rebound locations) is next.

## 2026-10-30 — Sequential rebounding manual, Step 05: release-time spatial prior: BLOCKED (coverage at 50%)

At the owner's request ("start step 05"). Code `src/rebounding/R/spatial_prior.R`, `run_step05.R`,
`tests/unit/test_spatial_prior.R`, `tests/gates/test_step_05.R`; settings `config/experiment.yaml` (`step05`, written
before any fit); evidence `outputs/rebounding/step05/` (figures in `figures/`); report
`outputs/rebounding/reports/05_spatial_prior.md`; record `gate_results/05_spatial.json` (status BLOCKED). Full cell maps
in `outputs/cache/rebounding/step05_spatial_prior.rds` (git-ignored, reproducible). TrueImpactShotCharts (MIT) read
for its kernel heatmaps and Voronoi rebound chances; no code copied.

- **Target.** The credited rebounder's position (`rebounds.location` turned into the attack frame; median gap to the
  tracked rebounder 0 ft; 5 missing locations taken from tracking and flagged). Not the ball's free landing point and
  not first contact (Step 02 BLOCKED); 2D only. All 630 locations lie inside the attacked half court. Team awards (73)
  have no location and are outside the target.
- **Models** (1 ft cells, settings by inner leave-one-game-out): uniform; zone bins (6 rings × 6 sectors); pooled
  Gaussian kernel (bandwidth 1.5 ft in all folds, 2% uniform mix); range kernel (pooled shrunk halfway to the shot
  range's own map); side and range kernel (as range, with every shot mirrored to one side; weight 0.5 or 0.75).
- **Scores, 630 held-out locations** (negative log density per sq ft): side and range 5.816, range 5.831, pooled
  5.858, zone bins 5.957, uniform 7.741. The side and range map beats the pooled map (−0.042, interval −0.063 to −0.020,
  9 of 10 games, every drop-one mean negative), so conditioning on shot range and side helps the proper score.
- **Why blocked.** The prespecified rule also needs coverage within 0.05 of 50 / 80 / 95%. The 80% and 95% regions
  pass for every kernel, but the 50% regions hold too many locations: pooled 0.559 (Wilson 0.520–0.597), side and
  range 0.587 (0.548–0.625). The cores are too wide (under-confident): rim shots are over-covered (pooled 0.74 at 50%)
  and threes under-covered (0.45). So the pooled baseline and the candidate are both BLOCKED.
- **Fallback in the manual** ("spatial prior poorly calibrated: fall back to broad train-only prior; do not assert
  high-precision landing zones"). Zone bins meet coverage at all three levels (0.478, 0.789, 0.949) but score 0.099
  worse than the pooled kernel. They were exploratory, not the prespecified baseline, so adopting them is an owner
  decision.
- **Fixes during the run, before any decision was read:** a data.table row filter, and the Wilson interval clamped to
  [0, 1] (a lower bound of 7e-18 above an observed 0 failed a gate test).
- **Checks, all passed:** maps sum to 1 (error 0) and are positive for all 703 episodes × 5 models; 1 sq ft cells;
  fits use exactly the training games' locations; moving a held-out game's locations leaves its maps unchanged;
  reruns reproduce every score. 86 unit and 31 gate expectations pass.

### Open choices

- Adopt zone bins as the Step 05 baseline (a recorded deviation), or keep Step 05 BLOCKED and treat the kernel maps
  as exploratory in Steps 07 and 09.
- **Later the same day: zone bins are calibrated only on average.** By shot range their 50% regions hold 0.667 of rim
  rebounds (Wilson 0.583–0.741), 0.512 of other twos and 0.367 of threes (0.313–0.424); at 80%, 0.909 / 0.775 / 0.744.
  The opposite errors cancel in the pooled figure. The side and range kernel is closer within ranges at 50% (0.659 /
  0.603 / 0.543). So zone bins are not a sound fallback; recommendation changed to keeping Step 05 BLOCKED.
- **Owner decision (2026-10-31): keep Step 05 BLOCKED.** No spatial prior is validated. The kernel maps (best: side
  and range) stay available as exploratory inputs for Steps 07 and 09, labelled as such; zone bins are not adopted.

## 2026-10-31 — Sequential rebounding manual, Step 06: causal ball filter BLOCKED, gravity-only forecast PASS_BASELINE

At the owner's request ("Start Step 06"). Code `src/rebounding/R/ball_filter.R`, `R/ball_noise.R`, `run_step06.R`,
`tests/unit/test_ball_filter.R`, `tests/gates/test_step_06.R`; settings `config/experiment.yaml` (`step06`, written
before any real-data run); evidence `outputs/rebounding/step06/`; report `outputs/rebounding/reports/06_filter_diagnostics.md`;
record `gate_results/06_ball_filter.json` (status PASS_BASELINE). Filter equations as in filterpy and the Kalman book
(MIT; written independently in R).

- **Filter.** State (x, y, z, vx, vy, vz), constant velocity with gravity on z, white-noise acceleration q, per-axis
  observation noise r. Only measured ball frames are observations (single filled frames missing), each usable one frame
  later. Learned on each fold's training free-flight segments: r = 0.073–0.078 / 0.063–0.068 / 0.137–0.142 ft (x/y/z),
  g = 28.1–28.4 ft/s², q = 3 in every fold.
- **Held-out forecasts in free flight** (645 of 703 segments free by the Step 02 one-step rule; 3D error, ft):
  gravity-only from the last two measured frames 0.20 / 0.42 / 0.87 at 2 / 5 / 10 frames; filter 0.28 / 0.54 / 0.98;
  constant velocity 0.43 / 1.32 / 3.62; persistence 2.41 / 4.80 / 8.38. The filter is worse than gravity-only at every
  horizon (by 0.07–0.12 ft, worse in all 10 games), so it fails non-inferiority (margin 0.05 ft).
- **Coverage fails too.** 50% ellipsoids hold 0.66 / 0.50 / 0.46 at 2 / 5 / 10 frames, 90% ellipsoids 0.92 / 0.84 /
  0.80; normalised innovations average 1.64 in free flight (3 if the noise were right). Too wide one step ahead, too
  narrow further out.
- **Likely cause (not tested):** the vendor track is smooth, so neighbouring errors are correlated, and each flight
  has its own curvature (p10 20.6 to p90 31.8 ft/s², decision log 2026-10-28). A filter with one g and a stiff q
  averages over the whole flight and carries that bias forward; two recent points adapt to the flight in hand.
- **Status per the manual:** filter BLOCKED; use the gravity-only forecast and make no claim of reliable online
  uncertainty yet. Forecasts across a contact (tagged, not gated) are 2–4 times worse for every method, as Step 07
  expects.
- **Checks, all passed:** Step 03 freeze in force; 12,134 origin covariances finite, symmetric, positive; parameters
  from training games only; the state at t is identical with later frames removed or corrupted; reruns reproduce every
  error. 32 unit and 18 gate expectations pass. A bug found on the first run (`out[[j]] <- NULL` deletes a list element
  in R) was fixed and covered by a unit test before any result was read.

### Open choices

- Whether to try a second filter version (for example z-acceleration in the state, or a larger q range) as a recorded,
  exploratory follow-up; its held-out games have now been seen.
- Step 07 (rim and board contacts, particle forecasts) is next; its free-flight part would use the gravity-only
  forecast.

## 2026-10-31 — Sequential rebounding manual, Step 07: post-rim forecasts: BLOCKED (empirical narrowly misses coverage; physics fails)

At the owner's request ("Start Step 07"). Code `src/rebounding/R/physics.R`, `R/particle_filter.R`, `run_step07.R`,
`tests/unit/test_postimpact.R`, `tests/gates/test_step_07.R`; settings `config/experiment.yaml` (`step07`, written before
any real-data run); evidence `outputs/rebounding/step07/`; report `outputs/rebounding/reports/07_collision_audit.md`;
record `gate_results/07_postimpact.json` (status BLOCKED). basketball-shot has no licence, so its physics is not
ported: textbook rigid-sphere contacts written independently. Resampling ideas from filterpy and the Kalman book (MIT).

- **Gate rule.** Gate 07 passes a collision model only for contact states with reliable labels; Step 02 is BLOCKED,
  so the physics model was BLOCKED before it ran. The empirical transition model was the PASS_BASELINE candidate.
- **Setup.** Origins 0, 5, 10, 15 frames after Step 03's causal rim-arrival trigger; targets 5 / 10 / 15 frames ahead
  before the credited rebound. Hoops per camera end from the training games' made shots (the offset is +0.6 to +1.1 ft at
  one end and −1.1 to −1.6 ft at the other in every game). g and noise from Step 06 by fold.
- **Deviation, after the first run.** The vendor measures the ball on a 5-frame cadence and the trigger is always one
  frame after a measured frame, so exact targets at multiples of 5 frames were unmeasured in about two thirds of
  episodes (268 of 679 scored). Targets are now the first measured frame 0–2 frames after origin + horizon, forecast
  for that exact frame by every model; 639 episodes and 5,268 targets per model. The first run is kept in
  `step07/first_run_exact_frames/` (its decisions were the same).
- **Results** (negative log density per cubic foot at 5 / 10 / 15 frames): empirical analogs 3.84 / 5.83 / 7.08;
  gravity-only Gaussian 5.41 / 8.10 / 9.70; physics 43 / 73 / 110. Empirical beats gravity-only at every horizon
  (−1.5 to −3.0 nats, all intervals below zero). Mean error of the forecast centre: empirical 1.3 / 2.5 / 3.7 ft.
- **Why empirical is still blocked.** Its 50% regions hold 0.560 and its 90% regions 0.847, just outside the 0.05
  tolerance (by 0.010 and 0.003): too wide at the core, slightly too narrow in the tails. Coverage is lower for Step 02's
  unclear cases (90%: 0.69 UNKNOWN, 0.57 no contact, 0.48 board) than for rim contacts (0.85–0.88).
- **Why physics fails.** Coverage 0.13 / 0.31, 15% of updates degenerate (effective sample size under 10%), and the
  scores change by about 25 nats per target with another seed or twice the particles (unstable). The example
  figure shows the likely cause: the ball track does not sit on FIBA fixtures (balls measured behind the board face or
  above it, 1–2.5 ft above the ring at contacts per Step 02), so contacts on nominal geometry send particles the wrong
  way, and tight weights then collapse the cloud. Not tested further.
- **Checks, all passed:** Step 03 freeze in force; weights sum to 1 (error 2e-16); ESS logged for 5,297 updates;
  hoops from training games only; all models on the same targets; forecasts unchanged when later inputs are corrupted.
  35 unit and 19 gate expectations pass. Two crashes on empty episodes were fixed before results were read; fold
  results are cached (`--reuse-folds`). The run takes about 7 minutes.

### Open choices

- Keep Step 07 BLOCKED (the empirical model then enters Step 09 only as an exploratory input), or accept the empirical
  model as PASS_BASELINE despite the narrow coverage miss (a recorded deviation).
- **Owner decision (2026-11-05): keep Step 07 BLOCKED.** No post-rim forecast is validated. The empirical analog
  model enters Step 09 only as a labelled exploratory input; the physics model stays BLOCKED.

## 2026-11-05 — Sequential rebounding manual, Step 08: movement PASS, interception BLOCKED, reach exploratory (PASS_BASELINE)

At the owner's request ("Start Step 08"). Code `src/rebounding/R/player_motion.R`, `R/reach.R`, `run_step08.R`,
`tests/unit/test_reach.R`, `tests/gates/test_step_08.R`; settings `config/experiment.yaml` (`step08`, written before any
real-data run); evidence `outputs/rebounding/step08/`; report `outputs/rebounding/reports/08_reachability.md`; record
`gate_results/08_reachability.json` (status PASS_BASELINE). Arrival rule adapted from LaurieOnTracking's
`simple_time_to_intercept` (MIT); its centred velocity filter is replaced by a trailing one (no future frames).

- **Gate rule.** Interception can only be validated against first-contact labels; Step 02 is BLOCKED, so the physical
  interception validation is BLOCKED and the reach margins are exploratory.
- **Movement** (players' tracked positions 5 / 10 / 15 / 25 frames after release, rim arrival and rim + 0.4 s; error in
  ft, detected targets): damped velocity 0.22 / 0.63 / 1.23 / 2.86; constant velocity 0.22 / 0.66 / 1.30 / 3.13;
  stationary 0.95 / 1.89 / 2.80 / 4.59. Damped is superior to both at every horizon (Step 03 rule); the speed-capped
  version adds nothing. Damping lambda = 0.5 /s in every fold, the smallest value on the grid, so the best value may be
  below it.
- **Limits.** Training v_max 15.2–15.4 ft/s and a_max about 20 ft/s² (99.5th percentiles of causal 0.24 s velocities
  in rebound windows); held-out detected speeds exceed v_max on at most 0.9% of frames. 15 ft/s is a data quantile,
  well under a sprint, so the arrival model is conservative about who can get there.
- **Reach at the rim arrival** (realised ball path, so after the fact): about 4.5 players can reach the ball on average,
  none can in 16% of misses. The credited rebounder can in 78% and has the best margin in 46% (top 3: 83%); Step 02's
  unvalidated first toucher can in 82% (best margin 53%). Sensitivity: 1 ft position error changes the earliest arriver
  in 21% of misses, reaction 0.1 / 0.3 s and half the ball frames in 7–9%, jump reach and takeoff barely.
- **Checks, all passed:** Step 03 freeze in force; velocities unchanged when later frames are corrupted; damping and
  limits from training games only; a ball above every reach gives no interception; reruns reproduce the errors.
  22 unit and 17 gate expectations pass. Obstruction is not modelled (Step 11).

### Open choices

- Whether to extend the damping grid below 0.5 /s in a later, recorded revision.
- Step 09 (combining ball and player access into updated rebound probabilities) is next.
- **Owner decision (2026-11-05): anticipation is measured at Step 10, not added to Step 08.** The damped
  fixed-direction forecast stays the "ignores the ball" baseline; Step 08's reach rule (run straight at the realised ball
  after the reaction time) is the perfect-reading bound. Step 10 measures movement toward the likely rebound area
  against the baseline, labelled exploratory while the post-rim ball forecast (Step 07) is unvalidated.

## 2026-11-05 — Sequential rebounding manual, Step 09: dynamic probabilities: C3a and C3b met, BLOCKED by particle stability

At the owner's request ("start step 9"). Code `src/rebounding/R/particle_integration.R`, `R/dynamic_choice.R`,
`run_step09.R`, `tests/unit/test_dynamic.R`, `tests/gates/test_step_09.R`; settings `config/experiment.yaml` (`step09`,
written before any real-data run); evidence `outputs/rebounding/step09/`; report
`outputs/rebounding/reports/09_model_comparison.md`; record `gate_results/09_dynamic.json` (status BLOCKED).

- **Model.** For each of 30 ball particles, one softmax over the 12 outcomes: Step 04's player features plus each
  player's access margin to the particle (Step 08 arrival rule, fold v_max) and whether he has the best margin; the
  episode's probabilities average the particles. Particles: the Step 05 release map at release, the Step 07 analog
  forecast of the ball 0.4 s ahead at rim + 0.2 s. A training episode's map and analogs come from models without the test
  game and without its own game. Lambda 3, no temperature. One fold takes about 3 minutes, so folds now run as parallel
  processes (`--fold=k`), each cached; the plain run assembles and scores (13 s).
- **Held-out results** (log loss / top-1 / top-3): release dynamic 2.181 / 23.9% / 54.3% against static 2.200 / 23.5% /
  50.8%; rim + 0.2 s dynamic 2.029 / 30.0% / 60.3% against static 2.085 / 21.1% / 55.4%. C3a (release, non-inferiority):
  −0.019, interval −0.030 to −0.008, better in 9 of 10 games: met (it is superior too). C3b (rim + 0.2 s, superiority):
  −0.057, interval −0.087 to −0.023, every drop-one mean negative, 9 of 10 games: met. Calibration met at both times.
  At rim + 0.2 s top-1 rises most on rim shots (41.8% vs 24.6%) and on offensive player rebounds (20.5% vs 10.6%).
  Access-only (no player geometry) is worse than static at both times; access adds to geometry, it does not replace it.
- **Why blocked.** The prespecified prediction-time stability check fails: redrawing the 30 particles with another seed
  moves an episode's log loss by 0.071 (release) and 0.131 (rim + 0.2 s) on average, and twice the particles by 0.036 and
  0.096, against a 0.02 limit. The mean differences are tiny (−0.002 to −0.007, limit 0.01), so the aggregate scores are
  stable but single predictions are noisy at this particle budget.
- **Other checks passed:** valid, normalised predictions; P(OREB) consistent; same episodes as static; every fit
  converged; halving the ball frames lowers confidence (mean top probability −0.015), it does not raise it;
  `predict_rebound()` replays the out-of-fold predictions exactly and ignores corrupted later frames. 17 unit
  expectations pass; the gate test fails only on stability (14 of 15 gate expectations pass).

### Open choices

- Keep Step 09 BLOCKED (ship the Step 04 static model; dynamic exploratory), or rerun the prediction step with a larger
  particle budget (fitted models unchanged) as a recorded deviation and rejudge stability, C3a and C3b.

### Rerun with 2,000 prediction particles (owner decision, same day): PASS

The owner chose to rerun the prediction step with more particles. Deviation recorded in `config/experiment.yaml`
(`step09.particles.prediction_count: 2000`): fitted models keep 30 particles per training episode; held-out predictions
use 2,000, predicted in chunks. The first run is kept in `step09/first_run_30_particles/`. All ten folds ran in parallel
(143 s); record `gate_results/09_dynamic.json` now PASS.

- **Stability met:** another seed moves an episode's log loss by 0.009 (release) and 0.016 (rim + 0.2 s) on average,
  4,000 particles by 0.004 and 0.012 (limit 0.02); mean differences under 0.002.
- **C3a met:** release log loss 2.177 against 2.200 static (−0.023, interval −0.032 to −0.013, better in all 10 games).
  **C3b met:** rim + 0.2 s 2.023 against 2.085 (−0.062, interval −0.086 to −0.036, 9 of 10 games, every drop-one mean
  negative). Calibration met (ECE 0.0054 / 0.0047 against 0.0047 / 0.0090). Top-1 at rim + 0.2 s 28.9% against 21.1%;
  rim shots 39.3% against 24.6%, offensive player rebounds 16.8% against 10.6%.
- **Other checks passed:** halving the ball frames lowers mean confidence (−0.014); the replay through
  `predict_rebound()` matches the out-of-fold predictions and ignores corrupted later frames. 17 unit and 15 gate
  expectations pass.
- **What it does not show:** the ball inputs (Steps 05 and 07) are still unvalidated; the gain is in held-out
  rebound scores, not proof that the ball forecasts are right.

## 2026-11-05 — Sequential rebounding manual, Step 10: positioning and movement measures: BLOCKED by response-onset stability; player claims PASS

At the owner's request ("Start Step 10"). Code `src/rebounding/R/opportunity_value.R`, `R/response.R`,
`R/positioning.R`, `run_step10.R`, `tests/unit/test_opportunity.R`, `tests/gates/test_step_10.R`; settings
`config/experiment.yaml` (`step10`, written before any real-data run); evidence `outputs/rebounding/step10/`; report
`outputs/rebounding/reports/10_movement_attribution.md`; record `gate_results/10_movement.json` (status BLOCKED).

- **Measures.** Q = a player's chance of reaching the ball, averaged over 500 particles from the Step 05 release map
  (logistic in his arrival margin from Step 08, sigma 0.45 s). Move = Q at rim arrival minus Q at release on the same
  particles in absolute time (≤ 0 by construction: the clock runs). vs_baseline = Q at rim arrival minus Q of Step 08's
  damped forecast that ignores the ball (access gained by reading the shot). Info = Q at release under the Step 07
  analog forecast minus under the reference. 678 episodes, 6,780 player-episodes.
- **Change before any real-data run:** the player-effect measure is `vs_baseline`, not `move`. The unit tests showed
  move mostly measures how long the ball is in the air, not the player.
- **Bug fix found on the first run:** episode tracks kept only 5 frames of players before release, so the 10-frame
  velocity variant had no velocity at release (100% "class changed"). Step 10 now reads 25 frames of history; every
  other result is identical to 1e-15 and the window-10 variant is stable (2.0% class change, 2-frame shift).
- **Results.** vs_baseline by role: offence other +0.084, defence other +0.071, offence nearest the hoop +0.043,
  shooter's defender +0.023, rim protector +0.021, safety +0.011 (interval touches 0), shooter −0.053. Larger on threes
  (+0.08) than rim shots (+0.004 to +0.009). 70–94% of players per role show no sustained move toward the ball before
  rim arrival + 10 frames; median onsets 0.56–0.92 s. Credited rebounder ranks first by Q at rim arrival in 24.6% of
  614 episodes (Q at release 20.2%, vs_baseline 11.7%).
- **Checks passed:** decomposition adds up (1e-16); reference sensitivity Spearman ≥ 0.996 against the pooled and
  zone maps; a particle redraw moves move / vs_baseline by 0.0076 / 0.0029; split-by-game player reliability r = 0.47
  over 25 players seen in two games, no sign changes at prior scales 0.5 and 2.
- **Why blocked.** Raising the response speed threshold from 6 to 8 ft/s shifts the median onset by 5 frames (0.2 s),
  over the prespecified 3; class changes are 9.4% (limit 20%). Four of five variants are stable. A higher threshold
  is reached later by construction, so the onset time depends on the chosen speed, not only on the player.
- **What it does not show:** the reference distribution (Step 05) is unvalidated, so every Q is relative to it;
  player claims rest on 25 players seen in two games (179 of 204 appear once).

### Open choices

- Keep Step 10 BLOCKED (opportunity and vs_baseline usable as exploratory; onset times not reported as player
  facts), or report onsets as threshold-dependent (a curve over 5–8 ft/s) as a recorded deviation.

### Onsets reported as a threshold curve (owner decision, same day): PASS

The owner chose to report onset timing as a curve over the speed threshold instead of one time. Deviation recorded in
`config/experiment.yaml` (`step10.response.threshold_curve: [5, 6, 7, 8]`): threshold variants are judged on class
change only, since a higher bar is reached later by construction; window and position-error variants keep the full
rule (class change ≤ 20% and median onset shift ≤ 3 frames). Base classes still use 6 ft/s. New output
`step10/response_onset_curve.csv`; record `gate_results/10_movement.json` now PASS (measurements and player claims).
Every other table is byte-identical to the blocked run.

- **Stability met:** 6 of 6 variants; class changes 0.9–9.4%; window 4 / 10 and 1-ft position error shift onsets by 1,
  2 and 0 frames.
- **Curve, all players** (share responding / median onset): 5 ft/s 13.3% / 0.60 s, 6 ft/s 11.1% / 0.60 s, 7 ft/s
  8.6% / 0.64 s, 8 ft/s 7.0% / 0.68 s. Offence "other" responds most (22% to 17%, median 0.52–0.66 s); the shooter
  and rim protector almost never (under 2.5%).
- **Gate test added:** a player timed at 6 and 8 ft/s never reaches the higher bar earlier. Shares can move either way
  (a higher bar also takes players out of "already moving"), so they are not tested for monotonicity.
- **What it does not show:** onsets for small roles rest on few responders (rim protector 9 players at 6 ft/s, none at
  8; safety 6); read those cells as descriptive.

## 2026-11-05 — Sequential rebounding manual, Step 11: geometric obstruction: BLOCKED by two prespecified geometry checks; box-out detection BLOCKED

At the owner's request ("start step 11"). Code `src/rebounding/R/pairwise_obstruction.R`, `R/boxout.R`,
`run_step11.R`, `tests/unit/test_obstruction.R`, `tests/gates/test_step_11.R`; `R/conditional_choice.R` now takes an
optional feature list (default = Step 04's; the Step 04 refit reproduces its held-out predictions to 6e-16). Settings
`config/experiment.yaml` (`step11`, written before any real-data run); rubric `docs/project/ANNOTATION_RUBRIC.md`
(box-out rubric v1); evidence `outputs/rebounding/step11/`; report `outputs/rebounding/reports/11_boxout_validity.md`;
record `gate_results/11_obstruction.json` (status BLOCKED).

- **Measure.** O_ij = how much player i stands on player j's route to 15 fixed, label-free points around the hoop
  (the hoop, rings at 4 and 8 ft), averaged over the points. The Step 05 map was not used as the target: its
  out-of-game fits include other folds' test games, and it is not validated. Player features: blocked_by_opp,
  blocking_opp. Pairings are never forced (`none` below 0.25, `ambiguous` within 0.1).
- **Passed:** mirroring (4e-16) and 30° rotation about the hoop (4e-15); no non-finite score; frames ≤ t and t before the
  rebound; planted future feature caught; label invariance; contribution identity (2e-16); unit tests (116 expectations).
- **Failed (why blocked).** (1) One-foot moves change the features by 0.054 on average at rim + 0.2 s (limit 0.05;
  0.048 at release). (2) The hoop-only target ranks blocked_by_opp differently: Spearman 0.753 at rim + 0.2 s (limit
  0.8; 0.809 at release; blocking_opp 0.95). Also reported, not gated: among players with a pair, 31% change pairing
  under a one-foot move (all players: 10.5%, limit 0.2). The proxy is sensitive to where routes are assumed to lead
  and to ordinary tracking error.
- **Model value (held-out, against Step 04): does not degrade, does not improve.** 12-class log loss difference
  +0.0004 at release (−0.005 to 0.005), −0.0022 at rim + 0.2 s (−0.008 to 0.003, better in 7 of 10 games); team log loss
  −0.001 at both; ECE no worse. Coefficients keep their sign in every fold: being blocked lowers a player's chance
  (−0.17 to −0.22 per sd at rim + 0.2 s), and so does blocking others (−0.05 to −0.11).
- **Contribution split (rim + 0.2 s, model-implied).** Removing a rim protector's blocking moves his own chance by
  −0.013 and his teammates' by +0.027 (side +0.014); other roles smaller. Read as association, not what a box-out causes.
- **Box-out labels.** 40 held-aside pairs drawn (8 per stratum: strong, ambiguous, close but not blocking, post,
  converging), pages and a blank sheet in `step11/review/`; Claude did not label them. Tracking-plot labels can only
  measure agreement with a reading of the same positions, so detection and box-out ability stay BLOCKED; no player
  box-out effects fitted.
- **Fix during the run:** two gate tests read the gate record before the runner writes it; they now read the
  comparison table and the report. No threshold or measure changed; the rerun reproduces every number.

### Open choices

- Keep Step 11 BLOCKED (obstruction reported as an exploratory description only), or accept a recorded deviation,
  for example judging target sensitivity on blocking_opp only or loosening the one-foot limit; either would be decided
  after seeing these results and must be logged as such.
- Whether someone other than Claude fills `step11/review/reviewer_heldout.csv`.

### Kept BLOCKED, context added (owner decision, same day)

The owner chose to keep Step 11 BLOCKED with every limit as prespecified. Added as a non-gating note
(`step11/perturbation_context.csv`, report section "Context, not gated"; `11_obstruction.json` `decision.owner_decision`):
the same one-foot moves applied to Step 04's features. Obstruction features move 0.24-0.26 SD (Step 04's relative
features 0.16-0.18 SD; distance to the hoop 0.07) but keep the ten players' order as well (rank correlation 0.95-0.97
against 0.91-0.96). The 0.05 limit had no scale reference, so that miss is small; the target miss is substantive
(blocked on the way to the hoop vs the area around it rank players differently at rim + 0.2 s, Spearman 0.75).
Alternatives considered and not taken: judging the one-foot check by rank correlation and splitting the target into two
named measures (both decided after seeing results), or redefining and rerunning (no fresh games to check it on).
Obstruction stays an exploratory description; later steps do not use it.

## 2026-11-05 — Step 02 rescored with reviewer 2: contact labels PASS where reviewed; automated labels still BLOCKED

The owner filled `outputs/rebounding/step02/review/reviewer2_heldout.csv` (30 of 30). Rescored with
`run_step02.R --phase=score` and `--phase=gate`; thresholds and the decision rule unchanged (the rule, written on
2026-10-29, judges the gate on reviewer 1 vs reviewer 2 once a second reviewer finishes). Details:
`outputs/rebounding/reports/02_annotation_reliability.md` ("Reviewer 2"); record `gate_results/02_contact_states.json`
(status PASS).

- **Reviewers agree on rim or board contact** (26/26 resolved, kappa 1.0, frame within ±2 in 22/23): PASS.
- **Everything softer is BLOCKED.** First touch: both name the player in 12/30 (target 60%); same player 11/12;
  frame within ±3 in 12/23. Control: both name the controller 19/30 (target 70%); same controller 18/19; frame 12/21.
  Tip vs catch kappa 0.0; same tip count 20/30. Identity agrees when named; timing and naming do not.
- **Automated labels stay BLOCKED for every type**, now against both reviewers (contact vs reviewer 2: kappa 0.46,
  frame within ±2 in 19/24). The PASS covers reviewed episodes only, so nothing downstream changes: Steps 03–11 use
  the credited rebounder; Step 07 physics, Step 08 first-contact checks and Step 12 stay blocked by labels.
- **Record text updated, decision unchanged:** `run_step02.R`'s gate phase still said "no second reviewer"; it now
  names reviewer 2 and adds `automated_labels_by_type` and a scope line that separates reviewed from automated labels.
  `contact_events.csv` and every other Step 02 output except the agreement tables are byte-identical.
- **For the v2 labeler:** these 30 episodes are v2 development data (owner decision 2026-10-29), now with two
  reviewers. The disagreements show the target: timing of soft events, not who.

### Open choices

- Whether reviewer 2 was blind to reviewer 1's sheet, the dev pages' automated marks and the credited rebounder
  while labelling (the record assumes yes).
- Whether to continue the v2 labeler (contact timing on every episode would unblock Step 07's physics checks), or to
  go on to Step 12 in reduced form with the credited rebounder only.

## 2026-11-05 — Site: the manual's results added to the Rebounding tab; box-out claims marked unvalidated

At the owner's request ("implement it into the site"). The live site (GitHub Pages, `web/`) still showed only the
first build (October 27–28); none of the manual's Steps 00–11 appeared on it.

- **New export** `src/rebounding/run_export_manual.R` → `web/public/data/rebounding_manual.json` (37 KB): every gate
  record (status, scope, parts) and the result tables of Steps 02 and 04–11, copied from `outputs/rebounding/` and
  rounded; nothing refitted.
- **New section 12** of the Rebounding tab (`web/src/components/ReboundingManual.svelte`): gate table for all
  twelve steps, who-gets-the-ball scores (dynamic, static, best baseline, uniform) and the C3 tests, ball coverage
  (Steps 05–07), movement (Step 08), reviewer agreement (Step 02), positioning and onset curve (Step 10), obstruction
  (Step 11). Every number is read from the export.
- **Corrections to the first build's pages:** a note under the tab's introduction says sections 1–11 are the first
  build and section 12 holds where they disagree; section 9 (box-outs) opens with "Not validated"; the play panel's
  "Box-outs now" is renamed "In the way now" with "not validated box-outs" in its hint. The panel's numbers and the
  first build's models are unchanged.
- **Checks:** `svelte-check` 0 errors, `vitest` 46 passed, build passes; checked in the local preview (no console
  errors, links scroll to section 12). Not deployed: the site updates when these `web/` changes are pushed to `main`.

## 2026-11-05 — Play viewer: the landing forecast drawn as nested regions

At the owner's request (a reference image of shrinking uncertainty regions: early flight, late flight, after the rim).
The play viewer's landing forecast now defaults to **Regions**: from each forecast's 40 simulated first landings, the
ellipse holding 90% of them if they were spread normally (dashed edge, light sand fill) and the one holding 50% (stronger
core), from the sample's mean and covariance scaled by the chi-square quantile with two degrees of freedom; axes at
least 0.75 ft; drawn inside the court's lines only (the panel already states the share landing out of bounds). Heatmap,
Dots and Off remain. Code: `web/src/lib/rebounding.ts` (`landingEllipse()`, `drawRegions()`), panel option and default
(`ReboundPanel.svelte`, `viewer.svelte.ts`); three new tests (`web/tests/rebounding.test.ts`). Checks: svelte-check 0
errors, 49 tests pass, build passes; checked in the preview on game 114243's first miss (release, 1 s, after the rim).

- **Same model as before.** The regions summarise the first build's simulated landings (`run_export.R`), which section 1
  of the Rebounding tab calls an illustration; the manual's ball forecasts (Steps 05–07) did not pass. The collection
  chances and team split in the play viewer are also still the first build's models, not the manual's Step 09 model.
- **Why the manual's model is not in the viewer yet:** Step 09's held-out predictions exist at two moments per miss
  (release and rim + 0.2 s, `step09/dynamic_oof.csv.gz`), while the viewer shows a forecast every 0.2 s. Showing it
  through a whole replay needs the Step 09 model run at every 0.2 s and a new export.

## 2026-11-05 — Play viewer: Step 09's held-out chances replace the first build's by default

At the owner's request ("Yes, add Step 09"). The play viewer's collection chances and team split now come from the
manual's Step 09 dynamic model (gate PASS) by default; a panel switch ("Step 09 chances" / "First build") brings the
first build back.

- **Held out.** `run_export_manual.R` writes `web/public/data/rebounding_manual/{game}.json` from
  `step09/dynamic_oof.csv.gz`: each miss's forecasts from the fold model fitted without its game, with the frame each was
  made at. No refit.
- **Only the validated moments.** Step 09 forecasts at release and at rim + 0.2 s, so the viewer shows the release
  forecast until the rim + 0.2 s one is made, then keeps it; it does not interpolate or extrapolate to other times
  (running the model every 0.2 s would need new validation). Coverage: all 703 misses with the same ten players; 650 with
  both moments (the other 53 keep the release forecast).
- **What stays the first build's:** the landing regions and the blocking links (not validated; the panel says so) and
  the "first 0.48 s of movement" ratings. The panel names the source and moment of every Step 09 forecast.
- **Code:** `web/src/lib/rebounding.ts` (`step09At()`, `withStep09()`), `data.ts` (`loadStep09()`), `Stage.svelte`,
  `ReboundPanel.svelte`, `viewer.svelte.ts`; three new tests. Checks: svelte-check 0 errors, 52 tests pass, build passes;
  checked in the preview on game 114243 (values equal the export; the switch works both ways).

## 2026-11-06 — EPV, court control and rebounding models archived; viewer simplified

Decided by the owner: the modelling work had become a black box to them, so it is set aside until it can be rebuilt
one understood step at a time. Nothing was deleted; everything moved to `zz_Archive/` under its original path.

- **Archived:** `src/epv/`, `src/court_control/`, `src/rebounding/`; `outputs/epv/`, `outputs/court_control/`,
  `outputs/rebounding/`; the caches `outputs/cache/{epv,court_control,rebounding}/` and `external/` (git-ignored, also
  under `zz_Archive/`); `BUILD_SPEC.md`, the rebounding manual HTML, `docs/project/{rebounding.md,
  ANNOTATION_RUBRIC.md,REVIEWER2_GUIDE.*,SOURCE_REGISTER.md}`; the site's EPV, court control, shot (xFG) and rebound
  panels, their libraries and tests, and their data files. The earlier entries in this log still describe that work;
  their paths now sit under `zz_Archive/`.
- **Kept:** the Rebounding tab's descriptive sections (data, ball-track audit, where misses go, the rebound finder),
  read from `web/public/data/rebounding_eda.json`, frozen from the archived `rebounding.json`. Its "decision" boxes,
  which pointed at the models, are now plain takeaways. The archetypes (`src/archetypes/`) keep working: the few
  tracking helpers they borrowed from `src/epv/R/features.R` are copied, unchanged, to
  `src/archetypes/R/tracking_state.R`.
- **Export:** the play binary no longer carries EPV prices or shot steps (`web/scripts/export_data.R`, `decode.ts`).
  `plays.json` gains `oreb`: offensive rebounds a player collected in the possession (rebounds table, `defensive` false
  and `rebounded` true; team rebounds are not counted). 166 of 1,557 possessions have one.
- **Viewer:** a filter for offensive rebounds (in the Shiny app's `filter_plays()` too, with three parity cases); an
  "Off. rebound" tag on list entries; a narrower, resizable left column (one filter per row; pairs return when it is
  dragged past 340 px); a trace panel between the court and the transport bar showing the ball's height, or a clicked
  player's floor distance to the nearest opponent, sampled every 0.2 s of playback, with extrapolated positions marked.
- **Checks:** export and parity reference rerun (`INDEX_VERSION` 4), svelte-check 0 errors, 39 tests pass, checked in
  the preview. The Shiny viewer's front end still holds its EPV and shot-panel code; with no prices it hides them.

## 2026-11-07 — Court orientation corrected; screen locations fixed; and-ones shown as makes

- **Finding (discrepancy with `docs/data_dictionary/tracking_data.md`):** tracking `y` runs from the far sideline to
  the near one in the camera's view, not "bottom to top" as documented. Evidence: across the ten games every shot whose
  region starts "left" (269) has its shooter on the offense's right in raw tracking, and every "right" shot (241) the
  reverse, while the event convention (offense's left at +y) matches the regions. The owner also found a broadcast
  replay where the viewer showed the shooter on the far side and the video on the near side.
- **Fix:** `play_payload()` stores `(flip * x, -flip * y)`, a true top-down court that matches the broadcast in the
  camera view; event locations map as `(-x, y)` (`web/scripts/annotations.R`). Shots, passes, dribbles, drives,
  closeouts, fouls, rebounds, turnovers and touches then sit on the actor's tracked position (median gap < 0.01 ft).
- **Second finding:** in `picks`, `handoffs` and `off_ball_screens`, `location` y has the wrong sign on most
  possessions where `leftHoop` is true (about 1,350 of 1,560 such events), and their `region` left/right with it. The
  export places each on whichever sign lies nearer the screener's tracked position (majority rule when he is not
  tracked); region labels of those tables are not used.
- **And-ones:** a possession whose last shot was made while fouled (outcome FOU, or FGM) is labelled "Made 2/3" with
  `and1 = TRUE` (29 possessions) instead of "Foul" (`INDEX_VERSION` 8).
- **Checks:** export and parity reference rerun; tests check every marker family against the tracked actor and the
  left/right side of labelled shots; 50 tests pass.

## 2026-11-07 — Viewing windows cut at each possession's deciding event; time-to-ball court control restored

- **Problem:** SkillCorner's possessions tile the video (one ends on the frame the next starts). After a made basket
  the next possession starts at the shot's endFrame, before the ball drops through; after a stoppage it starts only
  when the clock restarts, so the break and the other team's inbound sat at the end of the earlier possession (with
  Skip Dead Ball, the two seconds of lead-in before the restart). Before the fix 233 of 1,557 plays showed more than
  1 s past their deciding event (34 with the clock running) and 31 shared frames with the next play.
- **Fix (`view_windows()`, `src/play_viewer/R/data.R`, `INDEX_VERSION` 9):** a possession decided by a shot,
  turnover or foul ends 0.5-1.5 s after its last shot, rebound, turnover, foul or free throw (`SETTLE_GRACE`), never
  past the frame before the next possession's first touch; the next window starts on the following frame and so
  carries any break and its own inbound. End-of-period, jump-ball and out-of-bounds endings keep the old rule. The
  delivered possession frames are unchanged; only what the viewers show changes. After: 2 plays (both end of
  period) show more than 1 s past their deciding event, none share frames, 1,561 plays pass the minimum length.
- **Court control:** the archived model's "Control" layer only (who would reach the ball first at each spot, with
  the ball's travel time), in `web/src/lib/control.ts` with its constants written out; checked against the archived
  R reference cases (`web/tests/control.test.ts`). The rebound, relevance and scoring layers stay archived.

## 2026-11-07 — Player Tracking columns: court regions and a distance-based contest level

- **Regions (`web/src/lib/regions.ts`):** SkillCorner's region vocabulary from position alone, with boundaries read off
  25,531 labelled event locations in the ten games (shots, dribbles, passes, rebounds, turnovers; the screen tables are
  left out because of their y-sign error): backcourt x < 0, far beyond 31.5 ft, ra within 4.1 ft, the key, corner at
  76° or more from straight out, middle under 23°, three beyond the FIBA line. Agrees with SkillCorner's label on
  98.8% of those locations (at least 95.6% in every region).
- **Contest:** SkillCorner's `contestLevel` is not a function of distance alone (median closest-defender distance:
  plus 2.8 ft, light 4.1, average 4.5, open 6.0). The tab's stand-in grades the nearest defender's distance with
  cut-offs 3.5 / 5.5 / 6.5 ft (plus / average / light / open): SkillCorner's level on 50% of the ten games' shots,
  within one level on 81%. Labelled as a stand-in in the column's tooltip.

## 2026-11-08 — Player card and points-per-action figures from the ten tracked games

- **Why:** the season aggregates are offense-only and cover shots, drives and picks; rebounds, assists, minutes,
  ratings, shot quality, tracking and the other actions exist only in the ten games' events and tracking.
- **What (`web/scripts/sample_stats.R` → `web/public/data/sample.json`):** per person and team over the ten games:
  box score (FIBA FGA: fouled misses left out), on-court offensive and defensive ratings from the shots and free
  throws of the possessions he was on court for, usage, rebound shares, mean SkillCorner `shotQuality` of his FGA
  (rim = restricted area, mid-range = other twos, three), live-play tracking (speed, distance, top 0.5 s speed,
  paint time, nearest opponent) and points per action (own make plus assisted make, free throws left out; picks
  direct only, as in the season aggregates). Team points close to every final score; chance-based minutes run
  1-2% short of the full game clock (chances do not cover every second).
- **Labelling:** every figure in the site's player card and hover tables says whether it is Season (aggregates,
  293 games) or Tracked (the ten games). Tracked samples are small (most players appear in one game); counts are
  shown beside each rate.
- **2026-11-08 addition — Playstyle and guarded shot quality:** `web/scripts/playstyle.R` rebuilds each player's
  component scores (the archetype script saves loadings and centres, not player scores) from the same feature cache,
  scaling and fit players; the refit loadings match the saved ones to 0.002 and the fitted players' mean scores per
  archetype sit within 0.18 SD of the saved mixture centres (0.02 on defense). `sample.json` adds, per player, the
  shot quality and eFG of the opponents' FGA on which he was the closest defender, by zone. `export_data.R
  --figures` rewrites only season.json, sample.json and playstyle.json.

## 2026-11-08 — Shots without SkillCorner context rebuilt from tracking

- **Finding:** 26 of the ten games' 1,459 shot events have every tracking-derived field blank (location, distance,
  region, shotQuality, contestLevel, closestDef*, complexShotType). The tracking has all ten players and the ball at
  the release frame on 25 of them. Likely causes: 14 of the 17 threes were tracked within half a foot of the line
  (21.7-22.3 ft); six twos are tip-ins or putbacks at the rim; a few spots contradict the official value (a three
  from 10.9 ft, twos from 27-40 ft), suggesting a mistimed frame or player mix-up. For located shots, the tracked
  spot at startFrame matches SkillCorner's distance to 0.03 ft (median).
- **Treatment:** the site rebuilds location, distance, region, closest defender and a distance-based contest
  estimate from the tracking (`web/src/lib/shotfill.ts`), letting the official two/three decide the region within
  1.5 ft of the line and flagging larger contradictions on the shot card. Shot quality, type and release time show
  "Not Provided". `sample_stats.R` zones the blank twos by tracked distance and credits the nearest opponent as the
  closest defender. Play labels no longer print "(NA)" for a missing shot type (`INDEX_VERSION` 10).

## 2026-11-08 — Court control: each player's own sprint speed

- **Before:** every player ran to each spot at the archived VMAX, 18.11 ft/s (the league's 99th percentile of player
  speed in live play).
- **Now (`web/src/lib/control.ts`, figures from `web/scripts/sample_stats.R`):** each player runs at his own 99th
  percentile of live-play speed, measured as the model measures velocity (6-frame difference, capped at 30 ft/s),
  shrunk toward the pooled league value (17.84 ft/s) with 10 live minutes of prior weight, then scaled so the
  frame-weighted player average is the archived VMAX that REACT, SIGMA and LAMBDA were fitted with. Range 16.4-20.0
  ft/s; centres slowest, off-ball wings fastest. It is observed speed, so it mixes ability with role.
- **Effect:** on 389 sampled frames from 40 plays the offense's court share moved by a median of 1.7 points
  (90th percentile 8.4, max 21; the largest in open areas far from everyone). The R-parity test still runs with one
  speed. The other constants were not refitted.
- **2026-11-08 addition — acceleration and braking limits; archetype priors:** after reacting, a player's speed toward
  a spot now changes no faster than his own acceleration (speeding up) and braking (stopping first if moving away),
  up to his sprint speed (`runTime` in `web/src/lib/control.ts`); his sideways velocity is ignored. Limits are his
  99th percentiles of the change in speed between 6-frame velocities 0.24 s apart (league 12.4 ft/s² up, 11.9
  down). All three limits now shrink toward the frame-weighted average of his offensive archetype (10 live minutes
  of prior weight) instead of the league. Sprint speeds are still scaled to the archived VMAX average (a 2.7%
  increase: players' own 99th percentiles average 17.64 ft/s, frame-weighted). On 389 frames from 40 plays the
  offense's court share moved by a median of 4.4 points from the archived model (90th percentile 19, max 51); the
  largest swings are players running toward one end who can no longer reverse instantly. Still not refitted.
- **2026-11-08 addition — constants refitted (`web/scripts/fit_control.R`):** rebuilt the archived fit's data from
  the play viewer's tracking cache: 3,728 live passes (66 intercepted) with the ten players at release and the
  catch spot. Control at the catch spot, recalibrated by a logistic, scored by log loss; one game held out at a
  time. On this rebuild the archived motion's best point is reaction 0.3 s, spread 0.3 s, claim rate 50 (the
  archived 0.4 / 0.15 / 100 came from the archived pass table; nearby points score almost the same). Held-out log
  loss (base rate 0.0893): archived 0.0263; per-player sprint speeds only 0.0268 (no gain); per-player limits as
  measured 0.0215, better in 8 of 10 games (mean gain 0.0050, SE 0.0022); limits with acceleration ×1.5 0.0206
  (not adopted: an extra tuned factor for a gain within noise). Adopted for the limits model: reaction 0.05 s,
  spread 0.45 s, claim rate 50 per s (`FITTED` in control.ts); the archived constants stay for the no-limits path
  so the R parity test still holds. Caveats: only 66 interceptions; the players' limits use all ten games'
  tracking, including the held-out game's (movement, not outcomes). Outputs in outputs/court_control/.

## 2026-11-08 — Cuts (site): detection, Action filter, labels

- **Cuts** are detected at export (`web/scripts/cuts.R`; drawn by `web/src/lib/annotate.ts`, events from
  `web/src/lib/cuts.ts`): basket cuts without a screen from the tracking (an attacker off the ball, frontcourt, live
  play, ≥ 9 ft/s with ≥ 7 ft/s toward the hoop for ≥ 0.48 s, gaining ≥ 8 ft, from within 32 ft to within 14 ft),
  and every off-ball screen's cutter's run through the screen ("in" if it ends closer to the basket, "out" if
  further). 2,242 cuts in the ten games; 1,085 of 1,561 possessions have one. Only the possession's offense counts.
- **Action filter** (was "Play type"): the play types plus Basket Cut and Off-Ball Screen Cut (In/Out). Cuts are the
  site's own; the Shiny app's filter (renamed "Action" too) has no cut kinds, so the parity test compares without them.
- **Labels:** "Off-ball Screen" with a capital S (`INDEX_VERSION` 11); shortened to "Scr" in the trace panel's
  captions and the play list's chips, full in the filter and the caption under the court.
- **xPoints** on the shot card: SkillCorner shot quality / 100 × the shot's value, and its percentile among the ten
  games' 1,322 FGA with a shot quality (dunks average the 90th; mean xPoints 1.015 vs 1.034 actual points per FGA).
- **2026-11-08 additions — list counts, caption tilt, screen credit:** possession chips show "×n" when an action
  happens more than once (plays.json `typeCounts`; 754 of 1,561 possessions repeat one). Timeline captions in a
  crowded group now lean the way their leader runs (left-leaning first, anchors at or left of their ticks; then
  right-leaning), with the split that keeps leaders shortest on the rail and collisions checked between every pair
  of groups: 98% of tilted captions follow their leader (48% before). Screen ticks name the screener (handoff setter,
  off-ball screener; picks already did; `INDEX_VERSION` 12); screen cuts keep the cutter.
- **2026-11-08 addition — whistle and turnover details:** foul types from SkillCorner (shooting, offensive,
  flagrant, technical, personal with the bonus noted); turnover types pieced together at export, since SkillCorner
  gives none (`web/scripts/annotations.R`): team violation (teamTo), offensive foul (an offensive foul by the same
  player within a second, or his touch ending in one), pass stolen / steal (a stealer, with or without his own
  intercepted pass), bad pass (an errant pass, no stealer), out of bounds (ball tracked past the lines within half a
  second), else violation. Ten games: steal 85, pass stolen 59, violation 38, out 30, offensive foul 22, team 10, bad
  pass 4. Blocked shots and steals get a badge (BLK/STL) on the timeline, hover card and shot card; closeouts say
  what followed the catch (bhrAction).

## 2026-11-08 — Rebounding roles while a shot is in the air (site)

- **Method (`web/scripts/glass.R`):** for every shot, release to the end of its flight (shots.endFrame, ≤ 3 s);
  each attacker but the shooter gets one role from where he started and where he went: crash (within 8 ft of the
  hoop at the end, or gained 4+ ft and finished within 15 ft), back (3+ ft toward his own end, or into the
  backcourt), safety (the deepest attacker, 28+ ft out, who stayed there), else hold. The shooter: follow (crashed
  his own shot) or shooter. A crash is "met" when his release matchup ends between him and the hoop (within 5 ft of
  him, within 3 ft of his line to the hoop) — coarse, given the failed geometric box-out detector of 2026-11-05.
  Each role carries the share of the window he was on camera.
- **Ten games:** 7,283 attacker-shots on 1,457 shots: hold 38%, crash 24%, back 12%, safety 5%, shooter 20%, follow
  0.4%. On camera: crash 96%, hold 95%, back 81%, safety 66% (the camera follows the ball).
- **Checks:** offensive rebounds on misses: crash 11.4%, follow 11%, shooter 3%, hold 1.5%, safety 0.4%, back 0.4%.
  Opponent transition after a defensive rebound, by attackers back: none 44%, one 41%, two 36%, three+ 27%. Crashes
  met by their man rebound 10.8% of misses vs 11.8% open: the box-out flag barely separates, as before.
- **Shown:** court tags (Rebounding Roles toggle), the shot card's role counts, the player card's Tracking view.

## 2026-11-08 — Rebounding roles revised: three-point crash rule, box-out on the defender (site)

- **Crash:** within 8 ft of the hoop when the flight ends, or gained 4+ ft and finished inside the three-point line
  (FIBA 6.75 m arc, 6.6 m in the corners) — was "within 15 ft". "Back" is shown as **Retreat** (data key unchanged).
- **Box-outs:** checked for crashers and for any attacker already within 8 ft of the hoop at release; the release
  matchup is tried first, then the nearest other defender between the attacker and the hoop (same 5 ft / 3 ft
  geometry). The defender is exported as `boxer` and tagged **Box Out** on the court; the attacker's "met" tag is gone.
- **Release ghosts** now go when play goes on (first event or touch after the release, not before the flight ends),
  fading over 8 frames; previously they stayed 150 frames after the flight. Closeout captions drop "then".
- **Ten games, re-run:** attacker-shots (non-shooters) 5,826: hold 43%, crash 36%, retreat 14%, safety 7%.
  Offensive rebounds on misses: crash 10.0% (129/1,293), hold 1.3% (18/1,414), retreat 0.4% (2/475), safety 0.4%
  (1/224). Crashes boxed out rebound 9.4% (67/715) vs 10.7% open (62/578): still barely separates. Opponent
  transition after a defensive rebound by attackers back: 0 44% (74/169), 1 40% (86/216), 2 39% (29/75), 3+ 29% (6/21).
- **Box-out timing (same day):** checking only the frame the ball reached the rim missed textbook cases (114243-2-71:
  Rousselle 5.2 ft from Ubal at the rim, 1.9 ft at the rebound). Now checked frame by frame from 12 frames before the
  ball reaches the rim until the rebound (at most 25 frames after), needing 3+ frames in the spot. Crashes boxed out
  rose from 55% to 76% (986/1,293); boxed crashes rebound 9.6% of misses vs 11.1% open. Court cut tags drop "Screen"
  ("Cut · in" / "Cut · out"); the timeline keeps "Screen Cut In/Out".
- **Box-out must hold (same day):** 114243-1-34 flagged #55 on #22 and #19 on #77, though both crashers got to the rim
  (#22 0.8 ft from the hoop with #55 5 ft out). A box-out now also needs the defender never beaten after he first gets
  in the spot: the attacker never more than 1 ft closer to the hoop than him for the rest of the window. 1-34 now
  shows neither; 2-71 keeps Rousselle on Ubal. Crashes boxed out fell from 76% to 68% (873/1,293); boxed crashes
  rebound 9.5% (83/873) vs 11.0% open (46/420).
- **Box-out start (same day, display only):** the tag showed from release. Which crashes are boxed out is unchanged
  (held 3+ frames, never beaten: 873/1,293, 9.5% vs 11.0% as above); only when the tag appears moved. It starts
  (`bf`) at the first frame the crasher stalled at the defender: in the spot within 3 ft of him, with his speed toward
  the hoop (±3 frames) under 3 ft/s or under 70% of his fastest so far in the window (else the first frame within
  3 ft, else the first frame in the spot), and runs to the end of the window (`b1`). 2-71: Speight on Steinbergs from
  6 frames after the ball reached the rim, Rousselle on Ubal from 11 (Ubal kept drifting in at ~3.5 ft/s against a
  5.8 ft/s peak, so an absolute 3 ft/s cut alone missed him). A first version wrongly also required the stall to
  count a box-out (dropping it to 619/1,293); reverted.
- **Box-out needs contact (same day, owner's call):** 465 of 1,497 tagged box-outs never showed the crasher stalling;
  414 of them never came within 3 ft (a defender standing 3-5 ft in front, e.g. 114243-1-36 Benitez on Rousselle,
  5 ft at closest). A box-out now also needs at least one frame in the spot within 3 ft. Crashes boxed out: 50%
  (646/1,293); boxed crashes rebound 10.2% (66/646) vs 9.7% open (63/647). The examples without contact (1-36,
  2-56, 4-133) no longer show; 2-71 keeps both. 114234-1-42 keeps Soriano on Aranitovic: contact comes 25 frames
  after the ball reaches the rim, past the end of that clip (end of quarter), so its tag never shows in the viewer.
- **Box-out check, conditioned on where the ball went (same day, owner's question):** the 10.2%% vs 9.7%% above counts
  whether that crasher got the offensive rebound wherever the ball went, so long caroms count against boxed and open
  crashers alike. glass.R now also exports rd (ft from the crasher's spot when the flight ended to the rebounder's
  tracked spot at the rebound frame; NA on team rebounds) and sample.json league.glass.boxedNear splits misses by it.
  Crasher got it, boxed vs open: within 4 ft 38%% (41/108) vs 51%% (36/70); 6 ft 30%% (52/175) vs 33%% (46/139); 8 ft
  21%% (54/253) vs 27%% (54/199). Boxed crashers get the ball less when it comes their way, as expected, but samples
  are small (about 1.8 binomial SE at 4 ft, less at 6-8 ft; shots not clustered by game), so this is a sanity check
  on the flag, not a finding. Caveat: the box-out window starts 12 frames before the rim, so rd is not fully before it.

## 2026-11-08 — Seven exploration tabs for choosing the competition topic (site)

- **Why (owner):** explore seven candidate topics before choosing one for the entry: paint touches, pre-shot action
  chains and spacing, closeouts, crash rate, driving lanes, advantage creation, off-ball gravity. Each has its own tab
  (`#/explore/<topic>`) of descriptive EDA; no model is fitted (see the 2026-11-06 entry).
- **Build:** `web/scripts/explore/build.R` → `web/public/data/explore_<topic>.json`, one script per topic; text and
  numbers are written together in R. `common.R` caches one bundle per game (`outputs/cache/explore/`) reusing the
  export's cuts, screens (y-sign fixed) and rebounding roles unchanged. Unit: the **chance** (an offensive rebound
  starts a new one). Outcomes per chance: points, xPts per FGA (SkillCorner shotQuality / 100 × value; a reference,
  not a validated probability), turnover, free-throw trip, offensive rebound on live misses (fouled misses are not
  live). Population: chances not ending the period or in a jump ball (2,035; 1,511 half court). Intervals: 90%
  Wilson or ±1.645 SE, treating chances (or frames) as independent, which flatters them; the tabs say so.
- **Definitions chosen here (not validated against video):** paint touch = touch with key/ra in regionsIn (holder
  tracked in the key on 98% of them); lane = straight line ball handler → hoop, a defender "in" it within 6 ft;
  advantage = creator > 1 ft nearer the hoop than his defender, or two defenders within 6 ft, each for ~0.3 s, or a
  switch, within 2 s of the action; spot-up gravity = mean room off the ball for the same zone and ball-distance
  band minus his room, on perimeter frames 15+ ft from the ball and not just after his own screen; help pulled =
  a defender other than his matchup within 8 ft at the end of a roll or cut.
- **Found while building:** (1) a rebound frame can fall in the next possession, whose bundle positions are stored
  attacking the other way; the crash tab mirrors those spots (without it the offense looked nearest to 75% of
  rebounds; after, 26%). (2) SkillCorner starts every closeout before the catch (median 0.4 s), so "start before the
  catch" replaces a reaction time. (3) data.table non-equi joins with `mult = "first"` failed inside a helper;
  `marker_of()` uses an update join instead. (4) The first advantage rule had its sign reversed (96% "beaten").
- **Headline descriptions (ten games, associations only):** paint touch 1.02 vs 0.65 pts/chance; threes after a
  paint touch had the closest defender 6.8 vs 6.2 ft away. Tight closeouts (≤ 4 ft) → shot 29%, drive 37%; loose
  (> 6 ft) → 66%, 7%. Offense kept 19% of live misses with no crasher, 31-35% with one or more; the opponent's next
  chance after a defensive rebound did not get worse with more crashers in this sample. Drives with the defender
  > 90° off the lane were blow-bys 81% of the time, < 30° 7%; on pick drives that angle rises from 19° to 37° in the
  2 s before. Half-court actions created an advantage 51% of the time (drives 74%, isolations 23%); the tracked rate
  barely correlates with the season blow-by rate (0.07). High-volume shooters were guarded 0.40 ft tighter than
  typical, others ~0.25 ft looser, but player-level gravity barely tracks season shooting (r −0.02 volume, 0.11 %).
- **Not done:** the interactive crash app (needs the archived rebound and court-control models); any adjustment for
  team, opponent or lineup; game-clustered intervals.

## 2026-11-09 — Pick-and-pops, four-situation gravity, room explorer, readability (site)

- **Pick-and-pops (`web/scripts/cuts.R`, kind `pop`):** the screener of a SkillCorner pick, followed for up to 2.5 s
  (or until he gets the ball), set 12+ ft from the hoop, who never rolls (never within 10 ft of the hoop, never 6 ft
  closer) and ends 16+ ft out, having moved 3+ ft further away or finished beyond the arc after a 4+ ft run. 320 in
  the ten games (about 16% of picks). Shown in the play viewer like cuts (route, "Pop" tag, "Pick and Pop" on the
  timeline and in the Action filter, `cut_pop`), on the Pre-shot actions tab ("Pick → Pop") and the Gravity tab.
  Export and parity reference rerun; a test checks that every pop is a pick's screener ending away from the rim.
- **Gravity, four situations (NBA-style):** on or off the ball × perimeter (more than 20 ft from the hoop, the NBA's
  split) or interior. Gravity = expected minus actual distance to the nearest defender, expected = mean over all
  attackers in the same role, hoop-distance band and (off the ball) ball-distance band. Minutes = sampled half-court
  frames × 0.2 s. Only 195 such minutes exist across the ten games (all ten players must be on camera), so the table
  keeps players with 3+ minutes and blanks cells under half a minute. The NBA uses a defensive-pressure model; this
  uses distance, which is said on the tab.
- **Room explorer (`GravityRoom.svelte`, `explore_gravity_room.json`):** pick an off-ball spot, a ball spot and how
  often that kind of player shoots from his zone (thirds of season attempts per 100 possessions in that zone); the
  court shows the kernel-weighted mean room (bandwidths 2.5 ft on the player, 5 ft on the ball, every 3rd off-ball
  frame, mirrored left-right). Descriptive, not a model.
- **Readability:** prose on the exploration tabs is bullets (`BUL`, multi-item `TAKE`/`CAVEAT`); every table header
  has a one-line description (`web/scripts/explore/columns.R`); larger text and spacing on the non-viewer tabs;
  Archetypes split "what sets it apart" into above- and below-average columns (green/red), also in the Shiny app.

## 2026-11-09 (later) — Shot and possession cards, player card, wide tables (site)

- **Shot card** grouped under subheaders (Shot Quality, Location, Defense, Creation, Result and Season, Rebounding
  Roles). New: **Shooter Speed** at release (the shooter's smoothed tracked speed at shots.startFrame, as motion.ts
  computes speed; over 80% of shots have one). Pass now names the passer (SkillCorner passerId) or "None", and
  **Potential Assist** is its own Yes/No line (assisted, or SkillCorner's assistOpp). Rebounding roles are one line
  each with the number of attackers.
- **Possession card:** Dribbles and Ball now describe only the current ball handler (the latest touch to start: his
  dribbles on this touch and his time on the ball), instead of every touch so far.
- **Player card:** each rebounding role shows its own shot count, plus an "All Roles" row with the total; more space
  between sections and a thin rule under each header. Labels "True Shooting" and "Effective FG" are now TS% and eFG%.
- **Tables on the reading tabs** (`web/src/lib/fitwide.ts`): names never wrap; a table wider than the text column
  grows into the page margins instead of scrolling; numeric headers may take two lines; grids holding a table stack.
  At a 1500 px window no table scrolls.
- **Court cards no longer resize the court:** the shot card sits in the top corner on the backcourt side and the
  possession/tracking cards in the bottom corner. When they would overlap, the bottom stack slides toward center court
  beside the shot card; a shot card taller than the court scrolls inside it. The court window no longer grows
  (live.annNeed stays 0), so the trace panel keeps its room.
- **Fix (same day):** three outcome tables showed placeholder zeros for eFG%, OREB% and live misses (Advantage's
  action table and its outcome charts, Closeouts' table by the ball handler's action, eFG% in Crashing's next-chance
  table): their action tables did not carry those chance columns. They now carry the chance's real outcomes; the
  Closeouts table also uses the chance's xPts instead of the shot after the closeout, so every column is per chance.
  A scan finds no other all-zero or empty column on the seven tabs.

## 2026-11-09 (later) — Kickout transformer (learning exercise, not the entry)

- New `src/kickout_transformer/` (R torch): predicts shot / drive / pass / other for the receiver of a perimeter
  pass from a 10-player freeze frame, with and without the last second of movement. 1,738 catches (115 strict
  kickouts), leave-one-game-out. Write-up and how to run: `src/kickout_transformer/EXPLAINER.md`.
- Result: the freeze-frame transformer ties a 10-feature multinomial logistic (log loss 0.985 vs 0.980, paired
  difference +0.005, game-bootstrap 95% interval −0.006 to +0.015); movement history makes it worse (+0.019). Both beat
  league / archetype / player tendencies (~1.10), which do not differ from each other. Owner choices: train on all
  perimeter catches and report the kickout subset; four classes including "other"; build freeze then history.

## 2026-11-09 (later) — Kickout transformer, three-class variant

Re-ran the kickout learning exercise without the "other" class (`--drop-other`; outputs in `outputs/kickout_transformer_3class/`). 1,662 catches, 106 strict kickouts. Held-out log loss on all catches: league 0.961, logistic 0.833, freeze transformer 0.838, history transformer 0.861. Conclusions unchanged: the transformer ties the logistic model, movement history hurts, player/archetype tendencies add nothing. Fixed a training bug exposed by the smaller sample (a one-catch final batch lost a tensor dimension); the four-class run never hit it.

## 2026-11-09 (later) — Pick coverage EDA tab (groundwork for a coverage transformer; no model)

- New exploration tab **Pick coverage** after Gravity (`#/explore/coverage`, `web/scripts/explore/coverage.R`,
  built by `build.R coverage` in about 3 s from the cached bundles). Descriptive only; the owner asked for EDA before
  any transformer.
- **Label:** bhrDefType and scrDefType are one call. Switch, ice and blitz are always called for both defenders;
  over/under always pair with soft/show (6 picks with screener 'none'). Seven joint calls over 1,520 picks:
  over · show 502, over · soft 496, under · soft 167, under · show 113, switch 218, ice 14, blitz 4. Season direct
  picks have a similar mix (over 66%, under 15%, switch 18%).
- **Timing:** picks.frame is the screen (handler closest to screener a median 0.2 s later). Single-measure AUC:
  under/over 0.59 at −1 s, 0.97 at +0.4 s; show/soft 0.67 at −0.4 s, 0.84 at 0; switch 0.64 at 0, 0.91 at +2 s.
  A model that sees past the screen is mostly recognising the label; "before the screen" is the real forecast.
- **Context:** switches rise as the shot clock falls (7% with 18+ s, 25% with 6 s or less); under is more common
  when the handler starts 13+ ft above the screen (32%) and, season-wide, against handlers with little off-dribble
  three volume (r = −0.27); soft is less common against popping screeners (r = −0.53). Defenses differ in their mix,
  but within a game calls are not streaky (31% repeat vs 30% by chance).
- **Baselines (frequency look-ups, leave one game out):** league shares log loss 1.52; no honest look-up improves it
  by more than 0.02; a defense's whole-game mix (uses the answers) gives 1.42. The matchups table confirms 71% of
  switches hand the handler to the screener's defender.

## 2026-11-09 (later) — Kickout transformer, film study of confident misses

Added `06_film_study.R` and a shared play-card drawing (`R/draw_play.R`, also used by step 5 now). Of 1,662 catches, 117 were confident (≥60%) misses by both models of the form "expected pass, was drive" and 75 "expected pass, was shot"; only 18 were transformer-only and 14 logistic-only, so the two models fail on the same plays. Found while reviewing: neither model sees the game clock (with under 24 s left in a period, receivers shoot 52% vs 24%), step 1 fills a missing shot clock with 24 s (20 catches), and two catches have broken positions (receiver drawn > 40 ft from the hoop). Not acted on yet.

## 2026-11-09 (later) — Kickout transformer: time to act replaces the filled-in shot clock

`time_to_act` = min(shot clock, game clock, 24 s) is now the clock input for both models (logistic feature; transformer context vector, joined after attention). It replaced `shot_clock` rather than sitting beside it because the two are identical on all but 5 of 1,662 catches. Before/after on the same catches (`07_compare_runs.R`): the 5 changed catches improve sharply for all models (logistic 3.13 → 2.03 log loss), overall log loss is unchanged within noise (logistic 0.833 → 0.829, freeze transformer 0.838 → 0.840). Old three-class outputs kept in `outputs/kickout_transformer_3class_before_time_to_act/`. The four-class outputs were not re-run and still use the shot clock.

## 2026-11-09 (later) — Kickout exercise: timing audit, horizon target, cue comparison; screen-coverage lead-time baseline

- **Timing audit** (`src/kickout_transformer/08_timing_audit.R`, `outputs/kickout_timing/`): the same-touch label often describes a later action. Median time from catch to the labelled action is 0.88 s for shots, 0.80 s for drives and 1.60 s for passes; 32%, 37% and 58% happen after 1.25 s, and 18% of labelled actions follow a ball screen on the same touch. The audit reproduces the event times quoted for the eight film cards and the Marcos play (screen +2.40 s, drive +3.68 s, kickout +5.32 s).
- **Horizon target:** the state at 1.25 s after the catch (shot 16%, drive 10%, pass 23%, other 1%, still holding 49%) is defined for all 1,738 catches. Kept as a second target alongside the same-touch label; neither replaces the other yet.
- **Cues** (`09_cue_features.R`): directional space, pass context and screen setup, from frames up to the catch only. Fixed during the build: data.table substitutes the join column in a non-equi update join, which made every earlier A→B pass look like an immediate return. The rewritten cue flags 9% of catches.
- **Logistic comparison** (`10_cue_comparison.R`): each group added separately, same held-out games. All changes are ≤ 0.007 in log loss; only screen setup on the 1.25 s target excludes zero (−0.0065, −0.011 to −0.001). Confident calls are close to calibrated either way. Not added to the transformer.
- **Screen coverage, first model** (`src/screen_coverage/01_lead_time_baseline.R`, `outputs/screen_coverage/`): five joint calls (ice, blitz and over + none dropped, 24 picks), 1,491 picks with all four players tracked. Leave-one-game-out log loss: league 1.46, defense's earlier calls in the game 1.45, four-player geometry at −0.8 s 1.34, at −0.4 s 1.20, at the tag 0.90, at +0.4 s 0.69. Single-measure AUC for over vs under is 0.57 at −0.8 s and 0.88 at the tag, so most of the signal is recognition. Fall–Marcos (under + soft): 7% at −0.8 s, 6% at −0.4 s (Jefferson is still above the screen), 42% at the tag, 76% at +0.4 s. A film checklist of 12 confident −0.4 s forecasts (6 right, 6 wrong) is in `film_check.csv` for the owner to watch.

## 2026-11-10 — Screen coverage: the other six players added, and they hurt

- At the owner's request, `src/screen_coverage/01_lead_time_baseline.R` now also gives the logistic model the other six players' x, y, vx and vy (three attackers and three defenders, each ordered by distance to the screener; plays mirrored so the screener is at y ≥ 0): 24 more inputs. The ball handler's hoop distance was not added because it is exactly `h_lvl + s_hoop`. All ten players are tracked at every cutoff on the same 1,491 picks, so the scored set did not change.
- Result: adding the six makes every cutoff worse by 0.03-0.04 log loss (−0.4 s, with "so far": 1.182 → 1.222, change +0.040, 95% interval 0.022 to 0.059; better in 1 of 10 held-out games). A stronger ridge penalty narrows the gap (decay 20: +0.010; decay 50: +0.003, interval spanning 0) but never reverses it, so in raw-coordinate form the six carry little that the four don't already have, and the model mostly fits noise. The full model's largest weights stay on the four-player levels (bd_lvl, bd_lvl_v, sd_lvl). Kept as a reported comparison; the four-player model remains the better baseline.
- Film checks: `film_check.csv` is now from the 10-player model; `film_check_4players.csv` reproduces the earlier list exactly.

## 2026-11-10 (later) — Screen coverage predicted at every frame; archetypes; hindsight test

- `src/screen_coverage/02_per_frame.R`: one four-player logistic model per frame from −2 s to +1 s around the screen tag (76 models), on the 1,464 screens with all four players tracked over the whole window. The shot clock is now read at each frame from the tracking (step 1 read it at the tag). Outputs in `outputs/screen_coverage/per_frame/`.
- **Curve:** log loss is flat around 1.37 from −2 s to −1 s (baselines 1.45-1.46), falls to 1.18 at −0.4 s and 0.89 at the tag, and levels off near 0.62-0.67 from +0.4 s. Most of the drop happens in the last 0.4 s before the tag.
- **Archetypes** (ball handler's and screener's offensive archetype; levels with < 40 screens in the role pooled as "other"): no help. +0.009 log loss before the tag (−0.011 to 0.031) and +0.008 after it (−0.005 to 0.023). Leakage review: the archetypes were clustered without the coverage-faced shares (built but never entered the clustering); the only overlap is that part of each player's style profile comes from the ten tracked games.
- **Hindsight test:** a single pooled model never told when the screen comes. It is +0.07 worse before the tag (+0.067 with "closeness" weights from the visible handler-screener distance), with the smallest gap (+0.02-0.03) from −1.0 to −0.6 s and the largest at −2 s, where it falls below the baselines. After the tag it is +0.21 to +0.33 worse. Reading: a forecast from about −1 s to −0.5 s needs little hindsight; at −2 s, and for recognising the call once the screen happens, knowing the moment of the screen does much of the work, so a live version would need to detect the screen moment itself. The pooled model is also less flexible, so these gaps are upper bounds on the hindsight effect.
- Probability strips for the 12 film-check screens plus Fall–Marcos (`figures/strips/`, data in `strips.csv`), each with the raw positions of both defenders underneath. Smoothing is a trailing 0.2 s average, so it never uses a later frame.

## 2026-11-10 (later) — Live coverage probabilities in the play viewer

- `src/screen_coverage/02_per_frame.R` now also writes `web/public/data/coverage_frames.json` (1,464 screens in 979 possessions, 1.6 MB): the held-out per-frame probabilities of the "4 players + so far" logistic models, whole percent, −2 s to +1 s around each screen tag.
- The viewer shows them as a **Coverage Read** card over the backcourt (Display → Annotations → Coverage Read, on by default; `web/src/lib/coverage.ts`, `Annotations.svelte`). It is visible only inside a screen's window, smooths over the last 0.2 s (never a later frame), and shows the tagged call only from the screen tag on, so film review is not spoiled. Like the other court cards, it needs a court at least 480 px wide.
- Checked in the preview on Fall–Marcos (possession-188630-1-16): −0.40 s over + show 34% / over + soft 32%; at the tag switch 32% / under + soft 30%; +0.40 s under + soft 72%. These match the strip figure. svelte-check is clean and all 103 vitest tests pass.
