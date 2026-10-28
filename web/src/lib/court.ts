// Court geometry and drawing. FIBA markings are specified in metres; tracking is in feet with the origin at
// centre court and the offense attacking +x. Ported from www/player.js in the Shiny app.

const M = 3.28084;
export const HALF_L = 14 * M;
export const HALF_W = 7.5 * M;
const HOOP_X = HALF_L - 1.575 * M;
const KEY_X = HALF_L - 5.8 * M, KEY_HALF_W = 2.45 * M;
const THREE_R = 6.75 * M, THREE_Y = 6.6 * M;
const CIRCLE_R = 1.8 * M, NO_CHARGE_R = 1.25 * M;
const BOARD_X = HALF_L - 1.2 * M, BOARD_HALF_W = 0.9 * M, RIM_R = 0.225 * M;
const LANE_MARKS = [1.75 * M, 3.85 * M, 4.7 * M], LANE_BLOCK = [2.6 * M, 3.0 * M];

export const MARGIN = 1.5;   // feet between the court's lines and the edge of the layout
export const REACH = 4;      // feet outside the lines in which players and the ball are still drawn
export const PAD = { top: 6, bottom: 26, side: 6 };
export const HEADER_TOP = 40;   // top padding while a video is recorded: room for the header drawn on the canvas

// The court keeps its light hardwood look; everything around it follows the dark dashboard theme.
// Team colours come with each play (Play.colors).
export const COLORS = {
  paper: "#1B2334", floor: "#F6CFA3", line: "#2B2622", ink: "#E8EDF6", muted: "#93A0B8", ball: "#F59A23",
  ballEdge: "#7A3E00", panel: "#0F1522", dark: "#0B0E14", best: "#18A56B", risk: "#F5B02E",
};

export type CourtView = "full" | "half";

/**
 * Where the court sits on the canvas: scale in pixels per foot and the pixel origin of (0, 0) feet. Plays are
 * stored with the offense attacking +x; `f` is -1 when the play is drawn rotated 180° back to the camera's view
 * (the offense attacking the left hoop), so consecutive plays line up. Map feet to pixels with px() and py().
 */
export interface Layout {
  W: number;
  H: number;
  s: number;
  f: 1 | -1;
  left: number;
  top: number;
  cw: number;
  ch: number;
  ox: number;
  oy: number;
}

/** Pixel position of a point given in the play's stored feet (offense attacking +x). */
export const px = (L: Layout, x: number): number => L.ox + L.f * x * L.s;
export const py = (L: Layout, y: number): number => L.oy - L.f * y * L.s;

/** @param f 1 to draw the play as stored (offense attacking right), -1 to rotate it to the camera's view. */
export function courtLayout(W: number, H: number, view: CourtView, padTop = PAD.top, f: 1 | -1 = 1): Layout {
  // the half court is the half the offense attacks: on the left when the play is rotated
  const x0 = view === "half" ? (f > 0 ? -MARGIN : -(HALF_L + MARGIN)) : -(HALF_L + MARGIN);
  const x1 = view === "half" && f < 0 ? MARGIN : HALF_L + MARGIN;
  const y0 = -(HALF_W + MARGIN), y1 = HALF_W + MARGIN;
  const s = Math.max(1, Math.min((W - 2 * PAD.side) / (x1 - x0), (H - padTop - PAD.bottom) / (y1 - y0)));
  const cw = (x1 - x0) * s, ch = (y1 - y0) * s;
  const left = (W - cw) / 2, top = padTop + (H - padTop - PAD.bottom - ch) / 2;
  return { W, H, s, f, left, top, cw, ch, ox: left - x0 * s, oy: top + y1 * s };
}

function halfCourtLines(ctx: CanvasRenderingContext2D): void {
  const a = Math.atan2(THREE_Y, -Math.sqrt(THREE_R * THREE_R - THREE_Y * THREE_Y));
  ctx.beginPath();
  ctx.rect(KEY_X, -KEY_HALF_W, HALF_L - KEY_X, 2 * KEY_HALF_W);
  ctx.moveTo(HALF_L, THREE_Y);
  ctx.lineTo(HOOP_X + THREE_R * Math.cos(a), THREE_Y);
  ctx.arc(HOOP_X, 0, THREE_R, a, 2 * Math.PI - a);
  ctx.lineTo(HALF_L, -THREE_Y);
  ctx.moveTo(KEY_X, CIRCLE_R);
  ctx.arc(KEY_X, 0, CIRCLE_R, Math.PI / 2, 1.5 * Math.PI);
  ctx.moveTo(BOARD_X, NO_CHARGE_R);
  ctx.lineTo(HOOP_X, NO_CHARGE_R);
  ctx.arc(HOOP_X, 0, NO_CHARGE_R, Math.PI / 2, 1.5 * Math.PI);
  ctx.lineTo(BOARD_X, -NO_CHARGE_R);
  ctx.moveTo(BOARD_X, -BOARD_HALF_W);
  ctx.lineTo(BOARD_X, BOARD_HALF_W);
  ctx.moveTo(HOOP_X + RIM_R, 0);
  ctx.arc(HOOP_X, 0, RIM_R, 0, 2 * Math.PI);
  for (const side of [1, -1]) {
    for (const d of LANE_MARKS) {
      ctx.moveTo(HALF_L - d, side * KEY_HALF_W);
      ctx.lineTo(HALF_L - d, side * (KEY_HALF_W + 0.5));
    }
  }
  ctx.stroke();
  for (const side of [1, -1]) {
    ctx.fillRect(HALF_L - LANE_BLOCK[1], side > 0 ? KEY_HALF_W : -KEY_HALF_W - 0.5, LANE_BLOCK[1] - LANE_BLOCK[0], 0.5);
  }
  ctx.save();
  ctx.setLineDash([1.1, 1.1]);
  ctx.beginPath();
  ctx.arc(KEY_X, 0, CIRCLE_R, -Math.PI / 2, Math.PI / 2);
  ctx.stroke();
  ctx.restore();
}

/** Floor and lines, drawn in feet with +y up. Leaves the context's transform as it found it. */
export function drawCourt(ctx: CanvasRenderingContext2D, L: Layout, dpr: number): void {
  ctx.save();
  ctx.beginPath();
  ctx.rect(L.left, L.top, L.cw, L.ch);
  ctx.clip();
  ctx.setTransform(dpr * L.s, 0, 0, -dpr * L.s, dpr * L.ox, dpr * L.oy);
  ctx.fillStyle = COLORS.floor;
  ctx.fillRect(-HALF_L, -HALF_W, 2 * HALF_L, 2 * HALF_W);
  ctx.strokeStyle = COLORS.line;
  ctx.fillStyle = COLORS.line;
  ctx.lineWidth = Math.max(1.25, 0.14 * L.s) / L.s;
  ctx.lineJoin = "round";
  ctx.beginPath();
  ctx.rect(-HALF_L, -HALF_W, 2 * HALF_L, 2 * HALF_W);
  ctx.moveTo(0, -HALF_W);
  ctx.lineTo(0, HALF_W);
  ctx.moveTo(CIRCLE_R, 0);
  ctx.arc(0, 0, CIRCLE_R, 0, 2 * Math.PI);
  ctx.stroke();
  halfCourtLines(ctx);
  ctx.scale(-1, 1);
  halfCourtLines(ctx);
  ctx.restore();
}
