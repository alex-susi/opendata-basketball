# Step 09: rebound probabilities with ball uncertainty and player access

Run 2026-11-05 by `src/rebounding/run_step09.R`; settings `config/experiment.yaml` (`step09`, config v3), fixed before any
real-data run. Compared with the Step 04 static conditional logit at the same time point (Step 03's C3a and C3b).

**Model.** For each of 30 ball particles, one softmax over the 12 outcomes with the Step 04 player features plus each
player's access margin to that particle (Step 08 arrival rule) and whether he has the best margin; the episode's
probabilities are the average over particles. Particles: the Step 05 release map at release; the Step 07 analog
forecast of the ball 0.4 s ahead at rim + 0.2 s (both exploratory). A training episode's particles come from models
fitted without the test game and without its own game. Lambda 3, no temperature.

## Held-out scores

| time_point | model | episodes | log_loss | brier | top1 | top3 | team_log_loss | ece |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| release | dynamic | 703 | 2.1810 | 0.8629 | 0.2390 | 0.5434 | 0.5925 | 0.0062 |
| release | static_clogit | 703 | 2.2001 | 0.8686 | 0.2347 | 0.5078 | 0.5942 | 0.0047 |
| release | access_only | 703 | 2.2445 | 0.8783 | 0.1906 | 0.5107 | 0.6184 | 0.0066 |
| rim+0.2 | dynamic | 650 | 2.0286 | 0.8264 | 0.3000 | 0.6031 | 0.5681 | 0.0070 |
| rim+0.2 | static_clogit | 650 | 2.0851 | 0.8479 | 0.2108 | 0.5538 | 0.5753 | 0.0090 |
| rim+0.2 | access_only | 650 | 2.1754 | 0.8478 | 0.2785 | 0.6092 | 0.6152 | 0.0164 |

## Confirmatory tests

| test | candidate | reference | time_point | metric | mean_diff | lo | hi | games_better | drop_one_max | superior | non_inferior |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C3a (confirmatory) | dynamic | static_clogit | release | ll | -0.0192 | -0.0298 | -0.0077 |  9 | -0.0144 |  TRUE |  TRUE |
| C3b (confirmatory) | dynamic | static_clogit | rim+0.2 | ll | -0.0565 | -0.0868 | -0.0230 |  9 | -0.0517 |  TRUE |  TRUE |
| exploratory | access_only | static_clogit | release | ll | 0.0444 | 0.0169 | 0.0757 |  1 | 0.0580 | FALSE | FALSE |
| exploratory | dynamic | access_only | release | ll | -0.0636 | -0.0878 | -0.0445 | 10 | -0.0593 |  TRUE |  TRUE |
| exploratory | dynamic | static_clogit | release | team_ll | -0.0018 | -0.0063 | 0.0024 |  6 | -0.0009 | FALSE |  TRUE |
| exploratory | access_only | static_clogit | rim+0.2 | ll | 0.0902 | 0.0509 | 0.1381 |  0 | 0.0971 | FALSE | FALSE |
| exploratory | dynamic | access_only | rim+0.2 | ll | -0.1467 | -0.1759 | -0.1229 | 10 | -0.1398 |  TRUE |  TRUE |
| exploratory | dynamic | static_clogit | rim+0.2 | team_ll | -0.0072 | -0.0211 | 0.0057 |  6 | -0.0036 | FALSE |  TRUE |

- C3a (release, non-inferiority, margin 0.02): **met**.
- C3b (rim + 0.2 s, superiority): **met**.
- Calibration (class-wise ECE at most static + 0.02): met.
- **Step 09: PASS.**

| time_point | dynamic | static_clogit | ok |
| --- | --- | --- | --- |
| release | 0.0062 | 0.0047 | TRUE |
| rim+0.2 | 0.0070 | 0.0090 | TRUE |

## Access coefficients (per standard deviation, range over folds)

| time_point | term | mean | min | max |
| --- | --- | --- | --- | --- |
| release | access_margin | 0.927 | 0.844 | 0.999 |
| release | best_access | 0.076 | 0.013 | 0.161 |
| rim+0.2 | access_margin | -0.363 | -0.516 | -0.174 |
| rim+0.2 | best_access | 0.572 | 0.528 | 0.642 |

## Particle stability and the degraded ball

| run | time_point | episodes | mean_abs_diff | mean_diff | stable |
| --- | --- | --- | --- | --- | --- |
| second seed | release | 703 | 0.0714 | -0.0040 | FALSE |
| twice the particles | release | 703 | 0.0364 | -0.0022 | FALSE |
| second seed | rim+0.2 | 650 | 0.1312 | -0.0048 | FALSE |
| twice the particles | rim+0.2 | 650 | 0.0963 | -0.0071 | FALSE |

| episodes | mean_top_full | mean_top_degraded | rise | ok |
| --- | --- | --- | --- | --- |
| 650 | 0.3052 | 0.2899 | -0.0154 | TRUE |

## By subgroup

| time_point | model | group | n | log_loss | top1 |
| --- | --- | --- | --- | --- | --- |
| release | dynamic | outcome: def player | 457 | 1.923 | 0.328 |
| release | static_clogit | outcome: def player | 457 | 1.944 | 0.317 |
| release | dynamic | outcome: def team award |  36 | 2.960 | 0.028 |
| release | static_clogit | outcome: def team award |  36 | 3.025 | 0.000 |
| release | dynamic | outcome: off player | 173 | 2.515 | 0.098 |
| release | static_clogit | outcome: off player | 173 | 2.527 | 0.116 |
| release | dynamic | outcome: off team award |  37 | 3.047 | 0.000 |
| release | static_clogit | outcome: off team award |  37 | 3.026 | 0.000 |
| release | dynamic | shot range: midrange (other 2s) | 228 | 2.229 | 0.215 |
| release | static_clogit | shot range: midrange (other 2s) | 228 | 2.238 | 0.228 |
| release | dynamic | shot range: rim (<5 ft) | 148 | 2.003 | 0.324 |
| release | static_clogit | shot range: rim (<5 ft) | 148 | 2.043 | 0.291 |
| release | dynamic | shot range: three | 327 | 2.228 | 0.217 |
| release | static_clogit | shot range: three | 327 | 2.245 | 0.214 |
| rim+0.2 | dynamic | outcome: def player | 425 | 1.765 | 0.381 |
| rim+0.2 | static_clogit | outcome: def player | 425 | 1.838 | 0.282 |
| rim+0.2 | dynamic | outcome: def team award |  35 | 2.896 | 0.000 |
| rim+0.2 | static_clogit | outcome: def team award |  35 | 2.878 | 0.000 |
| rim+0.2 | dynamic | outcome: off player | 161 | 2.318 | 0.205 |
| rim+0.2 | static_clogit | outcome: off player | 161 | 2.358 | 0.106 |
| rim+0.2 | dynamic | outcome: off team award |  29 | 3.233 | 0.000 |
| rim+0.2 | static_clogit | outcome: off team award |  29 | 3.241 | 0.000 |
| rim+0.2 | dynamic | shot range: midrange (other 2s) | 210 | 2.080 | 0.276 |
| rim+0.2 | static_clogit | shot range: midrange (other 2s) | 210 | 2.108 | 0.200 |
| rim+0.2 | dynamic | shot range: rim (<5 ft) | 122 | 1.770 | 0.418 |
| rim+0.2 | static_clogit | shot range: rim (<5 ft) | 122 | 1.935 | 0.246 |
| rim+0.2 | dynamic | shot range: three | 318 | 2.094 | 0.270 |
| rim+0.2 | static_clogit | shot range: three | 318 | 2.128 | 0.204 |

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE |  TRUE |
| predictions valid (12 outcomes, finite, non-negative, sum to 1) | 4 | 4 |  TRUE |
| dynamic, access-only and static scored on the same episodes and time points | 2 | 2 |  TRUE |
| P(OREB) = offensive players + offensive team award, and the 12 outcomes sum to 1 | 1.89e-15 | < 1e-9 |  TRUE |
| every fit converged | 40 | 40 |  TRUE |
| particle draws stable (second seed, twice the particles) | 0.0714 / 0.0364 / 0.1312 / 0.0963 | mean |diff| < 0.02, |mean diff| < 0.01 | FALSE |
| confidence does not rise when half the ball frames are dropped (mean top probability change) | -0.0154 | <= 0.02 |  TRUE |
| predict_rebound replays the out-of-fold predictions and ignores corrupted later frames (12 episodes) | TRUE | TRUE |  TRUE |

## Limits

- The ball inputs are not validated (Steps 05 and 07 BLOCKED); any gain is a gain in held-out scores, not proof the
  ball forecasts are right.
- Two time points only; ten games; no player heights or skills.
