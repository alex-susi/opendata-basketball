// Foul and turnover types, closeout follow-ups, and block/steal flags on the timeline (lib/whistles.ts).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { decodePlay } from "../src/lib/decode";
import { foulLines, TURNOVER_NAMES, turnoverLines } from "../src/lib/whistles";
import type { PeriodIndex, Play, PlayRow } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const plays = json<PlayRow[]>("plays.json");
const loaded: Play[] = [];
for (const file of [...new Set(plays.map((r) => r.file))].slice(0, 12)) {
  const b = readFileSync(join(DATA, `${file}.bin`));
  const buf = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
  const idx = json<PeriodIndex>(`${file}.json`);
  for (const row of plays.filter((r) => r.file === file)) loaded.push(decodePlay(buf, idx.plays[row.id]));
}
const events = loaded.flatMap((play) => play.events.map((ev) => ({ play, ev })));

describe("timeline details", () => {
  it("name every foul's type", () => {
    const fouls = events.filter(({ ev }) => ev.kind === "foul");
    expect(fouls.length).toBeGreaterThan(20);
    for (const { ev } of fouls) {
      expect(ev.short).toMatch(/^(Technical|Shooting|Offensive|Flagrant|Personal) Foul$/);
      expect(ev.label).toMatch(/Foul( , Bonus)?/);
    }
  });

  it("name every turnover's type, and flag steals", () => {
    const tos = events.filter(({ ev }) => ev.kind === "turnover");
    expect(tos.length).toBeGreaterThan(10);
    const names = new Set(Object.values(TURNOVER_NAMES));
    for (const { play, ev } of tos) {
      expect(names.has(ev.short!.replace("TO · ", ""))).toBe(true);
      const t = play.ann!.turnovers.find((x) => x.f === ev.f)!;
      expect(ev.flag === "STL").toBe(t.stealer != null);
      expect(turnoverLines(play, t)[0].k).toBe("Type");
    }
  });

  it("flag blocked shots", () => {
    const blocked = events.filter(({ ev }) => ev.flag === "BLK");
    expect(blocked.length).toBeGreaterThan(0);
    for (const { play, ev } of blocked) expect(play.ann!.shots.find((s) => s.f === ev.f)?.blocked).toBe(true);
  });

  it("say what followed each closeout", () => {
    const cos = events.filter(({ ev }) => ev.kind === "closeout");
    expect(cos.length).toBeGreaterThan(5);
    for (const { ev } of cos) {
      expect(ev.short).toMatch(/^Closeout · (Shot|Drive|Pass|Other)$/);
      expect(ev.label).toMatch(/, then /);
    }
  });

  it("give fouls a hover card", () => {
    const { play, ev } = events.find(({ ev }) => ev.kind === "foul")!;
    const lines = foulLines(play, play.ann!.fouls.find((x) => x.f === ev.f)!);
    expect(lines.map((l) => l.k)).toEqual(expect.arrayContaining(["Type", "Fouler"]));
  });
});
