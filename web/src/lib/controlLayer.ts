// Draws court control under the players: whichever layer is chosen while the ball is live, and the rebound
// surface while a shot is in the air. The numbers come from lib/control.ts; this file only caches and paints.

import { HALF_L, HALF_W, type Layout } from "./court";
import {
  bodiesAt, courtGrid, generalControl, reboundChance, relevance, shotInAir, valueOnGrid,
  type ControlParams, type Grid,
} from "./control";
import type { Play } from "./types";

export type ControlMode = "control" | "relevant" | "scoring";

export interface ControlReading {
  kind: ControlMode | "rebound";
  grid: Grid;
  /** Offense share of control in each cell. */
  pc: Float64Array;
  /** How strongly each cell is drawn, 0 to 1. */
  weight: Float64Array;
  /** Scoring mode draws in the offense's colour alone; the others run from defense to offense. */
  oneSided: boolean;
  /** Readout cells (label, value) for the side panel. */
  readout: [string, string][];
}

const MAX_ALPHA = 0.66;
const REBOUND_ALPHA = 0.42;  // lighter while a shot is in the air, so the rebounding forecast drawn over it stays readable
// Fallback colours when a play has no team colours. Plays carry their clubs' colours, de-clashed in the export
// (team_kit() in src/play_viewer/R/data.R swaps the away kit when the two primaries are too alike).
export const CONTROL_COLORS = { off: "#1F6FE5", def: "#F26A36" };
const NEUTRAL: [number, number, number] = [246, 246, 246];
const TOSS_UP_ALPHA = 0.3;   // share of full strength at which a 50-50 spot is drawn (not on the rebound surface)
const SATURATE = 0.35;       // a team's colour is at full strength this far from 50-50

interface Grids {
  p: ControlParams;
  general: Grid;
  rebound: Grid;
  value: Float64Array;
  half: Float64Array;
}

let grids: Grids | null = null;
function gridsFor(p: ControlParams): Grids {
  if (grids?.p !== p) {
    const general = courtGrid(p, p.general.cell);
    grids = { p, general, rebound: courtGrid(p, p.rebound.cell, true, p.rebound.reach), value: valueOnGrid(general, p),
              half: Float64Array.from(general.x, (x) => (x >= 0 ? 1 : 0)) };
  }
  return grids;
}

const pct = (v: number) => `${Math.round(v * 100)}%`;
// The latest reading: playback asks for the same frame many times.
let lastKey = "", last: ControlReading | null = null;
const atRelease = new Map<string, number>();

/** Court control at index i of the play's frames, or null when nothing can be drawn there. */
export function controlAt(play: Play, i: number, mode: ControlMode, p: ControlParams): ControlReading | null {
  const key = `${play.id}:${i}:${mode}`;
  if (key === lastKey) return last;
  lastKey = key;
  last = compute(play, i, mode, p);
  return last;
}

function compute(play: Play, i: number, mode: ControlMode, p: ControlParams): ControlReading | null {
  const G = gridsFor(p), b = bodiesAt(play, i);
  if (b.nOff < 5 || b.x.length - b.nOff < 5) return null;
  const shot = shotInAir(play, i, p);
  // While a shot is in the air the surface is control with rebound timing (the ball reaches each spot when a miss
  // would), drawn everywhere near the basket. Its own rebound chance is not shown: the rebounding panel's models
  // (src/rebounding/) replace it.
  if (shot) {
    const now = reboundChance(b, G.rebound, shot.sx, shot.sy, shot.elapsed, p);
    return { kind: "rebound", grid: G.rebound, pc: now.pc, weight: new Float64Array(now.pc.length).fill(1), oneSided: false, readout: [] };
  }
  const bx = play.ball.x[i], by = play.ball.y[i];
  if (Number.isNaN(bx) || Number.isNaN(by)) return null;
  const pc = generalControl(b, G.general, bx, by, p), n = pc.length;
  if (mode === "control") {
    let off = 0, cells = 0;
    for (let c = 0; c < n; c++) if (G.half[c]) { off += pc[c]; cells++; }
    return { kind: mode, grid: G.general, pc, weight: new Float64Array(n).fill(1), oneSided: false,
             readout: [["Offense controls of its half", pct(off / cells)]] };
  }
  const w = relevance(G.general, bx, by, pc, p);
  if (mode === "relevant") {
    let top = 0, next = 0;
    for (let c = 0; c < n; c++) { top = Math.max(top, w[c]); next += w[c] * pc[c]; }
    return { kind: mode, grid: G.general, pc, weight: w.map((v) => Math.sqrt(v / top)), oneSided: false,
             readout: [["Offense control where the ball goes next", pct(next)]] };
  }
  const so = new Float64Array(n);
  let total = 0;
  for (let c = 0; c < n; c++) total += so[c] = pc[c] * w[c] * G.value[c];
  return { kind: mode, grid: G.general, pc, weight: so.map((v) => Math.min(1, Math.sqrt(v / p.relevance.obsoRef))), oneSided: true,
           readout: [["Scoring opportunity", `${total.toFixed(2)} pts`]] };
}

function rgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const n = parseInt(h.length === 3 ? h.replace(/./g, (c) => c + c) : h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

let raster: HTMLCanvasElement | null = null;

/** Paint a reading over the floor, clipped to the court's lines. */
export function drawControl(ctx: CanvasRenderingContext2D, L: Layout, r: ControlReading, colors: { off: string; def: string } = CONTROL_COLORS): void {
  const g = r.grid, offC = rgb(colors.off), defC = rgb(colors.def);
  raster ??= document.createElement("canvas");
  if (raster.width !== g.nx || raster.height !== g.ny) {
    raster.width = g.nx;
    raster.height = g.ny;
  }
  const rc = raster.getContext("2d")!, img = rc.createImageData(g.nx, g.ny);
  for (let c = 0; c < g.at.length; c++) {
    const at = 4 * g.at[c], t = r.pc[c];
    let color: [number, number, number], strength = 1;
    if (r.oneSided) color = offC;
    else {
      const end = t >= 0.5 ? offC : defC, s = Math.min(1, Math.abs(t - 0.5) / SATURATE);
      color = [0, 1, 2].map((k) => NEUTRAL[k] + (end[k] - NEUTRAL[k]) * s) as [number, number, number];
      strength = TOSS_UP_ALPHA + (1 - TOSS_UP_ALPHA) * s;
    }
    img.data[at] = color[0];
    img.data[at + 1] = color[1];
    img.data[at + 2] = color[2];
    img.data[at + 3] = Math.round(255 * (r.kind === "rebound" ? REBOUND_ALPHA : MAX_ALPHA) * strength * r.weight[c]);
  }
  rc.putImageData(img, 0, 0);
  ctx.save();
  ctx.beginPath();
  ctx.rect(L.ox - HALF_L * L.s, L.oy - HALF_W * L.s, 2 * HALF_L * L.s, 2 * HALF_W * L.s);
  ctx.clip();
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(raster, L.ox - HALF_L * L.s, L.oy - HALF_W * L.s, g.nx * g.cell * L.s, g.ny * g.cell * L.s);
  ctx.restore();
}
