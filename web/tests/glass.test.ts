// Rebounding roles (web/scripts/glass.R): exported per shot, shown on the shot card and player card, and checked
// against what should follow from them (crashers get offensive rebounds; players back cut transition).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { shotCard } from "../src/lib/context";
import { decodePlay } from "../src/lib/decode";
import { playerSections, sampleOf } from "../src/lib/player";
import type { PeriodIndex, Play, PlayRow, Sample } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const plays = json<PlayRow[]>("plays.json");
const sample = json<Sample>("sample.json");
const loaded: Play[] = [];
for (const file of [...new Set(plays.map((r) => r.file))].slice(0, 6)) {
  const b = readFileSync(join(DATA, `${file}.bin`));
  const buf = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
  const idx = json<PeriodIndex>(`${file}.json`);
  for (const row of plays.filter((r) => r.file === file)) loaded.push(decodePlay(buf, idx.plays[row.id]));
}

describe("rebounding roles", () => {
  it("give every attacker of a tracked shot one role, the shooter his own", () => {
    let shots = 0;
    for (const play of loaded) {
      for (const shot of play.ann!.shots) {
        const roles = (play.ann!.glass ?? []).filter((g) => g.f === shot.f);
        if (!roles.length) continue;
        shots++;
        expect(new Set(roles.map((g) => g.pid)).size).toBe(roles.length);
        const own = roles.find((g) => g.pid === shot.pid);
        if (own) expect(["shooter", "follow"]).toContain(own.role);
        for (const g of roles.filter((x) => x.pid !== shot.pid)) expect(["crash", "back", "safety", "hold"]).toContain(g.role);
      }
    }
    expect(shots).toBeGreaterThan(50);
  });

  it("pick out the offensive rebounders: crashers rebound far more of the misses than anyone else", () => {
    const o = sample.league.glass!.oreb;
    const rate = (r: string) => o[r][1] / o[r][0];
    expect(rate("crash")).toBeGreaterThan(5 * rate("hold"));
    expect(rate("crash")).toBeGreaterThan(10 * rate("back"));
  });

  it("go with less transition the more attackers get back", () => {
    const t = sample.league.glass!.transition;
    const rate = (k: string) => t[k][1] / t[k][0];
    expect(rate("0")).toBeGreaterThan(rate("2"));
    expect(rate("1")).toBeGreaterThan(rate("3"));
  });

  it("appear on the shot card and the player card", () => {
    const { play, shot } = loaded.flatMap((p) => p.ann!.shots.map((s) => ({ play: p, shot: s })))
      .find(({ play, shot }) => (play.ann!.glass ?? []).some((g) => g.f === shot.f && g.role === "crash"))!;
    // The roles get their own group on the shot card, one line each with how many attackers took it.
    const lines = shotCard(play, shot, { peak: false, season: null }).lines;
    const at = lines.findIndex((l) => l.head && l.k === "Rebounding Roles");
    expect(at).toBeGreaterThan(-1);
    expect(lines.slice(at + 1, at + 5).map((l) => l.k)).toEqual(["Crash", "Retreat", "Safety", "Hold"]);
    expect(Number(lines[at + 1].v)).toBeGreaterThan(0);
    const p = play.players.find((q) => sampleOf(sample, q)?.glass)!;
    const sec = playerSections("tracking", null, sample, p).find((x) => x.title === "Rebounding Roles");
    expect(sec?.rows.map((r) => r.k)).toContain("Crash");
  });
});
