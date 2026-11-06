# Step 03: evaluation design, reference baselines and scoring harness

Run 2026-10-30 by `src/rebounding/run_step03.R`; settings `config/experiment.yaml` (`step03`, config v3), frozen in
`outputs/rebounding/step03/design_freeze.json` before any baseline was scored. Step 02 is BLOCKED, so every model
is scored on the credited outcome only: the ten players tracked at release, or a team award to either side.

## Design

- **Population**: the 703 Step 01 eligible episodes; the 39 excluded episodes stay out of every model.
- **Folds**: leave one game out, fold k holds out the k-th game by date; inner folds leave one game out within the
  nine training games and are used only for tuning and for choosing the reference baseline.
- **Information time**: a forecast at frame t reads tracking frames up to t. Ball frames count once the next
  frame shows they are measured (not the vendor's midpoint fill), so the ball lags one frame. The hoop is the
  nominal one; the calibrated hoops come from the test game's own made shots and are not used.
- **Time points**: release (shots.startFrame), and a causal rim-arrival trigger (first measured ball frame at least
  6 frames after release, within 4.5 ft of the hoop horizontally, between 7 and 14 ft high, below an earlier high
  point) plus 0 to 1.4 s. Pre-contact is not used: its only definitions are after-the-fact proxies. A point exists
  only while the ball is loose (t before the credited rebound frame), the same rule for every model.
- **Baselines** (fitted on the nine training games per fold and time point): uniform over players; side prior
  (constant OREB rate split over the five of each side); role prior (side x hoop-distance rank within side);
  nearest to hoop (rank among all ten); inside rule (rank of the hoop-distance gap to the nearest opponent). All
  give the two team awards the training games' rates. Config v2 adds role prior and nearest to hoop fitted
  separately for each shot range (rim under 5 ft, other twos, threes), each with smoothed per-range team-award
  rates; they were added after the v1 scores were seen, as candidates only. The selected reference is the baseline with the lowest
  inner leave-one-game-out log loss on the training games. Binary OREB reference: the training OREB share.
- **Scores**: per episode, never per player row: 12-class log loss (primary), Brier, top-1/top-3 with ties
  counted against the model; binary OREB log loss and Brier; class-wise and team calibration.
- **Uncertainty and decisions** (for later steps): paired per-episode differences; game bootstrap and a t interval
  on per-game means, the wider one used; mean with each game dropped. Superiority needs the upper bound below 0
  and every drop-one mean below 0; non-inferiority needs the upper bound below 0.02 nats. Ten games are too
  few for precise inference.
- **Confirmatory comparisons** (later steps): C1 static conditional logit superior to every baseline and to the
  selected reference at release, each tested on its own (config v3); C2
  binary OREB model vs constant rate at release; C3a/C3b dynamic vs same-time static at release (non-inferiority)
  and at rim + 0.2 s (superiority). Everything else is exploratory.

## Prediction points

| time_point | defined | no_rim_arrival | resolved_before_t | too_few_players |
| --- | --- | --- | --- | --- |
| release | 703 |  0 |   0 | 0 |
| rim+0 | 678 | 24 |   1 | 0 |
| rim+0.2 | 650 | 24 |  29 | 0 |
| rim+0.4 | 592 | 24 |  87 | 0 |
| rim+0.6 | 536 | 24 | 143 | 0 |
| rim+0.8 | 438 | 24 | 241 | 0 |
| rim+1 | 317 | 24 | 362 | 0 |
| rim+1.4 | 164 | 24 | 515 | 0 |

The rim-arrival trigger fired in 679 of 703 episodes, a median 1.04 s after release; it is at or before the
Step 01 contact proxy in 73% of them (median -2 frames) and within 3 frames of it in 55%.
Of the 24 episodes it misses, 18 are blocked shots, 5 have no rim or board contact by the Step 01 proxy (airballs) and 1 other; their rim-anchored points are undefined for every model.

## Reference baselines at the confirmatory time points (held-out games)

| time_point | model | episodes | log_loss | brier | top1 | top3 | team_log_loss | ece |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| release | uniform | 703 | 2.472 | 0.915 | 0.000 | 0.000 | 0.694 | 0.003 |
| release | side_prior | 703 | 2.379 | 0.898 | 0.000 | 0.000 | 0.610 | 0.005 |
| release | role_prior | 703 | 2.274 | 0.884 | 0.127 | 0.482 | 0.610 | 0.009 |
| release | nearest_hoop | 703 | 2.263 | 0.882 | 0.182 | 0.457 | 0.620 | 0.004 |
| release | inside_rule | 703 | 2.385 | 0.901 | 0.092 | 0.363 | 0.625 | 0.006 |
| release | role_prior_by_range | 703 | 2.261 | 0.881 | 0.134 | 0.484 | 0.612 | 0.008 |
| release | nearest_hoop_by_range | 703 | 2.268 | 0.880 | 0.164 | 0.421 | 0.617 | 0.008 |
| release | selected_reference | 703 | 2.278 | 0.885 | 0.149 | 0.461 | 0.618 | 0.007 |
| rim+0.2 | uniform | 650 | 2.470 | 0.914 | 0.000 | 0.000 | 0.689 | 0.001 |
| rim+0.2 | side_prior | 650 | 2.376 | 0.898 | 0.000 | 0.000 | 0.605 | 0.005 |
| rim+0.2 | role_prior | 650 | 2.180 | 0.868 | 0.155 | 0.511 | 0.605 | 0.005 |
| rim+0.2 | nearest_hoop | 650 | 2.174 | 0.867 | 0.217 | 0.552 | 0.606 | 0.007 |
| rim+0.2 | inside_rule | 650 | 2.358 | 0.899 | 0.105 | 0.358 | 0.618 | 0.003 |
| rim+0.2 | role_prior_by_range | 650 | 2.183 | 0.868 | 0.165 | 0.537 | 0.605 | 0.007 |
| rim+0.2 | nearest_hoop_by_range | 650 | 2.186 | 0.868 | 0.186 | 0.534 | 0.608 | 0.008 |
| rim+0.2 | selected_reference | 650 | 2.174 | 0.867 | 0.217 | 0.552 | 0.606 | 0.007 |

Baseline chosen as the selected reference (folds):

| time_point | model | N |
| --- | --- | --- |
| release | nearest_hoop |  5 |
| release | role_prior_by_range |  4 |
| release | nearest_hoop_by_range |  1 |
| rim+0 | nearest_hoop | 10 |
| rim+0.2 | nearest_hoop | 10 |
| rim+0.4 | role_prior |  6 |
| rim+0.4 | nearest_hoop |  3 |
| rim+0.4 | role_prior_by_range |  1 |
| rim+0.6 | role_prior |  7 |
| rim+0.6 | role_prior_by_range |  3 |
| rim+0.8 | role_prior |  9 |
| rim+0.8 | role_prior_by_range |  1 |
| rim+1 | role_prior | 10 |
| rim+1.4 | nearest_hoop |  7 |
| rim+1.4 | role_prior |  2 |
| rim+1.4 | role_prior_by_range |  1 |

Paired log-loss differences against uniform (negative is better; interval is the conservative one):

| time_point | candidate | mean_diff | lo | hi | games_better | worst_game |
| --- | --- | --- | --- | --- | --- | --- |
| release | side_prior | -0.094 | -0.117 | -0.069 | 10 | 191313 |
| release | role_prior | -0.199 | -0.257 | -0.147 | 10 | 114234 |
| release | nearest_hoop | -0.210 | -0.283 | -0.146 | 10 | 114234 |
| release | inside_rule | -0.087 | -0.151 | -0.030 |  8 | 191313 |
| release | role_prior_by_range | -0.211 | -0.283 | -0.145 | 10 | 114234 |
| release | nearest_hoop_by_range | -0.205 | -0.293 | -0.127 | 10 | 114243 |
| release | selected_reference | -0.194 | -0.269 | -0.129 | 10 | 114243 |
| rim+0.2 | side_prior | -0.094 | -0.122 | -0.065 | 10 | 114086 |
| rim+0.2 | role_prior | -0.289 | -0.378 | -0.220 | 10 | 114243 |
| rim+0.2 | nearest_hoop | -0.296 | -0.401 | -0.212 | 10 | 114243 |
| rim+0.2 | inside_rule | -0.112 | -0.153 | -0.071 |  9 | 191313 |
| rim+0.2 | role_prior_by_range | -0.287 | -0.379 | -0.213 | 10 | 114243 |
| rim+0.2 | nearest_hoop_by_range | -0.284 | -0.403 | -0.182 | 10 | 114234 |
| rim+0.2 | selected_reference | -0.296 | -0.401 | -0.212 | 10 | 114243 |

The rank-only baselines (nearest to hoop, inside rule) ignore side, so their P(OREB) at release averages 0.377 and 0.392 against an OREB rate of 0.299; side and role priors are calibrated for it (0.299, 0.300).
Top-1 counts ties against the model, so baselines that tie whole sides (uniform, side prior) score 0 unless a team
award is the single most likely outcome.

All time points, by-game scores, calibration and every comparison are in `outputs/rebounding/step03/`.

## Leakage, invariance and reproducibility checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| episodes in exactly one outer test fold | 703 | 703 | TRUE |
| folds whose test game reaches training or an inner fold | 0 | 0 | TRUE |
| one game per outer fold | 10 | 10 | TRUE |
| episode ids unique | 0 | 0 | TRUE |
| baseline fits use exactly the training games' episodes at their time point | TRUE | TRUE | TRUE |
| baseline predictions unchanged when the test game's labels are altered (release, every fold) | 10 | 10 | TRUE |
| planted test-label leak is detected by the label-invariance check | TRUE | TRUE | TRUE |
| planted future-only feature is rejected by the information-time check | TRUE | TRUE | TRUE |
| features never read a frame after their information time | 0 | 0 | TRUE |
| future-frame poisoning leaves triggers and features unchanged (5 episodes per game, every defined point) | 50 | 50 | TRUE |
| re-running the baselines reproduces every prediction exactly | TRUE | TRUE | TRUE |
| re-running a comparison with the same seed reproduces its interval | TRUE | TRUE | TRUE |
| every prediction table is valid (choice set, finite, non-negative, sums to 1) | 64 | 64 | TRUE |
| every model is scored on the same episodes at each time point | 8 | 8 | TRUE |
| one label definition for every model (episode_labels), team awards kept as team outcomes | 630 player / 73 team | both > 0 | TRUE |
| episodes outside the Step 01 population are in no prediction | 0 | 0 | TRUE |
| no probability floored before the log | 0 | 0 | TRUE |
| predictions equal those of the frozen design | TRUE | TRUE | TRUE |

## Limits

- Leave one game out trains on games played after the test game (October to May); season drift is not tested.
- Teams recur across games (Gran Canaria, Breogan and Zaragoza twice), so folds share players.
- Delivered player positions may already be smoothed or extrapolated by the vendor using later frames; the
  information rule is causal with respect to the delivered frames only.
- The loose-ball rule uses the credited rebound frame to decide whether a point exists. Every model shares it, but
  scores at late points are conditional on the ball still being loose.
- 33 of 630 credited player rebounds are `identity_suspect`; scores without them are in
  `scores_without_identity_suspect.csv`.
