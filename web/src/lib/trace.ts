// The trace panel between the court and the transport bar: one number followed over the play.
//   ball:    the ball's height (ft) from the tracking.
//   nearest: the 2D distance (ft) from one player to the closest player of the other team.
// Samples are taken every few steps of the playback sequence, so the x axis is the transport bar's clock
// (dead-ball time is skipped when the viewer skips it). Pure, so the tests can run it in Node.

import { blend, FPS, type Cursor } from "./sequence";
import type { Play } from "./types";

export type TraceKind = { kind: "ball" } | { kind: "nearest"; pid: number };

/** Sequence steps between samples: 5 frames, 0.2 s at 25 fps. */
export const TRACE_STEP = 5;

export interface Nearest {
  /** The closest opponent. */
  pid: number;
  /** Distance between the two centres, in feet. */
  dist: number;
  /** Both positions were detected on screen (not extrapolated) at the frame. */
  detected: boolean;
}

/** The opponent closest to `pid` at the cursor (positions blended between frames), or null when he or every
 * opponent is off the tracked court. */
export function nearestAt(play: Play, pid: number, c: Cursor): Nearest | null {
  const me = play.players.find((p) => p.id === pid);
  if (!me) return null;
  const x = blend(me.x, c), y = blend(me.y, c);
  if (x == null || y == null) return null;
  let best: Nearest | null = null;
  for (const q of play.players) {
    if (q.role === me.role) continue;
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

export interface TraceSample {
  /** Position in the playback sequence. */
  k: number;
  /** Seconds on the transport's clock. */
  t: number;
  /** The value, or null where it is missing. */
  v: number | null;
  /** A position behind the value was extrapolated rather than detected. */
  faint: boolean;
  /** Nearest trace: who the nearest opponent was. */
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
      const near = nearestOpponent(play, kind.pid, i);
      out.push({ k, t, v: near?.dist ?? null, faint: near ? !near.detected : false, opp: near?.pid ?? null });
    }
  }
  return out;
}
