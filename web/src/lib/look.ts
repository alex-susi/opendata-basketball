// How the site looks, set from the bottom-right corner's two switches:
//   look   "current" (app.css alone) or "unslop" (app.css plus unslop.css, whose rules apply only while
//          <html data-look="unslop">).
//   theme  "dark" (night, the default) or "light" (day: <html data-theme="light">, the day rules at the end of
//          app.css and unslop.css).
// A ?look=… or ?theme=… in the address wins, so a link opens as it names; otherwise the last choice in this browser;
// otherwise the current look at night.

import { COLORS } from "./court";
import { page } from "./theme.svelte";

export type Look = "current" | "unslop";
export type Theme = "dark" | "light";

// The canvas draws with COLORS, not CSS, so the court's surround (paper), the text drawn straight on it and the dark
// plate under tags are swapped here too. The court itself, the teams and the archetypes are the same throughout; the
// tag plates stay dark by day, since they sit on the hardwood.
const DARK_TEXT = { paperInk: COLORS.paperInk, paperMuted: COLORS.paperMuted };
const CANVAS: Record<Look, Record<Theme, Partial<typeof COLORS>>> = {
  current: {
    dark: { paper: COLORS.paper, panel: COLORS.panel, ...DARK_TEXT },
    light: { paper: "#FFFFFF", panel: COLORS.panel, paperInk: "#172033", paperMuted: "#5A6780" },
  },
  unslop: {
    dark: { paper: "#19191b", panel: "#0e0e0f", ...DARK_TEXT },
    light: { paper: "#ffffff", panel: "#0e0e0f", paperInk: "#1d1d1f", paperMuted: "#6e6e73" },
  },
};

const LOOK_KEY = "acb-viewer-look", THEME_KEY = "acb-viewer-theme";
const isLook = (v: unknown): v is Look => v === "current" || v === "unslop";
const isTheme = (v: unknown): v is Theme => v === "dark" || v === "light";

function initial<T>(param: string, key: string, test: (v: unknown) => v is T, fallback: T): T {
  const asked = new URLSearchParams(location.search).get(param);
  if (test(asked)) return asked;
  try {
    const saved = localStorage.getItem(key);
    if (test(saved)) return saved;
  } catch { /* storage unavailable: the default */ }
  return fallback;
}

export const initialLook = (): Look => initial("look", LOOK_KEY, isLook, "current");
export const initialTheme = (): Theme => initial("theme", THEME_KEY, isTheme, "dark");

const lookNow = (): Look => (document.documentElement.dataset.look === "unslop" ? "unslop" : "current");
const themeNow = (): Theme => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

// Remembers a choice in this browser and writes it into the address (left out of the address at its default, so
// ordinary links stay as they were).
function remember(param: string, key: string, value: string, fallback: string): void {
  try { localStorage.setItem(key, value); } catch { /* not remembered */ }
  const url = new URL(location.href);
  if (value !== fallback) url.searchParams.set(param, value);
  else url.searchParams.delete(param);
  if (url.href !== location.href) history.replaceState(history.state, "", url);
}

/** Puts the look on the page (and the canvas colours that go with it and the theme). */
export function applyLook(look: Look): void {
  document.documentElement.dataset.look = look;
  Object.assign(COLORS, CANVAS[look][themeNow()]);
  remember("look", LOOK_KEY, look, "current");
}

/** Puts the night or day theme on the page (and the canvas colours that go with it and the look). */
export function applyTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  page.light = theme === "light";
  Object.assign(COLORS, CANVAS[lookNow()][theme]);
  remember("theme", THEME_KEY, theme, "dark");
}
