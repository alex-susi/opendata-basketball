# Step 08: player movement and reachability

Run 2026-11-05 by `src/rebounding/run_step08.R`; settings `config/experiment.yaml` (`step08`, config v3), fixed before any
real-data run; folds and rules are Step 03's.

**Gate rule.** Interception can only be validated against first-contact labels, and Step 02 is BLOCKED, so the
physical interception validation is BLOCKED and the reach margins below are exploratory. The movement models are
validated on held-out games.

## Movement forecasts (held-out games, detected target positions, error in ft)

| horizon | model | forecasts | mean_err | median_err | p90_err |
| --- | --- | --- | --- | --- | --- |
|  5 | damped | 18201 | 0.216 | 0.188 | 0.409 |
|  5 | bounded | 18201 | 0.217 | 0.188 | 0.411 |
|  5 | constant_velocity | 18201 | 0.221 | 0.191 | 0.420 |
|  5 | stationary | 18201 | 0.954 | 0.848 | 1.785 |
| 10 | damped | 18013 | 0.635 | 0.554 | 1.184 |
| 10 | bounded | 18013 | 0.636 | 0.555 | 1.188 |
| 10 | constant_velocity | 18013 | 0.659 | 0.573 | 1.237 |
| 10 | stationary | 18013 | 1.888 | 1.688 | 3.514 |
| 15 | damped | 17894 | 1.232 | 1.081 | 2.287 |
| 15 | bounded | 17894 | 1.234 | 1.082 | 2.289 |
| 15 | constant_velocity | 17894 | 1.301 | 1.140 | 2.430 |
| 15 | stationary | 17894 | 2.801 | 2.528 | 5.179 |
| 25 | damped | 17618 | 2.862 | 2.546 | 5.298 |
| 25 | bounded | 17618 | 2.863 | 2.547 | 5.298 |
| 25 | constant_velocity | 17618 | 3.135 | 2.776 | 5.771 |
| 25 | stationary | 17618 | 4.590 | 4.156 | 8.441 |

Speed and acceleration limits and damping by fold (training games only):

| outer_fold | test_game | v_max | a_max | n_frames | lambda | n_train_rows |
| --- | --- | --- | --- | --- | --- | --- |
|  1 | 114243 | 15.158 | 20.115 | 424008 | 0.500 | 62674 |
|  2 | 114234 | 15.178 | 19.966 | 440227 | 0.500 | 64862 |
|  3 | 114169 | 15.324 | 20.110 | 431247 | 0.500 | 63569 |
|  4 | 114099 | 15.367 | 20.164 | 422377 | 0.500 | 62746 |
|  5 | 114086 | 15.305 | 20.176 | 446693 | 0.500 | 65570 |
|  6 | 178442 | 15.378 | 20.198 | 434390 | 0.500 | 64269 |
|  7 | 179612 | 15.340 | 20.169 | 439583 | 0.500 | 65054 |
|  8 | 184439 | 15.226 | 20.019 | 446910 | 0.500 | 65629 |
|  9 | 188630 | 15.303 | 20.136 | 447053 | 0.500 | 65672 |
| 10 | 191313 | 15.306 | 20.174 | 443870 | 0.500 | 65489 |

| outer_fold | frames | speed_above | accel_above |
| --- | --- | --- | --- |
|  1 | 62254 | 0.0082 | 0.0051 |
|  2 | 46035 | 0.0086 | 0.0080 |
|  3 | 55015 | 0.0041 | 0.0052 |
|  4 | 63885 | 0.0033 | 0.0045 |
|  5 | 39569 | 0.0044 | 0.0038 |
|  6 | 51872 | 0.0026 | 0.0038 |
|  7 | 46679 | 0.0035 | 0.0041 |
|  8 | 39352 | 0.0072 | 0.0071 |
|  9 | 39209 | 0.0045 | 0.0047 |
| 10 | 42392 | 0.0044 | 0.0039 |

## Damped against stationary and constant velocity (superiority, Step 03 rule): PASS

| candidate | reference | time_point | mean_diff | lo | hi | games_better | drop_one_max | superior |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| damped | stationary | h5 | -0.747 | -0.777 | -0.714 | 10 | -0.738 |  TRUE |
| damped | constant_velocity | h5 | -0.006 | -0.007 | -0.004 | 10 | -0.006 |  TRUE |
| bounded | damped | h5 | 0.001 | 0.000 | 0.002 |  0 | 0.001 | FALSE |
| damped | stationary | h10 | -1.268 | -1.324 | -1.209 | 10 | -1.253 |  TRUE |
| damped | constant_velocity | h10 | -0.027 | -0.033 | -0.022 | 10 | -0.026 |  TRUE |
| bounded | damped | h10 | 0.002 | 0.001 | 0.004 |  0 | 0.002 | FALSE |
| damped | stationary | h15 | -1.589 | -1.661 | -1.513 | 10 | -1.570 |  TRUE |
| damped | constant_velocity | h15 | -0.077 | -0.089 | -0.064 | 10 | -0.073 |  TRUE |
| bounded | damped | h15 | 0.003 | 0.001 | 0.005 |  1 | 0.003 | FALSE |
| damped | stationary | h25 | -1.750 | -1.847 | -1.648 | 10 | -1.730 |  TRUE |
| damped | constant_velocity | h25 | -0.290 | -0.324 | -0.255 | 10 | -0.281 |  TRUE |
| bounded | damped | h25 | 0.003 | -0.000 | 0.006 |  3 | 0.003 | FALSE |

By stratum (`movement_by_stratum.csv`): velocity from detected or extrapolated positions, target detected or not, origin.

## Reach after the rim arrival (exploratory)

Margin = time the ball is at a point (on its measured path to the credited rebound) minus the player's arrival
there (reaction 0.20 s, then straight at the fold's v_max to within 2.0 ft; a jump adds 0.25 s and reaches 11.0 ft).
Feasible = margin >= 0. The ball path is the realised one, so this is feasibility after the fact, not a forecast.
The credited rebounder is the final credit, not the first touch; Step 02's first toucher is unvalidated.

| variant | episodes | feasible_mean | none_feasible | credited_feasible | credited_top1 | credited_top3 | auto_first_feasible | auto_first_top1 | earliest_arriver_changes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base | 678 | 4.524 | 0.164 | 0.775 | 0.464 | 0.826 | 0.816 | 0.535 | 0.000 |
| half the ball frames | 678 | 4.032 | 0.245 | 0.671 | 0.474 | 0.813 | 0.723 | 0.550 | 0.087 |
| jump reach 10 ft | 678 | 4.476 | 0.177 | 0.759 | 0.485 | 0.826 | 0.807 | 0.541 | 0.037 |
| jump reach 12 ft | 678 | 4.537 | 0.156 | 0.779 | 0.463 | 0.826 | 0.816 | 0.535 | 0.006 |
| position error 1 ft | 678 | 4.456 | 0.167 | 0.759 | 0.446 | 0.829 | 0.814 | 0.504 | 0.212 |
| reaction 0.1 s | 678 | 4.963 | 0.128 | 0.827 | 0.432 | 0.805 | 0.859 | 0.491 | 0.087 |
| reaction 0.3 s | 678 | 4.044 | 0.217 | 0.707 | 0.500 | 0.842 | 0.764 | 0.578 | 0.074 |
| takeoff 0.15 s | 678 | 4.878 | 0.122 | 0.832 | 0.464 | 0.826 | 0.870 | 0.535 | 0.000 |
| takeoff 0.35 s | 678 | 4.142 | 0.208 | 0.697 | 0.464 | 0.826 | 0.753 | 0.535 | 0.000 |

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE | TRUE |
| velocities at t unchanged when later frames are corrupted (30 episodes) | TRUE | TRUE | TRUE |
| damping and limits use the training games only | TRUE | TRUE | TRUE |
| speed limit plausible (training v_max, ft/s) | 15.2 to 15.4 | 15 to 35 | TRUE |
| held-out detected speeds above the training v_max (largest fold share) | 0.0086 | <= 0.01 | TRUE |
| a ball above every player's reach gives no interception | TRUE | TRUE | TRUE |
| first touch, first control and final credit kept apart (reach is scored against neither as a pass test) | TRUE | TRUE | TRUE |
| re-running fold 1 reproduces every damped forecast error | TRUE | TRUE | TRUE |

## Limits

- No player heights, wingspans or jump data: the envelope is a broad assumption, not a measurement.
- Obstruction is not modelled (box-outs are Step 11).
- Reach uses the realised ball path; Step 09 has to use forecast paths instead.
