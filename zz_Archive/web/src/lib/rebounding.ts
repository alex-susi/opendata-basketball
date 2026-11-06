// The rebounding models' outputs for a play: which missed shot is live at a frame, the forecast made from
// what had been seen by then, and how it is drawn on the court. The numbers are computed in R
// (src/rebounding/run_export.R) and exported per game; nothing here models anything.

import { COLORS, HALF_L, HALF_W, type Layout } from "./court";
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
  /** Seconds since the ball was seen reaching the rim, on forecasts made by the late model; absent before. */
  tau?: number;
  /** Set when the chances (p, team) are Step 09's held-out forecast rather than the first build's. */
  source?: { model: "step09"; tp: string; fold: number; since: number };
}

/** One of Step 09's two held-out forecasts of a miss (rebounding_manual/<game>.json, src/rebounding/run_export_manual.R). */
export interface Step09Step {
  /** Frame the forecast was made at (its information time). */
  f: number;
  tp: string;
  /** Outer fold: the model was fitted on the other nine games. */
  fold: number;
  /** The ten players, offense first, and each one's chance; then the two team awards. */
  pid: number[];
  p: number[];
  team_off: number;
  team_def: number;
}
export interface Step09Game { game: number; model: string; gate: string; built: string; episodes: { id: string; steps: Step09Step[] }[] }
/** Whose chances the viewer shows: Step 09's validated model, or the first build's. */
export type ReboundModel = "step09" | "first";

/** Step 09's forecast live at a frame: the latest made at or before it, or null. */
export function step09At(steps: Step09Step[] | undefined, frame: number): Step09Step | null {
  let out: Step09Step | null = null;
  for (const s of steps ?? []) if (s.f <= frame && (!out || s.f >= out.f)) out = s;
  return out;
}

// One merged step per (first-build step, Step 09 forecast), so the same pair keeps the same object between frames.
const merged = new WeakMap<ReboundStep, Map<Step09Step, ReboundStep>>();

/**
 * The reading with Step 09's chances in place of the first build's: each player's chance, the two sides' collection and
 * award shares (nothing is left unresolved). The landing forecast and the blocking links stay the first build's. The
 * reading comes back unchanged when Step 09 has no forecast yet or does not cover the same ten players.
 */
export function withStep09(r: ReboundReading | null, forecasts: Map<string, Step09Step[]>, frame: number): ReboundReading | null {
  if (!r) return r;
  const s = step09At(forecasts.get(r.episode.id), frame);
  if (!s) return r;
  let byStep = merged.get(r.step);
  if (!byStep) { byStep = new Map(); merged.set(r.step, byStep); }
  let step = byStep.get(s);
  if (!step) {
    const at = new Map(s.pid.map((id, i) => [id, i]));
    if (r.step.pid.some((id) => !at.has(id))) return r;
    const off = s.p.slice(0, 5).reduce((a, b) => a + b, 0), def = s.p.slice(5).reduce((a, b) => a + b, 0);
    step = { ...r.step, p: r.step.pid.map((id) => s.p[at.get(id)!]), pt: undefined,
             team: [off, def, s.team_off, s.team_def, 0], source: { model: "step09", tp: s.tp, fold: s.fold, since: (s.f - r.episode.f0) / 25 } };
    byStep.set(s, step);
  }
  return { ...r, step };
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

export type LandingView = "regions" | "heat" | "dots" | "off";

/** An ellipse on the court, in feet: centre, semi-axes (a >= b) and the major axis's angle from +x (radians). */
export interface Ellipse { cx: number; cy: number; a: number; b: number; theta: number }

/**
 * The region holding `level` of the simulated landings if they were spread normally: the sample's mean and covariance,
 * scaled by the chi-square quantile with two degrees of freedom (sqrt(-2 ln(1 - level))). Axes are at least `minAxis`
 * feet so a tight forecast still shows. Null with fewer than three landings.
 */
export function landingEllipse(land: [number, number][], level: number, minAxis = 0.75): Ellipse | null {
  const m = land.length;
  if (m < 3) return null;
  let cx = 0, cy = 0;
  for (const [x, y] of land) { cx += x; cy += y; }
  cx /= m; cy /= m;
  let sxx = 0, syy = 0, sxy = 0;
  for (const [x, y] of land) { sxx += (x - cx) ** 2; syy += (y - cy) ** 2; sxy += (x - cx) * (y - cy); }
  sxx /= m - 1; syy /= m - 1; sxy /= m - 1;
  // eigenvalues of [[sxx, sxy], [sxy, syy]]
  const tr = (sxx + syy) / 2, d = Math.sqrt(((sxx - syy) / 2) ** 2 + sxy ** 2);
  const l1 = tr + d, l2 = Math.max(0, tr - d);
  const theta = 0.5 * Math.atan2(2 * sxy, sxx - syy);
  const k = Math.sqrt(-2 * Math.log(1 - level));
  return { cx, cy, a: Math.max(minAxis, k * Math.sqrt(l1)), b: Math.max(minAxis, k * Math.sqrt(l2)), theta };
}

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

// Warm sand for the landing regions: a soft outer region (90%) with a dashed edge and a stronger core (50%).
const REGION_RGB = "236, 196, 112";
const REGION_EDGE = "190, 140, 60";
export const LANDING_LEVELS = { outer: 0.9, inner: 0.5 } as const;

/** The landing forecast as two nested regions (90% dashed, 50% core), from the simulated landings. */
function drawRegions(ctx: CanvasRenderingContext2D, L: Layout, land: [number, number][]): void {
  const outer = landingEllipse(land, LANDING_LEVELS.outer), inner = landingEllipse(land, LANDING_LEVELS.inner);
  if (!outer || !inner) return;
  // screen y runs down, so angles flip sign; a play drawn turned 180° (L.f = -1) gives the same ellipse
  const path = (e: Ellipse) => {
    ctx.beginPath();
    ctx.ellipse(L.ox + L.f * e.cx * L.s, L.oy - L.f * e.cy * L.s, e.a * L.s, e.b * L.s, -e.theta, 0, 2 * Math.PI);
  };
  ctx.save();
  // drawn inside the court's lines only; the panel states the share of landings out of bounds
  const x0 = L.ox - HALF_L * L.s, y0 = L.oy - HALF_W * L.s;
  ctx.beginPath();
  ctx.rect(x0, y0, 2 * HALF_L * L.s, 2 * HALF_W * L.s);
  ctx.clip();
  path(outer);
  ctx.fillStyle = `rgba(${REGION_RGB}, 0.16)`;
  ctx.fill();
  ctx.setLineDash([7, 6]);
  ctx.lineWidth = 2;
  ctx.strokeStyle = `rgba(${REGION_EDGE}, 0.6)`;   // a deeper sand, so the edge reads on the wooden court
  ctx.stroke();
  path(inner);
  ctx.setLineDash([]);
  ctx.fillStyle = `rgba(${REGION_RGB}, 0.5)`;
  ctx.fill();
  ctx.restore();
}

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
  if (view === "regions") drawRegions(ctx, L, r.step.land);
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
