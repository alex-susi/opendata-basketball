// Court control, the simple time-to-ball version: for every 2 ft cell of the court, which team would get to the
// ball first if it were passed there now. Restored from the archived model (zz_Archive/web/src/lib/control.ts,
// mirroring zz_Archive/src/court_control/R/control.R) with only its "Control" layer; the rebound, relevance and
// scoring layers stay archived. No DOM here; drawControl() paints a reading.
//
// How a cell is decided, step by step:
//   1. The ball's travel time to the cell: BALL0 + BALL1 × distance (a pass at about 50 ft/s).
//   2. Each player's arrival time: he keeps his current velocity for REACT seconds, then runs straight to the cell at
//      VMAX ft/s.
//   3. His arrival is uncertain: by time t he has arrived with a logistic probability in (t − arrival) whose spread
//      is SIGMA seconds.
//   4. From the moment the ball gets there, while nobody has the cell, each arrived player takes it at rate LAMBDA
//      per second (fast, so the first to arrive nearly always wins).
//   5. The cell's colour is the offense's share of that (pale = a toss-up).
// The constants are the archived ones: VMAX and the ball's speed measured from the ten games' tracking and passes,
// REACT, SIGMA and LAMBDA picked from a small grid by how well they predicted which team ended up with passes.
// Coordinates are the play's stored frame: feet, the offense attacking the hoop at +x.

import { HALF_L, HALF_W, type Layout } from "./court";
import type { Play } from "./types";

const REACT = 0.4;              // s
const SIGMA = 0.15;             // s
const LAMBDA = 100;             // per s
const VMAX = 18.1147264926486;  // ft/s
const BALL0 = 0.0160704909212239, BALL1 = 0.0201103502526555;   // s, s per ft
const DT = 0.04, MAX_T = 6, TOL = 0.99;
const CELL = 2;                 // ft
const VEL_LAG = 6;              // frames: velocity from the position 0.24 s earlier
const MAX_SPEED = 30;           // ft/s; faster is a tracking jump

/** The players on court at one frame, offense first. */
export interface Bodies { x: Float64Array; y: Float64Array; vx: Float64Array; vy: Float64Array; nOff: number }

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
export function bodiesAt(play: Play, i: number): Bodies {
  const rows: [number, number, number, number, boolean][] = [];
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
    rows.push([x, y, vx, vy, p.role === "off"]);
  }
  rows.sort((a, b) => Number(b[4]) - Number(a[4]));
  return {
    x: Float64Array.from(rows, (r) => r[0]), y: Float64Array.from(rows, (r) => r[1]),
    vx: Float64Array.from(rows, (r) => r[2]), vy: Float64Array.from(rows, (r) => r[3]),
    nOff: rows.filter((r) => r[4]).length,
  };
}

/** The offense's share of control of each cell for a ball at (bx, by) (steps 1-5 above). */
export function timeToBallControl(b: Bodies, g: Grid, bx: number, by: number): Float64Array {
  const k = b.x.length, rx = new Float64Array(k), ry = new Float64Array(k);
  for (let j = 0; j < k; j++) {
    rx[j] = b.x[j] + b.vx[j] * REACT;
    ry[j] = b.y[j] + b.vy[j] * REACT;
  }
  const scale = Math.PI / Math.sqrt(3) / SIGMA, steps = Math.ceil(MAX_T / DT), rate = LAMBDA * DT;
  const tau = new Float64Array(k), P = new Float64Array(k), out = new Float64Array(g.x.length);
  for (let c = 0; c < g.x.length; c++) {
    const tBall = BALL0 + BALL1 * Math.hypot(g.x[c] - bx, g.y[c] - by);
    for (let j = 0; j < k; j++) {
      tau[j] = REACT + Math.hypot(g.x[c] - rx[j], g.y[c] - ry[j]) / VMAX;
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
  /** Offense share of its attacking half (x ≥ 0). */
  offHalf: number;
}

let lastKey = "", last: ControlReading | null = null;
/** Court control at index i of the play's frames (needs five a side and the ball), or null. */
export function controlAt(play: Play, i: number): ControlReading | null {
  const key = `${play.id}:${i}`;
  if (key === lastKey) return last;
  lastKey = key;
  const b = bodiesAt(play, i), bx = play.ball.x[i], by = play.ball.y[i];
  if (b.nOff < 5 || b.x.length - b.nOff < 5 || Number.isNaN(bx) || Number.isNaN(by)) return (last = null);
  const g = courtGrid(), pc = timeToBallControl(b, g, bx, by);
  let off = 0, cells = 0;
  for (let c = 0; c < pc.length; c++) if (g.x[c] >= 0) { off += pc[c]; cells++; }
  return (last = { pc, offHalf: off / cells });
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
