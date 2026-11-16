// The night/day theme as reactive state (set by applyTheme in lib/look.ts), so text drawn in a team's colour can
// stay readable on the day theme's white panels.

import { readableOn } from "./teamColors";

export const page = $state({ light: false });

/** A team's text colour for the page: as exported at night; by day, darkened where it would be too pale on white. */
export function pageText(hex: string): string;
export function pageText(hex: string | undefined): string | undefined;
export function pageText(hex: string | undefined): string | undefined {
  return hex && page.light ? readableOn(hex, "#FFFFFF", 3.2) : hex;
}
