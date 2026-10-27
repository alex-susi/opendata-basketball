// Team colours for shading the floor. A play's kits are already de-clashed for player dots (the away team wears
// its secondary colour when the primaries are alike); this picks, from each kit, a colour that shows on the light
// floor and stays apart from the other team's (court control shading).

import { COLORS } from "./court";
import type { Play, TeamColors } from "./types";

const FALLBACK = { off: "#1F6FE5", def: "#F26A36" };
const MIN_APART = 110;   // RGB distance below which two colours read as the same team

function rgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const n = parseInt(h.length === 3 ? h.replace(/./g, (c) => c + c) : h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function luminance(hex: string): number {
  const v = rgb(hex).map((c) => c / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
}

function contrast(a: string, b: string): number {
  const [lo, hi] = [luminance(a), luminance(b)].sort((x, y) => x - y);
  return (hi + 0.05) / (lo + 0.05);
}

function apart(a: string, b: string): number {
  const x = rgb(a), y = rgb(b);
  return Math.hypot(x[0] - y[0], x[1] - y[1], x[2] - y[2]);
}

/** The first pair of candidates (offense, defense) that both read on `surface` and differ from each other. */
function choose(off: string[], def: string[], surface: string, minContrast: number): { off: string; def: string } {
  for (const a of off) for (const b of def) {
    if (contrast(a, surface) >= minContrast && contrast(b, surface) >= minContrast && apart(a, b) >= MIN_APART) return { off: a, def: b };
  }
  return FALLBACK;
}

const candidates = (k: TeamColors) => [k.fill, k.mark, k.edge, k.text];

/** Colours for shading the floor (court control): each team's primary where the two differ and show on the floor. */
export function floorColors(play: Play): { off: string; def: string } {
  return choose(candidates(play.colors.off), candidates(play.colors.def), COLORS.floor, 1.6);
}
