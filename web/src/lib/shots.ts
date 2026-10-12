// The steps behind a shot's xFG, as the panel beside the half court lists them. Pure.
// Mirrors shotIndexAt(), SHOT_FEATURES, shotNotes() and renderShot() in the Shiny app's www/player.js.

import { pct } from "./geometry";
import type { ShotSteps } from "./types";

export const ZONE_NAMES: Record<ShotSteps["zone"], string> = { rim: "Rim", mid: "Midrange", three: "Three-point" };

type Unit = "pct" | "ft" | "ft/s" | "s" | "count";

// Inputs of the xFG context models in display order (XFG_FEATURES in src/epv/R/models.R). A shot lists the
// ones its own model takes: jump shots have no rim protector.
const SHOT_FEATURES: { key: string; label: string; unit: Unit; hint: string }[] = [
  { key: "loc_xfg", label: "Location xFG", unit: "pct", hint: "Make chance from court position alone: the location GAM" },
  { key: "def1", label: "Closest defender", unit: "ft", hint: "Distance to the nearest defender" },
  { key: "def2", label: "Second defender", unit: "ft", hint: "Distance to the second-nearest defender" },
  { key: "n6", label: "Defenders within 6 ft", unit: "count", hint: "Defenders within 6 ft of the shooter" },
  { key: "between", label: "Defenders in the path", unit: "count", hint: "Defenders between the shooter and the hoop, within 3 ft of the line to it" },
  { key: "rim_def", label: "Rim protector", unit: "ft", hint: "Distance from the hoop of the defender nearest to it" },
  { key: "closing", label: "Defender closing", unit: "ft/s", hint: "Speed at which the closest defender is closing on the shooter; negative when the gap is opening" },
  { key: "speed", label: "Shooter speed", unit: "ft/s", hint: "The shooter's speed over the last quarter second" },
  { key: "sc", label: "Shot clock", unit: "s", hint: "Seconds left on the shot clock" },
  { key: "held", label: "Time on the ball", unit: "s", hint: "Seconds since the shooter's touch began; on a jump shot 1.5 s or less counts as catch-and-shoot" },
  { key: "drib", label: "Dribbles", unit: "count", hint: "Dribbles the shooter took in this touch" },
];

export interface ShotRow {
  key: string;
  label: string;
  hint: string;
  /** The feature at release, with its unit; a dash where it was not measured. */
  value: string;
  /** What the feature adds to xFG, as a share of 1. */
  effect: number;
}

/** The shot the panel shows at a frame: the latest one released, or the first while none has been. -1 if there are none. */
export function shotIndexAt(shots: ShotSteps[], frame: number): number {
  let at = shots.length ? 0 : -1;
  shots.forEach((shot, i) => { if (shot.f <= frame) at = i; });
  return at;
}

function withUnit(v: number | null | undefined, unit: Unit): string {
  if (v == null) return "–";
  if (unit === "pct") return pct(v, 1);
  if (unit === "count") return String(v);
  return `${v.toFixed(1)} ${unit}`;
}

export function shotRows(shot: ShotSteps): ShotRow[] {
  return SHOT_FEATURES.filter((f) => f.key in shot.e)
    .map((f) => ({ key: f.key, label: f.label, hint: f.hint, value: withUnit(shot.v[f.key], f.unit), effect: shot.e[f.key] ?? 0 }));
}

/** What the reader should know about how this shot's effects were arrived at. */
export function shotNotes(shot: ShotSteps): string[] {
  const notes: string[] = [], kind = shot.model === "jump" ? "jump" : ZONE_NAMES[shot.zone].toLowerCase();
  const fixed = Object.keys(shot.fixed ?? {}).length > 0;
  if (fixed) notes.push("The closest-defender and catch-and-shoot effects are set from the season's three-point percentages; they were not fitted to these ten games. Catch-and-shoot means 1.5 s or less on the ball and shows under Time on the ball.");
  if (shot.rounds === 0) {
    notes.push(fixed ? `No other context effect held up for ${kind} shots when this game was left out of the fit.`
      : `No context effect held up for ${kind} shots when this game was left out of the fit, so xFG is their make rate and no feature moves it.`);
  }
  if (shot.fouled) notes.push("Fouled on the shot. xFG is the make chance of an unfouled attempt.");
  notes.push("Effects are percentage points of xFG in a model fitted on the other nine games. They describe the model, not cause and effect.");
  return notes;
}

/** An effect in percentage points of xFG, signed. */
export function points(effect: number): string {
  const text = Math.abs(100 * effect).toFixed(1);
  return text === "0.0" ? text : `${effect > 0 ? "+" : "−"}${text}`;
}
