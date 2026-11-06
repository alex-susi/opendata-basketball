// Court control, computed live from each frame's tracking with the parameters fitted in R
// (src/court_control/build_control.R, written to public/data/control.json). Every function here mirrors
// one in src/court_control/R/control.R; tests/control.test.ts checks them against R's reference cases.
// No DOM here.
//
// Coordinates are feet with the offense attacking the hoop at (hoopX, 0), as in the decoded plays.

import type { Play, PlayEvent } from "./types";

export interface ControlParams {
  built: string;
  court: { halfL: number; halfW: number; hoopX: number };
  integration: { dt: number; maxT: number; tol: number };
  general: { react: number; sigma: number; lambda: number; vmax: number; ball0: number; ball1: number; cell: number };
  rebound: {
    react: number; sigma: number; lambda: number; kappa: number; vmax: number;
    flight0: number; flight1: number; bounce0: number; bounce1: number; team_share: number; team_oreb: number;
    land0: number; land1: number; shape: number; focus: number; floor: number; cell: number; reach: number;
  };
  relevance: { spread: number; tilt: number; pull: number; aheadSeconds: number; obsoRef: number };
  value: { cell: number; nx: number; ny: number; v: number[] };
}

/** The players on court at one frame, offense first. */
export interface Bodies {
  x: Float64Array;
  y: Float64Array;
  vx: Float64Array;
  vy: Float64Array;
  /** Number of offensive players: the first nOff entries. */
  nOff: number;
}

/** Cell centres in row-major order (top row first, left to right), as court_grid() in R. */
export interface Grid {
  cell: number;
  nx: number;
  ny: number;
  /** Index of each kept cell in the full nx x ny raster. */
  at: Int32Array;
  x: Float64Array;
  y: Float64Array;
}

const VEL_LAG = 6;      // backward difference over 0.24 s, as add_velocity() in src/epv/R/features.R
const MAX_SPEED = 30;   // ft/s

export function courtGrid(p: ControlParams, cell: number, half = false, reach: number | null = null): Grid {
  const { halfL, halfW, hoopX } = p.court;
  const nx = Math.ceil((2 * halfL) / cell), ny = Math.ceil((2 * halfW) / cell);
  const at: number[] = [], xs: number[] = [], ys: number[] = [];
  for (let j = 0; j < ny; j++) {
    const y = halfW - cell * (j + 0.5);
    for (let i = 0; i < nx; i++) {
      const x = -halfL + cell * (i + 0.5);
      if (half && x < 0) continue;
      if (reach != null && Math.hypot(x - hoopX, y) > reach) continue;
      at.push(j * nx + i);
      xs.push(x);
      ys.push(y);
    }
  }
  return { cell, nx, ny, at: Int32Array.from(at), x: Float64Array.from(xs), y: Float64Array.from(ys) };
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

interface Physics {
  react: number;
  sigma: number;
  lambda: number;
  vmax: number;
}

/**
 * Offense share of control at each spot when the ball reaches it at tBall[k] (offense_control() in R).
 * Each player keeps his velocity for the reaction time, then runs straight to the spot at top speed; his
 * chance of having arrived by time t is logistic in t minus that arrival time. While the spot is free, an
 * arrived player takes it at rate lambda (defenders at kappa * lambda).
 */
export function offenseControl(b: Bodies, qx: Float64Array, qy: Float64Array, tBall: Float64Array, ph: Physics,
                               it: ControlParams["integration"], kappa = 1, out = new Float64Array(qx.length)): Float64Array {
  const k = b.x.length, rx = new Float64Array(k), ry = new Float64Array(k), lam = new Float64Array(k);
  for (let j = 0; j < k; j++) {
    rx[j] = b.x[j] + b.vx[j] * ph.react;
    ry[j] = b.y[j] + b.vy[j] * ph.react;
    lam[j] = ph.lambda * (j < b.nOff ? 1 : kappa) * it.dt;
  }
  const scale = Math.PI / Math.sqrt(3) / ph.sigma, steps = Math.ceil(it.maxT / it.dt);
  const tau = new Float64Array(k), P = new Float64Array(k);
  for (let c = 0; c < qx.length; c++) {
    for (let j = 0; j < k; j++) {
      tau[j] = ph.react + Math.hypot(qx[c] - rx[j], qy[c] - ry[j]) / ph.vmax;
      P[j] = 0;
    }
    let tot = 0;
    for (let s = 1; s <= steps; s++) {
      const t = tBall[c] + s * it.dt, free = 1 - tot;
      let next = 0;
      for (let j = 0; j < k; j++) {
        P[j] += (free * lam[j]) / (1 + Math.exp(-(t - tau[j]) * scale));
        next += P[j];
      }
      tot = next;
      if (tot >= it.tol) break;
    }
    let off = 0;
    for (let j = 0; j < b.nOff; j++) off += P[j];
    out[c] = off / Math.max(tot, 1e-9);
  }
  return out;
}

/** Ball travel time from (bx, by) to each spot of a grid, as a pass. */
export function ballTimes(g: Grid, bx: number, by: number, p: ControlParams): Float64Array {
  const t = new Float64Array(g.x.length);
  for (let c = 0; c < t.length; c++) t[c] = p.general.ball0 + p.general.ball1 * Math.hypot(g.x[c] - bx, g.y[c] - by);
  return t;
}

/** Offense control over the court for a ball at (bx, by). */
export function generalControl(b: Bodies, g: Grid, bx: number, by: number, p: ControlParams): Float64Array {
  return offenseControl(b, g.x, g.y, ballTimes(g, bx, by, p), p.general, p.integration);
}

/** Where the ball is likely to be aheadSeconds from now, summing to one over the grid (relevance() in R). */
export function relevance(g: Grid, bx: number, by: number, pc: Float64Array, p: ControlParams): Float64Array {
  const { spread, tilt, pull } = p.relevance, hoopX = p.court.hoopX, n = g.x.length;
  const lw = new Float64Array(n);
  let top = -Infinity;
  for (let c = 0; c < n; c++) {
    const d2 = (g.x[c] - bx) ** 2 + (g.y[c] - by) ** 2;
    lw[c] = -d2 / (2 * spread * spread) + tilt * Math.log(Math.max(pc[c], 1e-4)) - (pull * Math.hypot(g.x[c] - hoopX, g.y[c])) / 10;
    if (lw[c] > top) top = lw[c];
  }
  let sum = 0;
  for (let c = 0; c < n; c++) sum += lw[c] = Math.exp(lw[c] - top);
  for (let c = 0; c < n; c++) lw[c] /= sum;
  return lw;
}

/** Expected points of a shot from each cell of the general grid (location xFG times 2 or 3; 0 beyond 30 ft). */
export function valueOnGrid(g: Grid, p: ControlParams): Float64Array {
  const v = new Float64Array(g.x.length);
  for (let c = 0; c < v.length; c++) v[c] = p.value.v[g.at[c]] ?? 0;
  return v;
}

export interface Rebound {
  /** Chance of an offensive rebound if the shot misses. */
  p: number;
  /** Offense control at each rebound cell. */
  pc: Float64Array;
  /** Where the miss is rebounded: sums to one over the rebound cells. */
  dens: Float64Array;
}

/** Unnormalised landing density per square foot of a miss from (sx, sy) (landing_weight() in R). */
function landingWeight(qx: number, qy: number, sx: number, sy: number, r: ControlParams["rebound"], hoopX: number): number {
  const rr = Math.max(Math.hypot(qx - hoopX, qy), 0.25), dist = Math.hypot(sx - hoopX, sy);
  const mu = r.land0 + r.land1 * Math.min(dist, 30);
  const side = Math.cos(Math.atan2(qy, qx - hoopX) - Math.atan2(sy, sx - hoopX));
  return rr ** (r.shape - 2) * Math.exp((-r.shape * rr) / mu) * (Math.exp(r.focus * (side - 1)) + r.floor);
}

/** Chance of an offensive rebound for a shot released from (sx, sy), `elapsed` seconds ago (rebound_chance() in R). */
export function reboundChance(b: Bodies, g: Grid, sx: number, sy: number, elapsed: number, p: ControlParams): Rebound {
  const r = p.rebound, hoopX = p.court.hoopX, n = g.x.length, dist = Math.hypot(sx - hoopX, sy);
  const flightLeft = Math.max(r.flight0 + r.flight1 * Math.min(dist, 40) - elapsed, 0);
  const t = new Float64Array(n), dens = new Float64Array(n);
  let sum = 0;
  for (let c = 0; c < n; c++) {
    t[c] = flightLeft + r.bounce0 + r.bounce1 * Math.hypot(g.x[c] - hoopX, g.y[c]);
    sum += dens[c] = landingWeight(g.x[c], g.y[c], sx, sy, r, hoopX);
  }
  const pc = offenseControl(b, g.x, g.y, t, r, p.integration, r.kappa);
  let grabbed = 0;
  for (let c = 0; c < n; c++) {
    dens[c] /= sum;
    grabbed += dens[c] * pc[c];
  }
  return { p: (1 - r.team_share) * grabbed + r.team_share * r.team_oreb, pc, dens };
}

/** Seconds from release until a shot from `dist` feet reaches the rim. */
export function flightSeconds(dist: number, p: ControlParams): number {
  return p.rebound.flight0 + p.rebound.flight1 * Math.min(dist, 40);
}

export interface ShotInAir {
  /** The release event. */
  event: PlayEvent;
  /** Index in play.frames of the release. */
  i: number;
  sx: number;
  sy: number;
  /** Seconds since release. */
  elapsed: number;
}

/**
 * The shot in the air at frame index i, if any: from its release until the rebound (a miss) or until the ball
 * reaches the rim (a make). The outcome only decides how long the overlay stays; the chances never use it.
 */
export function shotInAir(play: Play, i: number, p: ControlParams): ShotInAir | null {
  const frame = play.frames[i];
  let event: PlayEvent | null = null;
  for (const e of play.events) {
    if (e.f > frame) break;
    if (e.kind === "made" || e.kind === "missed") event = e;
  }
  if (!event || frame - event.f > 5 * 25) return null;
  let at = i;
  while (at > 0 && play.frames[at] > event.f) at--;
  if (play.frames[at] !== event.f) return null;
  // The shooter's spot, as in R: the offensive player nearest the ball at release.
  const bx = play.ball.x[at], by = play.ball.y[at];
  if (Number.isNaN(bx) || Number.isNaN(by)) return null;
  let sx = bx, sy = by, best = Infinity;
  for (const pl of play.players) {
    const d = Math.hypot(pl.x[at] - bx, pl.y[at] - by);
    if (pl.role === "off" && d < best) [best, sx, sy] = [d, pl.x[at], pl.y[at]];
  }
  const elapsed = (frame - event.f) / 25;
  if (event.kind === "made") {
    if (elapsed > flightSeconds(Math.hypot(sx - p.court.hoopX, sy), p) + 0.3) return null;
  } else {
    const ends = play.events.find((e) => e.f > event!.f && (e.kind === "rebound" || e.kind === "turnover" || e.kind === "foul"));
    if (ends && frame > ends.f) return null;
  }
  return { event, i: at, sx, sy, elapsed };
}
