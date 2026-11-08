// Text for the annotation cards beside the court and the trace panel's hover card: shot details, possession
// context, tracking quality and season figures. Pure, so the tests can run it in Node.

import { clock } from "./geometry";
import { gapAt, stretch } from "./motion";
import type { AnnChance, AnnCloseout, AnnDrive, AnnScreen, AnnShot, Play, PlayerTrack, SeasonFigures } from "./types";

export interface Line {
  k: string;
  v: string;
  /** Optional colour of the value. */
  tone?: string;
  /** The value may wrap onto more lines (the card keeps its other lines' width). */
  wrap?: boolean;
}

/** Contest levels from open to blocked, and the colour each is drawn in (markers and card). */
export const CONTEST_COLORS: Record<string, string> = {
  open: "#2FAE5A", light: "#9BC53D", average: "#EEC23A", plus: "#F07C2A", blocked: "#E04848",
};

const START_LABELS: Record<string, string> = {
  DEFOB: "Inbound after a defensive out of bounds", FGDRB: "Defensive rebound of a missed shot",
  FGORB: "Offensive rebound of a missed shot", FTDRB: "Defensive rebound of a missed free throw",
  FTORB: "Offensive rebound of a missed free throw", JMP: "Jump ball", TO: "Live-ball turnover (steal)",
  FTM: "Inbound after a made free throw", FGM: "Inbound after a made basket",
};

const COVERAGE: Record<string, string> = {
  ice: "ICE", switch: "switch", over: "over", under: "under", blitz: "blitz", soft: "soft", show: "show",
  trail: "trail", whip: "whip", ride: "ride", "top lock": "top lock", drop: "drop", jam: "jam",
};

/** camelCase as lower-case words: "dribblePullUp" → "dribble pull up". */
export const words = (s: string): string => s.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase();

const MINOR = new Set(["a", "and", "by", "for", "from", "in", "of", "on", "the", "to", "vs"]);
/** Title Case, leaving short joining words lower case after the first word: "catch and shoot" → "Catch and Shoot". */
export const titleCase = (s: string): string =>
  s.split(" ").map((w, i) => (i && MINOR.has(w.toLowerCase()) ? w.toLowerCase() : w.charAt(0).toUpperCase() + w.slice(1))).join(" ");

/** A court region in Title Case: "left wing three" → "Left Wing Three", "ra" → "Restricted Area", "middle three" →
 * "ATB Three" (above the break). */
export const regionName = (r: string): string =>
  r === "ra" ? "Restricted Area" : r === "middle three" ? "ATB Three" : titleCase(r);

export function playerOf(play: Play, pid: number | undefined): PlayerTrack | undefined {
  return pid == null ? undefined : play.players.find((p) => p.id === pid);
}

/** "#11 Valtonen", or "unknown" for an id missing from the play's tracking. */
export function nameOf(play: Play, pid: number | undefined): string {
  const p = playerOf(play, pid);
  return p ? `#${p.jersey} ${p.last}` : "unknown";
}

/** Index of the last frame at or before `f` (0 before the first). */
export function frameIndex(play: Play, f: number): number {
  let lo = 0, hi = play.frames.length - 1;
  if (hi < 0 || f <= play.frames[0]) return 0;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (play.frames[mid] <= f) lo = mid; else hi = mid - 1;
  }
  return lo;
}

/** Coverage words for a screen, or "" when none was called on either player. */
export function coverageText(s: AnnScreen): string {
  const parts = [s.covUse, s.covScr].map((c) => (c && c !== "none" ? COVERAGE[c] ?? c : null));
  if (!parts[0] && !parts[1]) return "";
  return parts.map((c) => c ?? "–").join(" / ");
}

export const SCREEN_NAMES: Record<AnnScreen["kind"], string> = { pick: "Pick", handoff: "Handoff", off_ball_screen: "Screen" };

const madeOf = (shot: AnnShot): string =>
  `${shot.blocked ? "Blocked" : shot.made ? "Made" : "Missed"} ${shot.three ? 3 : 2}`;

/** The shot released most recently at or before frame `f`, if any. */
export function lastShot(play: Play, f: number): AnnShot | null {
  let out: AnnShot | null = null;
  for (const s of play.ann?.shots ?? []) if (s.f <= f) out = s;
  return out;
}

/** The highest the ball went between a shot's release and its end (tracking; noisy), or null. */
export function shotPeak(play: Play, shot: AnnShot): number | null {
  let peak = -Infinity;
  for (let i = frameIndex(play, shot.f); i < play.frames.length && play.frames[i] <= shot.f1; i++) {
    const z = play.ball.z[i];
    if (!Number.isNaN(z)) peak = Math.max(peak, z);
  }
  return Number.isFinite(peak) && peak < 30 ? peak : null;
}

// ---- season figures ------------------------------------------------------------------------------

export type Season = Record<string, SeasonFigures>;

export const seasonOf = (season: Season | null, p: PlayerTrack | undefined): SeasonFigures | null =>
  season && p?.canon != null && p.team != null ? season[`${p.canon}:${p.team}`] ?? null : null;

const share = (made: number, n: number): string => (n ? `${Math.round((100 * made) / n)}%` : "–");
const efg = (t: [number, number, number] | undefined): string =>
  t && t[0] ? `${Math.round((100 * (t[1] + 0.5 * t[2])) / t[0])}% eFG (${t[0]})` : "–";
const ppp = (pair: [number, number] | undefined): string =>
  pair && pair[0] ? `${(pair[1] / pair[0]).toFixed(2)} PPP (${pair[0]})` : "–";

const ZONE_OF_REGION: Record<string, keyof NonNullable<SeasonFigures["zone"]>> = {
  ra: "ra", key: "paint", "left corner two": "mid", "right corner two": "mid", "left wing two": "mid",
  "right wing two": "mid", "middle two": "mid", "left corner three": "c3", "right corner three": "c3",
  "left wing three": "ab3", "right wing three": "ab3", "middle three": "ab3",
};
const ZONE_NAMES = { ra: "the Restricted Area", paint: "the Paint", mid: "Mid-Range", c3: "the Corner 3", ab3: "ATB Three" };

/** A player's season in a few lines (offense only: the aggregates have no defensive figures). */
export function seasonLines(fig: SeasonFigures | null): Line[] {
  if (!fig) return [{ k: "Season", v: "No season row" }];
  const lines: Line[] = [];
  if (fig.g != null) lines.push({ k: "Games", v: String(fig.g) });
  if (fig.fg) lines.push({ k: "FG", v: `${fig.fg[1]}/${fig.fg[0]} (${share(fig.fg[1], fig.fg[0])}) · ${efg(fig.fg).replace(/ \(\d+\)$/, "")}` });
  if (fig.cns) lines.push({ k: "Catch and Shoot", v: efg(fig.cns) });
  if (fig.od) lines.push({ k: "Off the Dribble", v: efg(fig.od) });
  if (fig.drives?.[0]) lines.push({ k: "Drives", v: `${share(fig.drives[1], fig.drives[0])} successful (${fig.drives[0]})` });
  if (fig.handler?.[0]) lines.push({ k: "Pick Handler", v: ppp(fig.handler) });
  if (fig.screener?.[0]) lines.push({ k: "Pick Screener", v: ppp(fig.screener) });
  return lines;
}

/** The shooter's season from the shot's zone, e.g. "13/25 (52%) from mid-range". */
export function shotSeasonLine(fig: SeasonFigures | null, shot: AnnShot): Line | null {
  const zone = shot.region ? ZONE_OF_REGION[shot.region] : undefined;
  const pair = zone && fig?.zone?.[zone];
  if (!zone || !pair) return null;
  return { k: "Season", v: `${pair[1]}/${pair[0]} (${share(pair[1], pair[0])}) from ${ZONE_NAMES[zone]}` };
}

/** Season points per pick for both players against the coverage called on each (picks only). */
export function screenSeasonLines(play: Play, season: Season | null, s: AnnScreen): Line[] {
  if (s.kind !== "pick" || !season) return [];
  const out: Line[] = [];
  const add = (pid: number, role: "handler" | "screener", cov: string | undefined) => {
    const fig = seasonOf(season, playerOf(play, pid));
    const pair = cov && cov !== "none" ? fig?.[role === "handler" ? "handlerVs" : "screenerVs"]?.[cov] : fig?.[role];
    if (pair?.[0]) out.push({ k: `${nameOf(play, pid)}, ${titleCase(role)}`, v: `${ppp(pair)}${cov && cov !== "none" ? ` vs ${COVERAGE[cov] ?? cov}` : ""}` });
  };
  add(s.use, "handler", s.covUse);
  add(s.scr, "screener", s.covScr);
  return out;
}

// ---- shot card -----------------------------------------------------------------------------------

export interface Card {
  title: string;
  tone?: string;
  lines: Line[];
}

/** Who passed to the shooter, whenever the pass set up an assist chance (SkillCorner's assistOpp: assisted, or the
 * shot came within 3 s of the catch), made or missed. */
export function passLine(play: Play, shot: AnnShot): Line {
  if (shot.passer == null || !(shot.assisted || shot.ao)) return { k: "Pass", v: "Unassisted" };
  const by = nameOf(play, shot.passer);
  if (shot.assisted && shot.made) return { k: "Pass", v: `Assisted by ${by}` };
  return { k: "Pass", v: shot.made ? `From ${by} (No Assist Credited)` : `From ${by} (Potential Assist)` };
}

export function shotCard(play: Play, shot: AnnShot, opts: { peak: boolean; season: Season | null }): Card {
  const lines: Line[] = [];
  const tone = shot.cl ? CONTEST_COLORS[shot.cl] : undefined;
  if (shot.sq != null) lines.push({ k: "SkillCorner Shot Quality", v: `${Math.round(shot.sq)} / 100` });
  if (shot.dist != null) lines.push({ k: "Distance", v: `${shot.dist.toFixed(1)} ft` });
  if (shot.region) lines.push({ k: "Region", v: regionName(shot.region) });
  if (shot.cl) lines.push({ k: "Contest", v: titleCase(shot.cl), tone });
  if (shot.defDist != null) lines.push({ k: "Closest Defender Distance", v: `${shot.defDist.toFixed(1)} ft`, tone });
  if (shot.defId != null) lines.push({ k: "Closest Defender", v: nameOf(play, shot.defId), tone });
  if (shot.rt != null) lines.push({ k: "Release Time", v: `${shot.rt.toFixed(1)} s` });
  if (shot.drb != null) lines.push({ k: "Dribbles", v: String(shot.drb) });
  if (shot.cns != null) lines.push({ k: "Creation", v: shot.cns ? "Catch and Shoot" : "Off the Dribble" });
  if (shot.type) lines.push({ k: "Type", v: titleCase(words(shot.type)) });
  if (shot.sc != null) lines.push({ k: "Shot Clock", v: `${shot.sc.toFixed(1)} s` });
  lines.push(passLine(play, shot));
  if (shot.blocked && shot.blocker != null) lines.push({ k: "Blocked By", v: nameOf(play, shot.blocker) });
  if (shot.fouled) lines.push({ k: "Fouled", v: shot.ft.length ? `FT ${shot.ft.filter(Boolean).length}/${shot.ft.length}` : "Yes" });
  if (opts.peak) {
    const peak = shotPeak(play, shot);
    if (peak != null) lines.push({ k: "Ball Peak", v: `${peak.toFixed(1)} ft` });
  }
  if (opts.season) {
    const line = shotSeasonLine(seasonOf(opts.season, playerOf(play, shot.pid)), shot);
    if (line) lines.push(line);
  }
  return { title: `${madeOf(shot)} · ${nameOf(play, shot.pid)}`, tone: shot.made ? "#2FAE5A" : "#E04848", lines };
}

// ---- drives and closeouts --------------------------------------------------------------------------

const fmtNum = (v: number | null | undefined, digits: number, unit: string): string =>
  v == null || Number.isNaN(v) ? "–" : `${v.toFixed(digits)} ${unit}`;

/** One player's movement over an action, from the tracking (smoothed; see motion.ts). */
function movementLines(play: Play, pid: number, f0: number, f1: number, whose: string): Line[] {
  const m = stretch(play, pid, f0, f1);
  if (!m) return [];
  return [
    { k: "Duration", v: `${m.secs.toFixed(1)} s` },
    { k: `${whose} Max Speed`, v: fmtNum(m.maxSpeed, 1, "ft/s") },
    { k: `${whose} Distance Covered`, v: fmtNum(m.dist, 1, "ft") },
    { k: `${whose} Peak Acceleration`, v: fmtNum(m.accel, 1, "ft/s²") },
    { k: `${whose} Peak Deceleration`, v: fmtNum(m.decel, 1, "ft/s²") },
  ];
}

/** A drive: how it went (event fields), then the driver's movement and his separation from his defender. */
export function driveLines(play: Play, d: AnnDrive): Line[] {
  const lines: Line[] = [];
  if (d.dir) lines.push({ k: "Direction", v: titleCase(d.dir) });
  lines.push({ k: "Blow-By", v: d.blowby ? "Yes" : "No" });
  if (d.end) lines.push({ k: "Ended With", v: titleCase(words(d.end)) });
  if (d.def != null) {
    lines.push({ k: "Defender", v: nameOf(play, d.def) });
    const a = gapAt(play, d.pid, d.def, d.f), b = gapAt(play, d.pid, d.def, d.f1);
    lines.push({ k: "Separation", v: `${fmtNum(a, 1, "ft")} → ${fmtNum(b, 1, "ft")}` });
  }
  lines.push({ k: "Drive Length", v: fmtNum(Math.hypot(d.x1 - d.x0, d.y1 - d.y0), 1, "ft") });
  lines.push(...movementLines(play, d.pid, d.f, d.f1, "Driver"));
  return lines;
}

/** A closeout: the gap the defender closed (event fields), then how he ran out. */
export function closeoutLines(play: Play, c: AnnCloseout): Line[] {
  return [
    { k: "Ball Handler", v: nameOf(play, c.pid) },
    { k: "Gap", v: `${c.d0.toFixed(1)} ft → ${c.d1.toFixed(1)} ft` },
    ...movementLines(play, c.def, c.f, c.f1, "Defender"),
  ];
}

// ---- possession card -----------------------------------------------------------------------------

/** The possession's own chances, in order (a play's window can reach into the neighbouring possessions'). */
export const ownChances = (play: Play): AnnChance[] =>
  (play.ann?.chances ?? []).filter((c) => c.poss === play.id).sort((a, b) => a.f - b.f);

/** The chance under way at frame `f`, if any. */
export function chanceAt(play: Play, f: number): AnnChance | null {
  let out: AnnChance | null = null;
  for (const c of ownChances(play)) if (c.f <= f) out = c;
  return out;
}

export function possessionCard(play: Play, f: number, gc: number): Card {
  const ann = play.ann;
  const own = ownChances(play);
  const start = own[0]?.f ?? play.frames[0];
  const live = <T extends { f: number }>(rows: T[] | undefined) => (rows ?? []).filter((r) => r.f >= start && r.f <= f);
  const lines: Line[] = [];
  if (play.startType) lines.push({ k: "Start", v: START_LABELS[play.startType] ?? play.startType, wrap: true });
  const now = own.filter((c) => c.f <= f);
  if (own.length) {
    const orb = live(ann?.rebounds).filter((r) => !r.def && !r.team).length;
    lines.push({ k: "Chance", v: `${Math.max(1, now.length)} of ${own.length}${orb ? ` · ${orb} Off. Reb.` : ""}${now.some((c) => c.transition) ? " · Transition" : ""}` });
  }
  // Touches under way at any point since the chance began (the first can start a moment before it, on the inbound).
  const touches = play.touches.filter((t) => t.f1 >= start && t.f0 <= f);
  const dribbles = (ann?.dribbles ?? []).filter((d) => d.f >= Math.min(start, touches[0]?.f0 ?? start) && d.f <= f);
  lines.push({ k: "Touches", v: String(touches.length) });
  lines.push({ k: "Passes", v: String(live(ann?.passes).length) });
  // Dribbles by touch, in order: "4 | 0 | 2" is four dribbles on the first touch, none on the second and two so far
  // on the third.
  lines.push({ k: "Dribbles", v: touches.length
    ? touches.map((t) => dribbles.filter((d) => d.pid === t.pid && d.f >= t.f0 && d.f <= t.f1).length).join(" | ")
    : String(dribbles.length) });
  if (touches.length) {
    lines.push({ k: "Ball", v: touches.map((t) => `${nameOf(play, t.pid).split(" ")[0]} ${((Math.min(f, t.f1) - t.f0) / 25).toFixed(1)}s`).join(" → ") });
  }
  // Every free throw carries its foul, so the fouls' lists hold them all once (a shot's list repeats its foul's).
  const ft = live(ann?.fouls).flatMap((x) => x.ft);
  if (ft.length) lines.push({ k: "Free Throws", v: `${ft.filter(Boolean).length}/${ft.length}` });
  return { title: "Possession", lines };
}

/** Minutes each player had played entering the chance under way at frame `f`. */
export function minutesAt(play: Play, f: number): Map<number, number> {
  const c = chanceAt(play, f) ?? ownChances(play)[0];
  return new Map((c?.mins ?? []).map((m) => [m.pid, m.min]));
}
