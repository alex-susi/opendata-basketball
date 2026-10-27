// Small helpers shared by the Rebounding tab's charts: linear scales, round tick values and the chart palette.
// Colours are the validated dark-mode categorical steps (dataviz reference palette), in its fixed order.

export const SERIES = ["#3987e5", "#d95926", "#199e70"];
export const RAMP = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"];

export function linear(d0: number, d1: number, r0: number, r1: number): (v: number) => number {
  const k = d1 === d0 ? 0 : (r1 - r0) / (d1 - d0);
  return (v: number) => r0 + (v - d0) * k;
}

/** Round tick values covering [lo, hi], about `n` of them. */
export function ticks(lo: number, hi: number, n = 5): number[] {
  if (!(hi > lo)) return [lo];
  const raw = (hi - lo) / n, mag = 10 ** Math.floor(Math.log10(raw)), f = raw / mag;
  const step = (f >= 5 ? 10 : f >= 2 ? 5 : f >= 1 ? 2 : 1) * mag;
  const out: number[] = [];
  for (let v = Math.ceil(lo / step - 1e-9) * step; v <= hi + 1e-9; v += step) out.push(Math.round(v / step) * step);
  return out;
}

export const fmt = (v: number, d = 0) => (Number.isFinite(v) ? v.toFixed(d) : "–");
export const pctFmt = (v: number, d = 0) => (Number.isFinite(v) ? `${(100 * v).toFixed(d)}%` : "–");
