// Tracking readouts derived from player positions: speed, distance covered, spacing, the rim protector and how
// open each player is. Pure, so the tests can run it in Node.
//
// How much tracking is smoothed comes from the tab bar's Tracking menu (lib/smoothing.svelte.ts: smoothed, light or
// raw; motion() keeps one result per play and level). Smoothed and light average positions over a few frames on each
// side (within an unbroken run of frames) before differencing: raw broadcast tracking jitters by a foot or so, which
// would otherwise read as speed; a step faster than MAX_SPEED is then treated as a tracking jump and left out of both
// speed and distance. Raw differences the tracked positions as they are and drops nothing.

import { HOOP_X, KEY_HALF_W, KEY_X, HALF_L } from "./court";
import { FPS } from "./sequence";
import { smoothing, smoothNow, type SmoothLevel } from "./smoothing.svelte";
import type { Play, Role, Series } from "./types";

const MAX_SPEED = 35;   // ft/s; sprinting players reach about 25

export interface Motion {
  /** Per player (same order as play.players): smoothed speed in ft/s, NaN where unknown. */
  speed: Series[];
  /** Per player: feet covered from the first frame of the play up to each frame. */
  covered: Series[];
  /** Per player: smoothed velocity, ft/s (NaN where speed is unknown). */
  vx: Series[];
  vy: Series[];
  /** Per player: fastest speed so far in the play. */
  top: Series[];
}

const cache = new WeakMap<Play, Partial<Record<SmoothLevel, Motion>>>();

function joined(play: Play, i: number, j: number): boolean {
  return Math.abs(play.frames[j] - play.frames[i]) === Math.abs(j - i);
}

function smooth(play: Play, v: Series, half: number): Series {
  if (half === 0) return v;
  const n = v.length, out = new Float64Array(n).fill(NaN);
  for (let i = 0; i < n; i++) {
    if (Number.isNaN(v[i])) continue;
    let sum = 0, k = 0;
    for (let j = Math.max(0, i - half); j <= Math.min(n - 1, i + half); j++) {
      if (!Number.isNaN(v[j]) && joined(play, i, j)) { sum += v[j]; k++; }
    }
    out[i] = sum / k;
  }
  return out;
}

/** Speed and distance covered for every player of a play (computed once per play and smoothing level). */
export function motion(play: Play): Motion {
  const level = smoothing.level, set = smoothNow();
  const byLevel = cache.get(play) ?? {};
  cache.set(play, byLevel);
  let m = byLevel[level];
  if (m) return m;
  const n = play.frames.length;
  const cap = set.caps ? MAX_SPEED : Infinity;
  // The frame `k` steps from i (k < 0 before, k > 0 after) if it is joined to i and tracked, else i itself.
  const near = (sx: Series, i: number, k: number) => {
    const j = i + k;
    return j >= 0 && j < n && joined(play, i, j) && !Number.isNaN(sx[j]) ? j : i;
  };
  m = { speed: [], covered: [], vx: [], vy: [], top: [] };
  for (const p of play.players) {
    const sx = smooth(play, p.x, set.pos), sy = smooth(play, p.y, set.pos);
    const speed = new Float64Array(n).fill(NaN), covered = new Float64Array(n);
    const vx = new Float64Array(n).fill(NaN), vy = new Float64Array(n).fill(NaN), top = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const a = near(sx, i, -set.back);
      // Raw looks back one frame; on a play's first frame (nothing before) it looks one frame ahead instead.
      const b = set.fwd === 0 && a === i ? near(sx, i, 1) : near(sx, i, set.fwd);
      if (b > a && !Number.isNaN(sx[i])) {
        const v = (Math.hypot(sx[b] - sx[a], sy[b] - sy[a]) * FPS) / (b - a);
        if (v <= cap) {
          speed[i] = v;
          vx[i] = ((sx[b] - sx[a]) * FPS) / (b - a);
          vy[i] = ((sy[b] - sy[a]) * FPS) / (b - a);
        }
      }
      covered[i] = i ? covered[i - 1] : 0;
      top[i] = Math.max(i ? top[i - 1] : 0, Number.isNaN(speed[i]) ? 0 : speed[i]);
      if (i && joined(play, i - 1, i) && !Number.isNaN(sx[i - 1]) && !Number.isNaN(sx[i])) {
        const step = Math.hypot(sx[i] - sx[i - 1], sy[i] - sy[i - 1]);
        if (step * FPS <= cap) covered[i] += step;
      }
    }
    m.speed.push(speed);
    m.covered.push(covered);
    m.vx.push(vx);
    m.vy.push(vy);
    m.top.push(top);
  }
  byLevel[level] = m;
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

const MAX_ACCEL = 40;      // ft/s²; larger values are tracking jumps (sprinters reach about 15-20)

/**
 * A player's acceleration at frame index i, ft/s² (negative when slowing), or NaN: the change between his speed
 * accBack frames before and accFwd frames after (lib/smoothing.svelte.ts; smoothed: 5 and 5, 0.4 s; light: 2 and 2;
 * raw: from the previous frame to this one). Near the ends of a play or of a run of frames the span shrinks, to no
 * fewer than accMin frames. Accelerations past MAX_ACCEL are dropped unless the level is raw.
 */
export function accelAt(play: Play, speed: Series, i: number): number {
  const set = smoothNow();
  const ok = (j: number) => j >= 0 && j < speed.length && !Number.isNaN(speed[j]) && joined(play, i, j);
  let a = i - set.accBack, b = i + set.accFwd;
  while (a < i && !ok(a)) a++;
  while (b > i && !ok(b)) b--;
  // Raw on a first frame (no earlier speed): the change from the next frame's speed to the one after. (This frame's
  // own raw speed already looks one frame ahead, so it would match the next frame's.)
  if (set.accFwd === 0 && a === i && ok(i + 1) && ok(i + 2)) { a = i + 1; b = i + 2; }
  if (b - a < set.accMin || Number.isNaN(speed[a]) || Number.isNaN(speed[b])) return NaN;
  const v = ((speed[b] - speed[a]) * FPS) / (b - a);
  return !set.caps || Math.abs(v) <= MAX_ACCEL ? v : NaN;
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
