// Draws one moment of a possession on the canvas: court, court control, hulls, players, ball, EPV labels and
// the caption. The clock, score and EPV readout are on the page, not the canvas, except in a recorded video
// (drawHeader). Ported from draw(), drawPlayer(), drawTag(), drawOptions(), drawHeader() and drawCaption() in
// the Shiny app's www/player.js; court control exists only on the site.

import type { ControlParams } from "./control";
import { controlAt, drawControl, type ControlMode } from "./controlLayer";
import { COLORS, HEADER_TOP, MARGIN, PAD, REACH, courtLayout, drawCourt, px, py, type CourtView, type Layout } from "./court";
import { epvAt, type EpvReading } from "./epv";
import { collectionLabels, drawReboundUnder, type HeatGrid, type LandingView, type ReboundReading } from "./rebounding";
import { floorColors } from "./teamColors";
import { clamp, clock, convexHull, pct, polygonArea, quarter, type Point } from "./geometry";
import { ballHandler, blend, cursorAt, type Cursor } from "./sequence";
import { shotIndexAt } from "./shots";
import type { Play, PlayerTrack, TeamColors } from "./types";

const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
const CAPTION_FRAMES = 62;   // how long an event label stays up
const VALUE_SPAN = 0.35;     // points above/below current EPV at which pass-value colours saturate
const TEXT_ENDS = [[255, 138, 128], [241, 243, 248], [125, 240, 180]];

export interface DrawOptions {
  view: CourtView;
  showDef: boolean;
  showOff: boolean;
  showArch: boolean;
  showEpv: boolean;
  showPassValues: boolean;
  showPassTov: boolean;
  showBallTov: boolean;
  showShotPass: boolean;
  showBestPass: boolean;
  showControl: boolean;
  controlMode: ControlMode;
  /** The rebounding forecast on the court (landing sample, box-out links, collection chances). */
  showRebound: boolean;
  hoverPid: number | null;
}

/** A rebound forecast to draw, whether its talent-aware chances are the ones labelled, the game's landing grid
 * and how landings are shown. */
export interface ReboundDraw {
  reading: ReboundReading;
  talent: boolean;
  grid: HeatGrid | null;
  landing: LandingView;
}

/** What the page shows beside the canvas about the frame just drawn: rosters, clocks and the EPV readout. */
export interface FrameInfo {
  onCourt: number[];
  handler: number | null;
  areaOff: number | null;
  areaDef: number | null;
  gameClock: string;
  shotClock: string;
  /** Readout cells in display order, or null when nothing is priced at this frame. */
  readout: [string, string][] | null;
  /** Index in play.shots of the shot the panel beside the half court shows, or -1. */
  shot: number;
  /** Court control readout, or null when the overlay is off or has nothing to show. */
  control: { kind: string; cells: [string, string][] } | null;
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

// Red below the current EPV, neutral at it, green above it.
function valueColor(delta: number): string {
  const t = clamp(delta / VALUE_SPAN, -1, 1), end = t < 0 ? TEXT_ENDS[0] : TEXT_ENDS[2];
  return `rgb(${TEXT_ENDS[1].map((m, i) => Math.round(m + (end[i] - m) * Math.abs(t))).join(",")})`;
}

const shotClockText = (seconds: number): string => (Number.isNaN(seconds) ? "–" : String(Math.ceil(seconds)));

/** EPV, turnover odds for the rest of the possession, and cumulative turnover risk so far. */
function readoutCells(ep: EpvReading): [string, string][] {
  return [["EPV", ep.value == null ? "–" : ep.value.toFixed(2)], ["TOV% (ROP)", ep.rop == null ? "–" : pct(ep.rop, 1)],
          ["Cum. TOV", ep.cum == null ? "–" : pct(ep.cum, 1)]];
}

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

// A small dark label. `anchor` is "center" (x is its middle) or "left" (x is its left edge).
function drawTag(ctx: CanvasRenderingContext2D, x: number, cy: number, text: string, color: string, size: number, anchor: "center" | "left"): void {
  ctx.font = `700 ${size}px ${FONT}`;
  const w = ctx.measureText(text).width + 10, h = size + 7, left = anchor === "left" ? x : x - w / 2;
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

// A small pill attached to the right of a dot, like an exponent (above) or a subscript (below): the rebound
// chance in the team's kit above, the archetype in an outlined pill of its colour below.
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

// EPV labels around the offense. Player dots themselves are never restyled by the overlay.
function drawOptions(ctx: CanvasRenderingContext2D, L: Layout, dots: Dot[], r: number, ep: EpvReading, o: DrawOptions): void {
  const at = (d: Dot): Point => [px(L, d.x), py(L, d.y)];
  const holder = dots.find((d) => d.p.id === ep.holder);
  for (const d of dots) {
    if (d === holder) continue;
    const [x, y] = at(d), pv = ep.option(d.p.id, "pv"), tov = ep.option(d.p.id, "tov");
    if (o.showPassValues && pv != null) drawTag(ctx, x, y - r - 12, pv.toFixed(2), valueColor(pv - (ep.value ?? pv)), 12, "center");
    if (o.showPassTov && tov != null) drawTag(ctx, x + r + 5, y, `${pct(tov, 1)} TOV`, COLORS.ink, 10.5, "left");
  }
  if (!holder) return;
  const [x, y] = at(holder);
  if (o.showShotPass && ep.shot != null) {
    const w = 96, h = 34, top = y - r - 9 - h;
    ctx.fillStyle = COLORS.panel;
    ctx.globalAlpha = 0.92;
    ctx.beginPath();
    ctx.roundRect(x - w / 2, top, w, h, 5);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const cells: [string, number | null, number][] = [["SHOT", ep.shot, x - w / 4], ["PASS", ep.pass, x + w / 4]];
    for (const [label, value, cx] of cells) {
      ctx.font = `700 8.5px ${FONT}`;
      ctx.fillStyle = COLORS.muted;
      ctx.fillText(label, cx, top + 10);
      ctx.font = `700 12.5px ${FONT}`;
      ctx.fillStyle = COLORS.ink;
      ctx.fillText(value == null ? "–" : value.toFixed(2), cx, top + 23);
    }
  }
  if (o.showPassValues && ep.value != null) drawTag(ctx, x, y + r + 12, ep.value.toFixed(2), COLORS.ink, 12, "center");
  if (o.showBallTov && ep.haz != null) {
    const bx = x + r * 0.95, by = y - r * 0.95;
    ctx.beginPath();
    ctx.arc(bx, by, 13.5, 0, 2 * Math.PI);
    ctx.fillStyle = COLORS.risk;
    ctx.fill();
    ctx.fillStyle = COLORS.dark;
    ctx.font = `700 10px ${FONT}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(pct(ep.haz, ep.haz < 0.0995 ? 1 : 0), bx, by + 0.5);
  }
}

// The header of a recorded video, on one line above the court: quarter, shot clock, game clock, the score at
// the start of the possession, and the EPV readout where the frame is priced. On the page these live outside
// the canvas, so a saved video would otherwise not say what it shows.
function drawHeader(ctx: CanvasRenderingContext2D, L: Layout, play: Play, c: Cursor, ep: EpvReading | null, o: DrawOptions): void {
  const homeIsOff = play.off === play.home, gap = "   ·   ";
  const home = homeIsOff ? play.colors.off : play.colors.def, away = homeIsOff ? play.colors.def : play.colors.off;
  const parts: [string, string, number][] = [
    [`${quarter(play.period)}  `, COLORS.ink, 700], [shotClockText(play.sc[c.i0]), COLORS.risk, 700],
    [`  ${clock(play.gc[c.i0])}`, COLORS.ink, 700], [gap, COLORS.muted, 400], [play.home, home.text, 700],
    [`  ${play.homeScore} – ${play.awayScore}  `, COLORS.ink, 700], [play.away, away.text, 700]];
  if (ep) {
    for (const [label, value] of readoutCells(ep)) parts.push([`${label === "EPV" ? gap : "   "}${label} `, COLORS.muted, 400], [value, COLORS.ink, 700]);
  }
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
 * @param header Draw the clock, score and EPV readout on the canvas too (while a video is recorded).
 * @param control Court control parameters; null draws no court control.
 * @param rebound The rebound forecast live at this moment, or null.
 * @returns what is on court at that moment, or null when there is no play to draw.
 */
export function drawScene(ctx: CanvasRenderingContext2D, W: number, H: number, dpr: number, play: Play | null, seq: number[],
                          pos: number, o: DrawOptions, header = false, control: ControlParams | null = null,
                          rebound: ReboundDraw | null = null): FrameInfo | null {
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
  // Prices are read whether or not the court overlay is on: the readout beside the court always shows them.
  const ep = epvAt(play.epv, frame + c.t);
  const r = clamp(1.2 * L.s, 9, 22), handler = ballHandler(play, frame);

  ctx.save();
  ctx.beginPath();
  const reach = (REACH - MARGIN) * L.s;   // someone inbounding stands outside the layout's narrow margin
  ctx.rect(L.left - reach, L.top - reach, L.cw + 2 * reach, L.ch + 2 * reach);
  ctx.clip();
  const areaDef = drawHull(ctx, L, dots.def, play.colors.def, o.showDef);
  const areaOff = drawHull(ctx, L, dots.off, play.colors.off, o.showOff);
  // Court control goes over the hulls (their fill would hide it) and under the players. It is computed at the
  // tracking frame, not blended between frames.
  const cc = control && o.showControl ? controlAt(play, c.i0, o.controlMode, control) : null;
  if (cc) drawControl(ctx, L, cc, floorColors(play));
  if (ep && o.showEpv && o.showBestPass && ep.target != null) {
    const from = dots.off.find((d) => d.p.id === ep.holder), to = dots.off.find((d) => d.p.id === ep.target);
    if (from && to) {
      ctx.beginPath();
      ctx.moveTo(px(L, from.x), py(L, from.y));
      ctx.lineTo(px(L, to.x), py(L, to.y));
      ctx.lineWidth = 3;
      ctx.lineCap = "round";
      ctx.strokeStyle = COLORS.best;
      ctx.stroke();
    }
  }
  // The rebound forecast sits over court control and under the players; its chances are labelled after them.
  const rb = rebound && o.showRebound ? rebound : null;
  if (rb) {
    const at = new Map<number, [number, number]>(), mark = new Map<number, string>();
    for (const d of dots.def.concat(dots.off)) { at.set(d.p.id, [d.x, d.y]); mark.set(d.p.id, play.colors[d.p.role].mark); }
    drawReboundUnder(ctx, L, rb.reading, rb.grid, rb.landing, at, mark);
  }
  for (const d of dots.def.concat(dots.off)) drawPlayer(ctx, L, d, r, play.colors[d.p.role], d.p.id === handler, o);
  if (o.showArch) {
    for (const d of dots.def.concat(dots.off)) {
      if (!d.p.arch) continue;
      const tag = tint(archColor(d.p.arch.slot));
      drawScript(ctx, L, d, r, false, ARCH_ABBR[d.p.arch.name] ?? d.p.arch.short, COLORS.panel, tag, tag);
    }
  }
  if (ep && o.showEpv) drawOptions(ctx, L, dots.off, r, ep, o);
  if (rb) {
    const chance = collectionLabels(rb.reading, rb.talent);
    for (const d of dots.def.concat(dots.off)) {
      const p = chance.get(d.p.id), kit = play.colors[d.p.role];
      if (p != null) drawScript(ctx, L, d, r, true, `${Math.round(p * 100)}%`, kit.fill, kit.edge, kit.ink);
    }
  }
  const bx = blend(play.ball.x, c), by = blend(play.ball.y, c), bz = blend(play.ball.z, c) ?? 0;
  if (bx != null && by != null) {
    ctx.beginPath();
    ctx.arc(px(L, bx), py(L, by), clamp(0.55 * L.s, 4.5, 10) * (1 + (0.5 * clamp(bz, 0, 14)) / 14), 0, 2 * Math.PI);
    ctx.fillStyle = COLORS.ball;
    ctx.fill();
    ctx.lineWidth = 1.2;
    ctx.strokeStyle = COLORS.ballEdge;
    ctx.stroke();
  }
  ctx.restore();

  const labels = play.events.filter((e) => frame >= e.f && frame - e.f <= CAPTION_FRAMES).slice(-2).map((e) => e.label);
  if (header) drawHeader(ctx, L, play, c, ep, o);
  drawCaption(ctx, L, labels);
  return { onCourt: dots.off.concat(dots.def).map((d) => d.p.id), handler, areaOff, areaDef,
           gameClock: clock(play.gc[c.i0]), shotClock: shotClockText(play.sc[c.i0]), readout: ep ? readoutCells(ep) : null,
           shot: shotIndexAt(play.shots, frame), control: cc ? { kind: cc.kind, cells: cc.readout } : null };
}
