// The site's typeface and colour scheme, picked from the Font and Colors menus in the tab bar (App.svelte) and
// remembered in this browser. Trial settings for choosing a look; none of them is part of any analysis.
//   Fonts    one for the Play Viewer (the tab bar, the viewer, the court's canvas text) and one for the reading tabs
//            (Screen Coverage Model, Archetypes, Court Control, EDA). "Default" keeps each page's own type. The other
//            faces are Google Fonts, fetched when first shown (the Font menu previews them all).
//   Colors   one scheme for night and one for day. A scheme sets the surface variables (--bg, --panel, --raised,
//            --hover, --line, --ink, --muted) on <html> for the theme in force, the canvas surround (COLORS.paper,
//            paperInk, paperMuted) and, through DocFrame, the matching variables of the framed reading pages. The first
//            scheme of each theme is the site's own (app.css), so choosing it removes the overrides.

import { COLORS } from "./court";
import { page } from "./theme.svelte";

export interface FontOption { id: string; label: string; family: string; google?: string }

const SYSTEM = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
export const FONTS: FontOption[] = [
  { id: "default", label: "Default", family: SYSTEM },
  { id: "inter", label: "Inter", family: '"Inter", ' + SYSTEM, google: "Inter:wght@400;500;600;700;800" },
  { id: "plex", label: "IBM Plex Sans", family: '"IBM Plex Sans", ' + SYSTEM, google: "IBM+Plex+Sans:wght@400;500;600;700" },
  { id: "source", label: "Source Sans 3", family: '"Source Sans 3", ' + SYSTEM, google: "Source+Sans+3:wght@400;500;600;700;800" },
  { id: "roboto", label: "Roboto", family: '"Roboto", ' + SYSTEM, google: "Roboto:wght@400;500;700;900" },
  { id: "lato", label: "Lato", family: '"Lato", ' + SYSTEM, google: "Lato:wght@400;700;900" },
  { id: "franklin", label: "Libre Franklin", family: '"Libre Franklin", ' + SYSTEM, google: "Libre+Franklin:wght@400;500;600;700;800" },
  { id: "serif", label: "Source Serif 4", family: '"Source Serif 4", Georgia, serif', google: "Source+Serif+4:wght@400;600;700" },
];
export const fontOf = (id: string): FontOption => FONTS.find((f) => f.id === id) ?? FONTS[0];

/** The Google Fonts stylesheet for some faces (none for Default). */
export function fontHref(ids: string[]): string | null {
  const fams = [...new Set(ids)].map((id) => fontOf(id).google).filter(Boolean);
  return fams.length ? `https://fonts.googleapis.com/css2?${fams.map((f) => `family=${f}`).join("&")}&display=swap` : null;
}

/** Adds a font stylesheet to a document once (the page itself, or a framed reading page). */
export function loadFonts(doc: Document, ids: string[]): void {
  const href = fontHref(ids);
  if (!href || doc.querySelector(`link[data-font-href="${CSS.escape(href)}"]`)) return;
  const link = doc.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  link.dataset.fontHref = href;
  doc.head.appendChild(link);
}

export interface Scheme {
  id: string; label: string;
  bg: string; panel: string; raised: string; hover: string; line: string; ink: string; muted: string;
}
export const SCHEMES: Record<"dark" | "light", Scheme[]> = {
  dark: [
    { id: "slate", label: "Slate", bg: "#121826", panel: "#1B2334", raised: "#232D42", hover: "#283450", line: "#2F3B55", ink: "#E8EDF6", muted: "#93A0B8" },
    { id: "charcoal", label: "Charcoal", bg: "#141517", panel: "#1D1F23", raised: "#26292E", hover: "#2E3238", line: "#363A41", ink: "#ECEDEF", muted: "#9CA1AA" },
    { id: "midnight", label: "Midnight Navy", bg: "#0A1020", panel: "#101A2E", raised: "#17233C", hover: "#1D2C4A", line: "#24345A", ink: "#E6ECF8", muted: "#8D9BB8" },
    { id: "forest", label: "Forest", bg: "#0F1714", panel: "#16211D", raised: "#1D2B26", hover: "#23352F", line: "#2A3D36", ink: "#E5EFEA", muted: "#8FA59C" },
    { id: "espresso", label: "Espresso", bg: "#17130F", panel: "#201B16", raised: "#2A231D", hover: "#322A23", line: "#3A3129", ink: "#F0E9E1", muted: "#A89A8B" },
  ],
  light: [
    { id: "warm", label: "Warm Paper", bg: "#E6E3DC", panel: "#F6F4EF", raised: "#EDEAE3", hover: "#E2DED5", line: "#D3CEC4", ink: "#172033", muted: "#5A6780" },
    { id: "cool", label: "Cool Grey", bg: "#E3E6EA", panel: "#F4F6F8", raised: "#EAEDF0", hover: "#DFE3E8", line: "#CDD3DA", ink: "#161C26", muted: "#57616F" },
    { id: "mist", label: "Mist Blue", bg: "#DDE5EF", panel: "#F1F5FA", raised: "#E6EDF5", hover: "#DAE3EE", line: "#C6D2E0", ink: "#13213A", muted: "#52627D" },
    { id: "sand", label: "Sand", bg: "#E9E1D2", panel: "#F7F2E8", raised: "#EFE8DB", hover: "#E6DDCC", line: "#D6CBB7", ink: "#2A2118", muted: "#6F6250" },
    { id: "sage", label: "Sage", bg: "#DFE6DF", panel: "#F2F6F2", raised: "#E8EEE8", hover: "#DCE4DC", line: "#C9D4C9", ink: "#18241C", muted: "#56675B" },
  ],
};

const KEY = "acb-viewer-appearance";
export const appearance = $state({ viewerFont: "default", docFont: "default", dark: "slate", light: "warm" });
try {
  const saved = JSON.parse(localStorage.getItem(KEY) ?? "{}");
  for (const k of ["viewerFont", "docFont", "dark", "light"] as const) if (typeof saved[k] === "string") appearance[k] = saved[k];
} catch { /* storage unavailable: the defaults */ }

/** The scheme in force for the night or day theme now. */
export const schemeNow = (): Scheme => {
  const list = SCHEMES[page.light ? "light" : "dark"];
  return list.find((s) => s.id === appearance[page.light ? "light" : "dark"]) ?? list[0];
};
/** True when the scheme in force is the site's own (no overrides). */
export const schemeIsDefault = (): boolean => schemeNow() === SCHEMES[page.light ? "light" : "dark"][0];

const VARS = ["bg", "panel", "raised", "hover", "line", "ink", "muted"] as const;
// The canvas surround as app.css and lib/look.ts set it, restored when the site's own scheme is chosen.
let baseCanvas: { paper: string; paperInk: string; paperMuted: string } | null = null;

/** The canvas's text font, read by lib/draw.ts and lib/annotate.ts on every draw. */
export const canvasType = { family: SYSTEM };

/** Puts the chosen fonts and the scheme for the theme in force on the page. Call after any change and after the
 * night/day theme changes (lib/look.ts applyTheme). */
export function applyAppearance(): void {
  const root = document.documentElement;
  const scheme = schemeNow(), own = schemeIsDefault();
  for (const v of VARS) {
    if (own) root.style.removeProperty(`--${v}`);
    else root.style.setProperty(`--${v}`, scheme[v]);
  }
  // lib/look.ts sets the canvas colours for the theme just before this runs: keep them as the base.
  baseCanvas = { paper: COLORS.paper, paperInk: COLORS.paperInk, paperMuted: COLORS.paperMuted };
  if (!own) Object.assign(COLORS, { paper: scheme.panel, paperInk: scheme.ink, paperMuted: scheme.muted });
  const viewer = fontOf(appearance.viewerFont), doc = fontOf(appearance.docFont);
  loadFonts(document, [viewer.id, doc.id]);
  root.style.setProperty("--font-ui", viewer.family);
  if (doc.id === "default") root.style.removeProperty("--font-doc");
  else root.style.setProperty("--font-doc", doc.family);
  canvasType.family = viewer.family;
}

/** Records a choice, remembers it in this browser and applies it. */
export function choose(key: keyof typeof appearance, value: string): void {
  if (baseCanvas) Object.assign(COLORS, baseCanvas);   // undo this scheme's canvas colours before the next one's
  appearance[key] = value;
  try { localStorage.setItem(KEY, JSON.stringify(appearance)); } catch { /* not remembered */ }
  applyAppearance();
}

/** CSS for a framed reading page (DocFrame): the doc font on its body and headings, and the scheme on its own
 * variables (--bg, --surface, --soft-fill, --fg, --muted, --line). Empty when both are the defaults. */
export function frameCss(): string {
  const parts: string[] = [];
  const doc = fontOf(appearance.docFont);
  if (doc.id !== "default") parts.push(`:root { --font-body: ${doc.family} !important; --font-display: ${doc.family} !important; }`);
  if (!schemeIsDefault()) {
    const s = schemeNow();
    parts.push(`:root, :root[data-theme] { --bg: ${s.bg} !important; --surface: ${s.panel} !important; --soft-fill: ${s.raised} !important; --fg: ${s.ink} !important; --muted: ${s.muted} !important; --line: ${s.line} !important; }`);
  }
  return parts.join("\n");
}
