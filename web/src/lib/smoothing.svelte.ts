// How much the viewer smooths tracking before it shows movement, picked in the tab bar's Tracking menu and remembered
// in this browser. Display only: the screen-coverage model and every exported figure are untouched.
//   smoothed  the site's long-standing setting: positions averaged 2 frames each side (0.2 s window) before speed is
//             taken over 2 frames; acceleration from speeds 0.2 s either side; steps faster than 35 ft/s and
//             accelerations past 40 ft/s² dropped as tracking jumps; drive and cut paths averaged 3 frames each side,
//             trails 2 (never later than the current frame)
//   light     positions averaged 1 frame each side; speed over 2 frames; acceleration from speeds 0.08 s either side;
//             the same jump limits; paths and trails averaged 1 frame each side
//   raw       no averaging and no limits: speed from one frame to the next, acceleration from one frame's speed to the
//             next, paths and trails through the tracked positions as they are
// Positions on the court (the dots) are always the tracked positions, blended between frames for slow playback.

export type SmoothLevel = "smoothed" | "light" | "raw";

export interface SmoothSettings {
  label: string;
  title: string;
  /** Frames each side averaged into a position before speed is taken. */
  pos: number;
  /** Speed from the position this many frames before to this many after (raw: one frame back to now). */
  back: number; fwd: number;
  /** Acceleration from the speed this many frames before to this many after, and the fewest frames it may span. */
  accBack: number; accFwd: number; accMin: number;
  /** Drop steps faster than 35 ft/s and accelerations past 40 ft/s² as tracking jumps. */
  caps: boolean;
  /** Frames each side averaged when drawing drive and cut paths, and player trails. */
  path: number; trail: number;
}

export const SMOOTHING: Record<SmoothLevel, SmoothSettings> = {
  smoothed: { label: "Smoothed", title: "Positions averaged over 0.2 s, acceleration over 0.4 s, tracking jumps dropped (the site's usual setting)",
              pos: 2, back: 1, fwd: 1, accBack: 5, accFwd: 5, accMin: 3, caps: true, path: 3, trail: 2 },
  light: { label: "Light", title: "Positions averaged over 0.12 s, acceleration over 0.16 s, tracking jumps dropped",
           pos: 1, back: 1, fwd: 1, accBack: 2, accFwd: 2, accMin: 2, caps: true, path: 1, trail: 1 },
  raw: { label: "Raw", title: "The tracked positions as they are: speed and acceleration from one frame to the next, nothing dropped",
         pos: 0, back: 1, fwd: 0, accBack: 1, accFwd: 0, accMin: 1, caps: false, path: 0, trail: 0 },
};
export const SMOOTH_LEVELS = Object.keys(SMOOTHING) as SmoothLevel[];

const KEY = "acb-viewer-smoothing";
export const smoothing = $state({ level: "smoothed" as SmoothLevel });
try {
  const saved = localStorage.getItem(KEY);
  if (saved && saved in SMOOTHING) smoothing.level = saved as SmoothLevel;
} catch { /* storage unavailable: the default */ }

/** The settings in force (reading it inside a $derived makes the derived follow the menu). */
export const smoothNow = (): SmoothSettings => SMOOTHING[smoothing.level];

export function setSmoothing(level: SmoothLevel): void {
  smoothing.level = level;
  try { localStorage.setItem(KEY, level); } catch { /* not remembered */ }
}
