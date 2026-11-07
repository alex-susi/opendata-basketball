// The site's time-to-ball court control (src/lib/control.ts) against the R implementation it was ported from.
// tests/control_reference.json was written by the archived zz_Archive/src/court_control/build_control.R: three
// frames' players and R's offense share of control at a sample of cells (general_pc). The rebound, relevance and
// scoring fields in it belong to archived layers and are not checked here.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { courtGrid, timeToBallControl, type Bodies } from "../src/lib/control";

interface Case {
  players: { x: number[]; y: number[]; vx: number[]; vy: number[] };
  general_cells: number[];
  general_pc: number[];
}

const cases: Case[] = JSON.parse(readFileSync(join(__dirname, "control_reference.json"), "utf8"));

describe("time-to-ball court control matches R", () => {
  const g = courtGrid();
  cases.forEach((c, n) => {
    it(`case ${n + 1}`, () => {
      const b: Bodies = { x: Float64Array.from(c.players.x), y: Float64Array.from(c.players.y),
                          vx: Float64Array.from(c.players.vx), vy: Float64Array.from(c.players.vy), nOff: 5 };
      // R puts the ball with the first offensive player; its cells are 1-based.
      const pc = timeToBallControl(b, g, c.players.x[0], c.players.y[0]);
      c.general_cells.forEach((cell, k) => expect(pc[cell - 1]).toBeCloseTo(c.general_pc[k], 6));
    });
  });

  it("gives each team the spots right next to its own players", () => {
    const c = cases[0];
    const b: Bodies = { x: Float64Array.from(c.players.x), y: Float64Array.from(c.players.y),
                        vx: new Float64Array(10), vy: new Float64Array(10), nOff: 5 };
    const pc = timeToBallControl(b, g, c.players.x[0], c.players.y[0]);
    const nearest = (x: number, y: number) => g.x.reduce((best, _, k) => (Math.hypot(g.x[k] - x, g.y[k] - y) < Math.hypot(g.x[best] - x, g.y[best] - y) ? k : best), 0);
    expect(pc[nearest(c.players.x[0], c.players.y[0])]).toBeGreaterThan(0.5);
  });
});
