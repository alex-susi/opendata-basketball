# Step 07: forecasts after the ball reaches the rim

Run 2026-10-31 by `src/rebounding/run_step07.R`; settings `config/experiment.yaml` (`step07`, config v3), fixed before any
real-data run; folds and rules are Step 03's, free-flight noise and g are Step 06's per fold.

**Gate rule.** The manual passes a collision model only for contact states with reliable labels. Step 02 is BLOCKED, so
the physics model is BLOCKED whatever it scores; the empirical transition model is the candidate for PASS_BASELINE.

Origins: 0, 5, 10, 15 frames after the causal rim-arrival trigger; horizons 5, 10, 15 frames; targets are measured ball frames
before the credited rebound (639 episodes, 5268 targets per model). Hoops: per camera end from the training games' made shots.

**Deviation.** Targets are the first measured frame 0 to 2 frames after origin + horizon (exact lead used by every model). The prespecified exact-frame rule scored only 268 of 679 episodes because of the vendor's 5-frame measuring cadence; that first run is kept in `step07/first_run_exact_frames/`.

## Held-out scores (negative log density per cubic foot, energy score and mean error in ft; coverage of 50 / 90% regions)

| horizon | model | targets | episodes | nll | energy | err | cov50 | cov90 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  5 | empirical | 2118 | 639 | 3.842 | 0.936 | 1.285 | 0.587 | 0.869 |
|  5 | gravity_gauss | 2118 | 639 | 5.408 | 1.679 | 2.115 | 0.676 | 0.846 |
|  5 | physics | 2118 | 639 | 43.222 | 1.893 | 2.311 | 0.173 | 0.402 |
| 10 | empirical | 1761 | 577 | 5.827 | 1.778 | 2.456 | 0.549 | 0.839 |
| 10 | gravity_gauss | 1761 | 577 | 8.100 | 4.258 | 5.652 | 0.592 | 0.851 |
| 10 | physics | 1761 | 577 | 72.760 | 3.232 | 4.047 | 0.112 | 0.284 |
| 15 | empirical | 1389 | 507 | 7.085 | 2.668 | 3.677 | 0.531 | 0.822 |
| 15 | gravity_gauss | 1389 | 507 | 9.702 | 7.472 | 10.264 | 0.553 | 0.865 |
| 15 | physics | 1389 | 507 | 109.640 | 4.592 | 5.789 | 0.081 | 0.192 |

## Decisions

| candidate | reference | time_point | mean_diff | lo | hi | games_better | drop_one_max | superior |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| empirical | gravity_gauss | h5 | -1.489 | -1.732 | -1.265 | 10 | -1.448 |  TRUE |
| empirical | gravity_gauss | h10 | -2.365 | -2.747 | -2.028 | 10 | -2.285 |  TRUE |
| empirical | gravity_gauss | h15 | -2.986 | -3.239 | -2.804 | 10 | -2.947 |  TRUE |
| physics | empirical | h5 | 35.088 | 23.275 | 46.576 |  0 | 37.498 | FALSE |
| physics | empirical | h10 | 61.432 | 40.643 | 81.005 |  0 | 65.285 | FALSE |
| physics | empirical | h15 | 86.888 | 55.117 | 117.830 |  0 | 93.124 | FALSE |
| physics | gravity_gauss | h5 | 33.599 | 21.691 | 45.163 |  0 | 36.040 | FALSE |
| physics | gravity_gauss | h10 | 59.068 | 38.074 | 78.800 |  0 | 62.919 | FALSE |
| physics | gravity_gauss | h15 | 83.902 | 52.058 | 114.847 |  0 | 90.078 | FALSE |

| model | level | n | coverage | within_tol |
| --- | --- | --- | --- | --- |
| gravity_gauss | 0.500 | 5268 | 0.616 | FALSE |
| empirical | 0.500 | 5268 | 0.560 | FALSE |
| physics | 0.500 | 5268 | 0.129 | FALSE |
| gravity_gauss | 0.900 | 5268 | 0.853 |  TRUE |
| empirical | 0.900 | 5268 | 0.847 | FALSE |
| physics | 0.900 | 5268 | 0.307 | FALSE |

- Empirical transitions (coverage within 0.05 at both levels, superior to the gravity-only Gaussian at every horizon): **BLOCKED**.
- Physics particle filter: **BLOCKED** by the gate rule (no validated contact labels); the comparison above is exploratory.

## Particle filter diagnostics

| updates | mean_ess_share | resampled_share | degenerate_share | max_weight_sum_error |
| --- | --- | --- | --- | --- |
| 5297 | 0.407 | 0.658 | 0.151 | 0.000 |

| run | targets | mean_abs_diff | mean_diff | stable |
| --- | --- | --- | --- | --- |
| second seed | 5268 | 26.093 | 0.943 | FALSE |
| twice the particles | 5268 | 23.358 | -6.664 | FALSE |

Share of physics particles that touched each surface by the forecast time (weighted):

| horizon | rim | board | floor | none |
| --- | --- | --- | --- | --- |
|  5 | 0.724 | 0.511 | 0.033 | 0.159 |
| 10 | 0.767 | 0.568 | 0.088 | 0.091 |
| 15 | 0.763 | 0.573 | 0.241 | 0.035 |

## By stratum

| model | stratum | n | nll | cov90 |
| --- | --- | --- | --- | --- |
| gravity_gauss | Step 02 auto kind: UNKNOWN |  178 | 7.845 | 0.764 |
| empirical | Step 02 auto kind: UNKNOWN |  178 | 8.189 | 0.685 |
| physics | Step 02 auto kind: UNKNOWN |  178 | 160.437 | 0.225 |
| gravity_gauss | Step 02 auto kind: board |   25 | 7.401 | 0.880 |
| empirical | Step 02 auto kind: board |   25 | 7.589 | 0.480 |
| physics | Step 02 auto kind: board |   25 | 268.689 | 0.160 |
| gravity_gauss | Step 02 auto kind: none |  143 | 7.096 | 0.881 |
| empirical | Step 02 auto kind: none |  143 | 8.611 | 0.566 |
| physics | Step 02 auto kind: none |  143 | 154.882 | 0.231 |
| empirical | Step 02 auto kind: rim | 3090 | 5.340 | 0.851 |
| gravity_gauss | Step 02 auto kind: rim | 3090 | 7.510 | 0.844 |
| physics | Step 02 auto kind: rim | 3090 | 68.228 | 0.271 |
| empirical | Step 02 auto kind: rim_or_board | 1832 | 4.837 | 0.882 |
| gravity_gauss | Step 02 auto kind: rim_or_board | 1832 | 7.310 | 0.873 |
| physics | Step 02 auto kind: rim_or_board | 1832 | 56.615 | 0.384 |
| empirical | no player within reach | 1867 | 5.522 | 0.835 |
| gravity_gauss | no player within reach | 1867 | 7.451 | 0.790 |
| physics | no player within reach | 1867 | 74.818 | 0.268 |
| empirical | offset 0 | 1722 | 5.409 | 0.857 |
| gravity_gauss | offset 0 | 1722 | 7.910 | 0.820 |
| physics | offset 0 | 1722 | 23.166 | 0.491 |
| empirical | offset 10 | 1184 | 4.887 | 0.865 |
| gravity_gauss | offset 10 | 1184 | 6.347 | 0.963 |
| physics | offset 10 | 1184 | 103.137 | 0.166 |
| empirical | offset 15 |  883 | 5.071 | 0.841 |
| gravity_gauss | offset 15 |  883 | 6.239 | 0.963 |
| physics | offset 15 |  883 | 147.383 | 0.153 |
| empirical | offset 5 | 1479 | 5.857 | 0.824 |
| gravity_gauss | offset 5 | 1479 | 8.485 | 0.736 |
| physics | offset 5 | 1479 | 53.969 | 0.300 |
| empirical | player within reach | 3401 | 5.272 | 0.853 |
| gravity_gauss | player within reach | 3401 | 7.434 | 0.887 |
| physics | player within reach | 3401 | 68.297 | 0.329 |
| empirical | shot range: midrange (other 2s) | 1735 | 4.906 | 0.863 |
| gravity_gauss | shot range: midrange (other 2s) | 1735 | 7.061 | 0.926 |
| physics | shot range: midrange (other 2s) | 1735 | 47.312 | 0.402 |
| empirical | shot range: rim (<5 ft) |  680 | 5.186 | 0.826 |
| gravity_gauss | shot range: rim (<5 ft) |  680 | 6.337 | 0.975 |
| physics | shot range: rim (<5 ft) |  680 | 70.166 | 0.434 |
| empirical | shot range: three | 2853 | 5.679 | 0.842 |
| gravity_gauss | shot range: three | 2853 | 7.933 | 0.778 |
| physics | shot range: three | 2853 | 84.881 | 0.219 |

## Examples (`step07/figures/07_examples.png`)

Side view from the trigger: measured ball (grey), physics particles 10 frames ahead (blue), state at the trigger
(triangle), measured ball 10 frames ahead (cross), ring (orange), board (black). Kinds are Step 02's automated labels,
which failed their reliability check:

| episode_id | step02_auto_kind | label_status | physics_rim | physics_board | physics_none | auto_first_player_contact_frame | trigger_frame |
| --- | --- | --- | --- | --- | --- | --- | --- |
| shot-114169-2-64 | rim | unvalidated (Step 02 BLOCKED) | 0.800 | 0.210 | 0.180 |  60850 |  60828 |
| shot-191313-3-77 | rim | unvalidated (Step 02 BLOCKED) | 0.980 | 0.230 | 0.020 |  67368 |  67348 |
| shot-188630-2-59 | board | unvalidated (Step 02 BLOCKED) | 0.560 | 0.500 | 0.300 |  53675 |  53658 |
| shot-184439-3-91 | board | unvalidated (Step 02 BLOCKED) | 0.000 | 0.000 | 1.000 |  81611 |  81591 |
| shot-184439-4-131 | rim_or_board | unvalidated (Step 02 BLOCKED) | 0.990 | 0.960 | 0.000 | 132764 | 132746 |
| shot-191313-2-55 | rim_or_board | unvalidated (Step 02 BLOCKED) | 0.860 | 0.170 | 0.130 |  47770 |  47741 |
| shot-179612-1-21 | none | unvalidated (Step 02 BLOCKED) | 0.150 | 0.700 | 0.270 | NA |  11453 |
| shot-188630-1-26 | none | unvalidated (Step 02 BLOCKED) | 0.090 | 0.000 | 0.910 |  22588 |  22578 |

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE | TRUE |
| particle weights sum to 1 after every update (largest error) | 2.22e-16 | < 1e-9 | TRUE |
| effective sample size monitored (updates logged) | 5297 | > 0 | TRUE |
| hoops come from training games' made shots only | TRUE | TRUE | TRUE |
| every model scored on the same targets (targets with all three forecasts / all targets) | 5268 / 5268 | all models equal | TRUE |
| forecasts at an origin do not change when later frames are corrupted (3 episodes per game) | TRUE | TRUE | TRUE |

## Limits

- No validated contact labels: a course change may be the rim, the board, a hand or the tracking.
- Targets after a player reaches the ball are not ball physics; they are tagged (`player within reach`), not removed.
- The ring and board positions come from made shots and FIBA geometry; spin and restitution are drawn from broad priors.
