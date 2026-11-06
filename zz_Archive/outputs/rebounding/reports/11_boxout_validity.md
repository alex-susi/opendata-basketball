# Step 11: geometric obstruction and box-out validity

Run 2026-11-05 by `src/rebounding/run_step11.R`; settings `config/experiment.yaml` (`step11`, config v3), fixed before any
real-data run. The measure is named **obstruction**: geometric blocking of a route from floor positions, not body
contact. No video ships with the data and outside video is not allowed.

**Measure.** O_ij = how much player i stands on player j's route to 15 fixed points around the hoop (the hoop and
rings at 4 and 8 ft), averaged over the points: full weight when i is 0-3 ft ahead of j along the route and within
about 1.5 ft of it, fading with distance ahead and to the side, zero when i is level with or behind j. Player
features: blocked_by_opp (how much opponents block his routes) and blocking_opp (how much he blocks theirs).
Pairings are each player's most-obstructed opponent, `none` below 0.25 (no pair forced) and `ambiguous` when a
second opponent is within 0.1.

## Geometry checks (real data)

| time_point | mirror_max_diff | rotation_max_diff | all_finite | rho_blocked_hoop_only | rho_blocking_hoop_only | zero_distance_pairs |
| --- | --- | --- | --- | --- | --- | --- |
| release | 0.0000 | 0.0000 | TRUE | 0.8086 | 0.9577 | 0 |
| rim+0.2 | 0.0000 | 0.0000 | TRUE | 0.7527 | 0.9463 | 0 |

| time_point | player_episodes | mean_abs_change_blocked | mean_abs_change_blocking | pairing_changed | pairing_changed_among_paired |
| --- | --- | --- | --- | --- | --- |
| release | 7030 | 0.048 | 0.046 | 0.087 | 0.308 |
| rim+0.2 | 6500 | 0.054 | 0.051 | 0.105 | 0.307 |

**Context, not gated** (owner decision 2026-11-05, after the first run; the gate stays as prespecified). The same
one-foot moves applied to Step 04's features. The obstruction features move more in units of their spread (about
0.25 SD against 0.16-0.18 for Step 04's relative features) but keep the ten players' order as well (rank
correlation 0.95-0.97 against 0.91-0.96). The 0.05 limit had no scale reference; the miss is small.

| time_point | feature | source | sd | mean_abs_change | change_in_sd | rank_corr |
| --- | --- | --- | --- | --- | --- | --- |
| release | blocked_by_opp | Step 11 | 0.190 | 0.048 | 0.252 | 0.953 |
| release | blocking_opp | Step 11 | 0.197 | 0.046 | 0.235 | 0.968 |
| release | nearest_opp_dist | Step 04 | 4.181 | 0.771 | 0.184 | 0.964 |
| release | inside_gap | Step 04 | 6.728 | 1.220 | 0.181 | 0.924 |
| release | n_within_6 | Step 04 | 0.963 | 0.160 | 0.166 | 0.890 |
| release | closeness_share | Step 04 | 0.105 | 0.009 | 0.084 | 0.996 |
| release | dist_hoop | Step 04 | 8.871 | 0.635 | 0.072 | 0.996 |
| release | opp_inside | Step 04 | 1.833 | 0.119 | 0.065 | 0.975 |
| rim+0.2 | blocked_by_opp | Step 11 | 0.206 | 0.054 | 0.264 | 0.952 |
| rim+0.2 | blocking_opp | Step 11 | 0.217 | 0.051 | 0.236 | 0.966 |
| rim+0.2 | inside_gap | Step 04 | 6.448 | 1.183 | 0.184 | 0.915 |
| rim+0.2 | n_within_6 | Step 04 | 1.119 | 0.196 | 0.175 | 0.908 |
| rim+0.2 | nearest_opp_dist | Step 04 | 4.794 | 0.767 | 0.160 | 0.955 |
| rim+0.2 | closeness_share | Step 04 | 0.095 | 0.009 | 0.096 | 0.995 |
| rim+0.2 | opp_inside | Step 04 | 1.760 | 0.130 | 0.074 | 0.973 |
| rim+0.2 | dist_hoop | Step 04 | 9.351 | 0.638 | 0.068 | 0.996 |

The target check is a substantive result: at rim + 0.2 s, being blocked on the way to the hoop and on the way to
the area around it rank players differently (Spearman 0.75), so the measure depends on where a player is assumed
to be going.

## Pairings

| side | players | pair | ambiguous | none | median_o_best | time_point |
| --- | --- | --- | --- | --- | --- | --- |
| defence | 3515 | 0.271 | 0.003 | 0.726 | 0.094 | release |
| offence | 3515 | 0.079 | 0.006 | 0.916 | 0.000 | release |
| defence | 3250 | 0.314 | 0.006 | 0.680 | 0.106 | rim+0.2 |
| offence | 3250 | 0.109 | 0.011 | 0.881 | 0.000 | rim+0.2 |

Persistence over the 12 frames before t and closing speed of each player's paired opponent:

| time_point | blocker | pairs | median_persistence | held_all_frames | median_dist_ft | median_closing_ft_s |
| --- | --- | --- | --- | --- | --- | --- |
| release | defence |  954 | 1.000 | 0.581 | 3.384 | -0.891 |
| release | offence |  276 | 0.923 | 0.486 | 2.917 | 0.391 |
| rim+0.2 | defence | 1021 | 1.000 | 0.721 | 2.915 | -0.381 |
| rim+0.2 | offence |  353 | 0.923 | 0.465 | 2.892 | 0.024 |

## Does it help predict the rebound? (held-out games): does not degrade

Candidate = Step 04's conditional logit plus the two obstruction features; reference = Step 04's own held-out
predictions. Difference = candidate minus reference per rebound (negative is better); `non_inferior` needs `hi` <
0.02 nats; `superior` needs `hi` < 0 and every drop-one-game mean < 0.

| time_point | metric | episodes | mean_diff | lo | hi | games_better | drop_one_max | non_inferior | superior | ece_candidate | ece_reference | ece_ok |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| release | ll | 703 | 0.0004 | -0.0047 | 0.0054 | 6 | 0.0015 | TRUE | FALSE | 0.0039 | 0.0047 | TRUE |
| release | team_ll | 703 | -0.0013 | -0.0034 | 0.0008 | 7 | -0.0010 | TRUE | FALSE | 0.0039 | 0.0047 | TRUE |
| rim+0.2 | ll | 650 | -0.0022 | -0.0080 | 0.0031 | 7 | -0.0011 | TRUE | FALSE | 0.0088 | 0.0090 | TRUE |
| rim+0.2 | team_ll | 650 | -0.0012 | -0.0043 | 0.0012 | 8 | -0.0006 | TRUE | FALSE | 0.0088 | 0.0090 | TRUE |

| time_point | model | episodes | log_loss | brier | top1 | top3 | team_log_loss | ece |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| release | obstruction_clogit | 703 | 2.2005 | 0.8683 | 0.2304 | 0.5164 | 0.5929 | 0.0039 |
| release | static_clogit | 703 | 2.2001 | 0.8686 | 0.2347 | 0.5078 | 0.5942 | 0.0047 |
| rim+0.2 | obstruction_clogit | 650 | 2.0830 | 0.8465 | 0.2277 | 0.5738 | 0.5741 | 0.0088 |
| rim+0.2 | static_clogit | 650 | 2.0851 | 0.8479 | 0.2108 | 0.5538 | 0.5753 | 0.0090 |

Obstruction coefficients across the ten folds (per standard deviation):

| time_point | term | fold_min | fold_median | fold_max |
| --- | --- | --- | --- | --- |
| release | blocked_by_opp | -0.151 | -0.120 | -0.077 |
| release | blocking_opp | -0.049 | -0.018 | 0.024 |
| rim+0.2 | blocked_by_opp | -0.222 | -0.193 | -0.169 |
| rim+0.2 | blocking_opp | -0.112 | -0.084 | -0.049 |

## Collection, team chance and obstruction contribution (rim + 0.2 s, held-out fold models)

collection = P(the player is credited); team_secures = P(his side secures); contrib_* = predictions minus
predictions with his blocking removed, for him, his teammates (and own team award) and his side. Model-implied
associations, not effects of boxing out.

| role | n | games | collection | team_secures | blocking_opp | contrib_own | contrib_mates | contrib_mates_lo | contrib_mates_hi | contrib_team |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| defence: other | 1950 | 10 | 0.1194 | 0.7066 | 0.1868 | -0.0055 | 0.0098 | 0.0086 | 0.0112 | 0.0044 |
| defence: rim protector |  650 | 10 | 0.1948 | 0.7066 | 0.3501 | -0.0129 | 0.0268 | 0.0241 | 0.0295 | 0.0139 |
| defence: shooter's defender |  650 | 10 | 0.1006 | 0.7066 | 0.1803 | -0.0048 | 0.0083 | 0.0073 | 0.0095 | 0.0035 |
| offence: nearest the hoop |  650 | 10 | 0.1220 | 0.2934 | 0.2595 | -0.0052 | 0.0090 | 0.0082 | 0.0098 | 0.0038 |
| offence: other | 1730 | 10 | 0.0353 | 0.2956 | 0.0441 | -0.0010 | 0.0016 | 0.0012 | 0.0020 | 0.0005 |
| offence: safety |  220 | 10 | 0.0059 | 0.2755 | 0.0050 | -0.0000 | 0.0000 | 0.0000 | 0.0001 | -0.0000 |
| offence: shooter |  650 | 10 | 0.0312 | 0.2934 | 0.1162 | -0.0012 | 0.0034 | 0.0027 | 0.0044 | 0.0023 |

## Box-out labels

Held-aside sample: 40 pairs at rim + 0.2 s (ambiguous 8, close_not_blocking 8, converging 8, post 8, strong 8), pages `step11/review/heldout_*.png`, sheet
`step11/review/reviewer_heldout.csv` (labels: boxout_by_A, boxout_by_B, screen, post_defense, proximity, converging,
help, unclear). The pages show tracks only, not the score, the stratum or who is the blocker.
**Not labelled yet.**

Even when filled, tracking-plot labels measure agreement with a person's reading of the same floor positions, not
contact, so box-out detection and box-out ability stay BLOCKED in this release (config `step11.labels`).

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE |  TRUE |
| mirroring the court left to right changes no feature (largest change, both times) | 4.44e-16 | < 1e-9 |  TRUE |
| rotating players and targets 30 degrees about the hoop changes no feature (largest change) | 3.55e-15 | < 1e-9 |  TRUE |
| every pair score finite; pairs reported at one spot (distance < 0.05 ft) score 0 | TRUE; 0 pairs, max 0 | TRUE; 0 |  TRUE |
| one-foot moves: mean |change| of the two features (worst time and feature) | 0.0544 | <= 0.05 | FALSE |
| one-foot moves: share of players whose pairing changes (worst time) | 0.105 | <= 0.2 |  TRUE |
| target sensitivity: Spearman correlation with the hoop-only target (lowest) | 0.753 | >= 0.8 | FALSE |
| features from frames <= t and t before the credited rebound (every episode and time) | TRUE | TRUE |  TRUE |
| a planted future feature is caught | TRUE | TRUE |  TRUE |
| candidate predictions unchanged when the test game's labels are altered (rim+0.2, fold 1) | TRUE | TRUE |  TRUE |
| Step 04 refitted with its lambdas reproduces its held-out predictions (largest change) | 5.55e-16 / 5.55e-16 | < 1e-9 |  TRUE |
| candidate prediction tables valid (12 outcomes, sum to 1) | 2 | 2 |  TRUE |
| candidate and reference scored on the same episodes at each time | 2 | 2 |  TRUE |
| every candidate fit converged | TRUE | TRUE |  TRUE |
| contribution split adds up (largest |team - own - teammates|) | 2.13e-16 | < 1e-9 |  TRUE |

## Limits

- Floor positions only: no body orientation, arms or contact; positions err by about 1.5 ft on average.
- Targets are fixed points around the hoop, not where the ball goes; the Step 05 map is not validated.
- Ten games; contributions come from a logit's coefficients and describe association, not what a box-out causes.
- No player box-out effects were fitted (the manual allows them only after independent labels pass).
