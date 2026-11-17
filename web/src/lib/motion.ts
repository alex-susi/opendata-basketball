// Tracking readouts derived from player positions: speed, distance covered, spacing, the rim protector and how
// open each player is. Pure, so the tests can run it in Node.
//
// Smoothing (2026-11-17, the former "Light" setting; the Smoothed / Light / Raw switch was removed): positions are
// averaged over POS_HALF frames on each side (within an unbroken run of frames) before differencing, since raw
// broadcast tracking jitters by a foot or so, which would otherwise read as speed. Speed at a frame is taken from the
// averaged positions one frame before and one after (0.08 s); acceleration from the speeds ACC_HALF frames before and
// after (0.16 s). A step faster than MAX_SPEED or an acceleration past MAX_ACCEL is treated as a tracking jump and left
// out. At the start of a player's tracking (the play's first frame, or after a gap) there is no earlier frame to
// average with, and the one-sided values jumped (accelerations of 30+ ft/s² on frame 0): speed is left blank until
// SPEED_AFTER frames in (0.08 s) and acceleration until SPEED_AFTER + ACC_HALF frames in (0.16 s).

import { HOOP_X, KEY_HALF_W, KEY_X, HALF_L } from "./court";
import { FPS } from "./sequence";
import type { Play, Role, Series } from "./types";

const POS_HALF = 1;      // frames each side averaged into a position (3 frames, 0.12 s)
const ACC_HALF = 2;      // frames each side of the speed difference behind an acceleration (0.16 s)
const SPEED_AFTER = 2;   // frames into a run of tracking before a speed is given (0.08 s)
const MAX_SPEED = 35;    // ft/s; sprinting players reach about 25

/** Frames each side averaged when drawing drive and cut paths and player trails (lib/annotate.ts, lib/draw.ts). */
export const PATH_HALF = POS_HALF;

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
  /** Per player: frames since his current unbroken run of tracking began (0 on its first frame, NaN untracked). */
  inRun: Series[];
}

const cache = new WeakMap<Play, Motion>();

function joined(play: Play, i: number, j: number): boolean {
  return Math.abs(play.frames[j] - play.frames[i]) === Math.abs(j - i);
}

function smooth(play: Play, v: Series, half: number): Series {
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

/** Speed and distance covered for every player of a play (computed once per play). */
export function motion(play: Play): Motion {
  let m = cache.get(play);
  if (m) return m;
  const n = play.frames.length;
  // The frame `k` steps from i (k < 0 before, k > 0 after) if it is joined to i and tracked, else i itself.
  const near = (sx: Series, i: number, k: number) => {
    const j = i + k;
    return j >= 0 && j < n && joined(play, i, j) && !Number.isNaN(sx[j]) ? j : i;
  };
  m = { speed: [], covered: [], vx: [], vy: [], top: [], inRun: [] };
  for (const p of play.players) {
    const sx = smooth(play, p.x, POS_HALF), sy = smooth(play, p.y, POS_HALF);
    const speed = new Float64Array(n).fill(NaN), covered = new Float64Array(n), inRun = new Float64Array(n).fill(NaN);
    const vx = new Float64Array(n).fill(NaN), vy = new Float64Array(n).fill(NaN), top = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      if (!Number.isNaN(sx[i])) {
        const cont = i > 0 && joined(play, i - 1, i) && !Number.isNaN(sx[i - 1]);
        inRun[i] = cont ? inRun[i - 1] + 1 : 0;
      }
      const a = near(sx, i, -1), b = near(sx, i, 1);
      if (b > a && !Number.isNaN(sx[i]) && inRun[i] >= SPEED_AFTER) {
        const v = (Math.hypot(sx[b] - sx[a], sy[b] - sy[a]) * FPS) / (b - a);
        if (v <= MAX_SPEED) {
          speed[i] = v;
          vx[i] = ((sx[b] - sx[a]) * FPS) / (b - a);
          vy[i] = ((sy[b] - sy[a]) * FPS) / (b - a);
        }
      }
      covered[i] = i ? covered[i - 1] : 0;
      top[i] = Math.max(i ? top[i - 1] : 0, Number.isNaN(speed[i]) ? 0 : speed[i]);
      if (i && joined(play, i - 1, i) && !Number.isNaN(sx[i - 1]) && !Number.isNaN(sx[i])) {
        const step = Math.hypot(sx[i] - sx[i - 1], sy[i] - sy[i - 1]);
        if (step * FPS <= MAX_SPEED) covered[i] += step;
      }
    }
    m.speed.push(speed);
    m.covered.push(covered);
    m.vx.push(vx);
    m.vy.push(vy);
    m.top.push(top);
    m.inRun.push(inRun);
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

const MAX_ACCEL = 40;      // ft/s²; larger values are tracking jumps (sprinters reach about 15-20)

/**
 * A player's acceleration at frame index i, ft/s² (negative when slowing), or NaN: the change between his speed
 * ACC_HALF frames before and ACC_HALF frames after (0.16 s). The earlier speed must be there, so nothing is given until
 * 4 frames (0.16 s) into a run of tracking; near the end of a run the later side shrinks, to no fewer than 2 frames in
 * all. Accelerations past MAX_ACCEL are dropped as tracking jumps.
 */
export function accelAt(play: Play, speed: Series, i: number): number {
  const ok = (j: number) => j >= 0 && j < speed.length && !Number.isNaN(speed[j]) && joined(play, i, j);
  const a = i - ACC_HALF;
  // Speed exists only SPEED_AFTER frames into a run, so requiring the speed ACC_HALF frames back gives no acceleration
  // until SPEED_AFTER + ACC_HALF = 4 frames (0.16 s) in.
  if (!ok(a)) return NaN;
  let b = i + ACC_HALF;
  while (b > i && !ok(b)) b--;
  if (b - a < 2) return NaN;
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
