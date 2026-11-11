// Live screen-coverage probabilities for the Coverage Read card (Annotations.svelte).
//
// coverage_frames.json is written by src/screen_coverage/07_export_live.R: for every on-ball screen it scored, the
// held-out probability of each joint call (over + show, over + soft, under + soft, under + show, switch) at every
// frame from 2 s before the screen tag to 1 s after it. The live model (named in the file's `model`) is the transformer
// that is never told when the screen comes: all ten players at that frame and 0.24 s earlier, the shot clock, the
// defense's earlier calls in the game and the handler-screener closeness; each game's screens come from the network
// trained without that game. The card smooths them over the last few frames (never a later one).

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
  /** Smoothed whole-percent probability per call, in the file's call order. */
  pct: number[];
}

/** The read at a frame: the screen whose window holds the frame (the nearest tag when windows overlap), and its
 * probabilities averaged over the last `smooth_frames` frames up to this one. Null outside every window. */
export function coverageAt(cov: CoverageFile, possession: string, frame: number): CoverageRead | null {
  const list = cov.possessions[possession];
  if (!list?.length) return null;
  const [lo, hi] = cov.offsets;
  let best: CoverageScreen | null = null;
  for (const s of list) {
    const o = frame - s.f0;
    if (o < lo || o > hi) continue;
    if (!best || Math.abs(o) < Math.abs(frame - best.f0)) best = s;
  }
  if (!best) return null;
  const k = Math.round(frame - best.f0) - lo;
  const from = Math.max(0, k - cov.smooth_frames + 1);
  const pct = best.p.map((series) => {
    let sum = 0;
    for (let i = from; i <= k; i++) sum += series[i];
    return sum / (k - from + 1);
  });
  return { screen: best, t: (frame - best.f0) / 25, pct };
}

// ---- the live model's attention (the Display panel's Model Attention toggle) -----------------------------------
// coverage_attention.json (07_export_live.R): for each screen, its players (r, the four of the screen first) and, at
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

/** Attention share (0-1) per player id at a frame, from the screen whose window holds it; null outside every window. */
export function attentionAt(att: AttentionFile, possession: string, frame: number): Map<number, number> | null {
  const list = att.possessions[possession];
  if (!list?.length) return null;
  const [lo, hi] = att.offsets;
  let best: AttentionScreen | null = null;
  for (const s of list) {
    const o = frame - s.f0;
    if (o < lo || o > hi) continue;
    if (!best || Math.abs(o) < Math.abs(frame - best.f0)) best = s;
  }
  if (!best) return null;
  const i = Math.round(frame - best.f0) - lo;
  const w = best.w[i], k = best.k[i];
  if (!w || !k) return null;
  const pids = [best.r[0], best.r[1], best.r[2], best.r[3], ...k.map((j) => best!.r[j])];
  const out = new Map<number, number>();
  pids.forEach((pid, j) => out.set(pid, (out.get(pid) ?? 0) + w[j] / 100));
  return out;
}
