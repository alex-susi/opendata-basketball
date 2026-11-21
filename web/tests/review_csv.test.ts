// review_cases.csv from the play-review panel's answers (lib/review.svelte.ts).
import { describe, expect, it } from "vitest";
import { entryFor, review, reviewCsv, type ReviewSample } from "../src/lib/review.svelte";

const sample: ReviewSample = {
  version: 1, seed: 1, made: "2026-11-21", n: 2,
  cases: [
    { case: 1, id: "pick-1", game: 9, poss: "possession-1", f0: 1000, h: 1, s: 2, bd: 3, sd: 4, repeat_pass: true },
    { case: 2, id: "pick-2", game: 9, poss: "possession-2", f0: 2000, h: 1, s: 2, bd: 3, sd: 4, repeat_pass: false },
  ],
};

describe("review CSV", () => {
  it("writes one row per answered case and pass, keeping blank, none and unsure apart", () => {
    review.entries = {};
    review.reviewer = "AS";
    const e = entryFor(sample.cases[0], 1);
    e.stamps.approach = { f: 960, unsure: false };
    e.stamps.exchange = { f: "none", unsure: false };
    e.stamps.confirmed = { f: 1010, unsure: true };
    e.picks.depth = "at level";
    e.notes = 'held, then "late" switch';
    entryFor(sample.cases[0], 2).picks.depth = "high";
    const [head, ...rows] = reviewCsv(sample).trim().split("\n");
    const cols = head.split(",");
    const at = (row: string, k: string) => row.split(",")[cols.indexOf(k)];
    expect(rows).toHaveLength(2);                                      // case 1 on both passes, case 2 never opened
    expect(at(rows[0], "approach_t")).toBe("-1.60");
    expect(at(rows[0], "approach_unsure")).toBe("0");
    expect(at(rows[0], "exchange_frame")).toBe("none");
    expect(at(rows[0], "confirmed_t")).toBe("0.40");
    expect(at(rows[0], "confirmed_unsure")).toBe("1");
    expect(at(rows[0], "return_frame")).toBe("");                     // not recorded stays blank
    expect(at(rows[0], "depth")).toBe("at level");
    expect(rows[0]).toContain('"held, then ""late"" switch"');
    expect(at(rows[1], "pass")).toBe("2");
    expect(at(rows[1], "depth")).toBe("high");
  });
});
