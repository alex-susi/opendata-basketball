// The annotations exported by scripts/annotations.R and the readouts built from them (lib/motion.ts, lib/context.ts),
// on real plays from public/data.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { closeoutLines, driveLines, frameIndex, ownChances, possessionCard, shotCard } from "../src/lib/context";
import { decodePlay } from "../src/lib/decode";
import { accelAt, motion, spacing } from "../src/lib/motion";
import { contestOf, courtRegion } from "../src/lib/regions";
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

interface Placed { play: Play; f: number; pid?: number; x?: number; y?: number }

/** Distance from each event location to the named player's tracked position at the event's frame. */
function gaps(rows: Placed[]): number[] {
  const out: number[] = [];
  for (const { play, f, pid, x, y } of rows) {
    const p = play.players.find((q) => q.id === pid);
    const i = frameIndex(play, f);
    if (!p || x == null || y == null || play.frames[i] !== f || Number.isNaN(p.x[i])) continue;
    out.push(Math.hypot(p.x[i] - x, p.y[i] - y));
  }
  return out.sort((a, b) => a - b);
}
const median = (v: number[]) => v[Math.floor(v.length / 2)];

describe("annotations", () => {
  it("are exported with every play", () => {
    for (const play of sample) expect(play.ann).toBeDefined();
  });

  it("put each shot on the shooter's tracked position at release", () => {
    const g = gaps(sample.flatMap((play) => play.ann!.shots.map((s) => ({ play, f: s.f, pid: s.pid, x: s.x, y: s.y }))));
    expect(g.length).toBeGreaterThan(10);
    expect(median(g)).toBeLessThan(0.1);
  });

  it("put screens, passes, drives, closeouts, dribbles and rebounds on the tracked actor", () => {
    const families: Record<string, Placed[]> = {
      screens: sample.flatMap((play) => play.ann!.screens.map((s) => ({ play, f: s.f, pid: s.scr, x: s.x, y: s.y }))),
      passes: sample.flatMap((play) => play.ann!.passes.map((p) => ({ play, f: p.f, pid: p.pid, x: p.x0, y: p.y0 }))),
      drives: sample.flatMap((play) => play.ann!.drives.map((d) => ({ play, f: d.f, pid: d.pid, x: d.x0, y: d.y0 }))),
      closeouts: sample.flatMap((play) => play.ann!.closeouts.map((c) => ({ play, f: c.f, pid: c.def, x: c.x0, y: c.y0 }))),
      dribbles: sample.flatMap((play) => play.ann!.dribbles.map((d) => ({ play, f: d.f, pid: d.pid, x: d.x, y: d.y }))),
      rebounds: sample.flatMap((play) => play.ann!.rebounds.map((r) => ({ play, f: r.f, pid: r.pid, x: r.x, y: r.y }))),
    };
    for (const [name, rows] of Object.entries(families)) {
      const g = gaps(rows);
      expect(g.length, name).toBeGreaterThan(3);
      expect(median(g), name).toBeLessThan(1.5);
    }
  });

  it("draw a top-down court: shots labelled left are on the offense's left (+y when attacking +x)", () => {
    const shots = sample.flatMap((p) => p.ann!.shots).filter((s) => /^(left|right) /.test(s.region ?? ""));
    expect(shots.length).toBeGreaterThan(10);
    for (const s of shots) expect(Math.sign(s.y), s.region).toBe(s.region!.startsWith("left") ? 1 : -1);
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

  it("gives each frame to one play only, in order", () => {
    for (let k = 1; k < sample.length; k++) {
      const a = sample[k - 1], b = sample[k];
      expect(a.frames[a.frames.length - 1], `${a.id} / ${b.id}`).toBeLessThan(b.frames[0]);
    }
  });

  it("ends a play about a second after its last made basket reaches the rim", () => {
    let seen = 0;
    for (const play of sample) {
      const last = play.ann!.shots.filter((s) => s.pid != null).at(-1);
      if (!last?.made || !play.result.startsWith("Made") || play.and1) continue;   // an and-one ends on its free throw
      const tail = play.frames[play.frames.length - 1] - last.f1;
      expect(tail, play.id).toBeLessThanOrEqual(25);
      seen++;
    }
    expect(seen).toBeGreaterThan(5);
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

  it("name court regions as SkillCorner does for its shots", () => {
    const shots = plays.filter((r) => r.gameId === plays[0].gameId).map(loadPlay).flatMap((p) => p.ann!.shots).filter((s) => s.region);
    const same = shots.filter((s) => courtRegion(s.x, s.y) === s.region).length;
    expect(shots.length).toBeGreaterThan(100);
    expect(same / shots.length).toBeGreaterThan(0.9);
  });

  it("grade a contest from the nearest defender's distance", () => {
    expect([1, 4, 6, 9].map(contestOf)).toEqual(["plus", "average", "light", "open"]);
  });

  it("give accelerations within a plausible range, and velocity matching speed", () => {
    const play = sample[0], m = motion(play);
    for (let at = 0; at < play.players.length; at++) {
      for (let i = 0; i < play.frames.length; i += 5) {
        const a = accelAt(play, m.speed[at], i);
        if (!Number.isNaN(a)) expect(Math.abs(a)).toBeLessThanOrEqual(40);
        if (!Number.isNaN(m.speed[at][i])) expect(Math.hypot(m.vx[at][i], m.vy[at][i])).toBeCloseTo(m.speed[at][i], 6);
        if (i) expect(m.top[at][i]).toBeGreaterThanOrEqual(m.top[at][i - 1]);
      }
    }
  });

  it("measure each team's spacing and who is in the paint", () => {
    const play = sample.find((p) => p.players.filter((q) => q.role === "off" && !Number.isNaN(q.x[0])).length >= 2)!;
    const s = spacing(play, 0);
    expect(s.spread.off).toBeGreaterThan(0);
    for (const id of [...s.paint.off, ...s.paint.def]) expect(play.players.some((p) => p.id === id)).toBe(true);
  });

  it("write a shot card with shot quality first, then distance and the region in Title Case", () => {
    const play = sample.find((p) => p.ann!.shots.some((s) => s.region && s.sq != null))!;
    const shot = play.ann!.shots.find((s) => s.region && s.sq != null)!;
    const card = shotCard(play, shot, { peak: true, season: null });
    expect(card.title).toMatch(/^(Made|Missed|Blocked) [23] · #/);
    // Groups under subheaders: quality, then location, then defense and creation.
    const heads = card.lines.filter((l) => l.head).map((l) => l.k);
    expect(heads.slice(0, 2)).toEqual(["Shot Quality", "Location"]);
    const rows = card.lines.filter((l) => !l.head);
    expect(rows[0]).toEqual({ k: "SkillCorner Shot Quality", v: expect.stringMatching(/^\d+ \/ 100$/) });
    expect(rows[1].k).toBe("SkillCorner xPoints");   // no percentile without the league's xPoints
    expect(rows[2]).toEqual({ k: "Distance", v: expect.stringMatching(/^\d+\.\d ft$/) });
    expect(rows[3].k).toBe("Region");
    expect(rows[3].v).toMatch(/^[A-Z]/);
    for (const line of card.lines) expect(line.k).toMatch(/^[A-Z]/);
    // Shooter speed sits between release time and dribbles; the potential assist has its own line after the pass.
    const keys = rows.map((l) => l.k);
    if (keys.includes("Shooter Speed")) {
      expect(card.lines.find((l) => l.k === "Shooter Speed")!.v).toMatch(/^\d+\.\d ft\/s$/);
      if (keys.includes("Release Time")) expect(keys.indexOf("Release Time")).toBe(keys.indexOf("Shooter Speed") - 1);
      if (keys.includes("Dribbles")) expect(keys.indexOf("Dribbles")).toBe(keys.indexOf("Shooter Speed") + 1);
    }
    expect(keys.indexOf("Potential Assist")).toBe(keys.indexOf("Pass") + 1);
  });

  it("gives most released shots a shooter speed", () => {
    const shots = sample.flatMap((play) => play.ann!.shots.map((shot) => ({ play, shot })));
    const speeds = shots.map(({ play, shot }) => shotCard(play, shot, { peak: false, season: null }).lines.find((l) => l.k === "Shooter Speed"));
    expect(speeds.filter(Boolean).length / shots.length).toBeGreaterThan(0.8);
  });

  it("write a possession card with the current ball handler's dribbles and time on the ball", () => {
    const play = sample.find((p) => p.touches.length >= 3 && p.ann!.dribbles.length)!;
    const card = possessionCard(play, play.frames[play.frames.length - 1], play.gc[0]);
    const keys = card.lines.map((l) => l.k);
    expect(keys.indexOf("Touches")).toBeLessThan(keys.indexOf("Passes"));
    expect(keys.indexOf("Passes")).toBeLessThan(keys.indexOf("Dribbles"));
    const touches = Number(card.lines.find((l) => l.k === "Touches")!.v);
    if (touches) {
      expect(card.lines.find((l) => l.k === "Dribbles")!.v).toMatch(/^\d+$/);
      expect(card.lines.find((l) => l.k === "Ball")!.v).toMatch(/^#\S+ .+ \d+\.\d s$/);
    }
  });

  it("describe drives and closeouts with the tracked movement", () => {
    const withDrive = sample.find((p) => p.ann!.drives.length)!;
    expect(driveLines(withDrive, withDrive.ann!.drives[0]).map((l) => l.k)).toContain("Driver Max Speed");
    const withCloseout = sample.find((p) => p.ann!.closeouts.length);
    if (withCloseout) expect(closeoutLines(withCloseout, withCloseout.ann!.closeouts[0]).map((l) => l.k)).toContain("Defender Max Speed");
  });
});
