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
