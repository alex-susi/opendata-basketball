// Smoothed densities for the court maps: a Gaussian kernel density of (optionally weighted) points on a regular
// grid around the hoop, and the image that draws it on the sequential blue ramp.
import { RAMP } from "./scale";

/** Cell (c, r) is centred at x0 + cell * (c + 0.5), y0 + cell * (r + 0.5), in feet relative to the hoop. */
export interface Grid { x0: number; y0: number; cell: number; nx: number; ny: number }
export interface Pt { x: number; y: number; w?: number }

/** A grid covering x0..x1 by y0..y1 feet in `cell` ft squares. */
export function gridOf(x0: number, x1: number, y0: number, y1: number, cell = 0.5): Grid {
  return { x0, y0, cell, nx: Math.ceil((x1 - x0) / cell), ny: Math.ceil((y1 - y0) / cell) };
}

/**
 * Kernel density in share per square foot: each point spreads its weight as a Gaussian of sd `bw` feet, and the
 * weights are normalised to sum to one, so maps with different numbers of points are on the same scale.
 * Row 0 of the result is the bottom of the grid (smallest y).
 */
export function kde(points: Pt[], g: Grid, bw: number): Float64Array {
  const out = new Float64Array(g.nx * g.ny);
  const total = points.reduce((s, p) => s + (p.w ?? 1), 0);
  if (!(total > 0)) return out;
  const reach = Math.ceil((3 * bw) / g.cell), k = 1 / (2 * Math.PI * bw * bw * total), inv = 1 / (2 * bw * bw);
  for (const p of points) {
    const w = p.w ?? 1;
    if (!(w > 0)) continue;
    const ci = Math.floor((p.x - g.x0) / g.cell), ri = Math.floor((p.y - g.y0) / g.cell);
    for (let r = Math.max(0, ri - reach); r <= Math.min(g.ny - 1, ri + reach); r++) {
      const dy = g.y0 + g.cell * (r + 0.5) - p.y;
      for (let c = Math.max(0, ci - reach); c <= Math.min(g.nx - 1, ci + reach); c++) {
        const dx = g.x0 + g.cell * (c + 0.5) - p.x;
        out[r * g.nx + c] += w * k * Math.exp(-(dx * dx + dy * dy) * inv);
      }
    }
  }
  return out;
}

export const peak = (d: Float64Array) => d.reduce((m, v) => (v > m ? v : m), 0);

const RGB = RAMP.map((h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)));

/** The ramp colour at t in [0, 1], light to dark. */
export function rampAt(t: number): number[] {
  const u = Math.min(1, Math.max(0, t)) * (RGB.length - 1), i = Math.min(RGB.length - 2, Math.floor(u)), f = u - i;
  return RGB[i].map((v, j) => Math.round(v + f * (RGB[i + 1][j] - v)));
}

/**
 * The density as a PNG data URL, one pixel per cell, top row first: darker and more opaque where denser, clear
 * where there is (almost) nothing, so the floor and its lines show through. `vmax` fixes the top of the scale.
 */
export function heatImage(d: Float64Array, g: Grid, vmax: number): string {
  const canvas = document.createElement("canvas");
  canvas.width = g.nx;
  canvas.height = g.ny;
  const ctx = canvas.getContext("2d");
  if (!ctx || !(vmax > 0)) return "";
  const img = ctx.createImageData(g.nx, g.ny);
  for (let r = 0; r < g.ny; r++) {
    for (let c = 0; c < g.nx; c++) {
      const t = d[r * g.nx + c] / vmax;
      if (t < 0.02) continue;
      // the ramp's palest steps turn grey over the tan floor, so the faint end fades out in mid blue instead
      const at = 4 * ((g.ny - 1 - r) * g.nx + c), [R, G, B] = rampAt(0.3 + 0.7 * Math.min(1, t));
      img.data[at] = R; img.data[at + 1] = G; img.data[at + 2] = B;
      img.data[at + 3] = Math.round(255 * Math.min(0.92, 1.05 * Math.sqrt(t)));
    }
  }
  ctx.putImageData(img, 0, 0);
  return canvas.toDataURL();
}
