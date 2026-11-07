// Tracking readouts derived from player positions: speed, distance covered, spacing, the rim protector and how
// open each player is. Pure, so the tests can run it in Node.
//
// Positions are averaged over SMOOTH frames on each side (within an unbroken run of frames) before differencing:
// raw broadcast tracking jitters by a foot or so, which would otherwise read as speed. A step faster than MAX_SPEED
// is treated as a tracking jump and left out of both speed and distance.

import { HOOP_X, KEY_HALF_W, KEY_X, HALF_L } from "./court";
import { FPS } from "./sequence";
import type { Play, Role, Series } from "./types";

const SMOOTH = 2;
const MAX_SPEED = 35;   // ft/s; sprinting players reach about 25

export interface Motion {
  /** Per player (same order as play.players): smoothed speed in ft/s, NaN where unknown. */
  speed: Series[];
  /** Per player: feet covered from the first frame of the play up to each frame. */
  covered: Series[];
}

const cache = new WeakMap<Play, Motion>();

function joined(play: Play, i: number, j: number): boolean {
  return Math.abs(play.frames[j] - play.frames[i]) === Math.abs(j - i);
}

function smooth(play: Play, v: Series): Series {
  const n = v.length, out = new Float64Array(n).fill(NaN);
  for (let i = 0; i < n; i++) {
    if (Number.isNaN(v[i])) continue;
    let sum = 0, k = 0;
    for (let j = Math.max(0, i - SMOOTH); j <= Math.min(n - 1, i + SMOOTH); j++) {
      if (!Number.isNaN(v[j]) && joined(play, i, j)) { sum += v[j]; k++; }
    }
    out[i] = sum / k;
  }
  return out;
}

/** Speed and distance covered for every player of a play (computed once per play). */
export function motion(play: Play): Motion {
  let m = cache.get(play);
  if (m) return m;
  const n = play.frames.length;
  m = { speed: [], covered: [] };
  for (const p of play.players) {
    const sx = smooth(play, p.x), sy = smooth(play, p.y);
    const speed = new Float64Array(n).fill(NaN), covered = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const a = i > 0 && joined(play, i - 1, i) && !Number.isNaN(sx[i - 1]) ? i - 1 : i;
      const b = i < n - 1 && joined(play, i, i + 1) && !Number.isNaN(sx[i + 1]) ? i + 1 : i;
      if (b > a && !Number.isNaN(sx[i])) {
        const v = (Math.hypot(sx[b] - sx[a], sy[b] - sy[a]) * FPS) / (b - a);
        if (v <= MAX_SPEED) speed[i] = v;
      }
      covered[i] = i ? covered[i - 1] : 0;
      if (i && a === i - 1) {
        const step = Math.hypot(sx[i] - sx[i - 1], sy[i] - sy[i - 1]);
        if (step * FPS <= MAX_SPEED) covered[i] += step;
      }
    }
    m.speed.push(speed);
    m.covered.push(covered);
  }
  cache.set(play, m);
  return m;
}

/** In the paint the offense attacks (stored frame: the hoop at +x). */
export const inPaint = (x: number, y: number): boolean => x >= KEY_X && x <= HALF_L && Math.abs(y) <= KEY_HALF_W;

export interface Spacing {
  /** Mean distance between every pair of offensive players on court, ft. */
  spread: number | null;
  /** Offensive players in the paint. */
  paint: number;
  /** The defender closest to the hoop and his distance to it. */
  rim: { pid: number; dist: number } | null;
}

/** Spacing at frame index i, from the players with a position there. */
export function spacing(play: Play, i: number): Spacing {
  const at = (role: Role) => play.players.filter((p) => p.role === role && !Number.isNaN(p.x[i]));
  const off = at("off"), def = at("def");
  let sum = 0, pairs = 0;
  for (let a = 0; a < off.length; a++) {
    for (let b = a + 1; b < off.length; b++) {
      sum += Math.hypot(off[a].x[i] - off[b].x[i], off[a].y[i] - off[b].y[i]);
      pairs++;
    }
  }
  let rim: Spacing["rim"] = null;
  for (const d of def) {
    const dist = Math.hypot(d.x[i] - HOOP_X, d.y[i]);
    if (!rim || dist < rim.dist) rim = { pid: d.id, dist };
  }
  return { spread: pairs ? sum / pairs : null, paint: off.filter((p) => inPaint(p.x[i], p.y[i])).length, rim };
}
