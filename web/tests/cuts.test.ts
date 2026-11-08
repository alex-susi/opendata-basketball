// Cuts found from the tracking (lib/cuts.ts), route drawing inputs, and the shot card's xPoints rows.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { cutLines, shotCard, xPointsOf, xPointsPercentile } from "../src/lib/context";
import { HOOP_X } from "../src/lib/court";
import { decodePlay } from "../src/lib/decode";
import type { PeriodIndex, Play, PlayRow, Sample } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const plays = json<PlayRow[]>("plays.json");
const sample = json<Sample>("sample.json");
const files = [...new Set(plays.map((r) => r.file))].slice(0, 6);
const loaded: Play[] = [];
for (const file of files) {
  const b = readFileSync(join(DATA, `${file}.bin`));
  const buf = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
  const idx = json<PeriodIndex>(`${file}.json`);
  for (const row of plays.filter((r) => r.file === file)) loaded.push(decodePlay(buf, idx.plays[row.id]));
}
const cuts = loaded.flatMap((play) => (play.ann!.cuts ?? []).map((c) => ({ play, c })));

describe("cuts", () => {
  it("are found in a fair share of possessions, of every kind", () => {
    expect(cuts.length / loaded.length).toBeGreaterThan(0.5);
    expect(cuts.length / loaded.length).toBeLessThan(4);
    for (const kind of ["basket", "in", "out"]) expect(cuts.some(({ c }) => c.kind === kind), kind).toBe(true);
  });

  it("take basket cutters off the ball and closer to the hoop", () => {
    for (const { play, c } of cuts.filter(({ c }) => c.kind === "basket")) {
      const p = play.players.find((q) => q.id === c.pid)!;
      expect(p.role).toBe("off");
      const i0 = play.frames.indexOf(c.f), i1 = play.frames.indexOf(c.f1);
      if (i0 < 0 || i1 < 0 || Number.isNaN(p.x[i0]) || Number.isNaN(p.x[i1])) continue;
      const d0 = Math.hypot(HOOP_X - p.x[i0], p.y[i0]), d1 = Math.hypot(HOOP_X - p.x[i1], p.y[i1]);
      expect(d0 - d1).toBeGreaterThanOrEqual(6);   // 8 ft on smoothed positions at export; raw here
      expect(play.touches.some((t) => t.pid === c.pid && t.f0 <= c.f && t.f1 >= c.f)).toBe(false);
    }
  });

  it("cover every off-ball screen's cutter", () => {
    let screens = 0, covered = 0;
    for (const play of loaded) {
      for (const s of play.ann!.screens.filter((x) => x.kind === "off_ball_screen")) {
        screens++;
        if ((play.ann!.cuts ?? []).some((c) => c.pid === s.use && c.f <= s.f && c.f1 >= s.f - 12)) covered++;
      }
    }
    expect(covered / screens).toBeGreaterThan(0.8);
  });

  it("appear on the timeline with a label and a card", () => {
    const { play, c } = cuts[0];
    const ev = play.events.find((e) => e.kind === "cut" && e.f === c.f)!;
    expect(ev.label).toMatch(/cut/i);
    const keys = cutLines(play, c).map((l) => l.k);
    expect(keys).toContain("Type");
    expect(keys).toContain("Got the Ball");
  });
});

describe("xPoints", () => {
  const xs = sample.league.xpts!;
  it("are sorted shot quality times shot value", () => {
    expect(xs.length).toBeGreaterThan(1000);
    for (let i = 1; i < xs.length; i++) expect(xs[i]).toBeGreaterThanOrEqual(xs[i - 1]);
    expect(xs[xs.length - 1]).toBeLessThanOrEqual(3);
  });

  it("rank the best shots near the top and give the card both rows", () => {
    expect(xPointsPercentile(xs[xs.length - 1], xs)).toBeGreaterThan(99);
    expect(xPointsPercentile(xs[0], xs)).toBeLessThan(1);
    const { play, shot } = loaded.flatMap((p) => p.ann!.shots.map((s) => ({ play: p, shot: s }))).find((x) => x.shot.sq != null)!;
    const lines = shotCard(play, shot, { peak: false, season: null, xpts: xs }).lines;
    expect(lines[1]).toEqual({ k: "SkillCorner xPoints", v: xPointsOf(shot)!.toFixed(2) });
    expect(lines[2].k).toBe("xPoints Percentile");
    expect(lines[2].v).toMatch(/^\d+(st|nd|rd|th)$/);
  });
});

describe("the Action filter", () => {
  it("offers the cut kinds and finds plays by them", async () => {
    const { filterPlays, emptyFilters } = await import("../src/lib/filters");
    const meta = json<{ types: { value: string; label: string }[] }>("meta.json");
    expect(meta.types.map((o) => o.value)).toEqual(expect.arrayContaining(["cut_basket", "cut_in", "cut_out"]));
    expect(meta.types.find((o) => o.value === "off_ball_screen")?.label).toBe("Off-ball Screen");
    const hit = filterPlays(plays, { ...emptyFilters(), types: ["cut_basket"] });
    expect(hit.length).toBeGreaterThan(100);
    expect(hit.every((p) => p.types.includes("cut_basket") && p.typeLabels.includes("Basket Cut"))).toBe(true);
  });
});
