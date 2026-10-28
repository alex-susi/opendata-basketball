// Plays are stored with the offense attacking +x and drawn in the camera's view: a play whose offense attacks the
// left hoop is turned 180° back, so the end of one play and the start of the next line up.
import { describe, expect, it } from "vitest";
import { courtLayout, HALF_L, px, py } from "../src/lib/court";

describe("court orientation", () => {
  it("draws a stored play as is, or turned 180° about centre court", () => {
    const right = courtLayout(1000, 600, "full", 6, 1), left = courtLayout(1000, 600, "full", 6, -1);
    expect(px(left, 0)).toBeCloseTo(px(right, 0));
    expect(py(left, 0)).toBeCloseTo(py(right, 0));
    // the stored hoop (+x, offense's end) is on the right as stored and on the left when turned back
    expect(px(right, 40)).toBeGreaterThan(px(right, 0));
    expect(px(left, 40)).toBeLessThan(px(left, 0));
    // a rotation, not a mirror: +y goes down the screen as well
    expect(px(left, 10) - px(left, 0)).toBeCloseTo(-(px(right, 10) - px(right, 0)));
    expect(py(left, 10) - py(left, 0)).toBeCloseTo(-(py(right, 10) - py(right, 0)));
  });

  it("shows the attacked half in the half-court view either way", () => {
    for (const f of [1, -1] as const) {
      const L = courtLayout(1000, 600, "half", 6, f);
      for (const x of [0, HALF_L]) {
        expect(px(L, x)).toBeGreaterThanOrEqual(L.left - 1e-6);
        expect(px(L, x)).toBeLessThanOrEqual(L.left + L.cw + 1e-6);
      }
    }
  });
});
