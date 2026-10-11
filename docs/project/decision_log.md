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
