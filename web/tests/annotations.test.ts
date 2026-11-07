// The annotations exported by scripts/annotations.R and the readouts built from them (lib/motion.ts, lib/context.ts),
// on real plays from public/data.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { frameIndex, ownChances, possessionCard, shotCard } from "../src/lib/context";
import { decodePlay } from "../src/lib/decode";
import { motion, spacing } from "../src/lib/motion";
import type { PeriodIndex, Play, PlayRow } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const bytes = (name: string): ArrayBuffer => {
  const b = readFileSync(join(DATA, name));
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
};
const plays = json<PlayRow[]>("plays.json");
const loadPlay = (row: PlayRow): Play => decodePlay(bytes(`${row.file}.bin`), json<PeriodIndex>(`${row.file}.json`).plays[row.id]);
// Every play of one game period, so the checks cover a few dozen possessions.
const sample = plays.filter((r) => r.file === plays[0].file).map(loadPlay);

describe("annotations", () => {
  it("are exported with every play", () => {
    for (const play of sample) expect(play.ann).toBeDefined();
  });

  it("put each shot on the shooter's tracked position at release", () => {
    const gaps: number[] = [];
    for (const play of sample) {
      for (const s of play.ann!.shots) {
        const p = play.players.find((q) => q.id === s.pid);
        const i = frameIndex(play, s.f);
        if (!p || play.frames[i] !== s.f || Number.isNaN(p.x[i])) continue;
        gaps.push(Math.hypot(p.x[i] - s.x, p.y[i] - s.y));
      }
    }
    expect(gaps.length).toBeGreaterThan(10);
    gaps.sort((a, b) => a - b);
    expect(gaps[Math.floor(gaps.length / 2)]).toBeLessThan(0.1);
  });

  it("decodes tracking's expected error within its stored range", () => {
    let seen = 0;
    for (const play of sample) {
      for (const p of play.players) {
        for (let i = 0; i < p.e.length; i++) {
          if (Number.isNaN(p.e[i])) continue;
          expect(p.e[i]).toBeGreaterThanOrEqual(0);
          expect(p.e[i]).toBeLessThanOrEqual(25.4);
          seen++;
        }
      }
    }
    expect(seen).toBeGreaterThan(1000);
  });

  it("keeps a play's own chances only", () => {
    for (const play of sample) for (const c of ownChances(play)) expect(c.poss).toBe(play.id);
  });
});

describe("readouts", () => {
  it("give plausible speeds and a distance covered that never decreases", () => {
    for (const play of sample.slice(0, 10)) {
      const m = motion(play);
      m.speed.forEach((v) => v.forEach((s) => { if (!Number.isNaN(s)) expect(s).toBeLessThanOrEqual(35); }));
      m.covered.forEach((c) => { for (let i = 1; i < c.length; i++) expect(c[i]).toBeGreaterThanOrEqual(c[i - 1]); });
    }
  });

  it("measure spacing between the offensive players on court", () => {
    const play = sample.find((p) => p.players.filter((q) => q.role === "off" && !Number.isNaN(q.x[0])).length >= 2)!;
    const s = spacing(play, 0);
    expect(s.spread).toBeGreaterThan(0);
    expect(s.paint).toBeGreaterThanOrEqual(0);
  });

  it("write a shot card with the distance first", () => {
    const play = sample.find((p) => p.ann!.shots.length)!;
    const shot = play.ann!.shots[0];
    const card = shotCard(play, shot, { peak: true, season: null });
    expect(card.title).toMatch(/^(Made|Missed|Blocked) [23] · #/);
    expect(card.lines[0]).toEqual({ k: "Distance", v: expect.stringMatching(/^\d+\.\d ft/) });
  });

  it("write a possession card", () => {
    const play = sample[0];
    const card = possessionCard(play, play.frames[play.frames.length - 1], play.gc[0]);
    expect(card.lines.some((l) => l.k === "So far")).toBe(true);
  });
});
