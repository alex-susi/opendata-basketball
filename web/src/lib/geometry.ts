// Small pure helpers shared by the drawing code and the components.

export type Point = [number, number];

export const clamp = (v: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, v));

/** Seconds as m:ss (game clock, elapsed time). */
export const clock = (s: number): string => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

export const quarter = (p: number): string => (p <= 4 ? `Q${p}` : `OT${p - 4}`);

export const pct = (v: number, digits: number): string => `${(100 * v).toFixed(digits)}%`;

/** Convex hull by Andrew's monotone chain, counter-clockwise, without the closing point. */
export function convexHull(points: Point[]): Point[] {
  if (points.length < 3) return points.slice();
  const p = points.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const cross = (o: Point, a: Point, b: Point) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const chain = (pts: Point[]) => {
    const out: Point[] = [];
    for (const q of pts) {
      while (out.length >= 2 && cross(out[out.length - 2], out[out.length - 1], q) <= 0) out.pop();
      out.push(q);
    }
    out.pop();
    return out;
  };
  return chain(p).concat(chain(p.slice().reverse()));
}

/** Area of a simple polygon (shoelace formula). */
export function polygonArea(poly: Point[]): number {
  let twice = 0;
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i], b = poly[(i + 1) % poly.length];
    twice += a[0] * b[1] - b[0] * a[1];
  }
  return Math.abs(twice) / 2;
}
