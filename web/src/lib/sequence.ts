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
export const TILT = 24;
const TILT_GAP = 36;    // px between the anchors of neighbouring tilted captions, so their lines stay apart
const TILT_CAP = 94;    // widest tilted caption (max-width of .tick-label.lean-right / .lean-left); longer text is cut
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

// Place one group of neighbouring ticks. A tick alone gets a flat caption. Ticks that crowd get tilted captions:
// their anchors are spread TILT_GAP apart around the group (closer if the rail is too short for that), and the
// group leans left if it would run off the right.
function place(group: Tick[], width: number): void {
  const x = (tick: Tick) => tick.frac * width;
  if (group.length === 1) {
    const tick = group[0];
    tick.lean = "flat";
    tick.at = clamp(x(tick) - tick.width / 2, 0, Math.max(0, width - tick.width));
    return;
  }
  const gap = Math.max(14, Math.min(TILT_GAP, (width - 40) / (group.length - 1)));
  const at = group.map(x);
  for (let i = 1; i < at.length; i++) at[i] = Math.max(at[i], at[i - 1] + gap);
  // Centre the spread anchors on their ticks, then keep them on the rail.
  const drift = at.reduce((sum, p, i) => sum + p - x(group[i]), 0) / at.length;
  const nudge = Math.max(drift - at[0], Math.min(0, width + drift - at[at.length - 1]));
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

// The stretch of rail a group's captions occupy at the height of flat captions, and (tilted groups) higher up.
function low(group: Tick[]): Span {
  const first = group[0], last = group[group.length - 1];
  if (first.lean === "flat") return [first.at, first.at + first.width];
  return first.lean === "right" ? [first.at - 4, last.at + CLEAR] : [first.at - CLEAR, last.at + 4];
}
function high(group: Tick[]): Span | null {
  if (group[0].lean === "flat") return null;
  return group[0].lean === "right" ? [group[0].at, Math.max(...group.map((tick) => tick.at + run(tick)))]
                                   : [Math.min(...group.map((tick) => tick.at - run(tick))), group[group.length - 1].at];
}

// Whether two neighbouring groups' captions would collide. Tilted captions leaning the same way are parallel,
// so they only need their anchors TILT_GAP apart.
function collide(g: Tick[], h: Tick[]): boolean {
  if (meets(low(g), low(h), 4)) return true;
  const up = high(g), next = high(h);
  if (!up || !next || !meets(up, next)) return false;
  return g[0].lean !== h[0].lean || h[0].at - g[g.length - 1].at < TILT_GAP;
}

// Ticks for the possession's events, each captioned with the action above it and the player below. Captions that
// would overlap are tilted instead (see place); groups are merged until no two collide.
export function layoutTimeline(play: Play, seq: number[], width: number, measure: (text: string) => number): Timeline {
  const end = Math.max(1, seq.length - 1);
  const cuts: number[] = [], marks = new Set<number>();
  let groups: Tick[][] = [];
  for (let k = 1; k < seq.length; k++) {
    if (play.frames[seq[k]] - play.frames[seq[k - 1]] > 1) cuts.push(k / end);
  }
  for (const event of play.events) {
    const k = seqIndexOfFrame(play, seq, event.f);
    if (Math.abs(play.frames[seq[k]] - event.f) > LEAD_IN) continue;
    marks.add(k);
    const w = Math.max(measure(event.short ?? ""), measure(event.who ?? "")) + 8;
    groups.push([{ k, frac: k / end, event, lean: "flat", at: 0, width: w }]);
  }
  groups.sort((g, h) => g[0].k - h[0].k);
  for (;;) {
    for (const group of groups) place(group, width);
    const i = groups.findIndex((group, j) => j + 1 < groups.length && collide(group, groups[j + 1]));
    if (i < 0) break;
    groups.splice(i, 2, groups[i].concat(groups[i + 1]));
  }
  return { ticks: groups.flat(), cuts, marks: [...marks].sort((p, q) => p - q) };
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
