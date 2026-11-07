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
  /** Mean distance between every pair of a team's players on court, ft. */
  spread: Record<Role, number | null>;
  /** Each team's players in the paint (ids). */
  paint: Record<Role, number[]>;
  /** The defender closest to the hoop and his distance to it. */
  rim: { pid: number; dist: number } | null;
}

/** Spacing at frame index i, from the players with a position there. */
export function spacing(play: Play, i: number): Spacing {
  const at = (role: Role) => play.players.filter((p) => p.role === role && !Number.isNaN(p.x[i]));
  const def = at("def");
  const spread = (role: Role): number | null => {
    const team = at(role);
    let sum = 0, pairs = 0;
    for (let a = 0; a < team.length; a++) {
      for (let b = a + 1; b < team.length; b++) {
        sum += Math.hypot(team[a].x[i] - team[b].x[i], team[a].y[i] - team[b].y[i]);
        pairs++;
      }
    }
    return pairs ? sum / pairs : null;
  };
  const paint = (role: Role) => at(role).filter((p) => inPaint(p.x[i], p.y[i])).map((p) => p.id);
  let rim: Spacing["rim"] = null;
  for (const d of def) {
    const dist = Math.hypot(d.x[i] - HOOP_X, d.y[i]);
    if (!rim || dist < rim.dist) rim = { pid: d.id, dist };
  }
  return { spread: { off: spread("off"), def: spread("def") }, paint: { off: paint("off"), def: paint("def") }, rim };
}

const ACCEL_HALF = 5;      // frames each side of the speed difference behind an acceleration (0.2 s)
const MAX_ACCEL = 40;      // ft/s²; larger values are tracking jumps (sprinters reach about 15-20)

/** A player's acceleration at frame index i, ft/s² (negative when slowing), from his smoothed speed, or NaN. */
export function accelAt(play: Play, speed: Series, i: number): number {
  const a = i - ACCEL_HALF, b = i + ACCEL_HALF;
  if (a < 0 || b >= speed.length || !joined(play, a, b) || Number.isNaN(speed[a]) || Number.isNaN(speed[b])) return NaN;
  const v = ((speed[b] - speed[a]) * FPS) / (b - a);
  return Math.abs(v) <= MAX_ACCEL ? v : NaN;
}

export interface Stretch {
  /** Seconds from the first to the last frame. */
  secs: number;
  /** Fastest smoothed speed, ft/s (null when he is never tracked). */
  maxSpeed: number | null;
  /** Feet covered. */
  dist: number;
  /** Largest speeding up and slowing down, ft/s² (slowing as a positive number). */
  accel: number | null;
  decel: number | null;
}

/** One player's movement between frames f0 and f1 (tracking frame numbers), from motion(). */
export function stretch(play: Play, pid: number, f0: number, f1: number): Stretch | null {
  const at = play.players.findIndex((p) => p.id === pid);
  if (at < 0 || f1 < f0) return null;
  const m = motion(play);
  const speed = m.speed[at], covered = m.covered[at];
  let i0 = -1, i1 = -1, top = -Infinity, up = -Infinity, down = Infinity;
  for (let i = 0; i < play.frames.length; i++) {
    const fr = play.frames[i];
    if (fr < f0) continue;
    if (fr > f1) break;
    if (i0 < 0) i0 = i;
    i1 = i;
    if (!Number.isNaN(speed[i])) top = Math.max(top, speed[i]);
    const acc = accelAt(play, speed, i);
    if (!Number.isNaN(acc)) { up = Math.max(up, acc); down = Math.min(down, acc); }
  }
  if (i0 < 0) return null;
  return {
    secs: (play.frames[i1] - play.frames[i0]) / FPS,
    maxSpeed: Number.isFinite(top) ? top : null,
    dist: covered[i1] - covered[i0],
    accel: Number.isFinite(up) && up > 0 ? up : null,
    decel: Number.isFinite(down) && down < 0 ? -down : null,
  };
}

/** Floor distance between two players at frame f (tracking frame number), or null. */
export function gapAt(play: Play, a: number | undefined, b: number | undefined, f: number): number | null {
  const pa = play.players.find((p) => p.id === a), pb = play.players.find((p) => p.id === b);
  if (!pa || !pb) return null;
  let i = 0;
  while (i + 1 < play.frames.length && play.frames[i + 1] <= f) i++;
  const d = Math.hypot(pa.x[i] - pb.x[i], pa.y[i] - pb.y[i]);
  return Number.isNaN(d) ? null : d;
}
