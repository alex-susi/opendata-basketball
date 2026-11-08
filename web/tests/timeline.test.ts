// The trace panel's timeline captions (lib/sequence.ts, layoutTimeline) on real plays: tilted captions lean the way
// their leader runs where they can, and never cross another; screen ticks name the screener.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { decodePlay } from "../src/lib/decode";
import { TILT, buildSeq, layoutTimeline, type Tick } from "../src/lib/sequence";
import type { PeriodIndex, Play, PlayRow } from "../src/lib/types";

const DATA = join(__dirname, "..", "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const plays = json<PlayRow[]>("plays.json");
const loaded: Play[] = [];
for (const file of [...new Set(plays.map((r) => r.file))].slice(0, 8)) {
  const b = readFileSync(join(DATA, `${file}.bin`));
  const buf = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
  const idx = json<PeriodIndex>(`${file}.json`);
  for (const row of plays.filter((r) => r.file === file)) loaded.push(decodePlay(buf, idx.plays[row.id]));
}
const WIDTH = 560;
const measure = (text: string) => 6.4 * text.length;
const run = (t: Tick) => Math.min(t.width, 72) * Math.cos((TILT * Math.PI) / 180);
const span = (t: Tick): [number, number] => (t.lean === "left" ? [t.at - run(t), t.at] : [t.at, t.at + run(t)]);

describe("timeline captions", () => {
  const layouts = loaded.map((play) => layoutTimeline(play, buildSeq(play, true), WIDTH, measure));
  const tilted = layouts.flatMap((l) => l.ticks.filter((t) => t.lean !== "flat"));

  it("mostly lean the way their leader runs", () => {
    const leaders = tilted.filter((t) => Math.abs(t.at - t.frac * WIDTH) > 2);
    const along = leaders.filter((t) => (t.at < t.frac * WIDTH ? t.lean === "left" : t.lean === "right"));
    expect(leaders.length).toBeGreaterThan(20);
    expect(along.length / leaders.length).toBeGreaterThan(0.8);
  });

  it("never cross: a right-leaning caption has no left-leaning one starting inside its run", () => {
    for (const l of layouts) {
      const ts = l.ticks.filter((t) => t.lean !== "flat");
      for (const a of ts.filter((t) => t.lean === "right")) {
        for (const b of ts.filter((t) => t.lean === "left" && t.at > a.at)) {
          const [a0, a1] = span(a), [b0, b1] = span(b);
          expect(a0 < b1 + 4 && b0 < a1 + 4, `${a.event.label} / ${b.event.label}`).toBe(false);
        }
      }
    }
  });

  it("credit every screen to its screener", () => {
    let seen = 0;
    for (const play of loaded) {
      for (const s of play.ann!.screens) {
        const ev = play.events.find((e) => e.f === s.f && e.kind === s.kind);
        const scr = play.players.find((p) => p.id === s.scr);
        if (!ev || !scr) continue;
        expect(ev.who, ev.label).toBe(scr.last);
        seen++;
      }
    }
    expect(seen).toBeGreaterThan(50);
  });
});
