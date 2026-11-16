// The Player Trace's partner-change dots (lib/trace.ts, partnerChanges).

import { describe, expect, it } from "vitest";
import { partnerChanges, type TraceSample } from "../src/lib/trace";

const s = (k: number, opp: number | null, v: number | null = 3): TraceSample => ({ k, t: k / 25, v, faint: false, opp });

describe("partnerChanges", () => {
  it("marks each sample where the other player becomes someone else", () => {
    const got = partnerChanges([s(0, 1), s(5, 1), s(10, 2), s(15, 2), s(20, 1)]);
    expect(got.map((c) => [c.k, c.from, c.to])).toEqual([[10, 1, 2], [20, 2, 1]]);
  });
  it("passes over samples with nobody, and never marks the first player", () => {
    const got = partnerChanges([s(0, null), s(5, 7), s(10, null, null), s(15, 7), s(20, null), s(25, 9, null)]);
    expect(got).toEqual([{ k: 25, t: 1, v: null, from: 7, to: 9 }]);
  });
});
