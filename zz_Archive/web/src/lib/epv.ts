// Reads EPV prices at a playback frame. Pure. Ported from epvAt() in the Shiny app's www/player.js.

import { clamp } from "./geometry";
import type { Epv, OptionPrices, Series } from "./types";

export const EPV_STALE = 9;   // frames after the last price before the overlay is hidden

export interface EpvReading {
  holder: number;
  target: number | null;
  value: number | null;
  haz: number | null;
  rop: number | null;
  cum: number | null;
  shot: number | null;
  pass: number | null;
  option: (pid: number, key: keyof OptionPrices) => number | null;
}

// Prices sit on a coarser grid than the tracking. Blends between grid points while the same player holds
// the ball; returns null where nothing is priced (dead ball, nobody holding it, a shot in the air).
export function epvAt(epv: Epv | null, frame: number): EpvReading | null {
  if (!epv || !epv.f.length || frame < epv.f[0]) return null;
  let lo = 0, hi = epv.f.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (epv.f[mid] <= frame) lo = mid; else hi = mid - 1;
  }
  if (frame - epv.f[lo] > EPV_STALE) return null;
  const joined = lo + 1 < epv.f.length && epv.f[lo + 1] - epv.f[lo] <= EPV_STALE && epv.holder[lo + 1] === epv.holder[lo];
  const next = joined ? lo + 1 : lo;
  const t = joined ? clamp((frame - epv.f[lo]) / (epv.f[next] - epv.f[lo]), 0, 1) : 0;
  const read = (series: Series): number | null => {
    const a = series[lo], b = series[next];
    if (Number.isNaN(a)) return null;
    return Number.isNaN(b) ? a : a + (b - a) * t;
  };
  return {
    holder: epv.holder[lo],
    target: epv.to[lo] < 0 ? null : epv.to[lo],
    value: read(epv.v), haz: read(epv.haz), rop: read(epv.rop), cum: read(epv.cum), shot: read(epv.shot), pass: read(epv.pass),
    option: (pid, key) => {
      const prices = epv.players.get(pid);
      return prices ? read(prices[key]) : null;
    },
  };
}
