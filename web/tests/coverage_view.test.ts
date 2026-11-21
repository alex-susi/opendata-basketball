// Screen selection, recorded-coverage hiding and the forecast helpers of the Screen Coverage Read
// (lib/coverageView.svelte.ts, lib/coverage.ts; coverage product plan Phase 3).
import { beforeEach, describe, expect, it } from "vitest";
import { BALL_PARTS, BIG_PARTS, favorite, partSeries, readAt, stripPolygons, traceOf, type CoverageFile } from "../src/lib/coverage";
import { covView, guardRecordedCoverage, rawCoverage, recordedVisible, selectedScreen, setMode } from "../src/lib/coverageView.svelte";
import type { AnnScreen, Play } from "../src/lib/types";

const pick = (f: number, extra: Partial<AnnScreen> = {}): AnnScreen =>
  ({ f, kind: "pick", x: 0, y: 0, scr: 2, use: 1, covUse: "over", covScr: "drop", ...extra });

// A possession with two picks 1.2 s apart (a re-screen) and a handoff.
function makePlay(): Play {
  return { id: "possession-1", ann: { screens: [pick(1000), pick(1030, { covUse: "switch", covScr: "switch" }), pick(1100, { kind: "handoff" })] } } as unknown as Play;
}

beforeEach(() => {
  covView.pinned = {};
  covView.revealed = {};
  covView.blind = null;
  setMode("predict");
});

describe("selected screen", () => {
  it("follows the earliest window and keeps it through a re-screen", () => {
    const play = makePlay();
    expect(selectedScreen(play, 940)).toBeNull();              // 2.4 s before the first pick
    expect(selectedScreen(play, 960)?.pick.f).toBe(1000);       // −1.6 s
    const mid = selectedScreen(play, 1020)!;                    // both windows hold it, the nearer tag is the second
    expect(mid.pick.f).toBe(1000);
    expect(mid.other?.f).toBe(1030);
    expect(selectedScreen(play, 1026)?.pick.f).toBe(1030);      // the first window has ended (+1.04 s)
  });

  it("keeps a pinned screen while scrubbing, even outside its window", () => {
    const play = makePlay();
    covView.pinned[play.id] = 1030;
    const s = selectedScreen(play, 1001)!;
    expect(s.pick.f).toBe(1030);
    expect(s.pinned).toBe(true);
    expect(selectedScreen(play, 5000)?.inWindow).toBe(false);
  });

  it("counts picks only", () => {
    expect(selectedScreen(makePlay(), 1000)?.count).toBe(2);
  });
});

describe("recorded coverage", () => {
  it("is hidden until revealed in Predict mode, everywhere it is read", () => {
    const play = guardRecordedCoverage(makePlay());
    const [a, b, h] = play.ann!.screens;
    expect(a.covUse).toBeUndefined();
    expect(b.covScr).toBeUndefined();
    expect(h.covUse).toBe("over");                              // handoffs keep theirs
    covView.revealed["possession-1:1000"] = true;
    expect(a.covUse).toBe("over");
    expect(b.covUse).toBeUndefined();                           // only the revealed screen
    expect(rawCoverage(b)).toEqual({ use: "switch", scr: "switch" });
  });

  it("shows throughout in Full review, except a screen under blind review", () => {
    const play = guardRecordedCoverage(makePlay());
    setMode("full");
    expect(play.ann!.screens[1].covUse).toBe("switch");
    covView.blind = "possession-1:1030";
    expect(recordedVisible("possession-1", 1030)).toBe(false);
    expect(play.ann!.screens[1].covUse).toBeUndefined();
    expect(play.ann!.screens[0].covUse).toBe("over");
  });
});

describe("forecast helpers", () => {
  const calls = ["over + show", "over + drop", "under + drop", "under + show", "switch"];
  const series = (v: number) => Array.from({ length: 76 }, (_, i) => v + (i === 75 ? 1 : 0));
  const file = { offsets: [-50, 25], calls, possessions: {} } as unknown as CoverageFile;
  const screen = { id: "p", f0: 1000, h: 1, s: 2, bd: 3, sd: 4, call: "switch", p: [series(30), series(25), series(20), series(15), series(10)] };

  it("reads the frame's probabilities inside the window only", () => {
    expect(readAt(file, screen, 949)).toBeNull();
    expect(readAt(file, screen, 1026)).toBeNull();
    expect(readAt(file, screen, 950)!.pct).toEqual([30, 25, 20, 15, 10]);
    expect(readAt(file, screen, 1025)!.t).toBe(1);
  });

  it("stops the trace at the current frame until revealed", () => {
    expect(traceOf(file, screen, 960)).toHaveLength(11);
    expect(traceOf(file, screen, null)).toHaveLength(76);
    expect(traceOf(file, screen, 940)).toHaveLength(0);
  });

  it("sums each defender's options and stacks a strip to 100%", () => {
    const pct = [30, 25, 20, 15, 10];
    expect(partSeries(calls, pct, BALL_PARTS)).toEqual([55, 35, 10]);   // over, under, switch
    expect(partSeries(calls, pct, BIG_PARTS)).toEqual([45, 45, 10]);    // show, drop, switch
    // Two points summing to 99 and 101 still fill the strip: the top series ends at y = 0.
    const polys = stripPolygons([[-2, [50, 49]], [1, [51, 50]]], 300, 100);
    expect(polys).toHaveLength(2);
    expect(polys[0].split(" ")[0]).toBe("0.0,49.5");                    // bottom series' top edge at −2 s
    expect(polys[1].split(" ").slice(0, 2)).toEqual(["0.0,0.0", "300.0,0.0"]);
    expect(stripPolygons([[0, [1, 2]]], 300, 100)).toEqual([]);
  });

  it("calls a favorite only with a clear lead", () => {
    expect(favorite(calls, [30, 25, 20, 15, 10]).clear).toBe(false);   // below 45%
    expect(favorite(calls, [50, 42, 4, 2, 2]).clear).toBe(false);      // lead under 10 points
    const f = favorite(calls, [10, 55, 20, 10, 5]);
    expect(f).toEqual({ top: 1, second: 2, clear: true });
  });
});
