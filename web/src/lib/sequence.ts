// Which frames of a possession are played, and where its events sit on the timeline. Pure.
// Ported from www/player.js in the Shiny app (buildSeq, seqIndexOfFrame, cursor, renderTicks, stepAction).

import { clamp } from "./geometry";
import type { Play, PlayEvent, Series } from "./types";

export const FPS = 25;
export const LEAD_IN = 50;   // stopped-clock frames kept before a restart
export const TAIL = 25;      // stopped-clock frames kept after a whistle

// The play holds every live tracking frame of the possession. The sequence lists the indices to show:
// all of them, or (skip dead-ball time) the running-clock frames plus a short run-up to each restart.
export function buildSeq(play: Play, skipDead: boolean): number[] {
  const n = play.frames.length, keep = new Uint8Array(n);
  const joined = (i: number) => play.frames[i + 1] - play.frames[i] === 1;
  if (skipDead) {
    for (let i = 0; i < n; i++) {
      if (play.stopped[i]) continue;
      keep[i] = 1;
      for (let j = i - 1; j >= 0 && i - j <= LEAD_IN && play.stopped[j] && joined(j); j--) keep[j] = 1;
      for (let j = i + 1; j < n && j - i <= TAIL && play.stopped[j] && joined(j - 1); j++) keep[j] = 1;
    }
  }
  if (!skipDead || !keep.includes(1)) keep.fill(1);
  const seq: number[] = [];
  for (let i = 0; i < n; i++) if (keep[i]) seq.push(i);
  return seq;
}

/** First sequence position whose frame is at or after `frame`. */
export function seqIndexOfFrame(play: Play, seq: number[], frame: number): number {
  let lo = 0, hi = seq.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (play.frames[seq[mid]] < frame) lo = mid + 1; else hi = mid;
  }
  return lo;
}

export interface Cursor {
  i0: number;
  i1: number;
  t: number;
}

/** Frame pair and blend weight at a playback position; no blending across a cut in the footage. */
export function cursorAt(play: Play, seq: number[], pos: number): Cursor {
  const k = clamp(Math.floor(pos), 0, seq.length - 1);
  const i0 = seq[k], i1 = seq[Math.min(k + 1, seq.length - 1)];
  return { i0, i1, t: play.frames[i1] - play.frames[i0] === 1 ? pos - k : 0 };
}

/** A series' value at the cursor, or null where it is missing. */
export function blend(series: Series, c: Cursor): number | null {
  const a = series[c.i0], b = series[c.i1];
  if (Number.isNaN(a)) return null;
  return Number.isNaN(b) ? a : a + (b - a) * c.t;
}

/** Degrees a caption is tilted where ticks crowd. Matches the rotations of .tick-label in app.css. */
export const TILT = 20;
const TILT_GAP = 42;    // px between the anchors of neighbouring tilted captions, so their lines stay apart (14px / sin TILT)
const TILT_CAP = 72;    // widest tilted caption (max-width of .tick-label.lean-right / .lean-left); longer text is cut
const CLEAR = 22;       // px along the rail before a tilted caption has risen above a flat one
const RUN = Math.cos((TILT * Math.PI) / 180);

export interface Tick {
  k: number;
  frac: number;
  event: PlayEvent;
  /** Flat: the caption is centred on its tick. Where ticks crowd, captions tilt up from the rail, to the right or left. */
  lean: "flat" | "right" | "left";
  /** Flat: left edge of the caption. Tilted: the anchor on the rail the caption starts from (ends at, leaning left). */
  at: number;
  /** Width of the caption's text, with a little padding. */
  width: number;
}

export interface Timeline {
  ticks: Tick[];
  cuts: number[];
  marks: number[];
}

type Span = [number, number];
const meets = (p: Span, q: Span, pad = 0): boolean => p[0] < q[1] + pad && q[0] < p[1] + pad;
const run = (tick: Tick): number => Math.min(tick.width, TILT_CAP) * RUN;

// Place one group of neighbouring ticks. A tick alone gets a flat caption, centred on it. Ticks that crowd get tilted
// captions, each leaning the way its leader runs (from the tick up to the caption's anchor on the rail): the group's
// first captions lean left, their anchors at or left of their ticks, the rest lean right, anchored at or right of
// theirs. Same-way neighbours are anchored at least `gap` apart (their captions are parallel); the two middle ones,
// leaning apart, MID_GAP. The split between left and right is the one that keeps the leaders shortest with every
// caption on the rail; if no split fits, the old way is used: anchors spread round the group, all leaning one way.
const MID_GAP = 12;   // px between the anchors of the last left-leaning and first right-leaning captions
function place(group: Tick[], width: number): void {
  const x = (tick: Tick) => tick.frac * width;
  if (group.length === 1) {
    const tick = group[0];
    tick.lean = "flat";
    tick.at = clamp(x(tick) - tick.width / 2, 0, Math.max(0, width - tick.width));
    return;
  }
  const n = group.length, xs = group.map(x);
  const gap0 = Math.max(14, Math.min(TILT_GAP, (width - 40) / (n - 1)));
  let best: number[] | null = null, bestSplit = 0, bestCost = Infinity;
  // The widest spacing that lets some split fit (down to 14 px, as crowded rails always allowed).
  for (let gap = gap0; gap >= 14 && !best; gap = gap > 14 ? Math.max(14, gap - 4) : 0) for (let s = 0; s <= n; s++) {
    const at = new Array<number>(n);
    for (let j = s; j < n; j++) at[j] = j === s ? xs[j] : Math.max(xs[j], at[j - 1] + gap);
    for (let i = s - 1; i >= 0; i--) at[i] = i === s - 1 ? (s < n ? Math.min(xs[i], at[s] - MID_GAP) : xs[i]) : Math.min(xs[i], at[i + 1] - gap);
    const fits = group.every((tick, i) => (i < s ? at[i] - run(tick) >= -6 : at[i] + run(tick) <= width + 6));
    if (!fits) continue;
    const cost = at.reduce((c, p, i) => c + Math.abs(p - xs[i]), 0);
    if (cost < bestCost) { best = at; bestSplit = s; bestCost = cost; }
  }
  if (best) {
    group.forEach((tick, i) => { tick.lean = i < bestSplit ? "left" : "right"; tick.at = best![i]; });
    return;
  }
  const at = [...xs];
  for (let i = 1; i < n; i++) at[i] = Math.max(at[i], at[i - 1] + gap0);
  // Centre the spread anchors on their ticks, then keep them on the rail.
  const drift = at.reduce((sum, p, i) => sum + p - xs[i], 0) / n;
  const nudge = Math.max(drift - at[0], Math.min(0, width + drift - at[n - 1]));
  const anchors = at.map((p) => p - drift + nudge);
  const right = Math.max(...group.map((tick, i) => anchors[i] + run(tick)));
  const left = Math.min(...group.map((tick, i) => anchors[i] - run(tick)));
  const lean = right > width + 6 && left >= -6 ? "left" : "right";
  // Leaning right off the end with no room to lean left: slide the anchors back instead.
  const slide = lean === "right" ? Math.max(0, Math.min(right - width - 6, anchors[0])) : 0;
  group.forEach((tick, i) => {
    tick.lean = lean;
    tick.at = anchors[i] - slide;
  });
}

// Where one caption sits: along the rail at the height of flat captions (`low`), and its tilted run (`high`).
function low(tick: Tick): Span {
  if (tick.lean === "flat") return [tick.at, tick.at + tick.width];
  return tick.lean === "right" ? [tick.at - 4, tick.at + CLEAR] : [tick.at - CLEAR, tick.at + 4];
}
const high = (tick: Tick): Span => (tick.lean === "left" ? [tick.at - run(tick), tick.at] : [tick.at, tick.at + run(tick)]);

// Whether two groups' captions would collide: overlapping near the rail, a right-leaning caption running into a
// left-leaning one anchored further along, or two parallel ones whose anchors are under TILT_GAP apart. (A
// left-leaning caption and a right-leaning one anchored further along lean apart.)
function collide(g: Tick[], h: Tick[]): boolean {
  for (const a of g) {
    for (const b of h) {
      if (meets(low(a), low(b), 4)) return true;
      if (a.lean === "flat" || b.lean === "flat" || !meets(high(a), high(b), 4)) continue;
      const [l, r] = a.at <= b.at ? [a, b] : [b, a];
      if (l.lean === "right" && r.lean === "left") return true;
      if (a.lean === b.lean && Math.abs(b.at - a.at) < TILT_GAP) return true;
    }
  }
  return false;
}

// Ticks for the possession's events, each captioned with the action above it and the player below. Captions that
// would overlap are tilted instead (see place); groups are merged until no two collide.
export function layoutTimeline(play: Play, seq: number[], width: number, measure: (text: string) => number): Timeline {
  const end = Math.max(1, seq.length - 1);
  const cuts: number[] = [];
  let groups: Tick[][] = [];
  for (let k = 1; k < seq.length; k++) {
    if (play.frames[seq[k]] - play.frames[seq[k - 1]] > 1) cuts.push(k / end);
  }
  for (const { k, event } of eventsInSeq(play, seq)) {
    const w = Math.max(measure(shortScreen(event.short ?? "")) + (event.flag ? 30 : 0), measure(event.who ?? "")) + 8;
    groups.push([{ k, frac: k / end, event, lean: "flat", at: 0, width: w }]);
  }
  groups.sort((g, h) => g[0].k - h[0].k);
  for (;;) {
    for (const group of groups) place(group, width);
    // Any two groups, not only neighbours: a tilted caption can reach past a flat one.
    let hit = -1;
    for (let i = 0; i + 1 < groups.length && hit < 0; i++) {
      for (let j = i + 1; j < groups.length; j++) if (collide(groups[i], groups[j])) { hit = i; break; }
    }
    if (hit < 0) break;
    groups.splice(hit, 2, groups[hit].concat(groups[hit + 1]));
  }
  return { ticks: groups.flat(), cuts, marks: eventMarks(play, seq) };
}

/** Each event that falls inside the sequence, with its sequence position (the timeline's ticks). */
export function eventsInSeq(play: Play, seq: number[]): { k: number; event: PlayEvent }[] {
  if (!seq.length) return [];
  return play.events.flatMap((event) => {
    const k = seqIndexOfFrame(play, seq, event.f);
    return Math.abs(play.frames[seq[k]] - event.f) > LEAD_IN ? [] : [{ k, event }];
  });
}

/** Sequence positions of the events, in order, without repeats: what the previous/next action buttons step to. */
export function eventMarks(play: Play, seq: number[]): number[] {
  return [...new Set(eventsInSeq(play, seq).map((e) => e.k))].sort((p, q) => p - q);
}

/** Position of the next action, or of the previous one (the current one counts as passed after half a second). */
export function stepAction(marks: number[], pos: number, direction: 1 | -1, last: number): number {
  const target = direction > 0 ? marks.find((k) => k > pos + 1) : marks.slice().reverse().find((k) => k < pos - 12);
  return target ?? (direction > 0 ? last : 0);
}

/** The offensive or defensive player whose touch covers a frame, if any. */
export function ballHandler(play: Play, frame: number): number | null {
  let pid: number | null = null;
  for (const t of play.touches) if (t.f0 <= frame && frame <= t.f1) pid = t.pid;
  return pid;
}

/** A caption shortened for the trace panel and the play list: "Screen" becomes "Scr". */
export const shortScreen = (text: string): string => text.replace(/\bScreen\b/g, "Scr");
