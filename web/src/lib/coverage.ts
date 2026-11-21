// Live screen-coverage probabilities for the Coverage Read card (Annotations.svelte).
//
// coverage_frames.json is written by screen_coverage/01_scripts/06_export_live.R (live model: the time-aware transformer with
// two linked heads, 10_train_seq_transformer.R, unless another is exported): for every on-ball screen it scored, the
// held-out probability of each joint call (over + show, over + drop, under + drop, under + show, switch) at every
// frame from 2 s before the screen tag to 1 s after it. The live model (named in the file's `model`) is never told when
// the screen comes: it reads each of the ten players' last 1.6 s, time to act, the defense's earlier calls in the game
// and how close the handler has come to the screener; each game's screens come from the network trained without that
// game. The card shows each frame's raw value and sums it to each
// defender's call (the Raw / 0.08 s average switch was removed 2026-11-16). (The file's smooth_frames, 5, is no longer used.)

export interface CoverageScreen {
  id: string;
  /** Screen tag frame (picks.frame). */
  f0: number;
  /** Ball handler, screener, the handler's defender and the screener's defender (raw game ids). */
  h: number; s: number; bd: number; sd: number;
  /** The call SkillCorner tagged. */
  call: string;
  /** Whole-percent probability of each call (outer: calls, inner: frames from offsets[0] to offsets[1]). */
  p: number[][];
}

export interface CoverageFile {
  model: string;
  smooth_frames: number;
  /** First and last frame offset relative to the tag, inclusive. */
  offsets: [number, number];
  calls: string[];
  generated: string;
  possessions: Record<string, CoverageScreen[]>;
}

const base = `${import.meta.env.BASE_URL}data/`;
let file: Promise<CoverageFile | null> | null = null;

/** Fetched once; null when the file has not been exported (the card then stays hidden). */
export function loadCoverage(): Promise<CoverageFile | null> {
  file ??= fetch(`${base}coverage_frames.json`, { cache: "no-cache" })
    .then((r) => (r.ok ? (r.json() as Promise<CoverageFile>) : null))
    .catch(() => null);
  return file;
}

export interface CoverageRead {
  screen: CoverageScreen;
  /** Seconds relative to the tag (negative = before the screen). */
  t: number;
  /** Whole-percent probability per call at the frame, in the file's call order. */
  pct: number[];
}

/** The scored screen with this pick frame in a possession, or null (not scored: tracking incomplete, or a coverage
 * outside the five). */
export function screenAt(cov: CoverageFile, possession: string, f0: number): CoverageScreen | null {
  return cov.possessions[possession]?.find((s) => s.f0 === f0) ?? null;
}

/** A scored screen's whole-percent probabilities at a frame, or null outside its −2 s to +1 s window. */
export function readAt(cov: CoverageFile, screen: CoverageScreen, frame: number): CoverageRead | null {
  const [lo, hi] = cov.offsets;
  const o = Math.round(frame - screen.f0);
  if (o < lo || o > hi) return null;
  return { screen, t: o / 25, pct: screen.p.map((series) => series[o - lo]) };
}

/** A scored screen's probabilities from the start of its window up to a frame (all of it when `upTo` is null): the
 * time trace. Each point is [seconds from the pick frame, the five whole percents]. */
export function traceOf(cov: CoverageFile, screen: CoverageScreen, upTo: number | null): [number, number[]][] {
  const [lo, hi] = cov.offsets;
  const last = upTo == null ? hi : Math.min(hi, Math.round(upTo - screen.f0));
  const out: [number, number[]][] = [];
  for (let o = lo; o <= last; o++) out.push([o / 25, screen.p.map((series) => series[o - lo])]);
  return out;
}

// ---- probability strips (as in screen_coverage/03_outputs/evaluation/figures/strips, R/strips.R) -----------------
// A strip stacks the series bottom to top, each point scaled to 100% (the exported whole percents can sum to 99-101).

/** The strips' colours (R/strips.R STRIP_COLS and PART_COLS). */
export const STRIP_COLORS: Record<string, string> = {
  "over + show": "#2a78d6", "over + drop": "#eb6834", "under + drop": "#1baf7a", "under + show": "#eda100", switch: "#e87ba4",
  over: "#2a78d6", under: "#1baf7a", show: "#eda100", drop: "#eb6834",
};
export const BALL_PARTS = ["over", "under", "switch"];
export const BIG_PARTS = ["show", "drop", "switch"];

/** One defender's options summed from the joint percentages, in `labels` order (over = over + show + over + drop). */
export function partSeries(calls: string[], pct: number[], labels: string[]): number[] {
  return labels.map((label) => calls.reduce((s, c, j) => s + (c.split(" + ").includes(label) ? pct[j] : 0), 0));
}

/** SVG polygon points for each series of a stacked strip, bottom series first. `points` are [seconds from the pick
 * frame, values]; the x axis runs from −2 s to +1 s across `width`, 0-100% up `height`. */
export function stripPolygons(points: [number, number[]][], width: number, height: number): string[] {
  if (points.length < 2) return [];
  const x = (t: number) => (((t + 2) / 3) * width).toFixed(1);
  const cums = points.map(([, v]) => {
    const total = v.reduce((a, b) => a + b, 0) || 1;
    let c = 0;
    return [0, ...v.map((u) => (c += u / total))];
  });
  return points[0][1].map((_, k) => {
    const up = points.map(([t], i) => `${x(t)},${(height * (1 - cums[i][k + 1])).toFixed(1)}`);
    const down = points.map(([t], i) => `${x(t)},${(height * (1 - cums[i][k])).toFixed(1)}`).reverse();
    return [...up, ...down].join(" ");
  });
}

// "No clear favorite" (provisional display rule, Phase 3): the leading coverage is called favored only when it has
// at least FAVORED_MIN percent AND leads the second by at least FAVORED_GAP points. Both are display choices to be set
// on validation games in Phase 5, never on the held-out games.
export const FAVORED_MIN = 45;
export const FAVORED_GAP = 10;
/** The leading coverage, the runner-up, and whether the lead is clear enough to call it favored. */
export function favorite(calls: string[], pct: number[]): { top: number; second: number; clear: boolean } {
  const order = pct.map((v, j) => [v, j] as const).sort((a, b) => b[0] - a[0]);
  const [top, second] = [order[0][1], order[1][1]];
  return { top, second, clear: pct[top] >= FAVORED_MIN && pct[top] - pct[second] >= FAVORED_GAP };
}

// ---- the live model's attention (the Display panel's Model Attention toggle) -----------------------------------
// coverage_attention.json (06_export_live.R): for each screen, its players (r, the four of the screen first) and, at
// every frame of the window, which roster player sits in token rows 5-10 (k, indices into r) and the whole-percent
// share of the four screen players' attention going to each of the ten rows (w). Attention says which players' rows
// the model mixed in, not which players caused the call.

export interface AttentionScreen { id: string; f0: number; r: number[]; k: number[][]; w: number[][] }
export interface AttentionFile { model: string; offsets: [number, number]; generated: string; possessions: Record<string, AttentionScreen[]> }

let attFile: Promise<AttentionFile | null> | null = null;
/** Fetched once, the first time the toggle is on; null when the file has not been exported. */
export function loadCoverageAttention(): Promise<AttentionFile | null> {
  attFile ??= fetch(`${base}coverage_attention.json`, { cache: "no-cache" })
    .then((r) => (r.ok ? (r.json() as Promise<AttentionFile>) : null))
    .catch(() => null);
  return attFile;
}

/** Attention share (0-1) per player id at a frame, for the screen with pick frame f0 (the one the coverage read
 * follows, lib/coverageView.svelte.ts); null outside its window or without a screen. */
export function attentionAt(att: AttentionFile, possession: string, frame: number, f0: number | null): Map<number, number> | null {
  const best = f0 == null ? null : att.possessions[possession]?.find((s) => s.f0 === f0);
  if (!best) return null;
  const [lo, hi] = att.offsets;
  if (frame - best.f0 < lo || frame - best.f0 > hi) return null;
  const i = Math.round(frame - best.f0) - lo;
  const w = best.w[i], k = best.k[i];
  if (!w || !k) return null;
  const pids = [best.r[0], best.r[1], best.r[2], best.r[3], ...k.map((j) => best!.r[j])];
  const out = new Map<number, number>();
  pids.forEach((pid, j) => out.set(pid, (out.get(pid) ?? 0) + w[j] / 100));
  return out;
}

// ---- the roll-lane experiment (the Display panel's Roll Lanes toggle) ---------------------------------------
// coverage_lanes.json (screen_coverage/01_scripts/09_lane_figures.R): for each screen, its screener (s), its three
// off-ball defenders (r) and, at every frame of the window, each defender's gap to the screener-to-rim lane (d) and
// how fast that gap closed over the last 0.2 s (c), both in tenths and null when not valid. These are the inputs of
// the experimental variant B, not the live model.

export interface LaneScreen { id: string; f0: number; s: number; r: number[]; d: (number | null)[][]; c: (number | null)[][] }
export interface LanesFile { experiment: string; offsets: [number, number]; generated: string; possessions: Record<string, LaneScreen[]> }
export interface LaneHelper { pid: number; d: number | null; c: number | null }
export interface LaneFrame { screener: number; helpers: LaneHelper[] }

let lanesFile: Promise<LanesFile | null> | null = null;
/** Fetched once, the first time the toggle is on; null when the file has not been exported. */
export function loadCoverageLanes(): Promise<LanesFile | null> {
  lanesFile ??= fetch(`${base}coverage_lanes.json`, { cache: "no-cache" })
    .then((r) => (r.ok ? (r.json() as Promise<LanesFile>) : null))
    .catch(() => null);
  return lanesFile;
}

/** The screener and each off-ball defender's lane values at a frame, for the screen with pick frame f0 (the one the
 * coverage read follows); null outside its window or without a screen. */
export function lanesAt(file: LanesFile, possession: string, frame: number, f0: number | null): LaneFrame | null {
  const best = f0 == null ? null : file.possessions[possession]?.find((s) => s.f0 === f0);
  if (!best) return null;
  const [lo, hi] = file.offsets;
  if (frame - best.f0 < lo || frame - best.f0 > hi) return null;
  const i = Math.round(frame - best.f0) - lo;
  const tenth = (v: number | null | undefined) => (v == null ? null : v / 10);
  return { screener: best.s, helpers: best.r.map((pid, h) => ({ pid, d: tenth(best!.d[h]?.[i]), c: tenth(best!.c[h]?.[i]) })) };
}

// ---- each defender's part of the call -----------------------------------------------------------------------
// The joint calls split into the ball handler's defender (over, under, switch) and the screener's defender (show,
// drop, switch); a defender's probability is the sum of the joint calls with his part, e.g. over = over + show +
// over + drop. Switch is one call for both.

export interface PartRow { label: string; pct: number; top: boolean }
export const PART_COLORS: Record<string, string> = { over: "#3987e5", under: "#199e70", switch: "#d55181", show: "#c98500", drop: "#d95926" };

function parts(calls: string[], pct: number[], labels: string[]): PartRow[] {
  const rows = labels.map((label) => ({ label, pct: calls.reduce((s, c, j) => s + (c.split(" + ").includes(label) ? pct[j] : 0), 0), top: false }));
  const best = rows.reduce((a, b) => (b.pct > a.pct ? b : a), rows[0]);
  best.top = true;
  return rows;
}
/** The ball handler's defender's and the screener's defender's probabilities from the joint-call percentages. */
export function defenderParts(calls: string[], pct: number[]): { ball: PartRow[]; big: PartRow[] } {
  return { ball: parts(calls, pct, ["over", "under", "switch"]), big: parts(calls, pct, ["show", "drop", "switch"]) };
}
/** A tagged joint call's part for one defender ("under + drop" -> "under" / "drop"; "switch" -> "switch"). */
export const partOf = (call: string, which: "ball" | "big"): string => (call === "switch" ? "switch" : call.split(" + ")[which === "ball" ? 0 : 1]);
