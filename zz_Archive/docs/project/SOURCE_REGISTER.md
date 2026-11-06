# Source register: rebounding manual

Step 00 of "Dynamic Basketball Rebounding Model — Sequential Implementation Manual" (revision 2026-10-29). Every
external source the manual names is listed here with its pinned revision, its licence and what this project may take
from it. Checked 2026-10-29. Machine-readable twin: `outputs/rebounding/gate_results/00_setup.json`.

## Rules

- Third-party checkouts live in `external/` (git-ignored) and are never edited. Each is a shallow clone at the commit
  below; `git -C external/<name> rev-parse HEAD` must print it.
- **No licence file means all rights reserved.** Such repositories are read for ideas only: no code is copied,
  translated line by line or executed. Anything taken from them is written independently from the idea or the
  published method and credited here.
- MIT and CC BY sources may be adapted with attribution; an adaptation is recorded in the "Local adaptation" column
  when it is made, and its notice kept in the adapted file.
- **No outside data.** The competition allows only Analytics Cup data. ReboundingPrediction ships 3.6 GB of NBA
  SportVU games in `data/`; the checkout excludes that folder and the sample `.7z` (sparse checkout), and nothing from
  the other repositories' `data/` folders is read. Their published numbers are background, never inputs.
- The manual's code paths are Python; this project is R (no Python on this machine; see `local-runtimes` memory and
  CLAUDE.md "use the project's existing language"). The manual's file names map to R files listed in
  `docs/project/rebounding.md`.

## Data

| Source | Revision | Licence | Use |
| --- | --- | --- | --- |
| [SkillCorner/opendata-basketball](https://github.com/SkillCorner/opendata-basketball) | Upstream commit `4bbed2e35e8fdd2cf083e8c8b280b3e5381a2c66` (the repository's first commit). Local commit `474a543` replaced each `*_tracking_data.jsonl.gz` with its decompressed `.jsonl`; Step 00 checks that every `.jsonl` is byte-identical to the decompressed upstream `.gz` and that every other `data/` file equals upstream. Checksums: `outputs/rebounding/gate_results/data_checksums.csv` | MIT (`LICENSE`); dataset rights stay with SkillCorner and the competition rules | The only data. Read in place under `data/`, never modified |

## Code and method sources

| Source | Commit (date) | Licence | Files / functions to inspect | Step | What may be taken | Local adaptation |
| --- | --- | --- | --- | --- | --- | --- |
| [riders994/ReboundingPrediction](https://github.com/riders994/ReboundingPrediction) | `5c3e0eadf0bf7f81f1600ac1575fa6783d0bbbc1` (2026-08-24) | None found (no LICENSE, no `pyproject` licence field) | `README.md`; `rebounding/data/pairing.py` (`pair`, `find_release`, `assign_rim_contacts`, `PairingReport`), `data/court.py` (`attacking_basket`, `fold`, `unfold`), `data/derived.py`, `data/features.py`; `models/conditional_logit.py` (`ConditionalLogit`), `models/boosted.py` (`grouped_softmax_objective`); `eval/split.py`, `eval/metrics.py`, `eval/baseline.py`; `serve.py` (`predict`) | 01, 03, 04, 08, 09, 13 | Ideas only: resolve the attacked basket once per shot from the ball and apply one 180° rotation to every entity; bound flight by wall clock, not game clock; count every dropped shot by reason; grouped softmax over the ten players; per-shot (not per-row) top-1; damped-velocity caution | Step 01: per-shot orientation check from the ball at `endFrame` (written independently) |
| [ismayc/tracking-study](https://github.com/ismayc/tracking-study) | `6555fc9a6677f9f17e97cdc83769ff57d55b1f1e` (2026-10-23) | None found | `README.md`; `python/06_possession_join.py` (lead calibration, held-out turnover check), `python/09_frame_coverage.py` (per-period clock coverage gate); `python/11_join_diagnostics.py` | 01, 13 | Ideas only: per-period coverage = distinct running-clock values / (25 × period length) with start gaps; validate a join against an independent signal; extreme-value statistics on noisy tracking measure the noise. Its SportVU latency offsets do not apply (SkillCorner events carry exact frames) | Step 01: `period_coverage()` (written independently) |
| [timseymour42/shotquality-offensive-rebounding](https://github.com/timseymour42/shotquality-offensive-rebounding) | `8af77017f1c14d0e32d428e3e83c3a3620577e1c` (2023-09-06) | None found | `obrd_prediction.ipynb` | 04, 11 | Ideas only: static offensive-team benchmark, angles and distances, inferred box-out matchups | — |
| [djlee9812/basketball-shot](https://github.com/djlee9812/basketball-shot) | `af178baaefb49bae6037b58bfd8d032f8eac6c98` (2026-03-04) | None found | `engine.py` (`get_cd`, `get_acceleration`, `apply_friction`, `resolve_collisions`, `step_rk4`), `constants.py`, `simulate.py`, `vectorized_analysis.py`, `tests/` | 07 | Ideas only. The manual's "port `resolve_collisions` if the licence permits" does **not** apply: physics must be written independently from published mechanics | — |
| [rlabbe/filterpy](https://github.com/rlabbe/filterpy) | `5df4e095fac07684a05c495bd72d3424f7c68c9c` (2026-10-26) | MIT | `filterpy/kalman`, `filterpy/monte_carlo` (resampling) | 06, 07 | Algorithms may be adapted with the MIT notice | — |
| [rlabbe/Kalman-and-Bayesian-Filters-in-Python](https://github.com/rlabbe/Kalman-and-Bayesian-Filters-in-Python) | `04b2bea802321086effbd99402fc13c893d11110` (2024-07-14) | Text CC BY 4.0 (README; `license.html` names CC BY-NC-SA in its text but links CC BY); code MIT | Kalman and particle-filter notebooks | 06, 07 | Explanations with attribution; code under MIT | — |
| [Friends-of-Tracking-Data-FoTD/LaurieOnTracking](https://github.com/Friends-of-Tracking-Data-FoTD/LaurieOnTracking) | `7ed3ff857940d3f4611be55f3c08c79525c32171` (2021-06-15) | MIT | `Metrica_PitchControl.py` (`simple_time_to_intercept` method of the player class, `calculate_pitch_control_at_target`, `default_model_params`), `Metrica_Velocities.py` (`calc_player_velocities`) | 08 | Arrival-time model and velocity smoothing, adapted with the MIT notice | — |
| [dkStephanos/TrueImpactShotCharts](https://github.com/dkStephanos/TrueImpactShotCharts) | `5f2697251581b3e0c3b39fa5c58acc9085c3f292` (2025-02-02) | MIT | `code/`, `notebooks/`, README workflow | 05, 13 | Court and Voronoi plotting ideas, with the MIT notice | — |
| [MatanK77/ReboundingImpact](https://github.com/MatanK77/ReboundingImpact) | `617bca5b2514ca415da9d5cd23aed8a8350779ed` (2023-06-29) | None found | `Rebound Impact Modeling.R`, `Rebound Impact Function.R`, `XGBoost DReb Impact.R`, year-over-year scripts | 10–12 | Ideas only: collecting a rebound vs. helping the team get it. Its NBA CSVs are outside data and are not read | — |
| [Charlychee/Basketball-Trajectory-Prediction](https://github.com/Charlychee/Basketball-Trajectory-Prediction) | `a7d0437da50d357f3df5afc9e1cb074f09f5f53d` (2023-09-19) | None found | `transformerModel.py`, `ballerDataset.py`, `ballJson2Arr.py`, `engineMicro.py`, `engineMacro.py`, notebook | Optional | Ideas only, and only after Step 13 | — |

## Papers and books

| Reference | Local copy | Step | Read for |
| --- | --- | --- | --- |
| Maheswaran et al. (2014), The Three Dimensions of Rebounding, MIT Sloan SSAC | `research/rebounding/three dimensions of rebounding.pdf` | 02, 05, 10, 12 | Positioning (Voronoi-cell value of a shot-conditioned rebound density at release), crash/hustle (regression-normalised gain before the rim; an "opportunity" is being nearest when the ball drops below 10 ft), conversion |
| Okubo & Hubbard (2014), Rebounding strategies in basketball, Procedia Engineering 72 | `research/rebounding/rebounding strategies.pdf` (CC BY-NC-ND) | 02, 05, 07 | Six-sub-model flight/contact simulation; rebound position defined where the ball falls back through hoop height; best player position differs from most likely ball position |
| Okubo & Hubbard (2013), Estimation of rebound position in basketball | `research/rebounding/Estimation_of_Rebound_Position_in_Basketball.pdf` | 05, 07 | Background to the above |
| Maheswaran et al. (2012), Deconstructing the Rebound with Optical Tracking Data | `research/rebounding/deconstructing a rebound.pdf` | 05, 10 | Background |
| Kiriazis, Genest & Leblanc (2025), A Bayesian two-stage framework for lineup-independent assessment of individual rebounding ability, JQAS 21(4) | `research/rebounding/bayesian rebounding.pdf` (CC BY 4.0) | 12 | P(player collects) = P(collects \| team collects) × P(team collects): team-level and within-team abilities |
| Särkkä & Svensson (2023), Bayesian Filtering and Smoothing, 2nd ed., Cambridge | Not held locally | 06, 07 | Filtering vs smoothing, particle filters; obtain before Step 06 |
| SkillCorner primer and data dictionaries | `docs/PRIMER.md`, `docs/data_dictionary/` | 00–02 | Units, clocks, joins, field meanings |
