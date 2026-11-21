// The play-review panel's queue, answers and CSV export (coverage product plan, Phase 3, 2026-11-21).
//
// The queue is coverage_review_sample.json (screen_coverage/01_scripts/35_review_sample.R): about 50 screens in a
// shuffled order, chosen before anyone looked at the model's results, with no coverage in the file. Each case is
// reviewed in two stages:
//   1. blind · the forecast and the recorded coverage stay hidden. The reviewer stamps moments from the court (the
//      current frame) and picks what the defenders and the offense did
//   2. after reveal · the forecast trace and the recorded coverage show. The reviewer judges whether the forecast
//      would have helped and whether the label matches what was seen
// Pass 2 is the blind repeat of the marked subset, kept apart from pass 1 so its answers never show the first ones.
// Answers live in this browser (localStorage) until exported as review_cases.csv, which belongs in
// screen_coverage/03_outputs/product_review/. A moment left blank is "not recorded", "none" means it did not happen in
// the clip, and "unsure" marks an uncertain stamp: the three are never merged.

export interface ReviewCase { case: number; id: string; game: number; poss: string; f0: number; h: number; s: number; bd: number; sd: number; repeat_pass: boolean }
export interface ReviewSample { version: number; seed: number; made: string; n: number; cases: ReviewCase[] }

/** A stamped moment: a frame, "none" (did not happen in the clip) or null (not recorded), and whether it is unsure. */
export interface Stamp { f: number | "none" | null; unsure: boolean }
export interface ReviewEntry {
  id: string; pass: 1 | 2; stage: "blind" | "after" | "done";
  started: string; blindDone: string | null; done: string | null;
  stamps: Record<string, Stamp>;
  picks: Record<string, string>;
  notes: string; notesAfter: string;
}

/** The moments stamped in the blind stage, then after reveal. Keys become CSV columns. */
export const MOMENTS: { key: string; label: string; title: string; after?: boolean }[] = [
  { key: "approach", label: "Approach starts", title: "Handler and screener start coming together" },
  { key: "execution", label: "Screen engaged", title: "The screen is plausibly being used (the handler comes off it)" },
  { key: "first_evidence", label: "First readable sign", title: "The first moment you could tell how the defense is playing the screen · the screener's defender dropping low, holding at the level or showing high, the ball handler's defender starting over or under, or the two defenders starting to swap" },
  { key: "confirmed", label: "Coverage clear", title: "The moment the coverage is clear and stays clear" },
  { key: "pressure_start", label: "Pressure starts", title: "The screener's defender steps toward the handler (show, hedge, trap, at-level hold)" },
  { key: "pressure_end", label: "Pressure ends", title: "The screener's defender stops pressuring the handler" },
  { key: "return", label: "Return to screener", title: "The screener's defender moves back toward the screener" },
  { key: "exchange", label: "Exchange done", title: "Both defenders have taken the other's man" },
  { key: "decision_until", label: "Decision open until", title: "The last moment the handler could still make the choice picked under User decision and have it work · e.g. still go away from the screen, still attack a big caught high, still hit the roller before help arrives" },
  { key: "touch_end", label: "Handler's touch ends", title: "Pass, shot or turnover by the handler" },
  { key: "new_action", label: "New action", title: "A new screen, a dead ball or a possession change that starts a new read" },
  { key: "helpful_from", label: "Forecast helpful from", title: "After reveal: the first moment the forecast would have helped", after: true },
];

/** The choices of the blind stage, then after reveal. */
export const CHOICES: { key: string; label: string; options: string[]; title: string; after?: boolean }[] = [
  { key: "depth", label: "Screener's defender depth", options: ["low", "at level", "high", "unclear"], title: "Where the screener's defender is when the screen is engaged" },
  { key: "route", label: "Ball defender's route", options: ["over", "under", "not engaged", "unclear"], title: "How the handler's defender gets past the screen" },
  { key: "sd_takes_h", label: "Screener's defender takes handler", options: ["yes", "no", "unclear"], title: "Handler side of an exchange" },
  { key: "bd_takes_s", label: "Ball defender takes screener", options: ["yes", "no", "unclear"], title: "Screener side of an exchange" },
  { key: "pattern", label: "Pattern", options: ["pressure_return", "containment_return", "pressure_exchange", "at_level_emergency_exchange", "denial_countered", "other", "unclear"], title: "A review tag describing the sequence. It is never a model class" },
  { key: "denial", label: "Defensive denial", options: ["none", "sideline (ice-like)", "middle (weak-like)", "trap", "unclear"], title: "Did the defense try to keep the handler off the screen" },
  { key: "offense", label: "Handler's answer", options: ["used screen", "rejected", "snaked", "split", "reached middle", "passed early", "other", "unclear"], title: "What the handler did, kept apart from what the defense tried" },
  { key: "decision", label: "User decision", options: ["use or reject the screen", "attack the screener's defender", "find the roller or popper", "reset", "other"], title: "The main choice the handler faces on this screen. Its deadline is the Decision open until stamp" },
  { key: "after_pass", label: "Coverage still matters after a pass", options: ["yes", "no", "no pass", "unclear"], title: "When the handler passes, is the defense still dealing with this screen's coverage? Yes · the pass plays off it (to the roller, to the popper the show left open, a switch mismatch still being attacked). No · the pass starts a new action. No pass · the handler kept the ball (shot, turnover, still dribbling)" },
  { key: "tracking", label: "Tracking", options: ["fine", "some estimated positions", "poor"], title: "How much the positions look estimated or jumpy" },
  { key: "roles", label: "Roles", options: ["clear", "ambiguous"], title: "Are the handler, screener and their defenders the right four" },
  { key: "confidence", label: "Review confidence", options: ["high", "medium", "low"], title: "How sure the review is" },
  { key: "label_agrees", label: "Recorded coverage matches", options: ["yes", "no", "unsure"], title: "After reveal: does SkillCorner's label match what you saw", after: true },
  { key: "misleading", label: "Forecast misleading", options: ["no", "yes", "unsure"], title: "After reveal: did the forecast point confidently the wrong way at a moment that mattered", after: true },
  { key: "usefulness", label: "Forecast usefulness", options: ["useful", "partly", "not useful"], title: "After reveal: could a handler or coach act on or learn from it", after: true },
];

const KEY = "acb-coverage-review-v1";
interface Stored { reviewer: string; pass: 1 | 2; at: number; entries: Record<string, ReviewEntry> }

function load(): Stored {
  try {
    const s = JSON.parse(localStorage.getItem(KEY) ?? "") as Stored;
    if (s && s.entries) return s;
  } catch { /* nothing saved yet */ }
  return { reviewer: "", pass: 1, at: 0, entries: {} };
}

export const review = $state({ ...load(), sample: null as ReviewSample | null });

/** Save after every change (called by the panel). */
export function saveReview(): void {
  try {
    localStorage.setItem(KEY, JSON.stringify({ reviewer: review.reviewer, pass: review.pass, at: review.at, entries: review.entries }));
  } catch { /* storage full or blocked: the panel warns */ }
}

let sampleFile: Promise<ReviewSample | null> | null = null;
export function loadReviewSample(): Promise<ReviewSample | null> {
  sampleFile ??= fetch(`${import.meta.env.BASE_URL}data/coverage_review_sample.json`, { cache: "no-cache" })
    .then((r) => (r.ok ? (r.json() as Promise<ReviewSample>) : null))
    .catch(() => null);
  return sampleFile;
}

/** The queue for the current pass: every case on pass 1, the marked subset on pass 2. */
export const queueOf = (sample: ReviewSample | null, pass: 1 | 2): ReviewCase[] => (sample?.cases ?? []).filter((c) => pass === 1 || c.repeat_pass);

export const entryKey = (id: string, pass: 1 | 2): string => `${id}#${pass}`;

export function entryFor(c: ReviewCase, pass: 1 | 2): ReviewEntry {
  const k = entryKey(c.id, pass);
  review.entries[k] ??= { id: c.id, pass, stage: "blind", started: new Date().toISOString(), blindDone: null, done: null, stamps: {}, picks: {}, notes: "", notesAfter: "" };
  return review.entries[k];
}

const csvCell = (v: unknown): string => {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** review_cases.csv: one row per case and pass with any answer, moments as frame, seconds from the pick frame and
 * unsure flag. */
export function reviewCsv(sample: ReviewSample): string {
  const head = ["reviewer", "pass", "case", "screen_id", "game_id", "possession", "pick_frame", "stage", "started", "blind_done", "done",
                ...MOMENTS.flatMap((m) => [`${m.key}_frame`, `${m.key}_t`, `${m.key}_unsure`]),
                ...CHOICES.map((c) => c.key), "notes", "notes_after", "tool"];
  const rows = [head.join(",")];
  for (const pass of [1, 2] as const) {
    for (const c of sample.cases) {
      const e = review.entries[entryKey(c.id, pass)];
      if (!e) continue;
      const moments = MOMENTS.flatMap((m) => {
        const st = e.stamps[m.key];
        const f = st?.f;
        return [typeof f === "number" ? f : f ?? "", typeof f === "number" ? ((f - c.f0) / 25).toFixed(2) : f ?? "", st ? (st.unsure ? 1 : 0) : ""];
      });
      rows.push([review.reviewer, pass, c.case, c.id, c.game, c.poss, c.f0, e.stage, e.started, e.blindDone ?? "", e.done ?? "",
                 ...moments, ...CHOICES.map((ch) => e.picks[ch.key] ?? ""), e.notes, e.notesAfter, "viewer review panel v1"].map(csvCell).join(","));
    }
  }
  return rows.join("\n") + "\n";
}
