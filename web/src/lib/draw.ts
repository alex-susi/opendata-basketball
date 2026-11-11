// Draws one moment of a possession on the canvas: court, hulls, players, ball, the trace panel's pair and the
// caption. The clock and score are on the page, not the canvas, except in a recorded video (drawHeader). Ported
// from draw(), drawPlayer(), drawHeader() and drawCaption() in the Shiny app's www/player.js.

import { annContext, drawAnnotationsOver, drawAnnotationsUnder, type AnnSections } from "./annotate";
import { controlAt, drawControl, motionLimits } from "./control";
import { logoImage } from "./logos.svelte";
import { COLORS, HEADER_TOP, MARGIN, PAD, REACH, courtLayout, drawCourt, px, py, type CourtView, type Layout } from "./court";
import { clamp, clock, convexHull, polygonArea, quarter, type Point } from "./geometry";
import { ballHandler, blend, cursorAt, type Cursor } from "./sequence";
import { withAlpha } from "./teamColors";
import { nearestAt } from "./trace";
import type { Play, PlayerTrack, Sample, TeamColors } from "./types";

const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
const CAPTION_FRAMES = 62;   // how long an event label stays up

export interface DrawOptions {
  view: CourtView;
  showDef: boolean;
  showOff: boolean;
  showArch: boolean;
  /** A fading trail behind each player: where he has been over the last 0.6 s, so its length shows his speed. */
  showTrails: boolean;
  /** Court control: which team would reach the ball first at each spot (control.ts). */
  showControl: boolean;
  /** The tracked games' figures: court control uses each player's motion limits from them (null: one speed for all). */
  sample?: Sample | null;
  /** Annotation sections drawn on the court (annotate.ts). */
  ann: AnnSections;
  /** The player whose nearest opponent is shown: both ringed and joined by a line. Null shows no pair. */
  focusPid: number | null;
  hoverPid: number | null;
  /** The live coverage model's attention share (0-1) per player id at this frame, or null (coverage.ts). */
  attention?: Map<number, number> | null;
}

const ATT_COLOR = "#9b5de5";
// The coverage model's attention: a purple ring on each player, thicker the more of the four screen players'
// attention he gets, and the top three shares labelled above their dots.
function drawAttention(ctx: CanvasRenderingContext2D, L: Layout, dots: Dot[], r: number, att: Map<number, number>): void {
  const shares = dots.map((d) => ({ d, s: att.get(d.p.id) ?? 0 })).filter((x) => x.s > 0);
  const top = Math.max(...shares.map((x) => x.s), 0.01);
  for (const { d, s } of shares) {
    if (s < 0.03) continue;
    drawRing(ctx, px(L, d.x), py(L, d.y), r + 2, ATT_COLOR, 1 + 6 * (s / top));
  }
  for (const { d, s } of [...shares].sort((a, b) => b.s - a.s).slice(0, 3)) {
    drawTag(ctx, px(L, d.x), py(L, d.y) - r - 14, `${Math.round(100 * s)}%`, ATT_COLOR, 10);
  }
}

/** What the page shows beside the canvas about the frame just drawn: rosters and clocks. */
export interface FrameInfo {
  onCourt: number[];
  handler: number | null;
  areaOff: number | null;
  areaDef: number | null;
  gameClock: string;
  shotClock: string;
  /** Every player dot drawn, in CSS pixels, so a click on the canvas can find the player under it. */
  hits: { id: number; x: number; y: number; r: number }[];
  /** The court's box in CSS pixels, and whether the backcourt (the half the offense is not attacking) is the left
   * half, for the cards placed over it. */
  box: { left: number; top: number; w: number; h: number; backLeft: boolean };
  /** Index of the tracking frame drawn (the earlier of the two being blended). */
  i0: number;
  /** With court control on: the offense's share of the whole court and of its attacking half, or null. */
  control: { court: number; half: number } | null;
}

interface Dot {
  p: PlayerTrack;
  x: number;
  y: number;
}

// Archetype colours are the roster tags' (--arch-<slot> in app.css); each is read from the page once.
const archColors = new Map<string, string>();
function archColor(slot: string): string {
  let color = archColors.get(slot);
  if (color === undefined) {
    color = getComputedStyle(document.documentElement).getPropertyValue(`--arch-${slot}`).trim() || COLORS.muted;
    archColors.set(slot, color);
  }
  return color;
}

// Ball height (ft) at which the drawn ball is twice its floor size, and the height past which it stops growing
// (tracking noise can throw the ball's z well above any real arc).
const BALL_Z_DOUBLE = 10;
const BALL_Z_MAX = 20;

// Player dots are this much larger than they first were; the archetype tags beside them keep their old size.
const DOT_GROWTH = 1.15;

// The archetype tag under a dot is abbreviated; the roster beside the court spells it out.
const ARCH_ABBR: Record<string, string> = {
  "Slasher": "Slsh", "Roll & Cut Big": "R&C", "Athletic Finisher": "AthF", "Movement Shooter": "Mvmt",
  "Primary Ball Handler": "PBH", "Post Scorer": "Post", "Off Screen Shooter": "OffScr", "Stationary Shooter": "Stnry",
  "Secondary Ball Handler": "SBH", "Versatile Big": "VstlBig", "Point of Attack": "PoA", "Helper": "Hlpr",
  "Chaser": "Chsr", "Anchor Big": "Anchr",
};

// A colour mixed with white, like the roster tag's color-mix(in srgb, colour 75%, white).
function tint(color: string, share = 0.75): string {
  const m = /^#?([0-9a-f]{6})$/i.exec(color.trim());
  if (!m) return color;
  const v = parseInt(m[1], 16);
  return `rgb(${[16, 8, 0].map((s) => Math.round(share * ((v >> s) & 255) + (1 - share) * 255)).join(",")})`;
}

const shotClockText = (seconds: number): string => (Number.isNaN(seconds) ? "–" : String(Math.ceil(seconds)));

// A team's hull: filled in its primary colour, outlined in whichever of its colours shows best on the floor.
// Returns its area in square feet whether or not it is drawn, or null when fewer than three players are placed.
function drawHull(ctx: CanvasRenderingContext2D, L: Layout, dots: Dot[], kit: TeamColors, show: boolean): number | null {
  const poly = convexHull(dots.map((d): Point => [d.x, d.y]));
  if (poly.length < 3) return null;
  if (!show) return polygonArea(poly);
  ctx.beginPath();
  poly.forEach((q, i) => (i ? ctx.lineTo(px(L, q[0]), py(L, q[1])) : ctx.moveTo(px(L, q[0]), py(L, q[1]))));
  ctx.closePath();
  ctx.globalAlpha = 0.5;
  ctx.fillStyle = kit.fill;
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  ctx.strokeStyle = kit.mark;
  ctx.stroke();
  return polygonArea(poly);
}

// The glow round the ball handler: his team's secondary colour, strongest at the dot's edge and fading out.
function drawHalo(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, color: string): void {
  const reach = r + Math.max(9, 0.6 * r);
  const glow = ctx.createRadialGradient(x, y, r - 1, x, y, reach);
  glow.addColorStop(0, withAlpha(color, 0.95));
  glow.addColorStop(0.35, withAlpha(color, 0.55));
  glow.addColorStop(1, withAlpha(color, 0));
  ctx.beginPath();
  ctx.arc(x, y, reach, 0, 2 * Math.PI);
  ctx.fillStyle = glow;
  ctx.fill();
}

// A ring hugging a dot, in a team's secondary colour, over a faint dark line so a white or yellow ring still
// shows on the floor.
function drawRing(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, color: string, width: number): void {
  const at = r + 1 + width / 2;
  ctx.beginPath();
  ctx.arc(x, y, at, 0, 2 * Math.PI);
  ctx.lineWidth = width + 2;
  ctx.strokeStyle = "rgba(11, 14, 20, .45)";
  ctx.stroke();
  ctx.lineWidth = width;
  ctx.strokeStyle = color;
  ctx.stroke();
}

// A player dot: a disc of his team's primary colour with the number on it. The ball handler glows in his team's
// secondary colour; the player hovered in a roster is ringed in it. With the Data Quality annotations on, a
// position extrapolated rather than seen on screen is drawn faint with a dashed edge.
function drawPlayer(ctx: CanvasRenderingContext2D, L: Layout, d: Dot, r: number, kit: TeamColors, hasBall: boolean, o: DrawOptions,
                    faint = false): void {
  const x = px(L, d.x), y = py(L, d.y);
  if (hasBall) drawHalo(ctx, x, y, r, kit.edge);
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  ctx.globalAlpha = faint ? 0.45 : 1;
  ctx.fillStyle = kit.fill;
  ctx.fill();
  ctx.globalAlpha = 1;
  if (faint) {
    ctx.setLineDash([3, 2]);
    ctx.lineWidth = 1.6;
    ctx.strokeStyle = "rgba(11, 14, 20, .8)";
  } else {
    ctx.lineWidth = 1;
    ctx.strokeStyle = "rgba(11, 14, 20, .35)";
  }
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = kit.ink;
  ctx.font = `700 ${Math.round(r * (d.p.jersey.length > 1 ? 0.95 : 1.1))}px ${FONT}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(d.p.jersey, x, y + 0.5);
  if (o.hoverPid === d.p.id) drawRing(ctx, x, y, r, kit.edge, 2.5);
}

// A small dark label centred on x.
function drawTag(ctx: CanvasRenderingContext2D, x: number, cy: number, text: string, color: string, size: number): void {
  ctx.font = `700 ${size}px ${FONT}`;
  const w = ctx.measureText(text).width + 10, h = size + 7, left = x - w / 2;
  ctx.fillStyle = COLORS.panel;
  ctx.globalAlpha = 0.92;
  ctx.beginPath();
  ctx.roundRect(left, cy - h / 2, w, h, 4);
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.fillStyle = color;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, left + w / 2, cy + 0.5);
}

// A small pill attached to the right of a dot, like an exponent (above) or a subscript (below). Used for the
// archetype, in an outlined pill of its colour, below the dot.
function drawScript(ctx: CanvasRenderingContext2D, L: Layout, d: Dot, r: number, above: boolean, text: string,
                    fill: string, stroke: string, ink: string): void {
  const size = Math.round(clamp((0.62 * r) / DOT_GROWTH, 8.5, 11)), h = size + 4;   // sized as before the dots grew
  ctx.font = `700 ${size}px ${FONT}`;
  const w = ctx.measureText(text).width + 8;
  const left = px(L, d.x) + 0.62 * r, cy = py(L, d.y) + (above ? -0.82 : 0.82) * r;
  ctx.beginPath();
  ctx.roundRect(left, cy - h / 2, w, h, h / 2);
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.lineWidth = 1.2;
  ctx.strokeStyle = stroke;
  ctx.stroke();
  ctx.fillStyle = ink;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, left + w / 2, cy + 0.5);
}

// Player trails: the path each player covered over the last TRAIL_FRAMES frames of play, so its length is his speed
// (a sprint at about 20 ft/s leaves 12 ft, a walk a foot or two, standing still nothing). Positions are averaged
// over a few neighbouring frames to iron out tracking jitter; a trail never crosses a cut in the footage or a
// missing position, and one whose ends are less than TRAIL_MIN ft apart fades out.
const TRAIL_FRAMES = 15;   // 0.6 s at 25 fps
const TRAIL_SMOOTH = 2;    // frames averaged on each side (never later than the current frame)
const TRAIL_MIN = 1.5;     // ft: below this the trail is not drawn; it reaches full strength TRAIL_FADE ft later
const TRAIL_FADE = 2;

// A player's smoothed position at frame index i, using only frames joined to it, no later than `last`.
function smoothAt(play: Play, p: PlayerTrack, i: number, last: number): Point | null {
  let sx = 0, sy = 0, n = 0;
  for (let j = i; j >= Math.max(0, i - TRAIL_SMOOTH) && !Number.isNaN(p.x[j]); j--) {
    sx += p.x[j]; sy += p.y[j]; n++;
    if (j > 0 && play.frames[j] - play.frames[j - 1] !== 1) break;
  }
  for (let j = i + 1; j <= Math.min(last, i + TRAIL_SMOOTH) && play.frames[j] - play.frames[j - 1] === 1 && !Number.isNaN(p.x[j]); j++) {
    sx += p.x[j]; sy += p.y[j]; n++;
  }
  return n ? [sx / n, sy / n] : null;
}

// The trail's points in feet, from the dot back in time: the dot itself, then one point per earlier frame, the
// last one cut to end exactly TRAIL_FRAMES frames back.
function trailPoints(play: Play, d: Dot, c: Cursor): Point[] {
  const pts: Point[] = [[d.x, d.y]];
  let prev: Point | null = null;
  for (let i = c.i0; i >= 0; i--) {
    if (i < c.i0 && play.frames[i + 1] - play.frames[i] !== 1) break;
    const q = smoothAt(play, d.p, i, c.i0);
    if (!q) break;
    const age = c.i0 - i + c.t;
    if (age > TRAIL_FRAMES) {
      if (prev) {
        const k = TRAIL_FRAMES - (age - 1);   // share of the step from the previous point to this one
        pts.push([prev[0] + (q[0] - prev[0]) * k, prev[1] + (q[1] - prev[1]) * k]);
      }
      break;
    }
    pts.push(q);
    prev = q;
  }
  return pts;
}

// A tapering ribbon in the team's floor colour, widest and strongest at the dot and fading to nothing at its tail.
function drawTrail(ctx: CanvasRenderingContext2D, L: Layout, play: Play, d: Dot, c: Cursor, r: number, kit: TeamColors): void {
  const feet = trailPoints(play, d, c);
  if (feet.length < 3) return;
  const head = feet[0], tail = feet[feet.length - 1];
  const strength = clamp((Math.hypot(head[0] - tail[0], head[1] - tail[1]) - TRAIL_MIN) / TRAIL_FADE, 0, 1);
  if (strength <= 0) return;
  const pts = feet.map((q): Point => [px(L, q[0]), py(L, q[1])]);
  const n = pts.length, half = 0.6 * r, left: Point[] = [], right: Point[] = [];
  let nx = 0, ny = 0;
  for (let k = 0; k < n; k++) {
    const a = pts[Math.max(0, k - 1)], b = pts[Math.min(n - 1, k + 1)];
    const dx = b[0] - a[0], dy = b[1] - a[1], len = Math.hypot(dx, dy);
    if (len > 1e-6) { nx = -dy / len; ny = dx / len; }
    const w = half * (1 - k / (n - 1));
    left.push([pts[k][0] + nx * w, pts[k][1] + ny * w]);
    right.push([pts[k][0] - nx * w, pts[k][1] - ny * w]);
  }
  ctx.beginPath();
  left.forEach((q, k) => (k ? ctx.lineTo(q[0], q[1]) : ctx.moveTo(q[0], q[1])));
  for (let k = n - 1; k >= 0; k--) ctx.lineTo(right[k][0], right[k][1]);
  ctx.closePath();
  const fade = ctx.createLinearGradient(pts[0][0], pts[0][1], pts[n - 1][0], pts[n - 1][1]);
  fade.addColorStop(0, withAlpha(kit.mark, 0.6 * strength));
  fade.addColorStop(1, withAlpha(kit.mark, 0));
  ctx.fillStyle = fade;
  ctx.fill();
}

// The trace panel's pair: a dark line from the followed player to his nearest opponent, drawn under the dots.
function drawPairLine(ctx: CanvasRenderingContext2D, L: Layout, a: Dot, b: Dot): void {
  ctx.beginPath();
  ctx.moveTo(px(L, a.x), py(L, a.y));
  ctx.lineTo(px(L, b.x), py(L, b.y));
  ctx.lineWidth = 2.5;
  ctx.lineCap = "round";
  ctx.strokeStyle = "rgba(11, 14, 20, .75)";
  ctx.stroke();
}

// The header of a recorded video, on one line above the court: quarter, shot clock, game clock and the score at
// the start of the possession. On the page these live outside the canvas, so a saved video would otherwise not
// say what it shows.
function drawHeader(ctx: CanvasRenderingContext2D, L: Layout, play: Play, c: Cursor): void {
  const homeIsOff = play.off === play.home, gap = "   ·   ";
  const home = homeIsOff ? play.colors.off : play.colors.def, away = homeIsOff ? play.colors.def : play.colors.off;
  const parts: [string, string, number][] = [
    [`${quarter(play.period)}  `, COLORS.ink, 700], [shotClockText(play.sc[c.i0]), COLORS.risk, 700],
    [`  ${clock(play.gc[c.i0])}`, COLORS.ink, 700], [gap, COLORS.muted, 400], [play.home, home.text, 700],
    [`  ${play.homeScore} – ${play.awayScore}  `, COLORS.ink, 700], [play.away, away.text, 700]];
  const span = (size: number) => parts.reduce((sum, [text, , weight]) => {
    ctx.font = `${weight} ${size}px ${FONT}`;
    return sum + ctx.measureText(text).width;
  }, 0);
  const size = Math.max(9, Math.min(15, Math.floor((15 * (L.W - 24)) / span(15))));
  let x = L.W / 2 - span(size) / 2;
  ctx.textAlign = "left";
  ctx.textBaseline = "middle";
  for (const [text, color, weight] of parts) {
    ctx.font = `${weight} ${size}px ${FONT}`;
    ctx.fillStyle = color;
    ctx.fillText(text, x, L.top - HEADER_TOP / 2);
    x += ctx.measureText(text).width;
  }
}

export const DATA_CREDIT = "Data: Liga Endesa ACB 2025/2026 via SkillCorner";

// Under the court, centred and bold: both recent event labels if they fit, otherwise the latest one. On the page the
// data credit is in the tab bar; a recorded video carries it here, at the right, since it leaves the page behind.
function drawCaption(ctx: CanvasRenderingContext2D, L: Layout, labels: string[], credit: boolean): void {
  const y = L.top + L.ch + 14;
  ctx.textBaseline = "middle";
  if (credit && L.cw >= 420) {
    ctx.textAlign = "right";
    ctx.font = `400 11px ${FONT}`;
    ctx.fillStyle = COLORS.muted;
    ctx.fillText(DATA_CREDIT, L.left + L.cw, y);
  }
  ctx.font = `700 13px ${FONT}`;
  ctx.fillStyle = COLORS.ink;
  ctx.textAlign = "center";
  const both = labels.join("   ·   ");
  ctx.fillText(ctx.measureText(both).width <= L.cw - 16 ? both : labels[labels.length - 1] ?? "", L.left + L.cw / 2, y, L.cw);
}

/**
 * Draw the scene at playback position `pos` (an index into `seq`, fractional between frames).
 * @param header Draw the clock and score on the canvas too (while a video is recorded).
 * @returns what is on court at that moment, or null when there is no play to draw.
 */
export function drawScene(ctx: CanvasRenderingContext2D, W: number, H: number, dpr: number, play: Play | null, seq: number[],
                          pos: number, o: DrawOptions, header = false): FrameInfo | null {
  const L = courtLayout(W, H, o.view, header ? HEADER_TOP : PAD.top, play?.leftHoop ? -1 : 1);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = COLORS.paper;
  ctx.fillRect(0, 0, W, H);
  drawCourt(ctx, L, dpr, play ? logoImage(play.homeTeam) : null);
  if (!play || !seq.length) return null;

  const c = cursorAt(play, seq, pos), frame = play.frames[c.i0];
  const dots: Record<"off" | "def", Dot[]> = { off: [], def: [] };
  for (const p of play.players) {
    const x = blend(p.x, c), y = blend(p.y, c);
    if (x != null && y != null) dots[p.role].push({ p, x, y });
  }
  const r = clamp(1.2 * DOT_GROWTH * L.s, 9 * DOT_GROWTH, 22 * DOT_GROWTH), handler = ballHandler(play, frame);

  ctx.save();
  ctx.beginPath();
  const reach = (REACH - MARGIN) * L.s;   // someone inbounding stands outside the layout's narrow margin
  ctx.rect(L.left - reach, L.top - reach, L.cw + 2 * reach, L.ch + 2 * reach);
  ctx.clip();
  const areaDef = drawHull(ctx, L, dots.def, play.colors.def, o.showDef);
  const areaOff = drawHull(ctx, L, dots.off, play.colors.off, o.showOff);
  // Court control goes over the hulls (their fill would hide it) and under everything else, at the tracking frame.
  const cc = o.showControl ? controlAt(play, c.i0, motionLimits(play, o.sample ?? null)) : null;
  if (cc) drawControl(ctx, L, cc, { off: play.colors.off.fill, def: play.colors.def.fill });
  const all = dots.def.concat(dots.off);
  if (o.showTrails) for (const d of all) drawTrail(ctx, L, play, d, c, r, play.colors[d.p.role]);
  const k = annContext(ctx, L, play, c, r, all);
  drawAnnotationsUnder(k, o.ann);
  // The followed player and his nearest opponent: joined by a line under the dots, each ringed in his team's
  // secondary colour over the dots (the followed player's ring thicker), the distance on top of everything.
  let pair: { a: Dot; b: Dot; dist: number } | null = null;
  if (o.focusPid != null) {
    const near = nearestAt(play, o.focusPid, c);
    const a = all.find((d) => d.p.id === o.focusPid), b = near && all.find((d) => d.p.id === near.pid);
    if (a && b && near) {
      drawPairLine(ctx, L, a, b);
      pair = { a, b, dist: near.dist };
    }
  }
  for (const d of all) drawPlayer(ctx, L, d, r, play.colors[d.p.role], d.p.id === handler, o, o.ann.quality && d.p.d[c.i0] === 0);
  if (o.attention) drawAttention(ctx, L, all, r, o.attention);
  if (pair) {
    for (const [d, width] of [[pair.a, 3], [pair.b, 2]] as const) drawRing(ctx, px(L, d.x), py(L, d.y), r, play.colors[d.p.role].edge, width);
  }
  if (o.showArch) {
    for (const d of dots.def.concat(dots.off)) {
      if (!d.p.arch) continue;
      const tag = tint(archColor(d.p.arch.slot));
      drawScript(ctx, L, d, r, false, ARCH_ABBR[d.p.arch.name] ?? d.p.arch.short, COLORS.panel, tag, tag);
    }
  }
  const bx = blend(play.ball.x, c), by = blend(play.ball.y, c), bz = blend(play.ball.z, c) ?? 0;
  if (bx != null && by != null) {
    // The ball grows linearly with its height: floor size at z = 0, twice that at BALL_Z_DOUBLE feet.
    const height = clamp(bz, 0, BALL_Z_MAX);
    ctx.beginPath();
    ctx.arc(px(L, bx), py(L, by), clamp(0.55 * L.s, 4.5, 10) * (1 + height / BALL_Z_DOUBLE), 0, 2 * Math.PI);
    ctx.fillStyle = COLORS.ball;
    ctx.fill();
    ctx.lineWidth = 1.2;
    ctx.strokeStyle = COLORS.ballEdge;
    ctx.stroke();
  }
  drawAnnotationsOver(k, o.ann, handler, o.focusPid ?? o.hoverPid);
  if (pair) {
    const mx = (px(L, pair.a.x) + px(L, pair.b.x)) / 2, my = (py(L, pair.a.y) + py(L, pair.b.y)) / 2;
    drawTag(ctx, mx, my, `${pair.dist.toFixed(1)} ft`, COLORS.ink, 11);
  }
  ctx.restore();

  const labels = play.events.filter((e) => frame >= e.f && frame - e.f <= CAPTION_FRAMES).slice(-2).map((e) => e.label);
  if (header) drawHeader(ctx, L, play, c);
  drawCaption(ctx, L, labels, header);
  return { onCourt: dots.off.concat(dots.def).map((d) => d.p.id), handler, areaOff, areaDef,
           gameClock: clock(play.gc[c.i0]), shotClock: shotClockText(play.sc[c.i0]),
           hits: all.map((d) => ({ id: d.p.id, x: px(L, d.x), y: py(L, d.y), r })),
           box: { left: L.left, top: L.top, w: L.cw, h: L.ch, backLeft: L.f === 1 }, i0: c.i0,
           control: cc ? { court: cc.offShare, half: cc.offHalf } : null };
}
