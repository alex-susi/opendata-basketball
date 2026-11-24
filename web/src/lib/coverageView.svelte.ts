// Which screen the Screen Coverage Read follows, and when the recorded coverage may be seen (coverage product plan,
// Phase 3, 2026-11-21).
//
// Three things are kept apart on purpose:
//   - the forecast: the live model's probability of the screen's single recorded coverage, from what had happened by
//     the current frame (coverage_frames.json, CoveragePanel.svelte)
//   - the recorded coverage: SkillCorner's label for the whole screen (picks.bhrDefType / scrDefType), written after
//     the fact. Hidden until the user reveals it (Predict mode, the site's only mode since 2026-11-24)
//   - the screen being read: picked by the user (pinned) or, when nothing is pinned, the earliest screen whose
//     −2 s to +1 s window holds the frame. Earliest-first keeps one screen's read until its window ends instead of
//     jumping to a re-screen half-way; Phase 4 replaces this provisional rule with the reviewed episode rules.
//
// Hiding is done at the source: guardRecordedCoverage() turns each pick's covUse / covScr into getters that answer
// undefined while the screen is hidden, so the court's screen tags, the trace panel's hover cards and the season
// lines all follow the same switch.

import type { AnnScreen, Play } from "./types";

// The site always runs in Predict mode: the Predict / Full review switch and the Panel / Classic switch left the
// card on 2026-11-24 (owner's request), so the card is the Classic one and each screen waits for Reveal. Full review
// stays here for the tests.
export type CoverageMode = "predict" | "full";
/** Prediction window around each pick frame, in frames (matches coverage_frames.json offsets: −2 s to +1 s). */
export const WINDOW: [number, number] = [-50, 25];

export const covView = $state({
  /** Predict: recorded coverages hidden until revealed. Full review: shown throughout. */
  mode: "predict" as CoverageMode,
  /** The pinned screen of each possession: its pick frame. */
  pinned: {} as Record<string, number>,
  /** Screens whose recorded coverage the user has revealed ("<possession>:<pick frame>"). */
  revealed: {} as Record<string, boolean>,
  /** The play-review panel's blind stage: this screen's forecast and recorded coverage stay hidden in every mode. */
  blind: null as string | null,
  /** "Pause before screen": seconds before the pick frame. */
  pause: -1,
  /** A jump requested before its possession has loaded (App.svelte applies it once the play is in). */
  pendingJump: null as { poss: string; frame: number } | null,
});

export function setMode(mode: CoverageMode): void {
  covView.mode = mode;
}

export const screenKey =(poss: string, f: number): string => `${poss}:${f}`;

/** Whether a screen's recorded coverage may be shown now. */
export function recordedVisible(poss: string, f: number): boolean {
  const key = screenKey(poss, f);
  if (covView.blind === key) return false;
  return covView.mode === "full" || !!covView.revealed[key];
}

/** Whether a screen's forecast may be shown now (only the blind review stage hides it). */
export const forecastVisible = (poss: string, f: number): boolean => covView.blind !== screenKey(poss, f);

const raw = new WeakMap<AnnScreen, { use?: string; scr?: string }>();

/** The recorded coverage as delivered, whatever the switch says (the review panel's reveal stage). */
export const rawCoverage = (s: AnnScreen): { use?: string; scr?: string } => raw.get(s) ?? { use: s.covUse, scr: s.covScr };

/** Make every pick's recorded coverage answer only while it may be shown. Handoffs and off-ball screens keep theirs
 * (the model reads picks only). Returns the same play. */
export function guardRecordedCoverage(play: Play): Play {
  for (const s of play.ann?.screens ?? []) {
    if (s.kind !== "pick" || raw.has(s)) continue;
    const keep = { use: s.covUse, scr: s.covScr };
    raw.set(s, keep);
    Object.defineProperty(s, "covUse", { get: () => (recordedVisible(play.id, s.f) ? keep.use : undefined), enumerable: true, configurable: true });
    Object.defineProperty(s, "covScr", { get: () => (recordedVisible(play.id, s.f) ? keep.scr : undefined), enumerable: true, configurable: true });
  }
  return play;
}

/** The possession's picks in time order. */
export function picksOf(play: Play | null): AnnScreen[] {
  return (play?.ann?.screens ?? []).filter((s) => s.kind === "pick").sort((a, b) => a.f - b.f);
}

export interface Selection {
  /** The screen being read. */
  pick: AnnScreen;
  /** Its place among the possession's picks (0-based) and how many there are. */
  index: number; count: number;
  /** Chosen by the user, or by the earliest-window rule. */
  pinned: boolean;
  /** Seconds from its pick frame to the current frame. */
  t: number;
  /** Inside its −2 s to +1 s window. */
  inWindow: boolean;
  /** Another pick whose window also holds this frame (a re-screen the read is not following). */
  other: AnnScreen | null;
}

const inWin = (frame: number, f: number) => frame - f >= WINDOW[0] && frame - f <= WINDOW[1];

/** The screen the coverage read follows at a frame, or null when nothing is pinned and no window holds the frame. */
export function selectedScreen(play: Play | null, frame: number): Selection | null {
  const list = picksOf(play);
  if (!play || !list.length) return null;
  const pin = covView.pinned[play.id];
  let index = pin != null ? list.findIndex((s) => s.f === pin) : -1;
  const pinned = index >= 0;
  if (!pinned) index = list.findIndex((s) => inWin(frame, s.f));
  if (index < 0) return null;
  const pick = list[index];
  const other = list.find((s) => s !== pick && inWin(frame, s.f)) ?? null;
  return { pick, index, count: list.length, pinned, t: (frame - pick.f) / 25, inWindow: inWin(frame, pick.f), other };
}

/** The pick frame the attention and lane overlays should follow (the same screen as the coverage read). */
export const selectedPickFrame = (play: Play | null, frame: number): number | null => selectedScreen(play, frame)?.pick.f ?? null;
