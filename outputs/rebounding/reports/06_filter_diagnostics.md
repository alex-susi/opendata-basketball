# Step 06: causal ball filter

Run 2026-10-31 by `src/rebounding/run_step06.R`; settings `config/experiment.yaml` (`step06`, config v3), fixed before any
run on real data; folds and uncertainty are Step 03's frozen harness.

**Filter.** State (x, y, z, vx, vy, vz) in the attack frame. Constant velocity with gravity on z, white-noise
acceleration q, observation noise r per axis. Only measured ball frames are observations (single filled frames are
treated as missing), each usable one frame after it, so a forecast at frame t uses frames up to t - 1. r and g come
from the training games' free-flight arcs; q from a grid by the training innovation likelihood.

## Learned parameters by fold

| outer_fold | test_game | r_x | r_y | r_z | g | q | n_segments | n_obs | n_g | n_train_episodes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  1 | 114243 | 0.073 | 0.066 | 0.140 | 28.138 | 3 | 445 | 6778 | 415 | 445 |
|  2 | 114234 | 0.077 | 0.067 | 0.142 | 28.180 | 3 | 451 | 6798 | 420 | 451 |
|  3 | 114169 | 0.078 | 0.068 | 0.142 | 28.188 | 3 | 441 | 6713 | 410 | 441 |
|  4 | 114099 | 0.078 | 0.065 | 0.139 | 28.300 | 3 | 432 | 6502 | 404 | 432 |
|  5 | 114086 | 0.073 | 0.063 | 0.137 | 28.253 | 3 | 457 | 6946 | 427 | 457 |
|  6 | 178442 | 0.073 | 0.065 | 0.141 | 28.283 | 3 | 450 | 6809 | 420 | 450 |
|  7 | 179612 | 0.078 | 0.066 | 0.139 | 28.359 | 3 | 448 | 6731 | 415 | 448 |
|  8 | 184439 | 0.078 | 0.066 | 0.140 | 28.157 | 3 | 457 | 6912 | 426 | 457 |
|  9 | 188630 | 0.078 | 0.067 | 0.141 | 28.224 | 3 | 453 | 6876 | 423 | 453 |
| 10 | 191313 | 0.077 | 0.066 | 0.139 | 28.298 | 3 | 457 | 6876 | 425 | 457 |

Free-flight segments: 645 of 703 (one-step arc residual never above 1.0 ft). Forecasts are scored only inside them,
from three observations on, at measured target frames before the contact proxy.

## Held-out forecast error (ft, 3D)

| horizon | model | forecasts | episodes | mean_err | median_err | p90_err | rmse_z |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  2 | gravity_only | 5553 | 499 | 0.199 | 0.162 | 0.371 | 0.181 |
|  2 | kalman | 5553 | 499 | 0.276 | 0.238 | 0.488 | 0.255 |
|  2 | constant_velocity | 5553 | 499 | 0.428 | 0.416 | 0.628 | 0.427 |
|  2 | persistence | 5553 | 499 | 2.409 | 2.360 | 3.181 | 0.934 |
|  5 | gravity_only | 4576 | 465 | 0.421 | 0.350 | 0.762 | 0.385 |
|  5 | kalman | 4576 | 465 | 0.540 | 0.465 | 0.950 | 0.490 |
|  5 | constant_velocity | 4576 | 465 | 1.319 | 1.262 | 1.863 | 1.341 |
|  5 | persistence | 4576 | 465 | 4.803 | 4.925 | 5.815 | 1.587 |
| 10 | gravity_only | 3209 | 424 | 0.872 | 0.746 | 1.554 | 0.791 |
| 10 | kalman | 3209 | 424 | 0.984 | 0.844 | 1.749 | 0.863 |
| 10 | constant_velocity | 3209 | 424 | 3.617 | 3.528 | 4.694 | 3.653 |
| 10 | persistence | 3209 | 424 | 8.384 | 8.538 | 9.688 | 2.125 |

## Filter against gravity-only (non-inferiority margin 0.05 ft): not met

| time_point | episodes | mean_diff | lo | hi | games_better | worst_game_diff | non_inferior |
| --- | --- | --- | --- | --- | --- | --- | --- |
| h2 | 499 | 0.0721 | 0.0550 | 0.0939 | 0 | 0.1081 | FALSE |
| h5 | 465 | 0.1214 | 0.1033 | 0.1436 | 0 | 0.1575 | FALSE |
| h10 | 424 | 0.1200 | 0.0955 | 0.1500 | 0 | 0.1789 | FALSE |

## Predictive coverage (tolerance 0.05): not met

| horizon | level | n | coverage | within_tol |
| --- | --- | --- | --- | --- |
| 2 | 0.500 |  5553 | 0.660 | FALSE |
| 5 | 0.500 |  4576 | 0.504 |  TRUE |
| 10 | 0.500 |  3209 | 0.462 |  TRUE |
| 2 | 0.900 |  5553 | 0.916 |  TRUE |
| 5 | 0.900 |  4576 | 0.837 | FALSE |
| 10 | 0.900 |  3209 | 0.801 | FALSE |
| all | 0.500 | 13338 | 0.558 | FALSE |
| all | 0.900 | 13338 | 0.862 |  TRUE |

## Innovations (normalised squared, 3 df: mean 3 if the noise is right)

| free | updates | mean_nis | share_above_chi2_95 |
| --- | --- | --- | --- |
|  TRUE | 5724 | 1.643 | 0.027 |
| FALSE |  885 | 31.318 | 0.435 |

## By stratum (filter)

| horizon | stratum | n | mean_err | cov50 | cov90 |
| --- | --- | --- | --- | --- | --- |
|  2 | high third | 1967 | 0.276 | 0.649 | 0.913 |
|  2 | measured share >= 0.5 | 5553 | 0.276 | 0.660 | 0.916 |
|  2 | middle third | 1920 | 0.280 | 0.646 | 0.895 |
|  2 | midrange (other 2s) | 1431 | 0.251 | 0.740 | 0.913 |
|  2 | predError low third | 1666 | 0.270 | 0.688 | 0.945 |
|  2 | rim (<5 ft) |   78 | 0.450 | 0.410 | 0.590 |
|  2 | three | 4044 | 0.281 | 0.636 | 0.924 |
|  5 | high third | 1539 | 0.532 | 0.490 | 0.828 |
|  5 | measured share >= 0.5 | 4576 | 0.540 | 0.504 | 0.837 |
|  5 | middle third | 1510 | 0.557 | 0.503 | 0.817 |
|  5 | midrange (other 2s) | 1077 | 0.503 | 0.594 | 0.876 |
|  5 | predError low third | 1527 | 0.532 | 0.518 | 0.866 |
|  5 | rim (<5 ft) |   39 | 1.106 | 0.179 | 0.333 |
|  5 | three | 3460 | 0.546 | 0.479 | 0.831 |
| 10 | high third |  938 | 0.978 | 0.455 | 0.779 |
| 10 | measured share >= 0.5 | 3209 | 0.984 | 0.462 | 0.801 |
| 10 | middle third | 1018 | 1.023 | 0.446 | 0.779 |
| 10 | midrange (other 2s) |  610 | 0.935 | 0.551 | 0.849 |
| 10 | predError low third | 1253 | 0.958 | 0.479 | 0.836 |
| 10 | rim (<5 ft) |   15 | 2.564 | 0.000 | 0.000 |
| 10 | three | 2584 | 0.987 | 0.443 | 0.795 |

## Forecasts that cross a contact (tagged, not in the gate)

| horizon | model | forecasts | mean_err | median_err |
| --- | --- | --- | --- | --- |
|  2 | gravity_only |  694 | 0.443 | 0.314 |
|  2 | constant_velocity |  694 | 0.520 | 0.461 |
|  2 | kalman |  694 | 0.591 | 0.356 |
|  2 | persistence |  694 | 2.071 | 2.149 |
|  5 | gravity_only | 1631 | 1.299 | 0.811 |
|  5 | kalman | 1631 | 1.490 | 0.938 |
|  5 | constant_velocity | 1631 | 1.528 | 1.339 |
|  5 | persistence | 1631 | 3.980 | 4.129 |
| 10 | gravity_only | 3049 | 3.645 | 2.785 |
| 10 | constant_velocity | 3049 | 3.769 | 3.352 |
| 10 | kalman | 3049 | 3.925 | 3.062 |
| 10 | persistence | 3049 | 6.094 | 6.107 |

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE | TRUE |
| every origin covariance finite, symmetric, smallest eigenvalue > -1e-9 (count) | 12134 | 12134 | TRUE |
| each fold's parameters use only its training games' free segments | 10 | 10 | TRUE |
| online state at t identical with later frames removed or corrupted (5 episodes per game) | TRUE | TRUE | TRUE |
| re-running fold 1 reproduces every forecast error | TRUE | TRUE | TRUE |
| forecast targets are measured frames only | TRUE | TRUE | TRUE |
| free-flight segments (step02 one-step rule) | 645 of 703 | reported | TRUE |

**Decision: filter BLOCKED.** Stability: met.

## Limits

- The vendor's ball track is already smoothed and partly filled; the filter's noise is the scatter around that track,
  not the distance to the true ball, which this data cannot measure.
- Free flight only. Rim, board and player contacts (Step 07) break the constant-velocity-with-gravity model.
