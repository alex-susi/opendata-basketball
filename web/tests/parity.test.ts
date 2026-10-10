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
            team: string[]; team_side: "any" | "off" | "def"; player: string; player_role: "any" | "off" | "def" | "actor" };
  ids: string[];
}
interface OptionSums { id: number; sv: number; pv: number; tov: number; present: number }
interface PayloadSums {
  id: string; n: number; m: number; frames: number; gc: number; sc: number; scPresent: number; stopped: number; ball: number[];
  players: { id: number; role: string; x: number; y: number; present: number; detected: number }[];
  epv: { f: number; to: number; holder: number; v: number; shot: number; pass: number; haz: number; rop: number; cum: number; players: OptionSums[] };
}
interface Reference { export_generated: string; filters: FilterCase[]; payloads: PayloadSums[] }

const reference = json<Reference>("../../tests/parity_reference.json");
const meta = json<Meta>("meta.json");
const plays = json<PlayRow[]>("plays.json");

const total = (v: ArrayLike<number>): number => {
  let sum = 0;
  for (let i = 0; i < v.length; i++) if (!Number.isNaN(v[i])) sum += v[i];
  return sum;
};
const present = (v: Series): number => v.reduce((n, x) => n + (Number.isNaN(x) ? 0 : 1), 0);
// Sums of values stored to 2-4 decimals: agree with R to rounding error of the summation only.
const close = (got: number, want: number) => expect(Math.abs(got - want)).toBeLessThan(1e-6 * Math.max(1, Math.abs(want)));

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
        const size = 4 * (h.n + 3 * h.m) + 2 * (5 * h.n + 2 * h.n * h.players.length + 6 * h.m + 3 * h.m * h.priced.length) + h.n * (1 + h.players.length);
        at += size + ((4 - (size % 4)) % 4);
        seen++;
      }
      expect(at).toBe(index.bytes);
    }
    expect(seen).toBe(plays.length);
  });
});

describe("filters match the Shiny server", () => {
  for (const c of reference.filters) {
    it(`${c.name}: ${c.ids.length} plays`, () => {
      const f: FilterState = { game: c.inputs.game, period: c.inputs.period, result: c.inputs.result, shotType: c.inputs.shot_type,
                               types: c.inputs.types, typesMode: c.inputs.types_mode, team: c.inputs.team, teamSide: c.inputs.team_side,
                               player: c.inputs.player, playerRole: c.inputs.player_role };
      expect(filterPlays(plays, f).map((p) => p.id)).toEqual(c.ids);
    });
  }

  it("the cases do not all return the same plays", () => {
    expect(new Set(reference.filters.map((c) => c.ids.length)).size).toBeGreaterThan(10);
  });
});

describe("decoded plays match the Shiny payload", () => {
  for (const want of reference.payloads) {
    it(want.id, () => {
      const row = plays.find((p) => p.id === want.id)!;
      const play = decodePlay(bytes(`${row.file}.bin`), json<PeriodIndex>(`${row.file}.json`).plays[row.id]);
      expect(play.frames.length).toBe(want.n);
      close(total(play.frames), want.frames);
      close(total(play.gc), want.gc);
      close(total(play.sc), want.sc);
      expect(present(play.sc)).toBe(want.scPresent);
      close(total(play.stopped), want.stopped);
      [play.ball.x, play.ball.y, play.ball.z].forEach((series, i) => close(total(series), want.ball[i]));
      expect(play.players.map((p) => [p.id, p.role])).toEqual(want.players.map((p) => [p.id, p.role]));
      play.players.forEach((p, i) => {
        close(total(p.x), want.players[i].x);
        close(total(p.y), want.players[i].y);
        expect(present(p.x)).toBe(want.players[i].present);
        close(total(p.d), want.players[i].detected);
      });
      expect(play.epv?.f.length ?? 0).toBe(want.m);
      if (!play.epv) return;
      const e = play.epv;
      close(total(e.f), want.epv.f);
      close(total(Array.from(e.to).filter((v) => v >= 0)), want.epv.to);
      close(total(e.holder), want.epv.holder);
      for (const key of ["v", "shot", "pass", "haz", "rop", "cum"] as const) close(total(e[key]), want.epv[key]);
      expect([...e.players.keys()]).toEqual(want.epv.players.map((p) => p.id));
      for (const p of want.epv.players) {
        const got = e.players.get(p.id)!;
        close(total(got.sv), p.sv);
        close(total(got.pv), p.pv);
        close(total(got.tov), p.tov);
        expect(present(got.pv)).toBe(p.present);
      }
    });
  }
});

describe("geometry and sequence helpers", () => {
  it("finds a hull and its area", () => {
    const pts: Point[] = [[0, 0], [10, 0], [10, 10], [0, 10], [5, 5]];
    const hull = convexHull(pts);
    expect(hull.length).toBe(4);
    expect(polygonArea(hull)).toBe(100);
  });

  it("drops dead-ball frames only when asked, and steps between actions", () => {
    const row = plays.find((p) => p.id === reference.payloads[0].id)!;
    const play = decodePlay(bytes(`${row.file}.bin`), json<PeriodIndex>(`${row.file}.json`).plays[row.id]);
    expect(buildSeq(play, false).length).toBe(play.frames.length);
    expect(buildSeq(play, true).length).toBeLessThan(play.frames.length);
    expect(stepAction([10, 50, 90], 50, 1, 120)).toBe(90);
    expect(stepAction([10, 50, 90], 55, -1, 120)).toBe(10);
    expect(stepAction([10, 50, 90], 95, 1, 120)).toBe(120);
  });
});
