# Step 04: static rebounding model

Run 2026-10-30 by `src/rebounding/run_step04.R`; settings `config/experiment.yaml` (`step04`, config v3), fixed before any fit.
Folds, outcomes, scoring and decision rules are Step 03's frozen harness. Step 02 is BLOCKED: the target is the credited
outcome (ten players, team award to either side) of 703 missed shots.

## Models

- **Grouped conditional logit** over the 12 outcomes. Player features at t: distance to the hoop, distance minus the
  ten's mean, nearest opponent, inside gap, opponents and teammates nearer the hoop, angle from the shooter's line,
  offence, shooter, distance x shot distance, shooter on a rim shot, players within 6 ft, closeness share. Team awards
  are alternatives with a constant and a shot-distance slope. Standardised and L2-penalised on the training games;
  lambda by inner leave-one-game-out. Fitted at release (C1) and at rim + 0.2 s (exploratory; Step 09's C3b reference).
- **Binary OREB model** (C2): logistic regression on shot distance, three, the two nearest offensive and defensive
  hoop distances, offence minus defence mean distance, and attackers nearer the hoop than their assigned defender
  (five-against-five assignment minimising total distance).
- **Boosted challenger**: not run (optional in the manual, only after the logit passes).

## C1: conditional logit at release: PASS

Paired log-loss difference, logit minus each reference (negative is better). Superiority needs `hi` < 0 and every
drop-one-game mean < 0:

| reference | mean_diff | lo | hi | games_better | drop_one_max | pass |
| --- | --- | --- | --- | --- | --- | --- |
| uniform | -0.2722 | -0.3513 | -0.2064 | 10 | -0.2574 | TRUE |
| side_prior | -0.1786 | -0.2571 | -0.1138 | 10 | -0.1645 | TRUE |
| role_prior | -0.0735 | -0.1134 | -0.0398 | 10 | -0.0666 | TRUE |
| nearest_hoop | -0.0624 | -0.0892 | -0.0397 | 10 | -0.0548 | TRUE |
| inside_rule | -0.1850 | -0.2413 | -0.1354 | 10 | -0.1758 | TRUE |
| role_prior_by_range | -0.0611 | -0.1000 | -0.0297 |  9 | -0.0522 | TRUE |
| nearest_hoop_by_range | -0.0674 | -0.0996 | -0.0383 |  9 | -0.0612 | TRUE |
| selected_reference | -0.0782 | -0.1100 | -0.0493 | 10 | -0.0711 | TRUE |

Class-wise ECE: logit 0.0047, selected reference 0.0075 (allowed: reference + 0.02): met.

## C2: binary OREB model at release: BLOCKED

| model | episodes | team_log_loss | team_brier | mean_p_off | oreb_rate |
| --- | --- | --- | --- | --- | --- |
| oreb_logit | 703 | 0.6021 | 0.2060 | 0.2994 | 0.2987 |
| constant_oreb | 703 | 0.6102 | 0.2097 | 0.2987 | 0.2987 |
| static_clogit (implied) | 703 | 0.5942 | 0.2028 | 0.2994 | 0.2987 |

Paired binary log loss, model minus constant: -0.0082 (interval -0.0242 to 0.0076, better in 8 of 10 games, drop-one max -0.0057).
Calibration in the large: |mean P(OREB) - rate| = 0.0007 (allowed 0.03).

## Scores at both time points (held-out games)

| time_point | model | episodes | log_loss | brier | top1 | top3 | team_log_loss | ece |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| release | static_clogit | 703 | 2.2001 | 0.8686 | 0.2347 | 0.5078 | 0.5942 | 0.0047 |
| release | role_prior_by_range | 703 | 2.2612 | 0.8809 | 0.1337 | 0.4836 | 0.6117 | 0.0082 |
| release | nearest_hoop | 703 | 2.2625 | 0.8821 | 0.1821 | 0.4566 | 0.6195 | 0.0041 |
| release | nearest_hoop_by_range | 703 | 2.2675 | 0.8805 | 0.1636 | 0.4211 | 0.6166 | 0.0083 |
| release | role_prior | 703 | 2.2737 | 0.8844 | 0.1266 | 0.4822 | 0.6102 | 0.0088 |
| release | selected_reference | 703 | 2.2784 | 0.8846 | 0.1494 | 0.4609 | 0.6179 | 0.0075 |
| release | side_prior | 703 | 2.3787 | 0.8984 | 0.0000 | 0.0000 | 0.6102 | 0.0046 |
| release | inside_rule | 703 | 2.3851 | 0.9014 | 0.0925 | 0.3627 | 0.6252 | 0.0058 |
| release | uniform | 703 | 2.4724 | 0.9147 | 0.0000 | 0.0000 | 0.6938 | 0.0028 |
| rim+0.2 | static_clogit | 650 | 2.0851 | 0.8479 | 0.2108 | 0.5538 | 0.5753 | 0.0090 |
| rim+0.2 | nearest_hoop | 650 | 2.1740 | 0.8670 | 0.2169 | 0.5523 | 0.6064 | 0.0069 |
| rim+0.2 | selected_reference | 650 | 2.1740 | 0.8670 | 0.2169 | 0.5523 | 0.6064 | 0.0069 |
| rim+0.2 | role_prior | 650 | 2.1804 | 0.8680 | 0.1554 | 0.5108 | 0.6048 | 0.0050 |
| rim+0.2 | role_prior_by_range | 650 | 2.1826 | 0.8682 | 0.1646 | 0.5369 | 0.6051 | 0.0072 |
| rim+0.2 | nearest_hoop_by_range | 650 | 2.1857 | 0.8677 | 0.1862 | 0.5338 | 0.6079 | 0.0083 |
| rim+0.2 | inside_rule | 650 | 2.3582 | 0.8991 | 0.1046 | 0.3585 | 0.6177 | 0.0030 |
| rim+0.2 | side_prior | 650 | 2.3759 | 0.8979 | 0.0000 | 0.0000 | 0.6048 | 0.0053 |
| rim+0.2 | uniform | 650 | 2.4698 | 0.9143 | 0.0000 | 0.0000 | 0.6894 | 0.0014 |

## Exploratory: logit at rim + 0.2 s against every baseline

| reference | mean_diff | lo | hi | games_better | drop_one_max | pass |
| --- | --- | --- | --- | --- | --- | --- |
| uniform | -0.3846 | -0.4849 | -0.3044 | 10 | -0.3662 | TRUE |
| side_prior | -0.2908 | -0.3939 | -0.2087 | 10 | -0.2716 | TRUE |
| role_prior | -0.0953 | -0.1376 | -0.0537 | 10 | -0.0871 | TRUE |
| nearest_hoop | -0.0888 | -0.1230 | -0.0542 | 10 | -0.0798 | TRUE |
| inside_rule | -0.2730 | -0.3561 | -0.2095 | 10 | -0.2580 | TRUE |
| role_prior_by_range | -0.0975 | -0.1360 | -0.0612 |  9 | -0.0906 | TRUE |
| nearest_hoop_by_range | -0.1006 | -0.1490 | -0.0554 |  9 | -0.0875 | TRUE |
| selected_reference | -0.0888 | -0.1230 | -0.0542 | 10 | -0.0798 | TRUE |

## Lambda chosen (folds)

| lambda | N | time_point |
| --- | --- | --- |
| 3.000 | 10 | release |
| 1.000 |  8 | rim+0.2 |
| 3.000 |  2 | rim+0.2 |

## Coefficients (all ten games, for reading only; per standard deviation)

| term | estimate_per_sd | fold_min | fold_max | sign_changes |
| --- | --- | --- | --- | --- |
| dist_hoop | -0.731 | -0.907 | -0.585 | FALSE |
| dist_minus_mean | -1.075 | -1.171 | -0.959 | FALSE |
| nearest_opp_dist | 0.356 | 0.316 | 0.418 | FALSE |
| inside_gap | -0.024 | -0.078 | 0.034 |  TRUE |
| opp_inside | -0.230 | -0.263 | -0.192 | FALSE |
| mates_inside | 0.186 | 0.126 | 0.241 | FALSE |
| abs_rel_bearing | 0.089 | 0.053 | 0.126 | FALSE |
| is_offense | -0.063 | -0.095 | -0.041 | FALSE |
| is_shooter | -0.185 | -0.226 | -0.132 | FALSE |
| dist_x_shot | 0.414 | 0.355 | 0.510 | FALSE |
| shooter_x_rim | -0.009 | -0.034 | 0.020 |  TRUE |
| n_within_6 | 0.071 | 0.046 | 0.098 | FALSE |
| closeness_share | -0.458 | -0.509 | -0.415 | FALSE |
| team_off | -0.080 | -0.162 | 0.004 |  TRUE |
| team_def | -0.168 | -0.300 | -0.086 | FALSE |
| team_off_x_shot_dist | 0.003 | -0.108 | 0.058 |  TRUE |
| team_def_x_shot_dist | 0.416 | 0.293 | 0.581 | FALSE |

`dist_hoop` and `dist_minus_mean` differ by a per-shot constant, so the softmax splits one distance effect between
them (and `dist_x_shot`); read them together. Fold ranges show how stable each term is across held-out games.

## Where it gains and loses (difference against the selected reference)

| time_point | group | episodes | log_loss | diff_vs_reference | top1 |
| --- | --- | --- | --- | --- | --- |
| release | all | 703 | 2.2001 | -0.0782 | 0.2347 |
| rim+0.2 | all | 650 | 2.0851 | -0.0888 | 0.2108 |
| release | shot range: rim (<5 ft) | 148 | 2.0426 | -0.1376 | 0.2905 |
| rim+0.2 | shot range: rim (<5 ft) | 122 | 1.9351 | -0.1349 | 0.2459 |
| release | shot range: three | 327 | 2.2448 | -0.0586 | 0.2141 |
| rim+0.2 | shot range: three | 318 | 2.1278 | -0.0961 | 0.2044 |
| release | shot range: midrange (other 2s) | 228 | 2.2383 | -0.0679 | 0.2281 |
| rim+0.2 | shot range: midrange (other 2s) | 210 | 2.1078 | -0.0511 | 0.2000 |
| release | outcome: off player | 173 | 2.5272 | 0.0414 | 0.1156 |
| rim+0.2 | outcome: off player | 161 | 2.3578 | 0.1965 | 0.1056 |
| release | outcome: def player | 457 | 1.9445 | -0.1341 | 0.3173 |
| rim+0.2 | outcome: def player | 425 | 1.8377 | -0.2085 | 0.2824 |
| release | outcome: def team award |  36 | 3.0249 | -0.0333 | 0.0000 |
| rim+0.2 | outcome: def team award |  35 | 2.8781 | -0.0878 | 0.0000 |
| release | outcome: off team award |  37 | 3.0259 | 0.0085 | 0.0000 |
| rim+0.2 | outcome: off team award |  29 | 3.2407 | 0.0793 | 0.0000 |
| release | without identity_suspect | 670 | 2.2007 | -0.0685 | 0.2328 |
| rim+0.2 | without identity_suspect | 622 | 2.0838 | -0.0881 | 0.2138 |
| release | blocked shots |  49 | 2.3429 | 0.0144 | 0.2245 |
| rim+0.2 | blocked shots |  21 | 2.1374 | -0.0235 | 0.2857 |

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force (config, harness code, baseline predictions) | TRUE | TRUE | TRUE |
| prediction tables valid (12 outcomes, finite, non-negative, sum to 1) | 2 | 2 | TRUE |
| exactly one credited outcome per choice set | 703 | 703 | TRUE |
| logit scored on exactly the baselines' episodes at each time point | 2 | 2 | TRUE |
| scalers and fits use exactly the nine training games' episodes | 20 | 20 | TRUE |
| every fit converged | 20 | 20 | TRUE |
| logit predictions unchanged when the test game's labels are altered (fold 1) | TRUE | TRUE | TRUE |
| planted test-label leak is detected | TRUE | TRUE | TRUE |
| OREB predictions unchanged when the test game's labels are flipped (fold 1) | TRUE | TRUE | TRUE |
| reordering candidate rows changes no player's probability (fold 1, largest change) | 3.33e-16 | < 1e-7 | TRUE |
| features in metres give the same probabilities (fold 1, largest change) | 6.91e-09 | < 1e-6 | TRUE |
| mirroring the court left to right gives the same probabilities (fold 1, largest change) | 0 | < 1e-6 | TRUE |
| re-running the release fits reproduces every prediction exactly | TRUE | TRUE | TRUE |
| constant OREB reference equals Step 03's | 4.77e-15 | < 1e-9 | TRUE |
| top-1 counted once per rebound | 1 | 1 | TRUE |

## Limits

- Ten games: intervals are indicative. Leave one game out trains on later games; teams recur across games.
- Release geometry only; no velocities, no ball. The rim + 0.2 s fit uses positions then, still without the ball.
- Coefficients describe association in these games, not effects of moving a player.
