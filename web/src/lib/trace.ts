// The trace panel under the court (the play's timeline): one number followed over the play.
//   ball:    the ball's height (ft) from the tracking.
//   player:  one player's measure, picked in the panel (METRICS): his distance to the nearest opponent, the nearest
//            teammate, his assigned matchup, the basket or the ball, or his speed, acceleration or speed toward the
//            basket (smoothed, lib/motion.ts).
// Samples are taken every few steps of the playback sequence, so the x axis is playback time
// (dead-ball time is skipped when the viewer skips it). Pure, so the tests can run it in Node.

import { HOOP_X } from "./court";
import { accelAt, motion } from "./motion";
import { blend, FPS, type Cursor } from "./sequence";
import type { Play } from "./types";

/** What the Player Trace tab follows for the chosen player. */
export type Metric = "nearest" | "teammate" | "matchup" | "hoop" | "ball" | "speed" | "accel" | "toward";

export interface MetricInfo {
  key: Metric;
  label: string;
  /** The trace panel's y-axis title, short enough to run up the side of the plot. */
  axis: string;
  unit: string;
  title: string;
  /** Another player the measure is taken against, joined to the followed player on the court. */
  pair?: true;
}

/** The measures, in the order of the panel's menu. */
export const METRICS: MetricInfo[] = [
  { key: "nearest", axis: "Gap to Opponent", label: "Nearest Opponent", unit: "ft", title: "Floor distance to the closest player of the other team", pair: true },
  { key: "matchup", axis: "Gap to Matchup", label: "Gap to Matchup", unit: "ft", title: "Floor distance to his assigned matchup: the defender guarding him, or the man he guards (matchups table)", pair: true },
  { key: "teammate", axis: "Gap to Teammate", label: "Nearest Teammate", unit: "ft", title: "Floor distance to the closest teammate (spacing)", pair: true },
  { key: "hoop", axis: "To Basket", label: "Distance to Basket", unit: "ft", title: "Floor distance to the basket the offense attacks" },
  { key: "ball", axis: "To Ball", label: "Distance to Ball", unit: "ft", title: "Floor distance to the ball (ball height left out)" },
  { key: "speed", axis: "Speed", label: "Speed", unit: "ft/s", title: "Smoothed speed" },
  { key: "accel", axis: "Acceleration", label: "Acceleration", unit: "ft/s²", title: "Change in smoothed speed over 0.4 s; negative while slowing down" },
  { key: "toward", axis: "Toward Basket", label: "Speed Toward Basket", unit: "ft/s", title: "Speed toward the basket the offense attacks; negative while moving away from it" },
];

export const metricInfo = (m: Metric): MetricInfo => METRICS.find((x) => x.key === m) ?? METRICS[0];

export type TraceKind = { kind: "ball" } | { kind: "player"; pid: number; metric: Metric };

/** Sequence steps between samples: 5 frames, 0.2 s at 25 fps. */
export const TRACE_STEP = 5;

export interface Nearest {
  /** The closest opponent (or teammate). */
  pid: number;
  /** Distance between the two centres, in feet. */
  dist: number;
  /** Both positions were detected on screen (not extrapolated) at the frame. */
  detected: boolean;
}

/** The opponent closest to `pid` at the cursor (positions blended between frames), or null when he or every
 * opponent is off the tracked court. With `mate`, the closest teammate instead. */
export function nearestAt(play: Play, pid: number, c: Cursor, mate = false): Nearest | null {
  const me = play.players.find((p) => p.id === pid);
  if (!me) return null;
  const x = blend(me.x, c), y = blend(me.y, c);
  if (x == null || y == null) return null;
  let best: Nearest | null = null;
  for (const q of play.players) {
    if (q.id === me.id || (q.role === me.role) !== mate) continue;
    const qx = blend(q.x, c), qy = blend(q.y, c);
    if (qx == null || qy == null) continue;
    const dist = Math.hypot(qx - x, qy - y);
    if (!best || dist < best.dist) best = { pid: q.id, dist, detected: me.d[c.i0] === 1 && q.d[c.i0] === 1 };
  }
  return best;
}

/** nearestAt on one frame (an index into the play's frames), with no blending. */
export function nearestOpponent(play: Play, pid: number, i: number): Nearest | null {
  return nearestAt(play, pid, { i0: i, i1: i, t: 0 });
}

/** The player `pid` is matched with at a tracking frame: his assigned defender (offense) or the man he guards. */
export function matchupOf(play: Play, pid: number, frame: number): number | null {
  const me = play.players.find((p) => p.id === pid);
  if (!me) return null;
  const m = (play.ann?.matchups ?? []).find((r) => r.f <= frame && frame <= r.f1 && (me.role === "off" ? r.off : r.def) === pid);
  return m ? (me.role === "off" ? m.def : m.off) : null;
}

export interface PlayerValue {
  /** The measure, or null where it is missing. */
  v: number | null;
  /** The other player of a paired measure (nearest opponent, teammate, matchup). */
  other: number | null;
  /** Every position behind the value was detected rather than extrapolated. */
  detected: boolean;
}

const NONE: PlayerValue = { v: null, other: null, detected: false };
const num = (v: number | null) => (v == null || Number.isNaN(v) ? null : v);

/** One player's measure at the cursor: positions and smoothed speeds blended between frames like the court. */
export function playerValue(play: Play, pid: number, metric: Metric, c: Cursor): PlayerValue {
  const at = play.players.findIndex((p) => p.id === pid);
  if (at < 0) return NONE;
  const me = play.players[at];
  const x = blend(me.x, c), y = blend(me.y, c);
  if (x == null || y == null) return NONE;
  const seen = me.d[c.i0] === 1;
  if (metric === "nearest" || metric === "teammate") {
    const near = nearestAt(play, pid, c, metric === "teammate");
    return near ? { v: near.dist, other: near.pid, detected: near.detected } : NONE;
  }
  if (metric === "matchup") {
    const other = matchupOf(play, pid, play.frames[c.i0]);
    const q = play.players.find((p) => p.id === other);
    const qx = q ? blend(q.x, c) : null, qy = q ? blend(q.y, c) : null;
    if (!q || qx == null || qy == null) return { ...NONE, other };
    return { v: Math.hypot(qx - x, qy - y), other, detected: seen && q.d[c.i0] === 1 };
  }
  if (metric === "hoop") return { v: Math.hypot(HOOP_X - x, y), other: null, detected: seen };
  if (metric === "ball") {
    const bx = blend(play.ball.x, c), by = blend(play.ball.y, c);
    return bx == null || by == null ? NONE : { v: Math.hypot(bx - x, by - y), other: null, detected: seen };
  }
  const m = motion(play);
  const series = (s: ArrayLike<number>) => {
    const a = s[c.i0], b = s[c.i1];
    if (Number.isNaN(a)) return null;
    return Number.isNaN(b) ? a : a + (b - a) * c.t;
  };
  if (metric === "speed") return { v: num(series(m.speed[at])), other: null, detected: seen };
  if (metric === "accel") {
    const a = accelAt(play, m.speed[at], c.i0), b = c.i1 === c.i0 ? a : accelAt(play, m.speed[at], c.i1);
    const v = Number.isNaN(a) ? null : Number.isNaN(b) ? a : a + (b - a) * c.t;
    return { v, other: null, detected: seen };
  }
  // toward: the velocity's component along the line to the basket
  const vx = series(m.vx[at]), vy = series(m.vy[at]), toHoop = Math.hypot(HOOP_X - x, y);
  if (vx == null || vy == null || toHoop < 1e-6) return { ...NONE, detected: seen };
  return { v: (vx * (HOOP_X - x) + vy * -y) / toHoop, other: null, detected: seen };
}

export interface TraceSample {
  /** Position in the playback sequence. */
  k: number;
  /** Seconds of playback. */
  t: number;
  /** The value, or null where it is missing. */
  v: number | null;
  /** A position behind the value was extrapolated rather than detected. */
  faint: boolean;
  /** Paired measures: who the other player was. */
  opp: number | null;
}

/** The trace sampled every TRACE_STEP steps of the sequence. */
export function traceSamples(play: Play, seq: number[], kind: TraceKind, step = TRACE_STEP): TraceSample[] {
  const out: TraceSample[] = [];
  for (let k = 0; k < seq.length; k += step) {
    const i = seq[k], t = k / FPS;
    if (kind.kind === "ball") {
      const z = play.ball.z[i];
      out.push({ k, t, v: Number.isNaN(z) ? null : z, faint: false, opp: null });
    } else {
      const got = playerValue(play, kind.pid, kind.metric, { i0: i, i1: i, t: 0 });
      out.push({ k, t, v: got.v, faint: got.v != null && !got.detected, opp: got.other });
    }
  }
  return out;
}

export interface PartnerChange {
  /** The sample where the new player first appears. */
  k: number;
  t: number;
  /** The value there (null when it is missing, so the chart has nowhere to put the dot). */
  v: number | null;
  from: number;
  to: number;
}

/** Paired measures: the samples where the other player becomes someone else. Samples with nobody (no matchup
 * assigned, or nobody on the tracked court) are passed over, so A, nobody, B is one change from A to B. */
export function partnerChanges(samples: TraceSample[]): PartnerChange[] {
  const out: PartnerChange[] = [];
  let last: number | null = null;
  for (const s of samples) {
    if (s.opp == null) continue;
    if (last != null && s.opp !== last) out.push({ k: s.k, t: s.t, v: s.v, from: last, to: s.opp });
    last = s.opp;
  }
  return out;
}
