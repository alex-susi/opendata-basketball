// Shots SkillCorner left without context (lib/shotfill.ts): rebuilt from the tracking on decode, across every play.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { shotCard } from "../src/lib/context";
import { decodePlay } from "../src/lib/decode";
import type { AnnShot, PeriodIndex, Play, PlayRow } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const plays = json<PlayRow[]>("plays.json");

const shots: { play: Play; shot: AnnShot }[] = [];
for (const file of [...new Set(plays.map((r) => r.file))]) {
  const b = readFileSync(join(DATA, `${file}.bin`));
  const buffer = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
  const index = json<PeriodIndex>(`${file}.json`);
  for (const row of plays.filter((r) => r.file === file)) {
    const play = decodePlay(buffer, index.plays[row.id]);
    for (const shot of play.ann?.shots ?? []) shots.push({ play, shot });
  }
}
const seen = new Map<string, AnnShot>();
for (const { play, shot } of shots) seen.set(`${play.game}:${shot.f}:${shot.pid}`, shot);
const unique = [...seen.values()];

describe("shots without SkillCorner context", () => {
  it("are a small share, and all but the untracked one are rebuilt", () => {
    const est = unique.filter((s) => s.est);
    expect(est.length).toBeGreaterThan(15);
    expect(est.length).toBeLessThan(40);
    const located = unique.filter((s) => s.x != null && Number.isFinite(s.x));
    expect(unique.length - located.length).toBeLessThanOrEqual(2);
  });

  it("get a distance and closest defender, and a region on the official value's side unless flagged", () => {
    const est = unique.filter((s) => s.est);
    for (const s of est) {
      expect(s.dist).toBeGreaterThanOrEqual(0);
      expect(s.defId).toBeDefined();
      expect(s.defDist).toBeGreaterThanOrEqual(0);
      const three = s.region!.endsWith("three") || s.region === "far" || s.region === "backcourt";
      if (!s.conflict) expect(three, `${s.region} for a ${s.three ? 3 : 2}`).toBe(s.three);
    }
    expect(est.filter((s) => s.conflict).length).toBeLessThanOrEqual(6);
  });

  it("show what is rebuilt and what is not provided on the shot card", () => {
    const odd = shots.find((x) => x.shot.est && x.shot.conflict)!;
    expect(shotCard(odd.play, odd.shot, { peak: false, season: null }).lines.find((l) => l.k === "Shot Context")?.v)
      .toMatch(/^From Tracking; Spot (Inside|Beyond) the Arc$/);
    const { play, shot } = shots.find((x) => x.shot.est && !x.shot.conflict)!;
    const lines = shotCard(play, shot, { peak: false, season: null }).lines;
    const get = (k: string) => lines.find((l) => l.k === k)?.v;
    expect(get("SkillCorner Shot Quality")).toBe("Not Provided");
    expect(get("Type")).toBe("Not Provided");
    expect(get("Distance")).toMatch(/ ft$/);
    expect(get("Contest")).toMatch(/\(Est\.\)$/);
    expect(get("Shot Context")).toBe("From Tracking");
  });

  it("leave no shot label ending in (NA)", () => {
    const labels = shots.flatMap(({ play }) => play.events.filter((e) => e.kind === "made" || e.kind === "missed").map((e) => e.label));
    expect(labels.filter((l) => /\(NA\)/.test(l))).toEqual([]);
  });
});
