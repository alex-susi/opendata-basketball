// The rebounding panel's lookups: which miss is live at a frame, which forecast is shown, and the side totals.
import { describe, expect, it } from "vitest";
import { collectionLabels, episodesInPlay, gameOf, reboundAt, sides, type ReboundEpisode, type ReboundGame, type ReboundStep } from "../src/lib/rebounding";
import type { Play } from "../src/lib/types";

const step = (f: number, p0: number): ReboundStep => ({
  f, pid: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], p: [p0, 0.02, 0.01, 0.01, 0.01, 0.4, 0.1, 0.03, 0.02, 0.01],
  team: [p0 + 0.05, 0.56, 0.05, 0.02, 0.01], land: [[38, 2]], heat: [3, 4, 100], out: 0.1, box: [{ b: 6, o: 1, s: 0.5 }],
});
const episode = (f0: number, rf: number): ReboundEpisode => ({
  id: `shot-${f0}`, f0, f1: f0 + 25, rf, rim: f0 + 25, shooter: 3, outcome: "def player", rebounder: 6,
  kind: "rim first", range: "mid (10-22 ft)", steps: [step(f0, 0.3), step(f0 + 5, 0.25), step(f0 + 10, 0.2)], pairs: [], anticipation: [],
});

describe("rebounding lookups", () => {
  const eps = [episode(100, 140), episode(300, 330)];

  it("reads the game id from a play id", () => {
    expect(gameOf({ id: "possession-114243-1-12" } as Play)).toBe(114243);
  });

  it("keeps only misses released inside the play", () => {
    const game: ReboundGame = { game: 1, talent: false, heat: { x0: 0, y0: 0, cell: 1.5, nx: 2, ny: 2 }, episodes: eps };
    const play = { id: "possession-1-1-0", frames: Int32Array.from([90, 200]) } as unknown as Play;
    expect(episodesInPlay(play, game).map((e) => e.f0)).toEqual([100]);
  });

  it("shows the latest forecast made at or before the frame", () => {
    expect(reboundAt(eps, 99)).toBeNull();
    expect(reboundAt(eps, 100)?.step.f).toBe(100);
    expect(reboundAt(eps, 107)?.step.f).toBe(105);
    const late = reboundAt(eps, 150);
    expect(late?.step.f).toBe(110);
    expect(late?.resolved).toBe(true);
    expect(late?.since).toBeCloseTo(0.4);
  });

  it("drops a miss once its hold after the rebound has passed", () => {
    expect(reboundAt(eps, 200)).toBeNull();
    expect(reboundAt(eps, 305)?.episode.f0).toBe(300);
  });

  it("adds collection and award for each side", () => {
    const s = sides(step(0, 0.3));
    expect(s.off).toBeCloseTo(0.4);
    expect(s.def).toBeCloseTo(0.58);
    expect(s.unresolved).toBeCloseTo(0.01);
  });

  it("labels only players with a real chance", () => {
    const r = reboundAt(eps, 100)!;
    expect([...collectionLabels(r, false).keys()]).toEqual([1, 6, 7]);
  });
});
