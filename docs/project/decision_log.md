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
