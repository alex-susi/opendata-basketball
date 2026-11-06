// Draws one moment of a possession on the canvas: court, hulls, players, ball, the trace panel's pair and the
// caption. The clock and score are on the page, not the canvas, except in a recorded video (drawHeader). Ported
// from draw(), drawPlayer(), drawHeader() and drawCaption() in the Shiny app's www/player.js.

import { COLORS, HEADER_TOP, MARGIN, PAD, REACH, courtLayout, drawCourt, px, py, type CourtView, type Layout } from "./court";
import { clamp, clock, convexHull, polygonArea, quarter, type Point } from "./geometry";
import { ballHandler, blend, cursorAt, type Cursor } from "./sequence";
import { nearestAt } from "./trace";
import type { Play, PlayerTrack, TeamColors } from "./types";

const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
const CAPTION_FRAMES = 62;   // how long an event label stays up

export interface DrawOptions {
  view: CourtView;
  showDef: boolean;
  showOff: boolean;
  showArch: boolean;
  /** The player whose nearest opponent is shown: both ringed and joined by a line. Null shows no pair. */
  focusPid: number | null;
  hoverPid: number | null;
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

// A player dot in his team's colours: secondary ring, primary centre; around it, the ring that marks the ball
// handler (or the hovered player).
function drawPlayer(ctx: CanvasRenderingContext2D, L: Layout, d: Dot, r: number, kit: TeamColors, hasBall: boolean, o: DrawOptions): void {
  const x = px(L, d.x), y = py(L, d.y), hovered = o.hoverPid === d.p.id;
  if (hovered || hasBall) {
    ctx.beginPath();
    ctx.arc(x, y, r + 5.5, 0, 2 * Math.PI);
    ctx.lineWidth = 2.5;
    ctx.strokeStyle = hovered ? COLORS.dark : kit.mark;
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  ctx.fillStyle = kit.edge;
  ctx.fill();
  ctx.beginPath();
  ctx.arc(x, y, r - 2.2, 0, 2 * Math.PI);
  ctx.fillStyle = kit.fill;
  ctx.fill();
  ctx.fillStyle = kit.ink;
  ctx.font = `700 ${Math.round(r * (d.p.jersey.length > 1 ? 0.95 : 1.1))}px ${FONT}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(d.p.jersey, x, y + 0.5);
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
  const size = Math.round(clamp(0.62 * r, 8.5, 11)), h = size + 4;
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

// The trace panel's pair, under the players: a line from the followed player to his nearest opponent with the
// distance at its middle, and a ring around each (thicker around the followed player).
function drawPair(ctx: CanvasRenderingContext2D, L: Layout, a: Dot, b: Dot, r: number, dist: number): void {
  const ax = px(L, a.x), ay = py(L, a.y), bx = px(L, b.x), by = py(L, b.y);
  ctx.beginPath();
  ctx.moveTo(ax, ay);
  ctx.lineTo(bx, by);
  ctx.lineWidth = 3;
  ctx.lineCap = "round";
  ctx.strokeStyle = COLORS.pair;
  ctx.stroke();
  for (const [x, y, w] of [[ax, ay, 3.5], [bx, by, 2]]) {
    ctx.beginPath();
    ctx.arc(x, y, r + 5.5, 0, 2 * Math.PI);
    ctx.lineWidth = w;
    ctx.stroke();
  }
  drawTag(ctx, (ax + bx) / 2, (ay + by) / 2, `${dist.toFixed(1)} ft`, COLORS.pair, 11);
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

// Under the court: both recent event labels if they fit beside the credit, otherwise the latest one.
function drawCaption(ctx: CanvasRenderingContext2D, L: Layout, labels: string[]): void {
  const credit = L.cw >= 420;
  const room = L.cw - (credit ? 200 : 0);
  ctx.textBaseline = "middle";
  ctx.font = `500 13px ${FONT}`;
  ctx.fillStyle = COLORS.ink;
  ctx.textAlign = "left";
  const both = labels.join("   ·   ");
  ctx.fillText(ctx.measureText(both).width <= room ? both : labels[labels.length - 1] ?? "", L.left, L.top + L.ch + 14, room);
  if (credit) {
    ctx.textAlign = "right";
    ctx.font = `400 11px ${FONT}`;
    ctx.fillStyle = COLORS.muted;
    ctx.fillText("Data: SkillCorner open data, Liga ACB", L.left + L.cw, L.top + L.ch + 14);
  }
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
  drawCourt(ctx, L, dpr);
  if (!play || !seq.length) return null;

  const c = cursorAt(play, seq, pos), frame = play.frames[c.i0];
  const dots: Record<"off" | "def", Dot[]> = { off: [], def: [] };
  for (const p of play.players) {
    const x = blend(p.x, c), y = blend(p.y, c);
    if (x != null && y != null) dots[p.role].push({ p, x, y });
  }
  const r = clamp(1.2 * L.s, 9, 22), handler = ballHandler(play, frame);

  ctx.save();
  ctx.beginPath();
  const reach = (REACH - MARGIN) * L.s;   // someone inbounding stands outside the layout's narrow margin
  ctx.rect(L.left - reach, L.top - reach, L.cw + 2 * reach, L.ch + 2 * reach);
  ctx.clip();
  const areaDef = drawHull(ctx, L, dots.def, play.colors.def, o.showDef);
  const areaOff = drawHull(ctx, L, dots.off, play.colors.off, o.showOff);
  const all = dots.def.concat(dots.off);
  if (o.focusPid != null) {
    const near = nearestAt(play, o.focusPid, c);
    const a = all.find((d) => d.p.id === o.focusPid), b = near && all.find((d) => d.p.id === near.pid);
    if (a && b && near) drawPair(ctx, L, a, b, r, near.dist);
  }
  for (const d of all) drawPlayer(ctx, L, d, r, play.colors[d.p.role], d.p.id === handler, o);
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
  ctx.restore();

  const labels = play.events.filter((e) => frame >= e.f && frame - e.f <= CAPTION_FRAMES).slice(-2).map((e) => e.label);
  if (header) drawHeader(ctx, L, play, c);
  drawCaption(ctx, L, labels);
  return { onCourt: dots.off.concat(dots.def).map((d) => d.p.id), handler, areaOff, areaDef,
           gameClock: clock(play.gc[c.i0]), shotClock: shotClockText(play.sc[c.i0]),
           hits: all.map((d) => ({ id: d.p.id, x: px(L, d.x), y: py(L, d.y), r })) };
}
