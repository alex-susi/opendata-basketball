# Step 05: release-time spatial prior of credited rebound locations

Run 2026-10-30 by `src/rebounding/run_step05.R`; settings `config/experiment.yaml` (`step05`, config v3), fixed before any fit;
folds and decision rules are Step 03's frozen harness.

**Target.** The credited rebounder's position at the rebound frame (`rebounds.location` turned into the attack frame).
It is **not** where the ball would land if nobody touched it, and not the first contact (Step 02 BLOCKED). Floor
location only: ball height and time to access are not modelled.

| source | N |
| --- | --- |
| rebounds.location | 625 |
| team award (no location) |  73 |
| tracked rebounder (fallback) |   5 |

Domain: the attacked half court, 46 x 50 cells of 1 sq ft. Inputs at release: shot range and the side the shot
comes from. The realised location is used only as a training target and a score.

## Models

- **uniform**: every cell equal. **zone bins**: distance rings x 6 angle sectors around the hoop, smoothed shares.
- **pooled kernel**: Gaussian kernel density of the training locations (bandwidth by inner leave-one-game-out),
  renormalised over the half court, mixed with the uniform at 2%.
- **range kernel**: pooled shrunk toward the shot range's own density (weight by inner leave-one-game-out).
- **side and range kernel** (confirmatory candidate): as range, with every training shot mirrored to come from the
  same side, and the map mirrored back for a test shot from the other side.

Settings chosen in the folds:

| setting | value | N |
| --- | --- | --- |
| bandwidth | 1.500 | 10 |
| w_range | 0.500 | 10 |
| w_side | 0.500 |  5 |
| w_side | 0.750 |  5 |

## Held-out scores (630 credited locations, 10 games)

Negative log density per sq ft (lower is better); coverage of the 50 / 80 / 95% highest-density regions; mean area.

| model | episodes | nll | area_50 | area_80 | area_95 | coverage_0.5 | coverage_0.8 | coverage_0.95 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| side_range_kde | 630 | 5.816 | 76.543 | 237.394 | 595.416 | 0.587 | 0.819 | 0.954 |
| range_kde | 630 | 5.831 | 75.876 | 236.744 | 608.333 | 0.570 | 0.817 | 0.954 |
| pooled_kde | 630 | 5.858 | 75.889 | 238.252 | 633.530 | 0.559 | 0.829 | 0.957 |
| zone_bins | 630 | 5.957 | 68.240 | 225.946 | 701.208 | 0.478 | 0.789 | 0.949 |
| uniform | 630 | 7.741 | 1150.000 | 1840.000 | 2185.000 | 0.000 | 0.000 | 0.000 |

## Decisions

| candidate | reference | mean_diff | lo | hi | games_better | drop_one_max | superior | confirmatory |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pooled_kde | uniform | -1.8827 | -2.0013 | -1.7668 | 10 | -1.8560 |  TRUE |  TRUE |
| side_range_kde | pooled_kde | -0.0422 | -0.0631 | -0.0197 |  9 | -0.0360 |  TRUE |  TRUE |
| range_kde | pooled_kde | -0.0266 | -0.0369 | -0.0143 |  9 | -0.0241 |  TRUE | FALSE |
| zone_bins | pooled_kde | 0.0987 | 0.0384 | 0.1544 |  1 | 0.1143 | FALSE | FALSE |
| side_range_kde | range_kde | -0.0156 | -0.0373 | 0.0058 |  6 | -0.0111 | FALSE | FALSE |

- Pooled kernel as the baseline (superior to uniform, coverage within 0.05): **BLOCKED**.
- Side and range kernel (superior to pooled, coverage within 0.05): **BLOCKED**.
- Zone bins (exploratory, the broad training-only prior the manual's hard-stop table falls back to when the kernel prior is poorly calibrated): coverage within 0.05 at every level: yes. Adopting it would be a deviation from the prespecified baseline and needs an owner decision.

Coverage with Wilson 95% intervals:

| model | level | n | coverage | lo | hi | mean_area | within_tol |
| --- | --- | --- | --- | --- | --- | --- | --- |
| uniform | 0.500 | 630 | 0.000 | 0.000 | 0.006 | 1150.000 | FALSE |
| zone_bins | 0.500 | 630 | 0.478 | 0.439 | 0.517 | 68.240 |  TRUE |
| pooled_kde | 0.500 | 630 | 0.559 | 0.520 | 0.597 | 75.889 | FALSE |
| range_kde | 0.500 | 630 | 0.570 | 0.531 | 0.608 | 75.876 | FALSE |
| side_range_kde | 0.500 | 630 | 0.587 | 0.548 | 0.625 | 76.543 | FALSE |
| uniform | 0.800 | 630 | 0.000 | 0.000 | 0.006 | 1840.000 | FALSE |
| zone_bins | 0.800 | 630 | 0.789 | 0.755 | 0.819 | 225.946 |  TRUE |
| pooled_kde | 0.800 | 630 | 0.829 | 0.797 | 0.856 | 238.252 |  TRUE |
| range_kde | 0.800 | 630 | 0.817 | 0.785 | 0.846 | 236.744 |  TRUE |
| side_range_kde | 0.800 | 630 | 0.819 | 0.787 | 0.847 | 237.394 |  TRUE |
| uniform | 0.950 | 630 | 0.000 | 0.000 | 0.006 | 2185.000 | FALSE |
| zone_bins | 0.950 | 630 | 0.949 | 0.929 | 0.964 | 701.208 |  TRUE |
| pooled_kde | 0.950 | 630 | 0.957 | 0.938 | 0.970 | 633.530 |  TRUE |
| range_kde | 0.950 | 630 | 0.954 | 0.935 | 0.968 | 608.333 |  TRUE |
| side_range_kde | 0.950 | 630 | 0.954 | 0.935 | 0.968 | 595.416 |  TRUE |

By shot range and game: `coverage_by_shot_range.csv`, `coverage_by_game.csv`. Subgroups:

| model | subgroup | episodes | nll | coverage_80 |
| --- | --- | --- | --- | --- |
| pooled_kde | identity_suspect |  33 | 6.400 | 0.697 |
| side_range_kde | identity_suspect |  33 | 6.426 | 0.667 |
| pooled_kde | location from tracking (fallback) |   5 | 6.005 | 0.800 |
| side_range_kde | location from tracking (fallback) |   5 | 5.909 | 0.800 |
| pooled_kde | low tracking quality | 262 | 5.822 | 0.828 |
| side_range_kde | low tracking quality | 262 | 5.726 | 0.802 |
| pooled_kde | shot range: midrange (other 2s) | 209 | 5.809 | 0.823 |
| side_range_kde | shot range: midrange (other 2s) | 209 | 5.799 | 0.809 |
| pooled_kde | shot range: rim (<5 ft) | 132 | 5.312 | 0.932 |
| side_range_kde | shot range: rim (<5 ft) | 132 | 5.215 | 0.864 |
| pooled_kde | shot range: three | 289 | 6.143 | 0.785 |
| side_range_kde | shot range: three | 289 | 6.102 | 0.806 |

Team awards (73) have no location and are outside this target. Clean catches and tip chains cannot be separated
(Step 02 BLOCKED).

## Figures

- `step05/figures/05_heatmaps_all_games.png`: maps fitted on all ten games (display only).
- `step05/figures/05_heldout_examples.png`: six held-out misses with their out-of-fold map, shooter (triangle) and
  credited location (cross).

## Checks

| check | value | expected | pass |
| --- | --- | --- | --- |
| Step 03 design freeze in force | TRUE | TRUE | TRUE |
| every map sums to 1 over the domain (largest error) | 0 | < 1e-9 | TRUE |
| every map is positive and finite | 3515 | 3515 | TRUE |
| maps exist for every eligible episode and model | 3515 | 3515 | TRUE |
| grid cell area (sq ft) | 1 | 1 | TRUE |
| every player rebound has a location inside the domain | 630 | 630 | TRUE |
| rebounds.location agrees with the tracked rebounder (median gap, ft) | 0 | < 0.5 | TRUE |
| each fold's maps are fitted on exactly its training games' locations | 10 | 10 | TRUE |
| one bandwidth and two weights chosen per fold, from the configured grids | TRUE | TRUE | TRUE |
| held-out locations never reach their own maps (fold 1's locations moved: its maps unchanged) | TRUE | TRUE | TRUE |
| re-running reproduces every score exactly | TRUE | TRUE | TRUE |

## Limits

- The target is where the rebound was credited, which already reflects who reached the ball; it is not a ball
  landing distribution and must not be read as one.
- Ten games; 630 locations. Shot angle enters only as its side; shot distance only as the three ranges.
