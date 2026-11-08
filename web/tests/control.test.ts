// The site's time-to-ball court control (src/lib/control.ts) against the R implementation it was ported from.
// tests/control_reference.json was written by the archived zz_Archive/src/court_control/build_control.R: three
// frames' players and R's offense share of control at a sample of cells (general_pc). The rebound, relevance and
// scoring fields in it belong to archived layers and are not checked here.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { courtGrid, runTime, timeToBallControl, type Bodies } from "../src/lib/control";
import type { Sample } from "../src/lib/types";

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

describe("per-player sprint speeds", () => {
  const sample = JSON.parse(readFileSync(join(__dirname, "..", "public", "data", "sample.json"), "utf8")) as Sample;
  const g = courtGrid();

  it("average the archived single speed over the players' live frames, with a realistic spread", () => {
    const rows = Object.values(sample.players).filter((p) => p.trk?.vmax != null);
    expect(rows.length).toBeGreaterThan(150);
    const v = rows.map((p) => p.trk!.vmax!);
    expect(Math.min(...v)).toBeGreaterThan(14);
    expect(Math.max(...v)).toBeLessThan(23);
    expect(Math.max(...v) - Math.min(...v)).toBeGreaterThan(2);
  });

  it("let the faster of two equidistant players win the spot between them", () => {
    // One attacker and one defender, 20 ft either side of a cell on the far side of the court from the ball.
    const cell = g.x.findIndex((x, k) => Math.abs(x - 21) < 1.01 && Math.abs(g.y[k] - 1) < 1.01);
    const at = (vOff: number, vDef: number) => {
      const b: Bodies = { x: Float64Array.of(g.x[cell] - 20, g.x[cell] + 20), y: Float64Array.of(g.y[cell], g.y[cell]),
                          vx: new Float64Array(2), vy: new Float64Array(2), nOff: 1, vmax: Float64Array.of(vOff, vDef) };
      return timeToBallControl(b, g, -40, 0)[cell];
    };
    expect(at(18, 18)).toBeCloseTo(0.5, 2);
    expect(at(20, 16.5)).toBeGreaterThan(0.6);
    expect(at(16.5, 20)).toBeLessThan(0.4);
  });
});

describe("acceleration-limited runs", () => {
  it("match instant top speed only when already at top speed toward the spot", () => {
    expect(runTime(30, 18, 18, 12, 12)).toBeCloseTo(30 / 18, 6);
    expect(runTime(30, 0, 18, 12, 12)).toBeGreaterThan(30 / 18 + 0.6);
  });

  it("make a player moving away stop first, and one at walking pace speed up", () => {
    const standing = runTime(15, 0, 18, 12, 12), toward = runTime(15, 8, 18, 12, 12), away = runTime(15, -8, 18, 12, 12);
    expect(toward).toBeLessThan(standing);
    expect(away).toBeGreaterThan(standing + 8 / 12);
  });

  it("follow constant acceleration on short runs", () => {
    expect(runTime(6, 0, 18, 12, 12)).toBeCloseTo(1, 6);   // 6 = 12 t² / 2
  });

  it("let the quicker starter win a spot both reach at the same top speed", () => {
    const g = courtGrid();
    const cell = g.x.findIndex((x, k) => Math.abs(x - 21) < 1.01 && Math.abs(g.y[k] - 1) < 1.01);
    const b: Bodies = { x: Float64Array.of(g.x[cell] - 12, g.x[cell] + 12), y: Float64Array.of(g.y[cell], g.y[cell]),
                        vx: new Float64Array(2), vy: new Float64Array(2), nOff: 1,
                        vmax: Float64Array.of(18, 18), amax: Float64Array.of(14, 10), dmax: Float64Array.of(12, 12) };
    expect(timeToBallControl(b, g, -40, 0)[cell]).toBeGreaterThan(0.6);
  });
});
