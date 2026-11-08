// Cuts: off-ball runs by an attacker. SkillCorner marks only the cuts that use an off-ball screen
// (off_ball_screens: the cutter and the screen's frame), so the rest are found here from the tracking. Run on
// decode, after the shots are filled in; adds `ann.cuts` and a "cut" event per cut to the play's timeline.
//
// A basket cut is a stretch of live play in which an attacker without the ball, in the frontcourt, runs toward the
// basket: smoothed speed (motion.ts) at least MIN_SPEED ft/s with at least MIN_TOWARD ft/s of it toward the hoop,
// for at least MIN_FRAMES (gaps of up to GAP frames bridged), gaining at least MIN_GAIN ft on the basket, starting
// within MAX_START ft of it (not a transition sprint from deep) and ending within MAX_END ft (in or near the paint).
// Every off-ball screen's cutter also gets a cut: his run through the screen, from LEAD frames before it until he
// slows below SETTLE ft/s or AFTER frames pass, merged with a basket cut it overlaps. Its kind says where it went:
//   basket   toward the hoop without a screen
//   in       through an off-ball screen, finishing closer to the basket (a curl, a back screen, ...)
//   out      through an off-ball screen, finishing further from it (a pin-down, a flare, ...)
// Pure, so the tests can run it.

import { HOOP_X } from "./court";
import { motion } from "./motion";
import type { AnnCut, Play, PlayEvent } from "./types";

const MIN_SPEED = 9, MIN_TOWARD = 7;        // ft/s
const MIN_FRAMES = 12, GAP = 3;             // frames (0.48 s, 0.12 s)
const MIN_GAIN = 8, MAX_START = 32, MAX_END = 14;   // ft
const LEAD = 12, AFTER = 50, SETTLE = 6;    // frames, frames, ft/s

const toHoop = (x: number, y: number) => Math.hypot(HOOP_X - x, y);

export function findCuts(play: Play): void {
  const ann = play.ann;
  if (!ann) return;
  const m = motion(play), { frames } = play, n = frames.length;
  const handler = (pid: number, f: number) => play.touches.some((t) => t.pid === pid && f >= t.f0 && f <= t.f1);
  const cuts: AnnCut[] = [];

  play.players.forEach((p, k) => {
    if (p.role !== "off") return;
    const sp = m.speed[k], vx = m.vx[k], vy = m.vy[k];
    const ok = (i: number) => {
      if (play.stopped[i] || Number.isNaN(sp[i]) || p.x[i] <= 0 || handler(p.id, frames[i])) return false;
      const d = toHoop(p.x[i], p.y[i]);
      const toward = d > 1e-6 ? (vx[i] * (HOOP_X - p.x[i]) + vy[i] * -p.y[i]) / d : 0;
      return sp[i] >= MIN_SPEED && toward >= MIN_TOWARD;
    };
    let i = 0;
    while (i < n) {
      if (!ok(i)) { i++; continue; }
      let j = i, miss = 0;
      for (let t = i + 1; t < n && frames[t] - frames[t - 1] === 1; t++) {
        if (ok(t)) { j = t; miss = 0; } else if (++miss > GAP) break;
      }
      const d0 = toHoop(p.x[i], p.y[i]), d1 = toHoop(p.x[j], p.y[j]);
      if (frames[j] - frames[i] >= MIN_FRAMES && d0 - d1 >= MIN_GAIN && d0 <= MAX_START && d1 <= MAX_END) {
        cuts.push({ f: frames[i], f1: frames[j], pid: p.id, kind: "basket" });
      }
      i = j + 1;
    }
  });

  // Cuts through off-ball screens: the run through the screen, merged with a basket cut it overlaps.
  for (const s of ann.screens.filter((x) => x.kind === "off_ball_screen")) {
    const k = play.players.findIndex((p) => p.id === s.use);
    if (k < 0) continue;
    const p = play.players[k], sp = m.speed[k];
    const at = frames.findIndex((f) => f >= s.f);
    if (at < 0) continue;
    let a = Math.max(0, at - LEAD), b = at;
    while (a < at && Number.isNaN(p.x[a])) a++;
    for (let t = at + 1; t < n && frames[t] - frames[t - 1] === 1 && frames[t] - s.f <= AFTER; t++) {
      if (Number.isNaN(p.x[t]) || handler(p.id, frames[t])) break;
      b = t;
      if (frames[t] - s.f > 6 && sp[t] < SETTLE) break;
    }
    if (Number.isNaN(p.x[a]) || Number.isNaN(p.x[b]) || b <= a) continue;
    const same = cuts.find((c) => c.pid === s.use && c.f <= frames[b] + 6 && c.f1 >= frames[a] - 6);
    if (same) {
      same.f = Math.min(same.f, frames[a]);
      same.f1 = Math.max(same.f1, frames[b]);
      same.kind = "in";
      same.cov = s.covUse;
      continue;
    }
    const closer = toHoop(p.x[b], p.y[b]) < toHoop(p.x[a], p.y[a]);
    cuts.push({ f: frames[a], f1: frames[b], pid: s.use, kind: closer ? "in" : "out", cov: s.covUse });
  }

  cuts.sort((x, y) => x.f - y.f);
  ann.cuts = cuts;
  const name = (pid: number) => play.players.find((q) => q.id === pid);
  const events: PlayEvent[] = cuts.map((c) => {
    const p = name(c.pid);
    return { f: c.f, kind: "cut", label: `${CUT_LABEL[c.kind]}: ${p ? `#${p.jersey} ${p.last}` : "unknown"}`, short: "Cut", who: p?.last ?? null };
  });
  play.events = [...play.events, ...events].sort((x, y) => x.f - y.f);
}

export const CUT_LABEL: Record<AnnCut["kind"], string> = { basket: "Basket cut", in: "Screen cut in", out: "Screen cut out" };
export const CUT_TAG: Record<AnnCut["kind"], string> = { basket: "Cut · basket", in: "Cut · screen · in", out: "Cut · screen · out" };
