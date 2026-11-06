# Step 10: positioning, movement and response

Run 2026-11-05 by `src/rebounding/run_step10.R`; settings `config/experiment.yaml` (`step10`, config v3), fixed before any
real-data run. Reference ball distribution: the Step 05 release map (not validated), so every measure is exploratory
with respect to it. Later time: the rim-arrival trigger (the ball's flight before the rim).

**Measures.** Q = a player's expected chance of reaching the ball over the reference distribution (logistic in his
arrival margin, sigma 0.45 s). Move = Q at the rim arrival minus Q at release, same distribution in absolute time:
0 for ideal pursuit, negative when time passes faster than he closes. vs_baseline = Q at the rim arrival minus Q of
the damped forecast that ignores the ball: access gained by reading the shot. Info = Q at release under the updated
ball forecast minus under the reference (player fixed).

## By role (game bootstrap intervals)

| role | n | q_release | move | move_lo | move_hi | vs_baseline | vs_lo | vs_hi | responded | already_moving | no_response | median_onset_s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| defence: other | 2034 | 0.866 | -0.284 | -0.297 | -0.273 | 0.071 | 0.065 | 0.078 | 0.145 | 0.135 | 0.720 | 0.680 |
| defence: rim protector |  678 | 0.958 | -0.224 | -0.236 | -0.211 | 0.021 | 0.015 | 0.026 | 0.013 | 0.059 | 0.928 | 0.880 |
| defence: shooter's defender |  678 | 0.922 | -0.469 | -0.498 | -0.439 | 0.023 | 0.017 | 0.029 | 0.035 | 0.147 | 0.817 | 0.720 |
| offence: nearest the hoop |  678 | 0.919 | -0.232 | -0.240 | -0.223 | 0.043 | 0.039 | 0.048 | 0.062 | 0.199 | 0.739 | 0.640 |
| offence: other | 1801 | 0.714 | -0.370 | -0.390 | -0.349 | 0.084 | 0.072 | 0.098 | 0.206 | 0.089 | 0.705 | 0.560 |
| offence: safety |  233 | 0.357 | -0.284 | -0.324 | -0.238 | 0.011 | -0.000 | 0.021 | 0.026 | 0.258 | 0.717 | 0.700 |
| offence: shooter |  678 | 0.906 | -0.540 | -0.567 | -0.512 | -0.053 | -0.060 | -0.047 | 0.006 | 0.053 | 0.941 | 0.920 |

## By side and shot range (vs_baseline)

| off | shot_range | n | games | mean | lo | hi |
| --- | --- | --- | --- | --- | --- | --- |
| FALSE | rim (<5 ft) |  685 | 10 | 0.009 | 0.006 | 0.011 |
|  TRUE | rim (<5 ft) |  685 | 10 | 0.004 | 0.003 | 0.007 |
| FALSE | three | 1605 | 10 | 0.081 | 0.074 | 0.086 |
|  TRUE | three | 1605 | 10 | 0.075 | 0.063 | 0.088 |
| FALSE | midrange (other 2s) | 1100 | 10 | 0.036 | 0.031 | 0.041 |
|  TRUE | midrange (other 2s) | 1100 | 10 | 0.021 | 0.017 | 0.026 |

## Decomposition (mean over player-episodes with an updated forecast)

| player_episodes | total | move | info | interaction |
| --- | --- | --- | --- | --- |
| 6780 | -0.7633 | -0.3396 | -0.6057 | 0.1820 |

## Does it line up with the credited rebounder? (association, rank within the ten)

| episodes | top1_by_vs_baseline | top1_by_q_later | top1_by_q_release | top3_by_q_later |
| --- | --- | --- | --- | --- |
| 614 | 0.117 | 0.246 | 0.202 | 0.625 |

## Response onset stability

Threshold variants are judged on class change only; their onset timing is reported as the curve below (owner
deviation 2026-11-05, after the first run's 8 ft/s variant shifted the median onset by 5 frames).

| variant | players | class_changed | median_onset_shift_frames | rule | stable |
| --- | --- | --- | --- | --- | --- |
| window 4 | 6780 | 0.009 | 1.000 | class change and onset shift | TRUE |
| window 10 | 6780 | 0.020 | 2.000 | class change and onset shift | TRUE |
| threshold 5 ft/s | 6780 | 0.064 | 2.000 | class change only (onset reported as a curve) | TRUE |
| threshold 7 ft/s | 6780 | 0.055 | 2.000 | class change only (onset reported as a curve) | TRUE |
| threshold 8 ft/s | 6780 | 0.094 | 5.000 | class change only (onset reported as a curve) | TRUE |
| position error 1 ft | 6780 | 0.019 | 0.000 | class change and onset shift | TRUE |

## Response onset by speed threshold (curve)

Onset = first frame of 5 in a row moving toward the ball's expected landing spot at least this fast (and 3 ft/s
faster than at release). Read onsets as a curve: a higher bar is reached later by construction.

| role | threshold_ft_s | players | responded | onset_q25_s | onset_median_s | onset_q75_s |
| --- | --- | --- | --- | --- | --- | --- |
| all players | 5.00 | 6780 | 0.13 | 0.44 | 0.60 | 0.80 |
| all players | 6.00 | 6780 | 0.11 | 0.44 | 0.60 | 0.80 |
| all players | 7.00 | 6780 | 0.09 | 0.44 | 0.64 | 0.84 |
| all players | 8.00 | 6780 | 0.07 | 0.48 | 0.68 | 0.88 |
| defence: other | 5.00 | 2034 | 0.18 | 0.48 | 0.68 | 0.92 |
| defence: other | 6.00 | 2034 | 0.14 | 0.48 | 0.68 | 0.92 |
| defence: other | 7.00 | 2034 | 0.09 | 0.50 | 0.72 | 0.92 |
| defence: other | 8.00 | 2034 | 0.07 | 0.56 | 0.76 | 0.96 |
| defence: rim protector | 5.00 |  678 | 0.02 | 0.70 | 0.82 | 1.09 |
| defence: rim protector | 6.00 |  678 | 0.01 | 0.76 | 0.88 | 1.00 |
| defence: rim protector | 7.00 |  678 | 0.01 | 0.72 | 0.92 | 0.96 |
| defence: rim protector | 8.00 |  678 | 0.00 |  NA |  NA |  NA |
| defence: shooter's defender | 5.00 |  678 | 0.04 | 0.37 | 0.68 | 0.88 |
| defence: shooter's defender | 6.00 |  678 | 0.04 | 0.50 | 0.72 | 1.01 |
| defence: shooter's defender | 7.00 |  678 | 0.02 | 0.50 | 0.80 | 1.10 |
| defence: shooter's defender | 8.00 |  678 | 0.01 | 0.48 | 0.72 | 0.88 |
| offence: nearest the hoop | 5.00 |  678 | 0.09 | 0.44 | 0.62 | 0.79 |
| offence: nearest the hoop | 6.00 |  678 | 0.06 | 0.44 | 0.64 | 0.80 |
| offence: nearest the hoop | 7.00 |  678 | 0.05 | 0.52 | 0.72 | 0.88 |
| offence: nearest the hoop | 8.00 |  678 | 0.04 | 0.59 | 0.76 | 0.97 |
| offence: other | 5.00 | 1801 | 0.22 | 0.36 | 0.52 | 0.68 |
| offence: other | 6.00 | 1801 | 0.21 | 0.40 | 0.56 | 0.72 |
| offence: other | 7.00 | 1801 | 0.19 | 0.40 | 0.60 | 0.80 |
| offence: other | 8.00 | 1801 | 0.17 | 0.44 | 0.66 | 0.87 |
| offence: safety | 5.00 |  233 | 0.04 | 0.60 | 0.66 | 0.87 |
| offence: safety | 6.00 |  233 | 0.03 | 0.53 | 0.70 | 0.72 |
| offence: safety | 7.00 |  233 | 0.02 | 0.59 | 0.74 | 0.96 |
| offence: safety | 8.00 |  233 | 0.02 | 0.56 | 0.56 | 0.76 |
| offence: shooter | 5.00 |  678 | 0.01 | 0.58 | 0.82 | 1.06 |
| offence: shooter | 6.00 |  678 | 0.01 | 0.71 | 0.92 | 1.11 |
| offence: shooter | 7.00 |  678 | 0.01 | 0.78 | 1.00 | 1.19 |
| offence: shooter | 8.00 |  678 | 0.00 | 1.10 | 1.24 | 1.32 |

## Player effects (vs_baseline, role-adjusted, empirical Bayes; players with at least 20 episodes: 161)

Split-by-game reliability over 25 players seen in two games: r = 0.470 (needed >= 0.3).

| scale | share_sign_change |
| --- | --- |
| 0.500 | 0.000 |
| 2.000 | 0.000 |

**Player-level claims: supported.** 

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE | TRUE |
| decomposition adds up (largest |total - move - info - interaction|) | 1.11e-16 | < 1e-9 | TRUE |
| movement measured with the same reference distribution at both times (one particle set per episode) | TRUE | TRUE | TRUE |
| reference sensitivity: Spearman correlation with other Step 05 maps (move and vs_baseline) | 0.997 / 0.997 / 0.997 / 0.996 | >= 0.8 | TRUE |
| particle redraw changes Q measures little (mean absolute change, move / vs_baseline) | 0.0076 / 0.0029 | < 0.02 | TRUE |
| response classes stable under smoothing, threshold and position-error variants; onsets stable under smoothing and position error | 6 | 6 | TRUE |
| player effects reported with exposure (episodes and games per player) | 204 | players | TRUE |
| episodes measured (with a rim arrival and ten players at both times) / with a rim arrival | 678 / 678 | reported | TRUE |

## Limits

- An onset is an observed response, not a physiological reaction time. Players who anticipate move before release
  ("already moving"); players with transition duty do not crash by design ("no response").
- Reference distribution and arrival rule are assumptions (Steps 05 and 08); no player heights or speeds of their own.
- 179 of 204 players appear in only one game, so player-level differences cannot be checked across games for them.
