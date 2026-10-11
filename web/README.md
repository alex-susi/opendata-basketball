# ACB play viewer — static site

The Shiny play viewer in `src/play_viewer/` as a static site: no server, loads one game period at a time,
and works on phones. R still does all the data work and modelling; this folder only draws what R exports.

Built with Vite, Svelte 5 and TypeScript. Tests run with Vitest.

## Layout

| Path | Holds |
| --- | --- |
| `scripts/export_data.R` | Writes `public/data/` from the Shiny app's caches, through the app's own functions |
| `scripts/parity_reference.R` | Runs filter cases through the real Shiny server and writes `tests/parity_reference.json` |
| `scripts/load_app.R` | Loads `src/play_viewer/` without launching it (shared by both scripts) |
| `public/data/` | `meta.json`, `plays.json`, `archetypes.html`, and one `.json` + `.bin` pair per game period |
| `src/lib/` | Decoding, filters, playback sequence, EPV lookup, court and scene drawing — no framework code |
| `src/components/`, `src/App.svelte` | The two tabs: the viewer (filters, play list, court, transport bar, side panel) and Archetypes |
| `tests/parity.test.ts` | Checks the site's filters and decoded plays against the Shiny app |

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

The export needs the viewer's caches (`outputs/cache/play_viewer/`, built on the Shiny app's first start) and,
for the EPV overlay, the prices from `Rscript src/epv/build_epv.R`. The archetype tags beside each player's name
and the Archetypes tab come from `outputs/archetypes/` (`Rscript src/archetypes/build_features.R`, then
`Rscript src/archetypes/cluster_archetypes.R`); rerun the export after changing the clusters or their wording.

## Deploying

`.github/workflows/deploy-web.yml` checks, tests, builds and publishes `web/dist` to GitHub Pages on every push
to `main` that touches `web/`. One-time setup: in the repository's Settings, Pages, set Source to
"GitHub Actions".

## Differences from the Shiny app

- Multi-select filters are a custom dropdown with checkboxes and a search box instead of selectize.
- The selected play is in the address (`#/play/<id>`), so a view can be shared as a link; the Archetypes tab is `#/archetypes`.
- The Archetypes tab is the Shiny app's page exported as HTML, so its text and numbers are edited in
  `src/play_viewer/R/archetype_page.R`, not here.
- On narrow screens the court comes first, then options and rosters, then filters and the play list.
- Coordinates and prices are stored as scaled integers at the precision the Shiny app already rounds to.

Data: SkillCorner open basketball data (Liga ACB 2025-2026), MIT licence.
