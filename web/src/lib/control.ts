// Court control, the simple time-to-ball version: for every 2 ft cell of the court, which team would get to the
// ball first if it were passed there now. Restored from the archived model (zz_Archive/web/src/lib/control.ts,
// mirroring zz_Archive/src/court_control/R/control.R) with only its "Control" layer; the rebound, relevance and
// scoring layers stay archived. No DOM here; drawControl() paints a reading.
//
// How a cell is decided, step by step:
//   1. The ball's travel time to the cell: BALL0 + BALL1 × distance (a pass at about 50 ft/s).
//   2. Each player's arrival time: he keeps his current velocity for the reaction time, then heads straight for the cell
//      within his own motion limits (sample.json; "Motion limits" in web/scripts/sample_stats.R): his velocity toward
//      the cell changes no faster than his acceleration (speeding up) or braking (first stopping, if he is moving
//      away), up to his sprint speed. A player already running at the cell gets there sooner than one standing, and
//      one running the other way has to stop first. His sideways velocity is ignored. Each limit is his own high
//      percentile in the ten games' live play, shrunk toward his offensive archetype's average when he was seen
//      briefly; sprint speeds are scaled so their average is the archived VMAX. Without the figures (and in the
//      R parity test) every player runs at VMAX from the moment he reacts, as in the archived model.
//   3. His arrival is uncertain: by time t he has arrived with a logistic probability in (t − arrival) whose spread
//      is the timing spread.
//   4. From the moment the ball gets there, while nobody has the cell, each arrived player takes it at the claim rate
//      per second (fast, so the first to arrive nearly always wins).
//   5. The cell's colour is the offense's share of that (pale = a toss-up).
// Constants. VMAX (the archived single sprint speed) and the ball's speed were measured from the ten games' tracking
// and passes. The reaction time, timing spread and claim rate come in two sets:
//   ARCHIVED  the archived model's (one speed, instant top speed), kept for the R parity test and for players
//             without figures in a play read without limits
//   FITTED    refitted for the per-player limits by web/scripts/fit_control.R: the grid point whose control at each
//             live pass's catch spot best separated completed from intercepted passes (3,728 passes, 66
//             intercepted; logistic recalibration, log loss). Left one game out at a time, this model beat the
//             archived one in 8 of 10 games (held-out log loss 0.0215 vs 0.0263; mean gain 0.0050, SE 0.0022);
//             per-player sprint speeds alone, without acceleration, did not (0.0268).
// Coordinates are the play's stored frame: feet, the offense attacking the hoop at +x.

import { HALF_L, HALF_W, type Layout } from "./court";
import type { Play, Sample } from "./types";

const ARCHIVED = { react: 0.4, sigma: 0.15, lambda: 100 };   // s, s, per s
const FITTED = { react: 0.05, sigma: 0.45, lambda: 50 };     // s, s, per s
const VMAX = 18.1147264926486;  // ft/s
const BALL0 = 0.0160704909212239, BALL1 = 0.0201103502526555;   // s, s per ft
const DT = 0.04, MAX_T = 6, TOL = 0.99;
const CELL = 2;                 // ft
const VEL_LAG = 6;              // frames: velocity from the position 0.24 s earlier
const MAX_SPEED = 30;           // ft/s; faster is a tracking jump

/** The league's acceleration and braking (ft/s²), for a player without his own figures. */
const ACCEL = 12.4, BRAKE = 11.9;

/** The players on court at one frame, offense first. With limits: each one's sprint speed, acceleration and braking
 * (without: every player at VMAX from the moment he reacts). */
export interface Bodies {
  x: Float64Array; y: Float64Array; vx: Float64Array; vy: Float64Array; nOff: number;
  vmax?: Float64Array; amax?: Float64Array; dmax?: Float64Array;
}

/** One player's motion limits: sprint speed (ft/s), acceleration and braking (ft/s²). */
export interface Limits { v: number; a: number; d: number }

/** Motion limits per player id for a play's players, from the tracked games' figures; null without them. */
const limitCache = new WeakMap<Play, Map<number, Limits>>();
export function motionLimits(play: Play, sample: Sample | null): Map<number, Limits> | null {
  if (!sample) return null;
  let out = limitCache.get(play);
  if (!out) {
    out = new Map();
    for (const p of play.players) {
      const t = p.canon != null && p.team != null ? sample.players[`${p.canon}:${p.team}`]?.trk : undefined;
      if (t?.vmax != null) out.set(p.id, { v: t.vmax, a: t.amax ?? sample.league.accel ?? ACCEL, d: t.dmax ?? sample.league.braking ?? BRAKE });
    }
    limitCache.set(play, out);
  }
  return out;
}

/** Seconds to cover `dist` ft heading straight at it, starting at speed `u` toward it (negative: moving away), with
 * acceleration a, braking d and top speed v. */
export function runTime(dist: number, u: number, v: number, a: number, d: number): number {
  let t = 0;
  if (u < 0) {                       // stop first, which carries him further away
    t = -u / d;
    dist += (u * u) / (2 * d);
    u = 0;
  }
  u = Math.min(u, v);
  const ramp = (v * v - u * u) / (2 * a);   // distance covered while speeding up to v
  if (ramp >= dist) return t + (Math.sqrt(u * u + 2 * a * dist) - u) / a;
  return t + (v - u) / a + (dist - ramp) / v;
}

/** Cell centres in row-major order (top row first, left to right). */
export interface Grid { nx: number; ny: number; at: Int32Array; x: Float64Array; y: Float64Array }

let grid: Grid | null = null;
export function courtGrid(): Grid {
  if (grid) return grid;
  const nx = Math.ceil((2 * HALF_L) / CELL), ny = Math.ceil((2 * HALF_W) / CELL);
  const at: number[] = [], xs: number[] = [], ys: number[] = [];
  for (let j = 0; j < ny; j++) {
    for (let i = 0; i < nx; i++) {
      at.push(j * nx + i);
      xs.push(-HALF_L + CELL * (i + 0.5));
      ys.push(HALF_W - CELL * (j + 0.5));
    }
  }
  return (grid = { nx, ny, at: Int32Array.from(at), x: Float64Array.from(xs), y: Float64Array.from(ys) });
}

/** Positions and velocities at index i of the play's frames. Players without a position are left out. */
export function bodiesAt(play: Play, i: number, limits: Map<number, Limits> | null = null): Bodies {
  const rows: [number, number, number, number, boolean, Limits][] = [];
  const back = i - VEL_LAG, joined = back >= 0 && play.frames[i] - play.frames[back] === VEL_LAG;
  for (const p of play.players) {
    const x = p.x[i], y = p.y[i];
    if (Number.isNaN(x) || Number.isNaN(y)) continue;
    let vx = 0, vy = 0;
    if (joined && !Number.isNaN(p.x[back]) && !Number.isNaN(p.y[back])) {
      vx = ((x - p.x[back]) * 25) / VEL_LAG;
      vy = ((y - p.y[back]) * 25) / VEL_LAG;
      const slow = Math.min(1, MAX_SPEED / Math.max(Math.hypot(vx, vy), 1e-6));
      vx *= slow;
      vy *= slow;
    }
    rows.push([x, y, vx, vy, p.role === "off", limits?.get(p.id) ?? { v: VMAX, a: ACCEL, d: BRAKE }]);
  }
  rows.sort((a, b) => Number(b[4]) - Number(a[4]));
  return {
    x: Float64Array.from(rows, (r) => r[0]), y: Float64Array.from(rows, (r) => r[1]),
    vx: Float64Array.from(rows, (r) => r[2]), vy: Float64Array.from(rows, (r) => r[3]),
    nOff: rows.filter((r) => r[4]).length,
    vmax: limits ? Float64Array.from(rows, (r) => r[5].v) : undefined,
    amax: limits ? Float64Array.from(rows, (r) => r[5].a) : undefined,
    dmax: limits ? Float64Array.from(rows, (r) => r[5].d) : undefined,
  };
}

/** The offense's share of control of each cell for a ball at (bx, by) (steps 1-5 above). */
export function timeToBallControl(b: Bodies, g: Grid, bx: number, by: number): Float64Array {
  // The refitted constants go with the motion limits; the archived ones with the archived motion.
  const c0 = b.amax && b.dmax && b.vmax ? FITTED : ARCHIVED;
  const k = b.x.length, rx = new Float64Array(k), ry = new Float64Array(k);
  for (let j = 0; j < k; j++) {
    rx[j] = b.x[j] + b.vx[j] * c0.react;
    ry[j] = b.y[j] + b.vy[j] * c0.react;
  }
  const scale = Math.PI / Math.sqrt(3) / c0.sigma, steps = Math.ceil(MAX_T / DT), rate = c0.lambda * DT;
  const tau = new Float64Array(k), P = new Float64Array(k), out = new Float64Array(g.x.length);
  for (let c = 0; c < g.x.length; c++) {
    const tBall = BALL0 + BALL1 * Math.hypot(g.x[c] - bx, g.y[c] - by);
    for (let j = 0; j < k; j++) {
      const dx = g.x[c] - rx[j], dy = g.y[c] - ry[j], dist = Math.hypot(dx, dy);
      if (b.amax && b.dmax && b.vmax) {
        // His speed toward the cell when he reacts (the velocity he kept), then the limited run.
        const u = dist > 1e-9 ? (b.vx[j] * dx + b.vy[j] * dy) / dist : 0;
        tau[j] = c0.react + runTime(dist, u, b.vmax[j], b.amax[j], b.dmax[j]);
      } else {
        tau[j] = c0.react + dist / (b.vmax ? b.vmax[j] : VMAX);
      }
      P[j] = 0;
    }
    let tot = 0;
    for (let s = 1; s <= steps; s++) {
      const t = tBall + s * DT, free = 1 - tot;
      let next = 0;
      for (let j = 0; j < k; j++) {
        P[j] += (free * rate) / (1 + Math.exp(-(t - tau[j]) * scale));
        next += P[j];
      }
      tot = next;
      if (tot >= TOL) break;
    }
    let off = 0;
    for (let j = 0; j < b.nOff; j++) off += P[j];
    out[c] = off / Math.max(tot, 1e-9);
  }
  return out;
}

export interface ControlReading {
  pc: Float64Array;
  /** The offense's share of the whole court, and of the half it attacks (the defense has the rest). */
  offShare: number;
  offHalf: number;
}

let lastKey = "", last: ControlReading | null = null;
/** Court control at index i of the play's frames (needs five a side and the ball), or null. With limits, each
 * player moves within his own sprint speed, acceleration and braking. */
export function controlAt(play: Play, i: number, limits: Map<number, Limits> | null = null): ControlReading | null {
  const key = `${play.id}:${i}:${limits ? "own" : "one"}`;
  if (key === lastKey) return last;
  lastKey = key;
  const b = bodiesAt(play, i, limits), bx = play.ball.x[i], by = play.ball.y[i];
  if (b.nOff < 5 || b.x.length - b.nOff < 5 || Number.isNaN(bx) || Number.isNaN(by)) return (last = null);
  const g = courtGrid(), pc = timeToBallControl(b, g, bx, by);
  let off = 0, half = 0, cells = 0;
  for (let c = 0; c < pc.length; c++) {
    off += pc[c];
    if (g.x[c] >= 0) { half += pc[c]; cells++; }
  }
  return (last = { pc, offShare: off / pc.length, offHalf: half / cells });
}

const MAX_ALPHA = 0.6;
const NEUTRAL: [number, number, number] = [246, 246, 246];
const TOSS_UP_ALPHA = 0.3;   // share of full strength at which a 50-50 cell is drawn
const SATURATE = 0.35;       // a team's colour is at full strength this far from 50-50

function rgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const n = parseInt(h.length === 3 ? h.replace(/./g, (c) => c + c) : h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

let raster: HTMLCanvasElement | null = null;

/** Paint a reading over the floor in the teams' colours, clipped to the court's lines. */
export function drawControl(ctx: CanvasRenderingContext2D, L: Layout, r: ControlReading, colors: { off: string; def: string }): void {
  const g = courtGrid(), offC = rgb(colors.off), defC = rgb(colors.def);
  raster ??= document.createElement("canvas");
  if (raster.width !== g.nx || raster.height !== g.ny) {
    raster.width = g.nx;
    raster.height = g.ny;
  }
  const rc = raster.getContext("2d")!, img = rc.createImageData(g.nx, g.ny);
  for (let c = 0; c < g.at.length; c++) {
    const at = 4 * g.at[c], t = r.pc[c];
    const end = t >= 0.5 ? offC : defC, s = Math.min(1, Math.abs(t - 0.5) / SATURATE);
    for (let k = 0; k < 3; k++) img.data[at + k] = NEUTRAL[k] + (end[k] - NEUTRAL[k]) * s;
    img.data[at + 3] = Math.round(255 * MAX_ALPHA * (TOSS_UP_ALPHA + (1 - TOSS_UP_ALPHA) * s));
  }
  rc.putImageData(img, 0, 0);
  ctx.save();
  ctx.beginPath();
  ctx.rect(L.ox - HALF_L * L.s, L.oy - HALF_W * L.s, 2 * HALF_L * L.s, 2 * HALF_W * L.s);
  ctx.clip();
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  // The grid is in the play's stored frame; a play drawn in the camera's view turns it 180° about centre court.
  ctx.translate(L.ox, L.oy);
  ctx.scale(L.f, L.f);
  ctx.drawImage(raster, -HALF_L * L.s, -HALF_W * L.s, g.nx * CELL * L.s, g.ny * CELL * L.s);
  ctx.restore();
}
