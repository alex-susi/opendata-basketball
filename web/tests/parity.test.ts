// Parity with the Shiny app. The reference (tests/parity_reference.json) is written by
// scripts/parity_reference.R from the real server; these tests recompute the same things from the exported
// files with the site's own code.

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { decodePlay } from "../src/lib/decode";
import { filterPlays, type FilterState } from "../src/lib/filters";
import { convexHull, polygonArea, type Point } from "../src/lib/geometry";
import { buildSeq, stepAction } from "../src/lib/sequence";
import { nearestOpponent, traceSamples } from "../src/lib/trace";
import type { Meta, PeriodIndex, PlayRow, Series } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
// A Node Buffer is a view into a shared pool; copy out its own bytes so typed-array views stay aligned.
const bytes = (name: string): ArrayBuffer => {
  const b = readFileSync(join(DATA, name));
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
};

interface FilterCase {
  name: string;
  inputs: { game: string[]; period: string[]; result: string[]; shot_type: string[]; types: string[]; types_mode: "any" | "all";
            team: string[]; team_side: "any" | "off" | "def"; player: string; player_role: "any" | "off" | "def" | "actor";
            oreb: "any" | "with" | "without" };
  ids: string[];
}
interface PayloadSums {
  id: string; n: number; frames: number; gc: number; sc: number; scPresent: number; stopped: number; ball: number[];
  players: { id: number; role: string; arch: string | null; x: number; y: number; present: number; detected: number }[];
}
interface Reference { export_generated: string; filters: FilterCase[]; payloads: PayloadSums[] }

const reference = json<Reference>("../../tests/parity_reference.json");
const meta = json<Meta>("meta.json");
const plays = json<PlayRow[]>("plays.json");
const shinyPlays = plays.map((p) => ({ ...p, types: p.types.filter((t) => !t.startsWith("cut_")),
                                       actors: p.actors.filter(([t]) => !String(t).startsWith("cut_")) }));

const total = (v: ArrayLike<number>): number => {
  let sum = 0;
  for (let i = 0; i < v.length; i++) if (!Number.isNaN(v[i])) sum += v[i];
  return sum;
};
const present = (v: Series): number => v.reduce((n, x) => n + (Number.isNaN(x) ? 0 : 1), 0);
// Sums of values stored to 2-4 decimals: agree with R to rounding error of the summation only.
const close = (got: number, want: number) => expect(Math.abs(got - want)).toBeLessThan(1e-6 * Math.max(1, Math.abs(want)));
const loadPlay = (id: string) => {
  const row = plays.find((p) => p.id === id)!;
  return decodePlay(bytes(`${row.file}.bin`), json<PeriodIndex>(`${row.file}.json`).plays[row.id]);
};

describe("export", () => {
  it("matches the reference's export stamp (rerun scripts/parity_reference.R after an export)", () => {
    expect(reference.export_generated).toBe(meta.generated);
  });

  it("lists every play once", () => {
    expect(plays.length).toBe(meta.plays);
    expect(new Set(plays.map((p) => p.id)).size).toBe(plays.length);
  });

  it("has a period file for every play, with segments that tile the file exactly", () => {
    const files = readdirSync(DATA).filter((f) => f.endsWith(".bin")).map((f) => f.replace(".bin", ""));
    expect(files.length).toBe(meta.files);
    const listed = new Set(plays.map((p) => `${p.file}/${p.id}`));
    let seen = 0;
    for (const file of files) {
      const index = json<PeriodIndex>(`${file}.json`), buffer = bytes(`${file}.bin`);
      expect(buffer.byteLength).toBe(index.bytes);
      let at = 0;
      for (const h of Object.values(index.plays)) {
        expect(h.o).toBe(at);
        expect(listed.has(`${file}/${h.id}`)).toBe(true);
        const size = 4 * h.n + 2 * (5 * h.n + 2 * h.n * h.players.length) + h.n * (1 + 2 * h.players.length);   // stopped, detected, predError
        at += size + ((4 - (size % 4)) % 4);
        seen++;
      }
      expect(at).toBe(index.bytes);
    }
    expect(seen).toBe(plays.length);
  });

  it("counts offensive rebounds on every play, and some plays have them", () => {
    expect(plays.every((p) => Number.isInteger(p.oreb) && p.oreb >= 0)).toBe(true);
    const withOreb = plays.filter((p) => p.oreb > 0).length;
    expect(withOreb).toBeGreaterThan(50);
    expect(withOreb).toBeLessThan(plays.length / 2);
  });
});

describe("archetypes", () => {
  it("tags players in the sampled plays, and the Archetypes page defines every archetype they carry", () => {
    const page = readFileSync(join(DATA, "archetypes.html"), "utf8");
    const escaped = (name: string) => name.replace(/&/g, "&amp;");
    const names = new Set(reference.payloads.flatMap((p) => p.players.map((pl) => pl.arch)).filter((n): n is string => n !== null));
    expect(names.size).toBeGreaterThan(1);
    for (const name of names) expect(page).toContain(escaped(name));
  });
});

describe("filters match the Shiny server", () => {
  for (const c of reference.filters) {
    it(`${c.name}: ${c.ids.length} plays`, () => {
      const f: FilterState = { game: c.inputs.game, period: c.inputs.period, result: c.inputs.result, shotType: c.inputs.shot_type,
                               types: c.inputs.types, typesMode: c.inputs.types_mode, team: c.inputs.team, teamSide: c.inputs.team_side,
                               player: c.inputs.player, playerRole: c.inputs.player_role, oreb: c.inputs.oreb };
      // Cuts are the site's own (web/scripts/cuts.R), so the Shiny app knows nothing of them: compare without them.
      expect(filterPlays(shinyPlays, f).map((p) => p.id)).toEqual(c.ids);
    });
  }

  it("the cases do not all return the same plays", () => {
    expect(new Set(reference.filters.map((c) => c.ids.length)).size).toBeGreaterThan(10);
  });
});

describe("decoded plays match the Shiny payload", () => {
  for (const want of reference.payloads) {
    it(want.id, () => {
      const play = loadPlay(want.id);
      expect(play.frames.length).toBe(want.n);
      close(total(play.frames), want.frames);
      close(total(play.gc), want.gc);
      close(total(play.sc), want.sc);
      expect(present(play.sc)).toBe(want.scPresent);
      close(total(play.stopped), want.stopped);
      [play.ball.x, play.ball.y, play.ball.z].forEach((series, i) => close(total(series), want.ball[i]));
      expect(play.players.map((p) => [p.id, p.role, p.arch?.name ?? null])).toEqual(want.players.map((p) => [p.id, p.role, p.arch ?? null]));
      play.players.forEach((p, i) => {
        close(total(p.x), want.players[i].x);
        close(total(p.y), want.players[i].y);
        expect(present(p.x)).toBe(want.players[i].present);
        close(total(p.d), want.players[i].detected);
      });
    });
  }
});

describe("trace panel", () => {
  const play = loadPlay(reference.payloads[1].id);
  const seq = buildSeq(play, true);

  it("finds the nearest opponent by brute force", () => {
    const off = play.players.find((p) => p.role === "off" && seq.slice(0, 200).some((i) => !Number.isNaN(p.x[i])))!;
    for (const i of seq.slice(0, 200)) {
      const got = nearestOpponent(play, off.id, i);
      if (Number.isNaN(off.x[i])) { expect(got).toBeNull(); continue; }
      let best = Infinity, who = -1;
      for (const q of play.players) {
        if (q.role === off.role || Number.isNaN(q.x[i])) continue;
        const d = Math.hypot(q.x[i] - off.x[i], q.y[i] - off.y[i]);
        if (d < best) { best = d; who = q.id; }
      }
      if (who < 0) expect(got).toBeNull();
      else { expect(got!.pid).toBe(who); close(got!.dist, best); }
    }
  });

  it("samples the ball's height every 5 sequence steps, on the transport's clock", () => {
    const s = traceSamples(play, seq, { kind: "ball" });
    expect(s.length).toBe(Math.floor((seq.length - 1) / 5) + 1);
    expect(s[1].t).toBeCloseTo(5 / 25, 9);
    for (const p of s) if (p.v != null) expect(p.v).toBe(play.ball.z[seq[p.k]]);
  });
});

describe("geometry and sequence helpers", () => {
  it("finds a hull and its area", () => {
    const pts: Point[] = [[0, 0], [10, 0], [10, 10], [0, 10], [5, 5]];
    const hull = convexHull(pts);
    expect(hull.length).toBe(4);
    expect(polygonArea(hull)).toBe(100);
  });

  it("drops dead-ball frames only when asked, and steps between actions", () => {
    const play = loadPlay(reference.payloads[0].id);
    expect(buildSeq(play, false).length).toBe(play.frames.length);
    expect(buildSeq(play, true).length).toBeLessThan(play.frames.length);
    expect(stepAction([10, 50, 90], 50, 1, 120)).toBe(90);
    expect(stepAction([10, 50, 90], 55, -1, 120)).toBe(10);
    expect(stepAction([10, 50, 90], 95, 1, 120)).toBe(120);
  });
});
