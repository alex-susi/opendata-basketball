// Which look the site wears: "current" (app.css alone) or "unslop" (app.css plus unslop.css, whose rules apply only
// while <html data-look="unslop">). A ?look=unslop or ?look=current in the address wins, so a link opens in the look it
// names; otherwise the last choice in this browser; otherwise the current look.

import { COLORS } from "./court";

export type Look = "current" | "unslop";

// The canvas draws with COLORS, not CSS, so its two slate-blue surfaces (the court's surround and the dark plate
// under tags) are swapped here too. Everything else on the canvas (court, teams, archetypes) is the same in both.
const CANVAS = {
  current: { paper: COLORS.paper, panel: COLORS.panel },
  unslop: { paper: "#19191b", panel: "#0e0e0f" },
};

const KEY = "acb-viewer-look";
const isLook = (v: unknown): v is Look => v === "current" || v === "unslop";

export function initialLook(): Look {
  const asked = new URLSearchParams(location.search).get("look");
  if (isLook(asked)) return asked;
  try {
    const saved = localStorage.getItem(KEY);
    if (isLook(saved)) return saved;
  } catch { /* storage unavailable: the current look */ }
  return "current";
}

// Puts the look on the page, remembers it in this browser and writes it into the address (kept out of the address
// for the current look, so ordinary links stay as they were).
export function applyLook(look: Look): void {
  document.documentElement.dataset.look = look;
  Object.assign(COLORS, CANVAS[look]);
  try { localStorage.setItem(KEY, look); } catch { /* not remembered */ }
  const url = new URL(location.href);
  if (look === "unslop") url.searchParams.set("look", "unslop");
  else url.searchParams.delete("look");
  if (url.href !== location.href) history.replaceState(history.state, "", url);
}
