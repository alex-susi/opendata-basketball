// Narrow windows: below FIT_WIDTH the whole page is drawn at FIT_WIDTH and scaled down to the window (CSS zoom on the
// root), so the three-column viewer keeps its layout and every part shrinks in proportion instead of wrapping.
// Phones (PHONE_MAX and under) keep their one-column layout at full size.
//
// Under zoom, pointer positions (clientX/clientY) and getBoundingClientRect() are in window pixels, while layout
// sizes and the left/top of fixed cards are in page pixels. toPage() converts the first into the second.

export const FIT_WIDTH = 1200;
export const PHONE_MAX = 760;

export const fit = $state({ scale: 1 });

/** A window-pixel length (from clientX, clientY or getBoundingClientRect) in page pixels. */
export const toPage = (v: number): number => v / fit.scale;

function apply(): void {
  const w = window.innerWidth;
  const scale = w > PHONE_MAX && w < FIT_WIDTH ? w / FIT_WIDTH : 1;
  if (scale === fit.scale) return;
  fit.scale = scale;
  const root = document.documentElement;
  root.style.zoom = scale === 1 ? "" : String(scale);
  root.style.setProperty("--fit", String(scale));
}

/** Scale the page to the window now and whenever the window is resized. */
export function initFit(): void {
  apply();
  window.addEventListener("resize", apply);
}
