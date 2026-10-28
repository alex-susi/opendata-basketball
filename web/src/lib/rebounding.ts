// The rebounding models' outputs for a play: which missed shot is live at a frame, the forecast made from
// what had been seen by then, and how it is drawn on the court. The numbers are computed in R
// (src/rebounding/run_export.R) and exported per game; nothing here models anything.

import { COLORS, type Layout } from "./court";
import type { Play } from "./types";

/** One forecast, made at frame `f` from the observed prefix only. */
export interface ReboundStep {
  f: number;
  /** The ten players on court (offense first) and each one's chance of collecting the rebound. */
  pid: number[];
  p: number[];
  /** Talent-aware chances (collection effects), present only when those effects passed their test. */
  pt?: number[];
  /** Offensive player, defensive player, offensive team award, defensive team award, unresolved. */
  team: [number, number, number, number, number];
  /** Where the ball would first reach the floor if nobody touched it: a sample of simulated miss paths. */
  land: [number, number][];
  /** The same landings as a density on the game file's `heat` grid: flat (column, row, weight 3-100) triplets. */
  heat: number[];
  /** Share of simulated landings outside the court's lines. */
  out: number;
  /** Obstruction now: blocker b stands in opponent o's way to the reachable ball with strength s (0 to 1). */
  box: { b: number; o: number; s: number }[];
}

export interface ReboundEpisode {
  id: string;
  f0: number;
  f1: number;
  rf: number;
  rim: number;
  shooter: number;
  outcome: "off player" | "def player" | "off team award" | "def team award";
  rebounder: number | null;
  kind: string;
  range: string;
  steps: ReboundStep[];
  /** Box-out pairs of the episode with their automated label (spatial proxy, not reviewed video). */
  pairs: { b: number; o: number; label: string; max: number }[];
  /** Model-assessed movement in the first 0.48 s against a role-matched reference (out-of-fold). */
  anticipation: { pid: number; gain: number; team: number; exposure: number; moved: number }[];
}

/** The landing-density grid: cell (c, r) is centred at x0 + cell * (c + 0.5), y0 + cell * (r + 0.5) in feet. */
export interface HeatGrid {
  x0: number;
  y0: number;
  cell: number;
  nx: number;
  ny: number;
}

export interface ReboundGame {
  game: number;
  talent: boolean;
  heat: HeatGrid;
  episodes: ReboundEpisode[];
}

export type LandingView = "heat" | "dots" | "off";

export interface ReboundReading {
  episode: ReboundEpisode;
  step: ReboundStep;
  /** Seconds after release at which this forecast was made. */
  since: number;
  /** True once the recorded rebound frame has passed: the outcome can be shown. */
  resolved: boolean;
}

const HOLD = 30;   // frames the last forecast stays up after the rebound

/** The game id inside a play id ("possession-<game>-<period>-<n>"). */
export function gameOf(play: Play): number {
  return Number(play.id.split("-")[1]);
}

/** Missed shots released inside the play's frames, in order. */
export function episodesInPlay(play: Play, game: ReboundGame | null): ReboundEpisode[] {
  if (!game || !play.frames.length) return [];
  const a = play.frames[0], b = play.frames[play.frames.length - 1];
  return game.episodes.filter((e) => e.f0 >= a && e.f0 <= b).sort((x, y) => x.f0 - y.f0);
}

/** The live episode at a frame and its latest forecast made at or before it, or null. */
export function reboundAt(episodes: ReboundEpisode[], frame: number): ReboundReading | null {
  for (let k = episodes.length - 1; k >= 0; k--) {
    const e = episodes[k];
    if (frame < e.f0) continue;
    const end = Math.max(e.rf, e.steps[e.steps.length - 1].f) + HOLD;
    if (frame > end) return null;
    let step = e.steps[0];
    for (const s of e.steps) if (s.f <= frame) step = s;
    return { episode: e, step, since: (step.f - e.f0) / 25, resolved: frame >= e.rf };
  }
  return null;
}

/** Offense and defense totals of a forecast: player collection plus team award. */
export function sides(step: ReboundStep): { off: number; def: number; unresolved: number } {
  return { off: step.team[0] + step.team[2], def: step.team[1] + step.team[3], unresolved: step.team[4] };
}

// One violet hue for the landing forecast, so it never reads as either team (teams own the court control shading).
export const LANDING_COLOR: [number, number, number] = [74, 52, 196];
const LANDING_ALPHA = 0.85;

let raster: HTMLCanvasElement | null = null;

/** The landing density as a smoothed raster: violet, stronger where more simulated misses would first land. */
function drawHeat(ctx: CanvasRenderingContext2D, L: Layout, grid: HeatGrid, heat: number[]): void {
  raster ??= document.createElement("canvas");
  if (raster.width !== grid.nx || raster.height !== grid.ny) { raster.width = grid.nx; raster.height = grid.ny; }
  const rc = raster.getContext("2d")!, img = rc.createImageData(grid.nx, grid.ny);
  for (let k = 0; k + 2 < heat.length; k += 3) {
    // raster rows run top (largest y) to bottom
    const at = 4 * ((grid.ny - 1 - heat[k + 1]) * grid.nx + heat[k]), w = heat[k + 2] / 100;
    img.data[at] = LANDING_COLOR[0]; img.data[at + 1] = LANDING_COLOR[1]; img.data[at + 2] = LANDING_COLOR[2];
    img.data[at + 3] = Math.round(255 * LANDING_ALPHA * Math.sqrt(w));
  }
  rc.putImageData(img, 0, 0);
  ctx.save();
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  const top = grid.y0 + grid.ny * grid.cell;
  // the grid is in the play's stored frame; a play drawn in the camera's view turns it 180° about centre court
  ctx.translate(L.ox, L.oy);
  ctx.scale(L.f, L.f);
  ctx.drawImage(raster, grid.x0 * L.s, -top * L.s, grid.nx * grid.cell * L.s, grid.ny * grid.cell * L.s);
  ctx.restore();
}

/**
 * Draw a forecast under the players: where the ball would first land untouched (a density or the sample of
 * simulated landings) and the box-out links between the players' current positions. Each link runs from the
 * blocker to the opponent he obstructs, as thick as it is strong.
 * @param at Where each player is drawn now, by player id.
 * @param mark Each player's team outline colour, by player id.
 */
export function drawReboundUnder(ctx: CanvasRenderingContext2D, L: Layout, r: ReboundReading, grid: HeatGrid | null,
                                 view: LandingView, at: Map<number, [number, number]>, mark: Map<number, string>): void {
  const px = (x: number) => L.ox + L.f * x * L.s, py = (y: number) => L.oy - L.f * y * L.s;
  if (view === "heat" && grid && r.step.heat?.length) drawHeat(ctx, L, grid, r.step.heat);
  ctx.save();
  if (view === "dots") {
    ctx.globalAlpha = 0.75;
    ctx.fillStyle = `rgb(${LANDING_COLOR.join(",")})`;
    for (const [x, y] of r.step.land) {
      ctx.beginPath();
      ctx.arc(px(x), py(y), Math.max(2.5, 0.3 * L.s), 0, 2 * Math.PI);
      ctx.fill();
    }
  }
  ctx.lineCap = "round";
  for (const link of r.step.box) {
    const a = at.get(link.b), b = at.get(link.o);
    if (!a || !b || link.s < 0.2) continue;
    ctx.globalAlpha = 0.35 + 0.6 * Math.min(1, link.s);
    ctx.strokeStyle = mark.get(link.b) ?? COLORS.ink;
    ctx.lineWidth = 1.5 + 5 * Math.min(1, link.s);
    ctx.beginPath();
    ctx.moveTo(px(a[0]), py(a[1]));
    ctx.lineTo(px(b[0]), py(b[1]));
    ctx.stroke();
  }
  ctx.restore();
}

/** Collection chance beside each player who has at least `min` of it. */
export function collectionLabels(r: ReboundReading, talent: boolean, min = 0.05): Map<number, number> {
  const probs = talent && r.step.pt ? r.step.pt : r.step.p, out = new Map<number, number>();
  r.step.pid.forEach((id, i) => { if (probs[i] >= min) out.set(id, probs[i]); });
  return out;
}
