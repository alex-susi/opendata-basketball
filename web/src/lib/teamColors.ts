// Team colours as the viewer draws them. A play's kits come with its export (team_kit and side_colors in
// play_viewer/01_app/R/data.R): the away team wears its secondary colour when the two primaries are alike. A player's
// dot is his team's primary alone, numbered in white (dark on a light primary). The secondary colour marks a
// player: the glow round the ball handler, and the ring round a selected player and his nearest opponent.

const WHITE = "#FFFFFF";
const DARK = "#0B0E14";

function rgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const n = parseInt(h.length === 3 ? h.replace(/./g, (c) => c + c) : h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function luminance(hex: string): number {
  const v = rgb(hex).map((c) => c / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
}

/** WCAG contrast ratio between two colours, from 1 to 21. */
export function contrast(a: string, b: string): number {
  const [lo, hi] = [luminance(a), luminance(b)].sort((x, y) => x - y);
  return (hi + 0.05) / (lo + 0.05);
}

/** The number on a dot of this colour: white, unless the colour is too light for white to read (yellow, sky blue). */
export function dotInk(fill: string): string {
  return contrast(WHITE, fill) >= 2.9 ? WHITE : DARK;
}

/** A hex colour with an opacity, as rgba(). */
export function withAlpha(hex: string, alpha: number): string {
  return `rgba(${rgb(hex).join(",")},${alpha})`;
}
