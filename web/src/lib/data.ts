// Fetches the exported files. Each file is requested once; period files are kept for the last few periods viewed.
// Requests carry the export's stamp (set at build time in vite.config.ts): the files keep their names from one
// export to the next, so without it a browser can run a new build against an older export it has cached.

import { decodePlay } from "./decode";
import type { ControlParams } from "./control";
import type { ReboundGame } from "./rebounding";
import type { Meta, PeriodIndex, Play, PlayRow } from "./types";

declare const __DATA_STAMP__: string;

const base = `${import.meta.env.BASE_URL}data/`;
const version = `?v=${encodeURIComponent(__DATA_STAMP__)}`;
const KEEP_PERIODS = 8;

async function fetchOk(name: string): Promise<Response> {
  const response = await fetch(base + name + version);
  if (!response.ok) throw new Error(`Could not load ${name} (${response.status})`);
  return response;
}

let meta: Promise<Meta> | null = null;
export function loadMeta(): Promise<Meta> {
  return (meta ??= fetchOk("meta.json").then((r) => r.json()));
}

let plays: Promise<PlayRow[]> | null = null;
export function loadPlays(): Promise<PlayRow[]> {
  return (plays ??= fetchOk("plays.json").then((r) => r.json()));
}

let archetypes: Promise<string> | null = null;
/** The Archetypes tab as the Shiny app renders it: an HTML fragment written by the export. */
export function loadArchetypes(): Promise<string> {
  archetypes ??= fetchOk("archetypes.html").then((r) => r.text());
  archetypes.catch(() => { archetypes = null; });
  return archetypes;
}

interface Period {
  index: PeriodIndex;
  buffer: ArrayBuffer;
}

const periods = new Map<string, Promise<Period>>();

function loadPeriod(file: string): Promise<Period> {
  let period = periods.get(file);
  if (!period) {
    period = Promise.all([fetchOk(`${file}.json`).then((r) => r.json()), fetchOk(`${file}.bin`).then((r) => r.arrayBuffer())])
      .then(([index, buffer]) => ({ index, buffer }));
    period.catch(() => periods.delete(file));
  }
  // Re-insert so the map's order is least recently used first, then drop the oldest.
  periods.delete(file);
  periods.set(file, period);
  for (const key of periods.keys()) {
    if (periods.size <= KEEP_PERIODS) break;
    periods.delete(key);
  }
  return period;
}

/** One possession's tracking and EPV prices, decoded from its game period's file. */
export async function loadPlay(row: PlayRow): Promise<Play> {
  const { index, buffer } = await loadPeriod(row.file);
  const header = index.plays[row.id];
  if (!header) throw new Error(`${row.id} is missing from ${row.file}.json`);
  return decodePlay(buffer, header);
}

// The rebounding files are re-exported on their own (src/rebounding/run_export.R) without a new play export, so
// they cannot rely on the play stamp: rebounding.json is revalidated on every load and its own `built` stamp is
// sent with each game's file.
let reboundDoc: Promise<{ built: string }> | null = null;
/** Every table the Rebounding tab shows (rebounding.json). */
export function loadReboundDoc<T>(): Promise<T> {
  reboundDoc ??= fetch(`${base}rebounding.json`, { cache: "no-cache" }).then((r) => {
    if (!r.ok) throw new Error(`Could not load rebounding.json (${r.status})`);
    return r.json();
  });
  reboundDoc.catch(() => { reboundDoc = null; });
  return reboundDoc as Promise<T>;
}

const rebounds = new Map<number, Promise<ReboundGame | null>>();
/** One game's rebound forecasts (rebounding/<game>.json), or null when the export has none. */
export function loadRebounds(game: number): Promise<ReboundGame | null> {
  let p = rebounds.get(game);
  if (!p) {
    p = loadReboundDoc<{ built: string }>()
      .then((doc) => fetch(`${base}rebounding/${game}.json?v=${encodeURIComponent(doc.built)}`))
      .then((r) => (r.ok ? (r.json() as Promise<ReboundGame>) : null))
      .catch(() => null);
    // A failed load is not remembered, so the next play of the game asks again.
    p.then((g) => { if (!g) rebounds.delete(game); });
    rebounds.set(game, p);
  }
  return p;
}

let control: Promise<ControlParams | null> | null = null;
/** Court control parameters (control.json). Null when the export has none, so the viewer runs without the overlay. */
export function loadControl(): Promise<ControlParams | null> {
  return (control ??= fetchOk("control.json").then((r) => r.json() as Promise<ControlParams>).catch(() => null));
}
