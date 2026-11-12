# Screen coverage: archived scripts

Archived on 2026-11-12. These scripts are kept as the record of earlier work, not as part of the current pipeline
(`screen_coverage/01_scripts/01_logistic_baseline.R` to `06_export_live.R`). The archive uses the project's own
layout: scripts in `01_scripts/`, caches in `02_cache/`, results in `03_outputs/`. See
`screen_coverage/04_docs/screen_coverage_reads.html` (change log) for what each one found.

| Script (`01_scripts/`) | What it was | Why archived |
|---|---|---|
| `01_lead_time_baseline.R` | First model: logistic snapshots at -0.8, -0.4, 0, +0.4 s; made the film-check list | Uses the old position lookup (up to 2 frames ahead) and the league-mix "so far"; superseded by the per-frame pipeline |
| `03_build_tokens.R` | Ten-player tokens for the token transformers | Only fed the token transformers |
| `04_train_transformer.R` | Four token-transformer variants (timed, archetypes, pooled, closeness) | Superseded by the time-aware transformer; not rebuilt under the past-only rules |
| `05_compare.R`, `06_classification.R`, `11_compare_seq.R` | Comparisons of the token transformers, the per-frame logistic models and the time-aware transformer | Depended on the token transformers and the per-frame logistic models told when the screen comes |
| `08_geometry_context.R` | Screen geometry, re-screens and context; features for the site's ice/blitz section | One-off test (no gain); old position lookup and league-mix "so far" |
| `R/transformer.R` | The token transformer module | Used only by `04_train_transformer.R` |
| `R/predictions.R` | Copy of the loaders as of 2026-11-12, including the token-transformer loaders | The active `screen_coverage/01_scripts/R/predictions.R` keeps only the live model's loaders |

They are not runnable as they stand. Their paths were updated to this layout on 2026-11-12 (outputs to
`zz_Archive/03_outputs/`, caches to `zz_Archive/02_cache/`), but they expect the per-frame features and token caches
of the v1 rules, while the current caches are built under different rules (`PAST_ONLY_RULES` in
`screen_coverage/01_scripts/R/past_only.R`). The site's ice/blitz section (`web/scripts/explore/coverage.R`) reads
`08_geometry_context.R`'s saved output from `screen_coverage/zz_Archive/03_outputs/context/`.
