// Annotations drawn on the court, by section (the Display panel's Annotations toggles):
//   events    where each action happened: shots, passes, dribbles, drives, screens, closeouts, fouls, rebounds,
//             turnovers, and every player's position at the last shot's release (ghosts)
//   defense   coverage on screens, matchup lines and switches, the shot's closest defender, help defenders
//   tracking  each player's openness, the followed or hovered player's speed, the ball's recent path
//   quality   tracking's expected error round each player; extrapolated players are drawn faint (draw.ts)
// The shot details, possession context, chance quality and season figures are HTML beside the court
// (Annotations.svelte, SidePanel.svelte). Event locations come from the event tables (annotations.R); everything
// else is the tracking at the current frame.

import { COLORS, px, py, type Layout } from "./court";
import { CONTEST_COLORS, SCREEN_NAMES, coverageText, frameIndex, lastShot, playerOf } from "./context";
import { clamp } from "./geometry";
import { CUT_TAG } from "./cuts";
import { inPaint, motion } from "./motion";
import type { Cursor } from "./sequence";
import { withAlpha } from "./teamColors";
import type { Play, PlayerTrack, Role, TeamColors } from "./types";

const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
const INK = "#141822";
const LOST = "#E04848";

export interface AnnSections {
  events: boolean;
  defense: boolean;
  shot: boolean;
  tracking: boolean;
  possession: boolean;
  quality: boolean;
  /** Each attacker's rebounding role while a shot is in the air (crash, back, safety, hold). */
  glass: boolean;
}

/** A player's drawn position (blended between frames), in feet. */
export interface Spot { p: PlayerTrack; x: number; y: number }

interface Ctx {
  ctx: CanvasRenderingContext2D;
  L: Layout;
  play: Play;
  c: Cursor;
  /** The tracking frame shown (the earlier of the two being blended). */
  frame: number;
  /** Player dot radius, px. */
  r: number;
  spots: Map<number, Spot>;
}

// How long markers stay up, in frames.
// A pass is shown only while the ball is in the air (an interception's cross for a second after); screens, closeouts
// and fouls for about a second after they happen.
const HOLD = { dribble: 75, pass: 0, intercept: 25, drive: 37, cut: 25, screenBefore: 8, screenAfter: 20, closeout: 12,
               foul: 12, faded: 75, closest: 50, switch: 37, ghosts: 150, ball: 20 };

/** Opacity of something that appears at `start`, stays full until `end`, then fades out over `fade` frames. */
function life(frame: number, start: number, end: number, fade: number): number {
  if (frame < start) return 0;
  if (frame <= end) return 1;
  return clamp(1 - (frame - end) / fade, 0, 1);
}

const kitOf = (play: Play, role: Role): TeamColors => play.colors[role];
const X = (k: Ctx, x: number) => px(k.L, x);
const Y = (k: Ctx, y: number) => py(k.L, y);

/** A player's position at an event's frame (no blending), or null. */
function posAt(k: Ctx, pid: number | undefined, f: number): [number, number] | null {
  const p = playerOf(k.play, pid);
  if (!p) return null;
  const i = frameIndex(k.play, f);
  return Number.isNaN(p.x[i]) ? null : [p.x[i], p.y[i]];
}

/** @param trim Pixels to stop short of the end point (the edge of a player dot drawn there). */
function arrow(k: Ctx, x0: number, y0: number, x1: number, y1: number, color: string, width: number, dashed: boolean, trim = 0): void {
  const { ctx } = k;
  const ax = X(k, x0), ay = Y(k, y0);
  const full = Math.hypot(X(k, x1) - ax, Y(k, y1) - ay);
  if (full - trim < 2) return;
  const ux = (X(k, x1) - ax) / full, uy = (Y(k, y1) - ay) / full;
  const len = full - trim, bx = ax + ux * len, by = ay + uy * len, head = Math.min(10, 0.45 * len);
  ctx.save();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  if (dashed) ctx.setLineDash([6, 5]);
  ctx.beginPath();
  ctx.moveTo(ax, ay);
  ctx.lineTo(bx - ux * head * 0.6, by - uy * head * 0.6);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.beginPath();
  ctx.moveTo(bx, by);
  ctx.lineTo(bx - ux * head - uy * head * 0.55, by - uy * head + ux * head * 0.55);
  ctx.lineTo(bx - ux * head + uy * head * 0.55, by - uy * head - ux * head * 0.55);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

const PATH_SMOOTH = 3;   // frames either side averaged when tracing a player's path (tracking jitters by about a foot)

/**
 * A player's tracked path from frame f0 to frame f1 (tracking frame numbers), lightly smoothed, in feet. Breaks in
 * the tracking are bridged by a straight segment.
 */
function pathOf(k: Ctx, pid: number, f0: number, f1: number): [number, number][] {
  const p = playerOf(k.play, pid);
  if (!p) return [];
  const { frames } = k.play, out: [number, number][] = [];
  for (let i = frameIndex(k.play, f0); i < frames.length && frames[i] <= f1; i++) {
    if (frames[i] < f0) continue;
    let sx = 0, sy = 0, n = 0;
    for (let j = Math.max(0, i - PATH_SMOOTH); j <= Math.min(frames.length - 1, i + PATH_SMOOTH); j++) {
      if (Math.abs(frames[j] - frames[i]) !== Math.abs(j - i) || frames[j] > f1 || frames[j] < f0 || Number.isNaN(p.x[j])) continue;
      sx += p.x[j]; sy += p.y[j]; n++;
    }
    if (n) out.push([sx / n, sy / n]);
  }
  return out;
}

/** An arrow along a path (feet), its head at the end; `trim` px are cut off the end (the edge of a dot there). */
function pathArrow(k: Ctx, path: [number, number][], color: string, width: number, trim = 0): void {
  const pts = path.map(([x, y]) => [X(k, x), Y(k, y)] as [number, number]);
  // Cut `trim` px off the end.
  let cut = trim;
  while (pts.length > 1 && cut > 0) {
    const [ax, ay] = pts[pts.length - 2], [bx, by] = pts[pts.length - 1], seg = Math.hypot(bx - ax, by - ay);
    if (seg > cut) { pts[pts.length - 1] = [bx - ((bx - ax) * cut) / seg, by - ((by - ay) * cut) / seg]; cut = 0; }
    else { pts.pop(); cut -= seg; }
  }
  if (pts.length < 2) return;
  let total = 0;
  for (let i = 1; i < pts.length; i++) total += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
  if (total < 4) return;
  // The head points along the last few pixels of the path.
  const [bx, by] = pts[pts.length - 1];
  let j = pts.length - 2;
  while (j > 0 && Math.hypot(bx - pts[j][0], by - pts[j][1]) < 8) j--;
  const d = Math.hypot(bx - pts[j][0], by - pts[j][1]) || 1, ux = (bx - pts[j][0]) / d, uy = (by - pts[j][1]) / d;
  const head = Math.min(10, 0.45 * total);
  const { ctx } = k;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length - 1; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.lineTo(bx - ux * head * 0.6, by - uy * head * 0.6);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(bx, by);
  ctx.lineTo(bx - ux * head - uy * head * 0.55, by - uy * head + ux * head * 0.55);
  ctx.lineTo(bx - ux * head + uy * head * 0.55, by - uy * head - ux * head * 0.55);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

/** Where a moving player is now along his action (his tracked spot, held at the action's end once it is over). */
function routeNow(k: Ctx, pid: number, f0: number, f1: number, fallback: [number, number]): [number, number] {
  const path = pathOf(k, pid, f0, Math.min(Math.max(k.frame, f0), f1));
  return path.length ? path[path.length - 1] : fallback;
}

/**
 * A player's whole route for an action (drive, cut, closeout), from its first frame to its last, drawn from the
 * start: the stretch he has already covered in `color`, the rest still ahead of him paler, and the head at the
 * route's end. The colour runs along the route with him.
 */
function routeArrow(k: Ctx, pid: number, f0: number, f1: number, color: string, width: number, dashed = false): void {
  const full = pathOf(k, pid, f0, f1);
  if (full.length < 2) return;
  const { ctx } = k;
  const done = k.frame >= f1 ? full.length : pathOf(k, pid, f0, Math.max(k.frame, f0)).length;
  if (dashed) ctx.setLineDash([6, 5]);
  pathArrow(k, full, done >= full.length ? color : withAlpha(color, 0.35), width);
  if (done >= 2 && done < full.length) {
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.beginPath();
    full.slice(0, done).forEach(([x, y], i) => (i ? ctx.lineTo(X(k, x), Y(k, y)) : ctx.moveTo(X(k, x), Y(k, y))));
    ctx.stroke();
    ctx.restore();
  }
  ctx.setLineDash([]);
}

/** A small dark label centred on (x, y), in px. */
export function tag(ctx: CanvasRenderingContext2D, x: number, y: number, text: string, color: string, size = 10): void {
  ctx.font = `700 ${size}px ${FONT}`;
  const w = ctx.measureText(text).width + 8, h = size + 6;
  ctx.fillStyle = withAlpha(COLORS.panel, 0.9);
  ctx.beginPath();
  ctx.roundRect(x - w / 2, y - h / 2, w, h, 4);
  ctx.fill();
  ctx.fillStyle = color;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, x, y + 0.5);
}

function cross(k: Ctx, x: number, y: number, size: number, color: string): void {
  const { ctx } = k, cx = X(k, x), cy = Y(k, y);
  for (const [w, c] of [[4.5, "rgba(11,14,20,.55)"], [2.5, color]] as const) {
    ctx.beginPath();
    ctx.moveTo(cx - size, cy - size); ctx.lineTo(cx + size, cy + size);
    ctx.moveTo(cx + size, cy - size); ctx.lineTo(cx - size, cy + size);
    ctx.lineWidth = w;
    ctx.lineCap = "round";
    ctx.strokeStyle = c;
    ctx.stroke();
  }
}

function letter(k: Ctx, x: number, y: number, text: string, fill: string, ink: string): void {
  const { ctx } = k, cx = X(k, x), cy = Y(k, y), s = 7;
  ctx.beginPath();
  ctx.moveTo(cx, cy - s); ctx.lineTo(cx + s, cy); ctx.lineTo(cx, cy + s); ctx.lineTo(cx - s, cy);
  ctx.closePath();
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.lineWidth = 1;
  ctx.strokeStyle = "rgba(11,14,20,.6)";
  ctx.stroke();
  ctx.fillStyle = ink;
  ctx.font = `800 8px ${FONT}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, cx, cy + 0.5);
}

// ---- under the players ---------------------------------------------------------------------------

function drawEventsUnder(k: Ctx): void {
  const { ctx, play, frame } = k, ann = play.ann!;
  const off = kitOf(play, "off"), def = kitOf(play, "def");

  for (const d of ann.dribbles) {
    const a = life(frame, d.f, d.f, HOLD.dribble);
    if (!a) continue;
    ctx.globalAlpha = 0.85 * a;
    ctx.beginPath();
    ctx.arc(X(k, d.x), Y(k, d.y), 2.6, 0, 2 * Math.PI);
    ctx.fillStyle = off.mark;
    ctx.fill();
  }
  ctx.globalAlpha = 1;

  for (const p of ann.passes) {
    const a = life(frame, p.f, p.f1, p.lost ? HOLD.intercept : HOLD.pass);
    if (!a || (frame > p.f1 && !p.lost)) continue;
    const from = p.x0 != null && p.y0 != null ? [p.x0, p.y0] : posAt(k, p.pid, p.f);
    // While the ball is in the air the head follows the receiver (or, on an interception, the defender who takes it)
    // where he is drawn now; the cross after an interception marks where he took it.
    const catcher = p.lost ? p.stealer : p.to;
    const now = frame <= p.f1 && catcher != null ? k.spots.get(catcher) : undefined;
    const to = now ? [now.x, now.y]
      : p.lost ? posAt(k, p.stealer, p.f1) ?? (p.x1 != null ? [p.x1, p.y1!] : null)
      : p.x1 != null && p.y1 != null ? [p.x1, p.y1] : posAt(k, p.to, p.f1);
    if (!from || !to) continue;
    ctx.globalAlpha = a;
    if (frame <= p.f1) arrow(k, from[0], from[1], to[0], to[1], p.lost ? LOST : "rgba(20,24,34,.8)", 2, true, now ? k.r + 2 : 0);
    else cross(k, to[0], to[1], 6, LOST);
  }
  ctx.globalAlpha = 1;

  for (const d of ann.drives) {
    const a = life(frame, d.f, d.f1, HOLD.drive);
    if (!a) continue;
    ctx.globalAlpha = 0.85 * a;
    // The driver's whole tracked route, coloured as far as he has got.
    routeArrow(k, d.pid, d.f, d.f1, off.mark, 3.5);
  }
  for (const c of ann.cuts ?? []) {
    const a = life(frame, c.f, c.f1, HOLD.cut);
    if (!a) continue;
    ctx.globalAlpha = 0.85 * a;
    routeArrow(k, c.pid, c.f, c.f1, off.mark, 2.5);
  }
  for (const c of ann.closeouts) {
    const a = life(frame, c.f, c.f1, HOLD.closeout);
    if (!a) continue;
    ctx.globalAlpha = 0.9 * a;
    // The defender's tracked run, coloured as far as he has got (his start and end spots if he is untracked).
    if (pathOf(k, c.def, c.f, c.f1).length >= 2) routeArrow(k, c.def, c.f, c.f1, def.mark, 2.5, true);
    else arrow(k, c.x0, c.y0, c.x1, c.y1, def.mark, 2.5, true);
  }
  for (const s of ann.screens) {
    const a = life(frame, s.f - HOLD.screenBefore, s.f, HOLD.screenAfter);
    if (!a) continue;
    ctx.globalAlpha = a;
    const user = posAt(k, s.use, s.f);
    let ux = 1, uy = 0;
    if (user) {
      const len = Math.hypot(user[0] - s.x, user[1] - s.y);
      if (len > 0.1) { ux = (user[0] - s.x) / len; uy = (user[1] - s.y) / len; }
    }
    // A "T": the stem from the screener's spot to a wall facing the player using the screen.
    const wx = s.x + 1.1 * ux, wy = s.y + 1.1 * uy, half = 1.5;
    ctx.lineCap = "round";
    for (const [w, color] of [[6.5, "rgba(11,14,20,.5)"], [4, off.mark]] as const) {
      ctx.beginPath();
      ctx.moveTo(X(k, s.x), Y(k, s.y)); ctx.lineTo(X(k, wx), Y(k, wy));
      ctx.moveTo(X(k, wx - half * uy), Y(k, wy + half * ux)); ctx.lineTo(X(k, wx + half * uy), Y(k, wy - half * ux));
      ctx.lineWidth = w;
      ctx.strokeStyle = color;
      ctx.stroke();
    }
  }
  ctx.globalAlpha = 1;

  // Every player at the last shot's release, until the next shot or six seconds on.
  const shot = lastShot(play, frame);
  if (shot && frame <= shot.f1 + HOLD.ghosts) {
    ctx.save();
    ctx.setLineDash([3, 3]);
    for (const g of shot.ghosts) {
      const p = playerOf(play, g.pid);
      if (!p) continue;
      const kit = kitOf(play, p.role), gx = X(k, g.x), gy = Y(k, g.y);
      ctx.globalAlpha = 0.7;
      ctx.beginPath();
      ctx.arc(gx, gy, 0.8 * k.r, 0, 2 * Math.PI);
      ctx.fillStyle = withAlpha(kit.fill, 0.18);
      ctx.fill();
      ctx.lineWidth = 1.6;
      ctx.strokeStyle = kit.mark;
      ctx.stroke();
      ctx.fillStyle = kit.mark;
      ctx.font = `700 ${Math.round(0.75 * k.r)}px ${FONT}`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(p.jersey, gx, gy + 0.5);
    }
    ctx.restore();
  }

  for (const s of ann.shots) {
    if (s.f > frame) continue;
    const color = CONTEST_COLORS[s.cl ?? ""] ?? COLORS.muted, cx = X(k, s.x), cy = Y(k, s.y);
    const rad = clamp(0.8 * k.L.s, 5, 9);
    ctx.beginPath();
    ctx.arc(cx, cy, rad, 0, 2 * Math.PI);
    if (s.made) {
      ctx.fillStyle = color;
      ctx.fill();
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = "rgba(11,14,20,.8)";
      ctx.stroke();
    } else {
      ctx.lineWidth = 5.5;
      ctx.strokeStyle = "rgba(11,14,20,.7)";
      ctx.stroke();
      ctx.lineWidth = 3;
      ctx.strokeStyle = color;
      ctx.stroke();
    }
  }
  for (const fo of ann.fouls) {
    if (fo.x == null || fo.y == null) continue;
    const a = life(frame, fo.f, fo.f + HOLD.foul, HOLD.foul);
    if (!a) continue;
    ctx.globalAlpha = a;
    cross(k, fo.x, fo.y, 5.5, "#F5B02E");
  }
  for (const rb of ann.rebounds) {
    if (rb.f > frame || rb.x == null || rb.y == null) continue;
    ctx.globalAlpha = life(frame, rb.f, rb.f + HOLD.faded, HOLD.faded) * 0.45 + 0.55;
    const kit = kitOf(play, rb.def ? "def" : "off");
    letter(k, rb.x, rb.y, "R", kit.fill, kit.ink);
  }
  for (const t of ann.turnovers) {
    if (t.f > frame || t.x == null || t.y == null) continue;
    ctx.globalAlpha = life(frame, t.f, t.f + HOLD.faded, HOLD.faded) * 0.45 + 0.55;
    letter(k, t.x, t.y, "TO", LOST, "#FFFFFF");
  }
  ctx.globalAlpha = 1;
}

function activeMatchups(k: Ctx) {
  return (k.play.ann?.matchups ?? []).filter((m) => m.f <= k.frame && k.frame <= m.f1);
}

function drawDefenseUnder(k: Ctx): void {
  const { ctx } = k, def = kitOf(k.play, "def");
  ctx.save();
  ctx.setLineDash([4, 4]);
  ctx.lineWidth = 1.4;
  ctx.strokeStyle = withAlpha(def.mark, 0.6);
  for (const m of activeMatchups(k)) {
    const a = k.spots.get(m.def), b = k.spots.get(m.off);
    if (!a || !b) continue;
    ctx.beginPath();
    ctx.moveTo(X(k, a.x), Y(k, a.y));
    ctx.lineTo(X(k, b.x), Y(k, b.y));
    ctx.stroke();
  }
  ctx.restore();
}

function drawQualityUnder(k: Ctx): void {
  const { ctx } = k;
  ctx.save();
  ctx.setLineDash([3, 3]);
  for (const s of k.spots.values()) {
    const err = s.p.e[k.c.i0];
    if (Number.isNaN(err)) continue;
    const rad = err * k.L.s;
    if (rad <= k.r + 1) continue;   // inside the dot
    ctx.beginPath();
    ctx.arc(X(k, s.x), Y(k, s.y), rad, 0, 2 * Math.PI);
    ctx.fillStyle = "rgba(11,14,20,.035)";
    ctx.fill();
    ctx.lineWidth = 1;
    ctx.strokeStyle = "rgba(11,14,20,.3)";
    ctx.stroke();
  }
  ctx.restore();
}

function drawBallTrail(k: Ctx): void {
  const { ctx, play, c } = k;
  ctx.save();
  for (let back = HOLD.ball; back >= 1; back--) {
    const i = c.i0 - back;
    if (i < 0 || play.frames[c.i0] - play.frames[i] !== back) continue;
    const x = play.ball.x[i], y = play.ball.y[i], z = play.ball.z[i];
    if (Number.isNaN(x) || Number.isNaN(y)) continue;
    const size = clamp(0.55 * k.L.s, 4.5, 10) * (1 + clamp(Number.isNaN(z) ? 0 : z, 0, 20) / 10);
    ctx.globalAlpha = 0.35 * (1 - back / (HOLD.ball + 1));
    ctx.beginPath();
    ctx.arc(X(k, x), Y(k, y), 0.7 * size, 0, 2 * Math.PI);
    ctx.fillStyle = COLORS.ball;
    ctx.fill();
  }
  ctx.restore();
}

/** Everything drawn under the player dots. */
export function drawAnnotationsUnder(k: Ctx, o: AnnSections): void {
  if (!k.play.ann) {
    if (o.quality) drawQualityUnder(k);
    return;
  }
  if (o.quality) drawQualityUnder(k);
  if (o.defense) drawDefenseUnder(k);
  if (o.events) drawEventsUnder(k);
  if (o.tracking) drawBallTrail(k);
}

// ---- over the players ----------------------------------------------------------------------------

/** A small pill beside a dot, like an exponent: openness, help, switch. */
function script(k: Ctx, s: Spot, text: string, ink: string, left = false): void {
  const { ctx, r } = k, size = 9;
  ctx.font = `700 ${size}px ${FONT}`;
  const w = ctx.measureText(text).width + 7, h = size + 4;
  const cx = X(k, s.x), cy = Y(k, s.y) - 0.82 * r;
  const x0 = left ? cx - 0.62 * r - w : cx + 0.62 * r;
  ctx.beginPath();
  ctx.roundRect(x0, cy - h / 2, w, h, h / 2);
  ctx.fillStyle = withAlpha(COLORS.panel, 0.92);
  ctx.fill();
  ctx.lineWidth = 1;
  ctx.strokeStyle = ink;
  ctx.stroke();
  ctx.fillStyle = ink;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, x0 + w / 2, cy + 0.5);
}

// Under each screen marker: its name (events) and the coverage called (defense).
function drawScreenTags(k: Ctx, names: boolean, coverage: boolean): void {
  const { ctx, play, frame, r } = k, def = kitOf(play, "def");
  for (const s of play.ann!.screens) {
    const a = life(frame, s.f - HOLD.screenBefore, s.f, HOLD.screenAfter);
    if (!a) continue;
    ctx.globalAlpha = a;
    const cx = X(k, s.x);
    let cy = Y(k, s.y) + r + 9;
    if (names) { tag(ctx, cx, cy, SCREEN_NAMES[s.kind], COLORS.ink, 10); cy += 16; }
    const cov = coverage ? coverageText(s) : "";
    if (cov) tag(ctx, cx, cy, cov, def.text, 10);
  }
  ctx.globalAlpha = 1;
}

function drawEventsOver(k: Ctx): void {
  const { ctx, play, frame, r } = k, ann = play.ann!;
  const def = kitOf(play, "def");
  for (const d of ann.drives) {
    const a = life(frame, d.f, d.f1, HOLD.drive);
    if (!a) continue;
    ctx.globalAlpha = a;
    const text = ["Drive", d.dir, d.blowby ? "blow-by" : null].filter(Boolean).join(" · ");
    const [ex, ey] = routeNow(k, d.pid, d.f, d.f1, [d.x1, d.y1]);
    tag(ctx, X(k, ex), Y(k, ey) - r - 10, text, COLORS.ink, 10);
  }
  for (const c of ann.cuts ?? []) {
    const a = life(frame, c.f, c.f1, HOLD.cut);
    if (!a) continue;
    const at = routeNow(k, c.pid, c.f, c.f1, [NaN, NaN]);
    if (Number.isNaN(at[0])) continue;
    ctx.globalAlpha = a;
    tag(ctx, X(k, at[0]), Y(k, at[1]) - r - 10, CUT_TAG[c.kind], COLORS.ink, 10);
  }
  for (const c of ann.closeouts) {
    const a = life(frame, c.f, c.f1, HOLD.closeout);
    if (!a) continue;
    ctx.globalAlpha = a;
    tag(ctx, X(k, c.x1), Y(k, c.y1) + r + 9, `Closeout ${c.d0.toFixed(0)}→${c.d1.toFixed(0)} ft${c.act ? ` · then ${c.act}` : ""}`, def.text, 10);
  }
  ctx.globalAlpha = 1;
}

function drawDefenseOver(k: Ctx, handler: number | null): void {
  const { ctx, play, frame, r } = k, def = kitOf(play, "def");
  const active = activeMatchups(k);
  const all = play.ann?.matchups ?? [];
  // Switches: a defender whose assignment changed in the last moment and a half.
  for (const m of active) {
    if (frame - m.f > HOLD.switch) continue;
    const before = all.find((b) => b.def === m.def && b.off !== m.off && b.f1 >= m.f - 2 && b.f1 <= m.f && b.f < m.f);
    const s = k.spots.get(m.def);
    if (before && s) script(k, s, "SW", "#F5B02E", true);
  }
  // Help: a defender well away from his man and near the ball or in the paint.
  const ball = handler != null ? k.spots.get(handler) : undefined;
  for (const m of active) {
    if (m.off === handler) continue;
    const d = k.spots.get(m.def), man = k.spots.get(m.off);
    if (!d || !man) continue;
    const away = Math.hypot(d.x - man.x, d.y - man.y);
    const nearBall = ball ? Math.hypot(d.x - ball.x, d.y - ball.y) < 9 : false;
    if (away > 10 && (nearBall || inPaint(d.x, d.y))) script(k, d, "Help", def.text, true);
  }
  // The shot's closest defender, ringed with his distance for two seconds after release.
  const shot = lastShot(play, frame);
  if (shot && shot.defId != null && frame - shot.f <= HOLD.closest) {
    const s = k.spots.get(shot.defId);
    if (s) {
      const cx = X(k, s.x), cy = Y(k, s.y);
      ctx.save();
      ctx.setLineDash([4, 3]);
      ctx.beginPath();
      ctx.arc(cx, cy, r + 5, 0, 2 * Math.PI);
      ctx.lineWidth = 2.5;
      ctx.strokeStyle = def.edge;
      ctx.stroke();
      ctx.restore();
      if (shot.defDist != null) tag(ctx, cx, cy + r + 22, `Closest ${shot.defDist.toFixed(1)} ft`, def.text, 10);
    }
  }
}

function drawTrackingOver(k: Ctx, focus: number | null): void {
  const { ctx, play, c, r } = k;
  // Openness: each offensive player's distance to his nearest defender.
  const defenders = [...k.spots.values()].filter((s) => s.p.role === "def");
  for (const s of k.spots.values()) {
    if (s.p.role !== "off" || !defenders.length) continue;
    const near = Math.min(...defenders.map((d) => Math.hypot(d.x - s.x, d.y - s.y)));
    const ink = near >= 6 ? "#2FAE5A" : near >= 3 ? "#EEC23A" : "#E04848";
    script(k, s, near.toFixed(0), ink);
  }
  // Speed of the followed or hovered player.
  if (focus != null) {
    const s = k.spots.get(focus), at = play.players.findIndex((p) => p.id === focus);
    const v = at >= 0 ? motion(play).speed[at][c.i0] : NaN;
    if (s && !Number.isNaN(v)) tag(ctx, X(k, s.x), Y(k, s.y) + r + 24, `${v.toFixed(1)} ft/s`, COLORS.ink, 10);
  }
}

// Rebounding roles: from release until a second after the flight ends, a tag over each attacker. A crash met by its
// matchup says so; a role read mostly from extrapolated positions (under half the window on camera) ends in "?".
export const GLASS_NAMES: Record<string, string> = { crash: "Crash", back: "Back", safety: "Safety", hold: "Hold", follow: "Follows", shooter: "" };
const GLASS_COLORS: Record<string, string> = { crash: "#FFB547", follow: "#FFB547", back: "#7FB2FF", safety: "#B8C2D6", hold: "#93A0B8" };
function drawGlassOver(k: Ctx): void {
  const { ctx, play, frame, r } = k, ann = play.ann!;
  // Players already tagged above their dot by a drive or a cut get the role one line higher.
  const busy = new Set<number>();
  for (const d of ann.drives) if (life(frame, d.f, d.f1, HOLD.drive)) busy.add(d.pid);
  for (const c of ann.cuts ?? []) if (life(frame, c.f, c.f1, HOLD.cut)) busy.add(c.pid);
  for (const g of ann.glass ?? []) {
    const a = life(frame, g.f, g.f1, 25);
    const name = GLASS_NAMES[g.role];
    if (!a || !name) continue;
    const s = k.spots.get(g.pid);
    if (!s) continue;
    ctx.globalAlpha = a;
    const text = `${name}${g.role === "crash" && g.boxed ? " · met" : ""}${(g.seen ?? 1) < 0.5 ? "?" : ""}`;
    tag(ctx, X(k, s.x), Y(k, s.y) - r - (busy.has(g.pid) ? 26 : 10), text, GLASS_COLORS[g.role] ?? COLORS.ink, 10);
  }
  ctx.globalAlpha = 1;
}

/** Everything drawn over the player dots. */
export function drawAnnotationsOver(k: Ctx, o: AnnSections, handler: number | null, focus: number | null): void {
  if (k.play.ann) {
    if (o.events || o.defense) drawScreenTags(k, o.events, o.defense);
    if (o.events) drawEventsOver(k);
    if (o.glass) drawGlassOver(k);
    if (o.defense) drawDefenseOver(k, handler);
  }
  if (o.tracking) drawTrackingOver(k, focus);
}

export function annContext(ctx: CanvasRenderingContext2D, L: Layout, play: Play, c: Cursor, r: number, spots: Spot[]): Ctx {
  return { ctx, L, play, c, frame: play.frames[c.i0] + c.t, r, spots: new Map(spots.map((s) => [s.p.id, s])) };
}
