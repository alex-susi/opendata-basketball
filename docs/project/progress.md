# Progress

Updated 2026-11-21 (Phase 3 built).

## Current phase

Screen coverage product plan (`docs/project/Screen_Coverage_Product_Model_Dashboard_Plan_20261120.html`), all part of the Dec 17 entry, aiming to finish by Dec 11. Work stops after each phase for the owner's review.

| Phase | What | Status |
| --- | --- | --- |
| 2 | Freeze and reproduce the live model | Done 2026-11-21 |
| 3 | Replay prototype (screen selection, Reveal, phone layout) and the 40–60-play review panel | Built 2026-11-21 · waiting on the owner's review |
| 4 | Timing, episode ownership and per-time eligibility | Not started |
| 5 | Evaluation report and matched baseline. Owner picks the primary score | Not started |
| 6 | B4, B2, B5 one at a time, then combinations | Waits for owner sign-off on evaluation |
| 7 | Replay and scouting dashboard | Not started |
| — | README, pitch video, submission | Due Dec 17 (internal) |

## Completed

- Phase 2 · release `live_2026-11-19_switch_positions` frozen (`screen_coverage/01_scripts/34_freeze_release.R`). Saved networks and a one-start retrain reproduce exactly, past-only test passes, weighted scores unchanged, web checks pass.
- Phase 3 · pause-and-reveal Screen Coverage Read (pinned screens, Predict / Full review, phone layout), review panel (`?review`), 50-play sample (`35_review_sample.R`). Task definition and review instructions in `docs/project/coverage_product_task.md`.

## Next action

- Owner · review the 50 plays on the panel (`http://localhost:5173/?review`), export `review_cases.csv` into `screen_coverage/03_outputs/product_review/`. A few days later, Pass 2 on the 12 marked plays.
- Then Phase 3 wrap-up · agreement between passes, reviewed decision moments, ambiguous cases and episode-boundary rules, a short gallery. Then Phase 4.

## Blockers and dependencies

- The owner's play review (40–60 plays, then 10–12 repeated) gates Phase 4's timing rules and the choice of primary score.
