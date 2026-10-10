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

export interface Tick {
  k: number;
  frac: number;
  event: PlayEvent;
  /** Caption row (0 nearest the rail, 1 outside it) or -1 when there is no room. */
  row: number;
  left: number;
  width: number;
}

export interface Timeline {
  ticks: Tick[];
  cuts: number[];
  marks: number[];
}

// Ticks for the possession's events, each captioned with the action above it and the player below.
// Captions that would overlap drop to a second row; if that is taken too, the tooltip still names them.
export function layoutTimeline(play: Play, seq: number[], width: number, measure: (text: string) => number): Timeline {
  const end = Math.max(1, seq.length - 1), rowEnds = [-Infinity, -Infinity];
  const cuts: number[] = [], ticks: Tick[] = [], marks = new Set<number>();
  for (let k = 1; k < seq.length; k++) {
    if (play.frames[seq[k]] - play.frames[seq[k - 1]] > 1) cuts.push(k / end);
  }
  for (const event of play.events) {
    const k = seqIndexOfFrame(play, seq, event.f);
    if (Math.abs(play.frames[seq[k]] - event.f) > LEAD_IN) continue;
    marks.add(k);
    const w = Math.max(measure(event.short ?? ""), measure(event.who ?? "")) + 8;
    const left = clamp((k / end) * width - w / 2, 0, Math.max(0, width - w));
    const row = rowEnds.findIndex((edge) => left >= edge);
    if (row >= 0) rowEnds[row] = left + w;
    ticks.push({ k, frac: k / end, event, row, left, width: w });
  }
  return { ticks, cuts, marks: [...marks].sort((a, b) => a - b) };
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
