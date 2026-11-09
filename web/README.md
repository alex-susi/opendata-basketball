# PySport Analytics Cup play viewer — static site

The Shiny play viewer in `src/play_viewer/` as a static site: no server, loads one game period at a time,
and works on phones. R still does all the data work and modelling; this folder only draws what R exports.

Built with Vite, Svelte 5 and TypeScript. Tests run with Vitest.

## Layout

| Path | Holds |
| --- | --- |
| `scripts/export_data.R` | Writes `public/data/` from the Shiny app's caches, through the app's own functions |
| `scripts/parity_reference.R` | Runs filter cases through the real Shiny server and writes `tests/parity_reference.json` |
| `scripts/load_app.R` | Loads `src/play_viewer/` without launching it (shared by both scripts) |
| `scripts/annotations.R` | The annotations the site draws and the Shiny app does not: event locations and context from the event files, season counts from `data/aggregates/` |
| `public/data/` | `meta.json`, `plays.json`, `season.json`, `sample.json` (per-player figures over the ten tracked games, `scripts/sample_stats.R`), `playstyle.json` (archetype probabilities and component scores, `scripts/playstyle.R`), `archetypes.html`, and one `.json` + `.bin` pair per game period |
| `public/logos/` | Optional team logos: `logos.json` maps a team id to an image file in the folder. Without it the scoreboard shows colour dots and the court has no midcourt logo |
| `src/lib/` | Decoding, filters, playback sequence, the trace panel's samples, court and scene drawing, annotations (`annotate.ts` on the court, `context.ts` for the cards, `motion.ts` for speed, acceleration and spacing), court control (`control.ts`, time to ball), team logos (`logos.svelte.ts`) — no framework code |
| `src/components/`, `src/App.svelte` | The three tabs: the viewer (filters, play list, court, trace panel with the play's timeline and a Players tab, playback controls, side panel), Archetypes and Rebounding |
| `tests/parity.test.ts` | Checks the site's filters and decoded plays against the Shiny app |
| `tests/annotations.test.ts` | Checks the exported annotations against the tracking, the plays' viewing windows, and the readouts built from them |
| `tests/control.test.ts` | Checks court control against the archived R implementation (`tests/control_reference.json`) |

## Commands

Run these in `web/` with Node 24 or newer.

```bash
npm install
npm run dev      # local site with hot reload
npm run check    # type and Svelte checks
npm test         # parity tests
npm run build    # production build in dist/
```

## Refreshing the data

Run both scripts from the repository root, in this order, and commit their outputs together. The first test
fails if the reference is older than the export, which stops the deploy.

```bash
Rscript web/scripts/export_data.R
Rscript web/scripts/parity_reference.R
```

The export needs the viewer's caches (`outputs/cache/play_viewer/`, built on the Shiny app's first start). The archetype tags beside each player's name
and the Archetypes tab come from `outputs/archetypes/` (`Rscript src/archetypes/build_features.R`, then
`Rscript src/archetypes/cluster_archetypes.R`); rerun the export after changing the clusters.

The Rebounding tab reads `public/data/rebounding_eda.json`: descriptive tables of the ten games' misses, frozen on
2026-11-06 from the rebounding pipeline when it was archived (`zz_Archive/src/rebounding/`; see
`docs/project/decision_log.md`). No script rewrites it. The tab's wording is in `src/components/Rebounding.svelte`;
its numbers all come from that file.

The EPV, court control and rebounding models, their panels and their data files are archived in `zz_Archive/`
(same paths as before).

### Exploration tabs

Seven tabs (Paint touches, Pre-shot actions, Closeouts, Crashing, Driving lanes, Advantage, Gravity), one per
candidate competition topic, address `#/explore/<topic>`. Each reads `public/data/explore_<topic>.json`, written by
`web/scripts/explore/<topic>.R`; text, charts and tables all come from that script, and
`src/components/explore/` only lays them out (`Explore.svelte`, `Block.svelte`, `DataTable.svelte`). Descriptive
only: counts, means, 90% intervals and simple tracking geometry, no fitted model.

```bash
Rscript web/scripts/explore/build.R                # every topic, about a minute
Rscript web/scripts/explore/build.R paint gravity  # some topics
Rscript web/scripts/explore/build.R --rebuild      # rebuild the per-game bundles first
```

`common.R` builds one cached bundle per game (`outputs/cache/explore/`, git-ignored): event tables, chance
outcomes, the export's cuts, screens and rebounding roles (`cuts.R`, `glass.R`, `annotations.R`, reused unchanged)
and the tracking in the viewer's frame. Rerun with `--rebuild` after changing those scripts.

To change only the wording of the Archetypes tab, edit `src/play_viewer/R/archetype_page.R` and rewrite the page
alone. This leaves the play data and its stamp untouched, so the parity reference stays valid.

```bash
Rscript web/scripts/export_data.R --page
```

Team colours (`TEAM_COLORS` in `src/play_viewer/R/data.R`) are written into each play, so a colour change needs
the full export.

## Deploying

`.github/workflows/deploy-web.yml` checks, tests, builds and publishes `web/dist` to GitHub Pages on every push
to `main` that touches `web/`. One-time setup: in the repository's Settings, Pages, set Source to
"GitHub Actions".

## Differences from the Shiny app

- Multi-select filters are a custom dropdown with checkboxes and a search box instead of selectize.
- The selected play is in the address (`#/play/<id>`), so a view can be shared as a link; the Archetypes tab is `#/archetypes`, the Rebounding tab `#/rebounding` and the exploration tabs `#/explore/<topic>`.
- The Rebounding tab, the trace panel under the court and the resizable left column exist only on the site.
- The Archetypes tab is the Shiny app's page exported as HTML, so its text and numbers are edited in
  `src/play_viewer/R/archetype_page.R`, not here. `public/data/archetypes.html` is overwritten by every export.
- On narrow screens the court comes first, then options and rosters, then filters and the play list.
- Coordinates are stored as scaled integers at the precision the Shiny app already rounds to.

Data: SkillCorner open basketball data (Liga ACB 2025-2026), MIT licence.
