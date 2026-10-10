// Draws one moment of a possession on the canvas: court, hulls, players, ball, EPV labels and the header.
// Ported from draw(), drawPlayer(), drawTag(), drawOptions() and drawHud() in the Shiny app's www/player.js.

import { COLORS, courtLayout, drawCourt, type CourtView, type Layout } from "./court";
import { epvAt, type EpvReading } from "./epv";
import { clamp, clock, convexHull, pct, polygonArea, quarter, type Point } from "./geometry";
import { ballHandler, blend, cursorAt, type Cursor } from "./sequence";
import type { Play, PlayerTrack } from "./types";

const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
const CAPTION_FRAMES = 62;   // how long an event label stays up
const VALUE_SPAN = 0.35;     // points above/below current EPV at which pass-value colours saturate
const TEXT_ENDS = [[255, 138, 128], [241, 243, 248], [125, 240, 180]];

export interface DrawOptions {
  view: CourtView;
  showDef: boolean;
  showOff: boolean;
  markExtrap: boolean;
  showEpv: boolean;
  showReadout: boolean;
  showPassValues: boolean;
  showPassTov: boolean;
  showBallTov: boolean;
  showShotPass: boolean;
  showBestPass: boolean;
  hoverPid: number | null;
}

/** What the rosters need to know about the frame just drawn. */
export interface FrameInfo {
  onCourt: number[];
  handler: number | null;
  areaOff: number | null;
  areaDef: number | null;
}

interface Dot {
  p: PlayerTrack;
  x: number;
  y: number;
  det: number;
}

// Red below the current EPV, neutral at it, green above it.
function valueColor(delta: number): string {
  const t = clamp(delta / VALUE_SPAN, -1, 1), end = t < 0 ? TEXT_ENDS[0] : TEXT_ENDS[2];
  return `rgb(${TEXT_ENDS[1].map((m, i) => Math.round(m + (end[i] - m) * Math.abs(t))).join(",")})`;
}

function drawHull(ctx: CanvasRenderingContext2D, L: Layout, dots: Dot[], color: string): number {
  const poly = convexHull(dots.map((d): Point => [d.x, d.y]));
  if (poly.length < 3) return 0;
  ctx.beginPath();
  poly.forEach((q, i) => (i ? ctx.lineTo(L.ox + q[0] * L.s, L.oy - q[1] * L.s) : ctx.moveTo(L.ox + q[0] * L.s, L.oy - q[1] * L.s)));
  ctx.closePath();
  ctx.globalAlpha = 0.5;
  ctx.fillStyle = color;
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  ctx.strokeStyle = color;
  ctx.stroke();
  return polygonArea(poly);
}

function drawPlayer(ctx: CanvasRenderingContext2D, L: Layout, d: Dot, r: number, hasBall: boolean, o: DrawOptions): void {
  const x = L.ox + d.x * L.s, y = L.oy - d.y * L.s, color = COLORS[d.p.role];
  const faded = o.markExtrap && !d.det, hovered = o.hoverPid === d.p.id;
  if (hovered || hasBall) {
    ctx.beginPath();
    ctx.arc(x, y, r + 5.5, 0, 2 * Math.PI);
    ctx.lineWidth = 2.5;
    ctx.strokeStyle = hovered ? COLORS.dark : color;
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  ctx.fillStyle = COLORS.white;
  ctx.fill();
  ctx.globalAlpha = faded ? 0.45 : 1;
  ctx.beginPath();
  ctx.arc(x, y, r - 2.2, 0, 2 * Math.PI);
  ctx.fillStyle = color;
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.fillStyle = faded ? color : COLORS.white;
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

// EPV labels around the offense. Player dots themselves are never restyled by the overlay.
function drawOptions(ctx: CanvasRenderingContext2D, L: Layout, dots: Dot[], r: number, ep: EpvReading, o: DrawOptions): void {
  const at = (d: Dot): Point => [L.ox + d.x * L.s, L.oy - d.y * L.s];
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

// Header, centred over the court and stacked: teams, then quarter / shot clock / game clock, then the EPV
// readout when prices are showing. The event caption and data credit sit under the court.
function drawHud(ctx: CanvasRenderingContext2D, L: Layout, play: Play, c: Cursor, labels: string[], ep: EpvReading | null, o: DrawOptions): void {
  const cx = L.left + L.cw / 2, shotClock = play.sc[c.i0];
  const cells: [string, string][] = ep && o.showReadout
    ? [["EPV", ep.value == null ? "–" : ep.value.toFixed(2)], ["TOV% (ROP)", ep.rop == null ? "–" : pct(ep.rop, 1)],
       ["CUM. TOV", ep.cum == null ? "–" : pct(ep.cum, 1)]]
    : [];
  const teamsY = L.top - (cells.length ? 96 : 44), clockY = teamsY + 24;
  ctx.textBaseline = "middle";

  const teams: [string, string, number][] = [[play.off, COLORS.offText, 700], ["  vs  ", COLORS.muted, 400], [play.def, COLORS.defText, 700]];
  const span = (size: number) => teams.reduce((sum, [text, , weight]) => {
    ctx.font = `${weight} ${size}px ${FONT}`;
    return sum + ctx.measureText(text).width;
  }, 0);
  const size = Math.max(10, Math.min(15, Math.floor((15 * (L.W - 24)) / span(15))));
  let x = cx - span(size) / 2;
  ctx.textAlign = "left";
  for (const [text, color, weight] of teams) {
    ctx.font = `${weight} ${size}px ${FONT}`;
    ctx.fillStyle = color;
    ctx.fillText(text, x, teamsY);
    x += ctx.measureText(text).width;
  }

  const period = quarter(play.period), game = clock(play.gc[c.i0]), pill = 34, gap = 10;
  ctx.font = `700 15px ${FONT}`;
  const periodW = ctx.measureText(period).width, gameW = ctx.measureText(game).width;
  x = cx - (periodW + pill + gameW + 2 * gap) / 2;
  ctx.fillStyle = COLORS.ink;
  ctx.fillText(period, x, clockY);
  ctx.fillText(game, x + periodW + pill + 2 * gap, clockY);
  ctx.fillStyle = COLORS.panel;
  ctx.beginPath();
  ctx.roundRect(x + periodW + gap, clockY - 11, pill, 22, 6);
  ctx.fill();
  ctx.fillStyle = COLORS.risk;
  ctx.textAlign = "center";
  ctx.fillText(Number.isNaN(shotClock) ? "–" : String(Math.ceil(shotClock)), x + periodW + gap + pill / 2, clockY + 0.5);

  if (cells.length) {
    const cellW = clamp(L.cw * 0.16, 86, 112), panelW = cells.length * cellW, panelTop = L.top - 58;
    ctx.fillStyle = COLORS.panel;
    ctx.beginPath();
    ctx.roundRect(cx - panelW / 2, panelTop, panelW, 48, 8);
    ctx.fill();
    cells.forEach(([label, value], i) => {
      const cellX = cx - panelW / 2 + (i + 0.5) * cellW;
      ctx.font = `700 9.5px ${FONT}`;
      ctx.fillStyle = COLORS.muted;
      ctx.fillText(label, cellX, panelTop + 13);
      ctx.font = `700 19px ${FONT}`;
      ctx.fillStyle = COLORS.ink;
      ctx.fillText(value, cellX, panelTop + 32);
    });
  }

  // Both recent event labels if they fit beside the credit, otherwise the latest one.
  const credit = L.cw >= 420;
  const room = L.cw - (credit ? 200 : 0);
  ctx.font = `500 13px ${FONT}`;
  ctx.fillStyle = COLORS.ink;
  ctx.textAlign = "left";
  const both = labels.join("   ·   ");
  ctx.fillText(ctx.measureText(both).width <= room ? both : labels[labels.length - 1] ?? "", L.left, L.top + L.ch + 17, room);
  if (credit) {
    ctx.textAlign = "right";
    ctx.font = `400 11px ${FONT}`;
    ctx.fillStyle = COLORS.muted;
    ctx.fillText("Data: SkillCorner open data, Liga ACB", L.left + L.cw, L.top + L.ch + 17);
  }
}

/**
 * Draw the scene at playback position `pos` (an index into `seq`, fractional between frames).
 * @returns what is on court at that moment, or null when there is no play to draw.
 */
export function drawScene(ctx: CanvasRenderingContext2D, W: number, H: number, dpr: number, play: Play | null, seq: number[],
                          pos: number, o: DrawOptions): FrameInfo | null {
  const L = courtLayout(W, H, o.view);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = COLORS.paper;
  ctx.fillRect(0, 0, W, H);
  drawCourt(ctx, L, dpr);
  if (!play || !seq.length) return null;

  const c = cursorAt(play, seq, pos), frame = play.frames[c.i0];
  const dots: Record<"off" | "def", Dot[]> = { off: [], def: [] };
  for (const p of play.players) {
    const x = blend(p.x, c), y = blend(p.y, c);
    if (x != null && y != null) dots[p.role].push({ p, x, y, det: p.d[c.i0] });
  }
  const ep = o.showEpv ? epvAt(play.epv, frame + c.t) : null;
  const r = clamp(1.2 * L.s, 9, 22), handler = ballHandler(play, frame);

  ctx.save();
  ctx.beginPath();
  ctx.rect(L.left, L.top, L.cw, L.ch);
  ctx.clip();
  const areaDef = o.showDef ? drawHull(ctx, L, dots.def, COLORS.def) : null;
  const areaOff = o.showOff ? drawHull(ctx, L, dots.off, COLORS.off) : null;
  if (ep && o.showBestPass && ep.target != null) {
    const from = dots.off.find((d) => d.p.id === ep.holder), to = dots.off.find((d) => d.p.id === ep.target);
    if (from && to) {
      ctx.beginPath();
      ctx.moveTo(L.ox + from.x * L.s, L.oy - from.y * L.s);
      ctx.lineTo(L.ox + to.x * L.s, L.oy - to.y * L.s);
      ctx.lineWidth = 3;
      ctx.lineCap = "round";
      ctx.strokeStyle = COLORS.best;
      ctx.stroke();
    }
  }
  for (const d of dots.def.concat(dots.off)) drawPlayer(ctx, L, d, r, d.p.id === handler, o);
  if (ep) drawOptions(ctx, L, dots.off, r, ep, o);
  const bx = blend(play.ball.x, c), by = blend(play.ball.y, c), bz = blend(play.ball.z, c) ?? 0;
  if (bx != null && by != null) {
    ctx.beginPath();
    ctx.arc(L.ox + bx * L.s, L.oy - by * L.s, clamp(0.55 * L.s, 4.5, 10) * (1 + (0.5 * clamp(bz, 0, 14)) / 14), 0, 2 * Math.PI);
    ctx.fillStyle = COLORS.ball;
    ctx.fill();
    ctx.lineWidth = 1.2;
    ctx.strokeStyle = COLORS.ballEdge;
    ctx.stroke();
  }
  ctx.restore();

  const labels = play.events.filter((e) => frame >= e.f && frame - e.f <= CAPTION_FRAMES).slice(-2).map((e) => e.label);
  drawHud(ctx, L, play, c, labels, ep, o);
  return { onCourt: dots.off.concat(dots.def).map((d) => d.p.id), handler, areaOff, areaDef };
}
