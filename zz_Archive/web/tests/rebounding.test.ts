// The rebounding panel's lookups: which miss is live at a frame, which forecast is shown, and the side totals.
import { describe, expect, it } from "vitest";
import { collectionLabels, episodesInPlay, landingEllipse, step09At, withStep09, type Step09Step, gameOf, reboundAt, sides, type ReboundEpisode, type ReboundGame, type ReboundStep } from "../src/lib/rebounding";
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

describe("landing regions", () => {
  // a symmetric cross of landings: spread 2 along x and 1 along y around (30, 5)
  const cross: [number, number][] = [[28, 5], [32, 5], [30, 4], [30, 6], [30, 5], [28, 5], [32, 5], [30, 4], [30, 6]];

  it("centres on the mean and scales the axes by the chi-square quantile", () => {
    const e = landingEllipse(cross, 0.5)!;
    expect(e.cx).toBeCloseTo(30); expect(e.cy).toBeCloseTo(5);
    const k = Math.sqrt(-2 * Math.log(0.5));
    const sx = Math.sqrt(16 / 8), sy = Math.sqrt(4 / 8);           // sample spreads of the cross
    expect(e.a).toBeCloseTo(k * sx); expect(e.b).toBeCloseTo(Math.max(0.75, k * sy));
    expect(Math.abs(Math.sin(e.theta))).toBeLessThan(1e-9);         // major axis along x
  });

  it("follows a rotated cloud and keeps the 50% core inside the 90% region", () => {
    const rot = cross.map(([x, y]): [number, number] => [30 + (x - 30 - (y - 5)) / Math.SQRT2, 5 + (x - 30 + (y - 5)) / Math.SQRT2]);
    const e = landingEllipse(rot, 0.9)!, c = landingEllipse(rot, 0.5)!;
    expect(Math.abs(Math.cos(2 * (e.theta - Math.PI / 4)))).toBeCloseTo(1); // major axis at 45°
    expect(c.a).toBeLessThan(e.a); expect(c.b).toBeLessThanOrEqual(e.b);
  });

  it("returns nothing for too few landings and a floor-sized region for identical ones", () => {
    expect(landingEllipse([[1, 1], [2, 2]], 0.9)).toBeNull();
    const same = landingEllipse([[3, 3], [3, 3], [3, 3]], 0.9)!;
    expect(same.a).toBe(0.75); expect(same.b).toBe(0.75);
  });
});

describe("Step 09 forecasts in the viewer", () => {
  const ep = episode(100, 140);
  // Step 09 lists the players offense first in its own order (1-5 offense, 6-10 defense)
  const s9 = (f: number, tp: string, p6: number): Step09Step => ({
    f, tp, fold: 1, pid: [5, 4, 3, 2, 1, 10, 9, 8, 7, 6], p: [0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, p6],
    team_off: 0.1, team_def: 0.45 - p6,                              // the twelve sum to 1
  });
  const forecasts = new Map([[ep.id, [s9(100, "release", 0.2), s9(130, "rim+0.2", 0.3)]]]);

  it("uses the latest Step 09 forecast made at or before the frame", () => {
    expect(step09At(forecasts.get(ep.id), 99)).toBeNull();
    expect(step09At(forecasts.get(ep.id), 129)?.tp).toBe("release");
    expect(step09At(forecasts.get(ep.id), 131)?.tp).toBe("rim+0.2");
  });

  it("puts each player's Step 09 chance on his own id and sums the sides", () => {
    const r = withStep09(reboundAt([ep], 135), forecasts, 135)!;
    expect(r.step.source?.tp).toBe("rim+0.2");
    expect(r.step.p[r.step.pid.indexOf(6)]).toBeCloseTo(0.3);       // player 6 in the first build's order
    expect(r.step.team[0]).toBeCloseTo(0.25); expect(r.step.team[1]).toBeCloseTo(0.5);
    expect(r.step.team[2]).toBeCloseTo(0.1); expect(r.step.team[3]).toBeCloseTo(0.15); expect(r.step.team[4]).toBe(0);
    expect(r.step.p.reduce((a, b) => a + b, 0) + r.step.team[2] + r.step.team[3]).toBeCloseTo(1);
    expect(r.step.land).toBe(ep.steps[2].land);                       // the landing forecast stays the first build's
  });

  it("keeps the same object between frames and falls back when Step 09 has nothing", () => {
    const a = withStep09(reboundAt([ep], 105), forecasts, 105)!, b = withStep09(reboundAt([ep], 106), forecasts, 106)!;
    expect(a.step).toBe(b.step);
    const none = reboundAt([ep], 105)!;
    expect(withStep09(none, new Map(), 105)!.step).toBe(none.step);
    const other = new Map([[ep.id, [{ ...s9(100, "release", 0.2), pid: [11, 4, 3, 2, 1, 10, 9, 8, 7, 6] }]]]);
    expect(withStep09(none, other, 105)!.step.source).toBeUndefined();  // different ten players: first build kept
  });
});
