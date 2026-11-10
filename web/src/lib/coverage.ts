// Live screen-coverage probabilities for the Coverage Read card (Annotations.svelte).
//
// coverage_frames.json is written by src/screen_coverage/02_per_frame.R: for every on-ball screen it scored, the
// held-out probability of each joint call (over + show, over + soft, under + soft, under + show, switch) at every
// frame from 2 s before the screen tag to 1 s after it. Each frame's numbers come from a logistic model that sees only
// the four players of the screen at that frame and 0.24 s earlier, the shot clock, and the defense's earlier calls in
// the game; it was fitted on the other nine games. The card smooths them over the last few frames (never a later one).

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
