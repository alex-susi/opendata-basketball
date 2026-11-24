# Progress

Updated 2026-11-24 (Phase 4 closed with the owner's window-end and pass choices).

## Current phase

Screen coverage product plan (`docs/project/Screen_Coverage_Product_Model_Dashboard_Plan_20261120.html`), all part of the Dec 17 entry, aiming to finish by Dec 11. Work stops after each phase for the owner's review.

| Phase | What | Status |
| --- | --- | --- |
| 2 | Freeze and reproduce the live model | Done 2026-11-21 |
| 3 | Replay prototype (screen selection, Reveal, phone layout) and the 40–60-play review panel | Pass 1 done and summarised 2026-11-23 · Pass 2 (12 plays, blind) due about 2026-11-26 |
| 4 | Timing, episode ownership and per-time eligibility | Done 2026-11-24 · window ends at +1.5 s, a pass by the handler stops the forecast (episode rules version 2) |
| 5 | Evaluation report and matched baseline. Owner picks the primary score | Not started · waits for the primary score and the owner's go |
| 6 | B4, B2, B5 one at a time, then combinations | Waits for owner sign-off on evaluation |
| 7 | Replay and scouting dashboard | Not started |
| — | README, pitch video, submission | Due Dec 17 (internal) |

## Completed

- Phase 2 · release `live_2026-11-19_switch_positions` frozen (`screen_coverage/01_scripts/34_freeze_release.R`). Saved networks and a one-start retrain reproduce exactly, past-only test passes, weighted scores unchanged, web checks pass.
- Phase 3 · pause-and-reveal Screen Coverage Read (pinned screens, Predict / Full review, phone layout), review panel (`?review`), 50-play sample (`35_review_sample.R`). Task definition and review instructions in `docs/project/coverage_product_task.md`.
- Phase 3 · play review Pass 1 (50 of 50) summarised by `36_review_summary.R`. Findings, candidate episode-boundary rules and gallery in `docs/project/coverage_review_findings.md`.
- Phase 4 · timing audit (`37_audit_timing.R`), episode and eligibility rules (`R/episode_eligibility.R`), availability sensitivities on the logistic baseline (`38_availability_sensitivity.R`). Write-up in `docs/project/coverage_timing_audit.md`. Owner's choices 2026-11-24 · +1.5 s window end and a stop at the handler's pass. 124,664 eligible rows over all 1,496 five-coverage screens.

## Next action

- Owner · Pass 2 on the 12 marked plays about 2026-11-26, without opening `review_component_check.csv` or the strata file. Export to `screen_coverage/03_outputs/product_review/review_cases.csv` again.
- Then rerun `36_review_summary.R` for pass agreement and close Phase 3.
- Owner decisions before Phase 5 · the primary score (the review puts the useful forecast stretch at about −0.3 s to +0.5 s) and the "Forecast helpful from" wording.

## Blockers and dependencies

- Pass 2 agreement closes Phase 3. Phase 5 starts on the owner's go once the primary score is chosen.
