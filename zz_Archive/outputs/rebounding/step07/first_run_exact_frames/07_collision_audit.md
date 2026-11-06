# Step 07: forecasts after the ball reaches the rim

Run 2026-10-31 by `src/rebounding/run_step07.R`; settings `config/experiment.yaml` (`step07`, config v3), fixed before any
real-data run; folds and rules are Step 03's, free-flight noise and g are Step 06's per fold.

**Gate rule.** The manual passes a collision model only for contact states with reliable labels. Step 02 is BLOCKED, so
the physics model is BLOCKED whatever it scores; the empirical transition model is the candidate for PASS_BASELINE.

Origins: 0, 5, 10, 15 frames after the causal rim-arrival trigger; horizons 5, 10, 15 frames; targets are measured ball frames
before the credited rebound (268 episodes, 2222 targets per model). Hoops: per camera end from the training games' made shots.

## Held-out scores (negative log density per cubic foot, energy score and mean error in ft; coverage of 50 / 90% regions)

| horizon | model | targets | episodes | nll | energy | err | cov50 | cov90 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  5 | empirical | 878 | 268 | 3.602 | 0.862 | 1.185 | 0.580 | 0.869 |
|  5 | gravity_gauss | 878 | 268 | 4.896 | 1.401 | 1.747 | 0.692 | 0.845 |
|  5 | physics | 878 | 268 | 37.918 | 1.677 | 2.055 | 0.206 | 0.425 |
| 10 | empirical | 739 | 232 | 5.755 | 1.737 | 2.401 | 0.548 | 0.839 |
| 10 | gravity_gauss | 739 | 232 | 7.855 | 3.898 | 5.120 | 0.608 | 0.840 |
| 10 | physics | 739 | 232 | 68.067 | 3.039 | 3.801 | 0.122 | 0.300 |
| 15 | empirical | 605 | 208 | 7.072 | 2.656 | 3.674 | 0.516 | 0.813 |
| 15 | gravity_gauss | 605 | 208 | 9.556 | 7.108 | 9.634 | 0.579 | 0.850 |
| 15 | physics | 605 | 208 | 108.955 | 4.477 | 5.639 | 0.088 | 0.215 |

## Decisions

| candidate | reference | time_point | mean_diff | lo | hi | games_better | drop_one_max | superior |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| empirical | gravity_gauss | h5 | -1.199 | -1.496 | -0.908 | 10 | -1.104 |  TRUE |
| empirical | gravity_gauss | h10 | -2.208 | -2.817 | -1.430 |  9 | -2.060 |  TRUE |
| empirical | gravity_gauss | h15 | -2.854 | -3.314 | -2.511 | 10 | -2.730 |  TRUE |
| physics | empirical | h5 | 29.177 | 13.006 | 53.575 |  0 | 32.560 | FALSE |
| physics | empirical | h10 | 54.320 | 26.978 | 95.545 |  0 | 59.717 | FALSE |
| physics | empirical | h15 | 83.698 | 50.800 | 135.786 |  0 | 91.902 | FALSE |
| physics | gravity_gauss | h5 | 27.978 | 11.711 | 52.466 |  0 | 31.382 | FALSE |
| physics | gravity_gauss | h10 | 52.112 | 24.348 | 93.928 |  0 | 57.505 | FALSE |
| physics | gravity_gauss | h15 | 80.844 | 47.741 | 133.020 |  0 | 88.933 | FALSE |

| model | level | n | coverage | within_tol |
| --- | --- | --- | --- | --- |
| gravity_gauss | 0.500 | 2222 | 0.633 | FALSE |
| empirical | 0.500 | 2222 | 0.552 | FALSE |
| physics | 0.500 | 2222 | 0.146 | FALSE |
| gravity_gauss | 0.900 | 2222 | 0.845 | FALSE |
| empirical | 0.900 | 2222 | 0.844 | FALSE |
| physics | 0.900 | 2222 | 0.326 | FALSE |

- Empirical transitions (coverage within 0.05 at both levels, superior to the gravity-only Gaussian at every horizon): **BLOCKED**.
- Physics particle filter: **BLOCKED** by the gate rule (no validated contact labels); the comparison above is exploratory.

## Particle filter diagnostics

| updates | mean_ess_share | resampled_share | degenerate_share | max_weight_sum_error |
| --- | --- | --- | --- | --- |
| 2124 | 0.427 | 0.633 | 0.153 | 0.000 |

| run | targets | mean_abs_diff | mean_diff | stable |
| --- | --- | --- | --- | --- |
| second seed | 2222 | 24.794 | 4.656 | FALSE |
| twice the particles | 2222 | 21.692 | -2.784 | FALSE |

Share of physics particles that touched each surface by the forecast time (weighted):

| horizon | rim | board | floor | none |
| --- | --- | --- | --- | --- |
|  5 | 0.709 | 0.490 | 0.035 | 0.179 |
| 10 | 0.766 | 0.558 | 0.089 | 0.096 |
| 15 | 0.761 | 0.560 | 0.226 | 0.042 |

## By stratum

| model | stratum | n | nll | cov90 |
| --- | --- | --- | --- | --- |
| gravity_gauss | Step 02 auto kind: UNKNOWN |  101 | 7.610 | 0.772 |
| empirical | Step 02 auto kind: UNKNOWN |  101 | 8.986 | 0.594 |
| physics | Step 02 auto kind: UNKNOWN |  101 | 193.722 | 0.287 |
| gravity_gauss | Step 02 auto kind: board |   13 | 6.684 | 1.000 |
| empirical | Step 02 auto kind: board |   13 | 9.167 | 0.231 |
| physics | Step 02 auto kind: board |   13 | 355.983 | 0.231 |
| gravity_gauss | Step 02 auto kind: none |   44 | 5.811 | 0.909 |
| empirical | Step 02 auto kind: none |   44 | 7.438 | 0.568 |
| physics | Step 02 auto kind: none |   44 | 70.372 | 0.295 |
| empirical | Step 02 auto kind: rim | 1178 | 5.214 | 0.846 |
| gravity_gauss | Step 02 auto kind: rim | 1178 | 7.209 | 0.829 |
| physics | Step 02 auto kind: rim | 1178 | 64.272 | 0.265 |
| empirical | Step 02 auto kind: rim_or_board |  886 | 4.738 | 0.893 |
| gravity_gauss | Step 02 auto kind: rim_or_board |  886 | 7.089 | 0.868 |
| physics | Step 02 auto kind: rim_or_board |  886 | 52.493 | 0.415 |
| empirical | no player within reach |  838 | 5.676 | 0.820 |
| gravity_gauss | no player within reach |  838 | 7.134 | 0.786 |
| physics | no player within reach |  838 | 67.271 | 0.264 |
| empirical | offset 0 |  708 | 5.213 | 0.867 |
| gravity_gauss | offset 0 |  708 | 7.604 | 0.792 |
| physics | offset 0 |  708 | 18.051 | 0.518 |
| empirical | offset 10 |  507 | 4.762 | 0.856 |
| gravity_gauss | offset 10 |  507 | 6.075 | 0.968 |
| physics | offset 10 |  507 | 99.602 | 0.174 |
| empirical | offset 15 |  397 | 5.097 | 0.834 |
| gravity_gauss | offset 15 |  397 | 6.012 | 0.950 |
| physics | offset 15 |  397 | 145.611 | 0.179 |
| empirical | offset 5 |  610 | 5.845 | 0.813 |
| gravity_gauss | offset 5 |  610 | 8.253 | 0.734 |
| physics | offset 5 |  610 | 46.599 | 0.326 |
| empirical | player within reach | 1384 | 5.013 | 0.858 |
| gravity_gauss | player within reach | 1384 | 7.158 | 0.880 |
| physics | player within reach | 1384 | 67.296 | 0.364 |
| empirical | shot range: midrange (other 2s) |  690 | 4.655 | 0.864 |
| gravity_gauss | shot range: midrange (other 2s) |  690 | 6.704 | 0.923 |
| physics | shot range: midrange (other 2s) |  690 | 34.943 | 0.461 |
| empirical | shot range: rim (<5 ft) |  323 | 4.917 | 0.836 |
| gravity_gauss | shot range: rim (<5 ft) |  323 | 6.011 | 0.957 |
| physics | shot range: rim (<5 ft) |  323 | 65.619 | 0.446 |
| empirical | shot range: three | 1209 | 5.702 | 0.835 |
| gravity_gauss | shot range: three | 1209 | 7.707 | 0.770 |
| physics | shot range: three | 1209 | 86.192 | 0.218 |

## Examples (`step07/figures/07_examples.png`)

Side view from the trigger: measured ball (grey), physics particles 10 frames ahead (blue), state at the trigger
(triangle), measured ball 10 frames ahead (cross), ring (orange), board (black). Kinds are Step 02's automated labels,
which failed their reliability check:

| episode_id | step02_auto_kind | label_status | physics_rim | physics_board | physics_none | auto_first_player_contact_frame | trigger_frame |
| --- | --- | --- | --- | --- | --- | --- | --- |
| shot-178442-2-49 | rim | unvalidated (Step 02 BLOCKED) | 0.740 | 0.210 | 0.220 |  44203 |  44163 |
| shot-179612-1-34 | rim | unvalidated (Step 02 BLOCKED) | 0.390 | 0.000 | 0.610 |  21704 |  21688 |
| shot-188630-2-59 | board | unvalidated (Step 02 BLOCKED) | 0.560 | 0.500 | 0.300 |  53675 |  53658 |
| shot-188630-4-130 | board | unvalidated (Step 02 BLOCKED) | 0.000 | 0.020 | 0.980 | 118418 | 118403 |
| shot-114243-1-12 | rim_or_board | unvalidated (Step 02 BLOCKED) | 0.900 | 0.060 | 0.100 |  11318 |  11293 |
| shot-178442-5-148 | rim_or_board | unvalidated (Step 02 BLOCKED) | 0.000 | 1.000 | 0.000 | 152553 | 152538 |
| shot-114099-1-36 | none | unvalidated (Step 02 BLOCKED) | 0.740 | 0.010 | 0.260 |  31258 |  31248 |
| shot-184439-3-80 | none | unvalidated (Step 02 BLOCKED) | 0.270 | 0.180 | 0.640 |  69588 |  69578 |

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE | TRUE |
| particle weights sum to 1 after every update (largest error) | 2.22e-16 | < 1e-9 | TRUE |
| effective sample size monitored (updates logged) | 2124 | > 0 | TRUE |
| hoops come from training games' made shots only | TRUE | TRUE | TRUE |
| every model scored on the same targets (targets with all three forecasts / all targets) | 2222 / 2222 | all models equal | TRUE |
| forecasts at an origin do not change when later frames are corrupted (3 episodes per game) | TRUE | TRUE | TRUE |

## Limits

- No validated contact labels: a course change may be the rim, the board, a hand or the tracking.
- Targets after a player reaches the ball are not ball physics; they are tagged (`player within reach`), not removed.
- The ring and board positions come from made shots and FIBA geometry; spin and restitution are drawn from broad priors.
