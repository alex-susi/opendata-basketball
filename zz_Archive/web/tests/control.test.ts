// The site's court control against R's. tests/control_reference.json is written by
// src/court_control/build_control.R (copied here by scripts/export_data.R): a few frames' players with what the
// R implementation gives for the rebound chance, control, relevance and scoring opportunity.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { courtGrid, generalControl, reboundChance, relevance, valueOnGrid, type Bodies, type ControlParams } from "../src/lib/control";

interface Case {
  players: { x: number[]; y: number[]; vx: number[]; vy: number[] };
  sx: number;
  sy: number;
  elapsed: number;
  poreb: number;
  rebound_cells: number[];
  rebound_pc: number[];
  rebound_dens: number[];
  general_cells: number[];
  general_pc: number[];
  relevance: number[];
  obso: number;
}

const paramsFile = join(__dirname, "..", "public", "data", "control.json");
const casesFile = join(__dirname, "control_reference.json");
const ready = existsSync(paramsFile) && existsSync(casesFile);

describe.skipIf(!ready)("court control matches R", () => {
  const p: ControlParams = JSON.parse(readFileSync(paramsFile, "utf8"));
  const cases: Case[] = JSON.parse(readFileSync(casesFile, "utf8"));
  const general = courtGrid(p, p.general.cell);
  const rebound = courtGrid(p, p.rebound.cell, true, p.rebound.reach);
  const value = valueOnGrid(general, p);
  const bodies = (c: Case): Bodies => ({ x: Float64Array.from(c.players.x), y: Float64Array.from(c.players.y),
                                         vx: Float64Array.from(c.players.vx), vy: Float64Array.from(c.players.vy), nOff: 5 });
  const at = (v: Float64Array, cells: number[]) => cells.map((k) => v[k - 1]);   // R's cells are 1-based

  it("has a value for every cell of the general grid", () => {
    expect(p.value.v.length).toBe(general.x.length);
  });

  cases.forEach((c, n) => {
    it(`case ${n + 1}: rebound chance, control, relevance and scoring opportunity`, () => {
      const b = bodies(c);
      const rb = reboundChance(b, rebound, c.sx, c.sy, c.elapsed, p);
      expect(rb.p).toBeCloseTo(c.poreb, 6);
      at(rb.pc, c.rebound_cells).forEach((v, k) => expect(v).toBeCloseTo(c.rebound_pc[k], 6));
      at(rb.dens, c.rebound_cells).forEach((v, k) => expect(v).toBeCloseTo(c.rebound_dens[k], 8));
      const pc = generalControl(b, general, c.players.x[0], c.players.y[0], p);
      at(pc, c.general_cells).forEach((v, k) => expect(v).toBeCloseTo(c.general_pc[k], 6));
      const w = relevance(general, c.players.x[0], c.players.y[0], pc, p);
      at(w, c.general_cells).forEach((v, k) => expect(v).toBeCloseTo(c.relevance[k], 8));
      let so = 0;
      for (let k = 0; k < pc.length; k++) so += pc[k] * w[k] * value[k];
      expect(so).toBeCloseTo(c.obso, 3);   // the value grid is sent rounded to 4 decimals
    });
  });
});
