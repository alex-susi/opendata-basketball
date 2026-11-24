// Text for the annotation cards beside the court and the trace panel's hover card: shot details, possession
// context, tracking quality and season figures. Pure, so the tests can run it in Node.

import { clock } from "./geometry";
import { gapAt, motion, stretch } from "./motion";
import { HOOP_X } from "./court";
import { courtRegion } from "./regions";
import type { AnnChance, AnnCloseout, AnnCut, AnnDrive, AnnRebound, AnnScreen, AnnShot, Play, PlayerTrack, SeasonFigures } from "./types";

export interface Line {
  k: string;
  v: string;
  /** Optional colour of the value. */
  tone?: string;
  /** The value may wrap onto more lines (the card keeps its other lines' width). */
  wrap?: boolean;
  /** A subheader that starts a new group of lines (`k` is its text, `v` is empty). */
  head?: boolean;
}

/** A subheader line for the cards. */
export const head = (k: string): Line => ({ k, v: "", head: true });

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
  ice: "ICE", switch: "switch", over: "over", under: "under", blitz: "blitz", drop: "drop", show: "show",
  trail: "trail", whip: "whip", ride: "ride", "top lock": "top lock", jam: "jam",
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
  `${shot.made ? "Made" : "Missed"} ${shot.three ? 3 : 2}`;   // a block is the title's badge

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
  t && t[0] ? `eFG% ${Math.round((100 * (t[1] + 0.5 * t[2])) / t[0])}% (${t[0]})` : "–";
const ppp = (pair: [number, number] | undefined): string =>
  pair && pair[0] ? `${(pair[1] / pair[0]).toFixed(2)} PPP (${pair[0]})` : "–";

const ZONE_OF_REGION: Record<string, keyof NonNullable<SeasonFigures["zone"]>> = {
  ra: "ra", key: "paint", "left corner two": "mid", "right corner two": "mid", "left wing two": "mid",
  "right wing two": "mid", "middle two": "mid", "left corner three": "c3", "right corner three": "c3",
  "left wing three": "ab3", "right wing three": "ab3", "middle three": "ab3",
};

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

/** The shooter's season from the shot's zone (the aggregates' coarser zones: restricted area, paint, mid-range, corner
 * three, above-the-break three), e.g. "13/25 (52%)". The card shows it under the shot's Region. */
export function shotSeasonLine(fig: SeasonFigures | null, shot: AnnShot): Line | null {
  const zone = shot.region ? ZONE_OF_REGION[shot.region] : undefined;
  const pair = zone && fig?.zone?.[zone];
  if (!zone || !pair) return null;
  return { k: "Season", v: `${pair[1]}/${pair[0]} (${share(pair[1], pair[0])})` };
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

const MUTED = "#93A0B8";

export interface Card {
  title: string;
  /** The player, at the title line's right end (the shot card's shooter). */
  who?: string;
  tone?: string;
  /** A badge beside the title (a blocked shot's "Blocked"). */
  flag?: string;
  lines: Line[];
}

/** Who passed to the shooter (SkillCorner's passerId), and whether that pass was a potential assist (SkillCorner's
 * assistOpp: the shot was assisted, or came within 3 s of the catch), made or missed. */
export function passLines(play: Play, shot: AnnShot): Line[] {
  const from = shot.passer != null ? nameOf(play, shot.passer) : null;
  return [
    { k: "Pass", v: from ? `From ${from}` : "None" },
    { k: "Potential Assist", v: from && (shot.assisted || shot.ao) ? "Yes" : "No" },
  ];
}

/** The shooter's speed at release (ft/s, lightly smoothed as in motion.ts), from the tracking; null when he is not tracked
 * then. */
export function shooterSpeed(play: Play, shot: AnnShot): number | null {
  const j = play.players.findIndex((p) => p.id === shot.pid);
  if (j < 0) return null;
  const i = frameIndex(play, shot.f);
  if (Math.abs(play.frames[i] - shot.f) > 2) return null;
  const v = motion(play).speed[j][i];
  return Number.isNaN(v) ? null : v;
}

/** "1st", "2nd", "3rd", "4th", ..., "11th", "21st". */
const ordinal = (n: number): string => {
  const t = n % 100, u = n % 10;
  return `${n}${t >= 11 && t <= 13 ? "th" : u === 1 ? "st" : u === 2 ? "nd" : u === 3 ? "rd" : "th"}`;
};

/** SkillCorner xPoints: shot quality (0-100) / 100 × the shot's value. */
export const xPointsOf = (shot: AnnShot): number | null => (shot.sq == null ? null : (shot.sq * (shot.three ? 3 : 2)) / 100);

/** Percentile (0-100) of an xPoints value among the tracked games' FGA (sorted), counting ties as half. */
export function xPointsPercentile(xp: number, sorted: readonly number[]): number {
  let lo = 0, hi = sorted.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (sorted[mid] < xp - 5e-4) lo = mid + 1; else hi = mid; }
  let eq = lo;
  while (eq < sorted.length && Math.abs(sorted[eq] - xp) <= 5e-4) eq++;
  return (100 * (lo + (eq - lo) / 2)) / sorted.length;
}

/**
 * The shot card. opts.xpts: every FGA's xPoints in the tracked games, sorted (sample.json), for the percentile.
 */
export function shotCard(play: Play, shot: AnnShot, opts: { peak: boolean; season: Season | null; xpts?: readonly number[] | null }): Card {
  const lines: Line[] = [];
  const tone = shot.cl ? CONTEST_COLORS[shot.cl] : undefined;
  const blank = { v: "Not Provided", tone: MUTED };
  const xp = xPointsOf(shot);
  // Groups, each under its own subheader (a group with no lines is left out).
  const group = (title: string, rows: Line[]) => { if (rows.length) lines.push(head(title), ...rows); };

  const quality: Line[] = [];
  // SkillCorner's shot quality (0-100) read as an expected make rate, xFG%. Their docs do not say it is a calibrated
  // make probability, so the % is their score as given, not a fitted one.
  if (shot.sq != null) quality.push({ k: "xFG%", v: `${Math.round(shot.sq)}%` });
  else if (shot.est) quality.push({ k: "xFG%", ...blank });
  if (xp != null) {
    quality.push({ k: "xPoints", v: xp.toFixed(2) });
    if (opts.xpts?.length) quality.push({ k: "xPoints Percentile", v: ordinal(Math.min(100, Math.max(1, Math.round(xPointsPercentile(xp, opts.xpts))))) });
  } else if (shot.est) {
    quality.push({ k: "xPoints", ...blank });
  }
  group("Shot Quality", quality);

  const where: Line[] = [];
  if (shot.dist != null) where.push({ k: "Distance (ft)", v: shot.dist.toFixed(1) });
  if (shot.region) where.push({ k: "Region", v: regionName(shot.region) });
  if (opts.season && !shot.conflict) {   // a flagged spot would name the wrong zone
    const line = shotSeasonLine(seasonOf(opts.season, playerOf(play, shot.pid)), shot);
    if (line) where.push(line);
  }
  group("Location", where);

  const defense: Line[] = [];
  if (shot.cl) defense.push({ k: "Contest", v: `${titleCase(shot.cl)}${shot.est ? " (Est.)" : ""}`, tone });
  if (shot.defId != null) defense.push({ k: "Closest Defender", v: nameOf(play, shot.defId), tone });
  if (shot.defDist != null) defense.push({ k: "Distance (ft)", v: shot.defDist.toFixed(1), tone });   // to that defender
  if (shot.blocked && shot.blocker != null) defense.push({ k: "Blocked By", v: nameOf(play, shot.blocker) });
  if (shot.fouled) defense.push({ k: "Shooting Foul", v: shot.ft.length ? `FT ${shot.ft.filter(Boolean).length}/${shot.ft.length}` : "Yes" });
  group("Defense", defense);

  const creation: Line[] = [];
  if (shot.rt != null) creation.push({ k: "Release Time (s)", v: shot.rt.toFixed(1) });
  else if (shot.est) creation.push({ k: "Release Time (s)", ...blank });
  const speed = shooterSpeed(play, shot);
  if (speed != null) creation.push({ k: "Speed at Release (ft/s)", v: speed.toFixed(1) });
  if (shot.drb != null) creation.push({ k: "Dribbles", v: String(shot.drb) });
  if (shot.cns != null) creation.push({ k: "Creation", v: shot.cns ? "Catch and Shoot" : "Off the Dribble" });
  if (shot.type) creation.push({ k: "Type", v: titleCase(words(shot.type)) });
  else if (shot.est) creation.push({ k: "Type", ...blank });
  if (shot.sc != null) creation.push({ k: "Shot Clock (s)", v: shot.sc.toFixed(1) });
  creation.push(...passLines(play, shot));
  if (opts.peak) {   // the ball's flight, with Tracking Readouts on
    const peak = shotPeak(play, shot);
    if (peak != null) creation.push({ k: "Max Ball Height (ft)", v: peak.toFixed(1) });
  }
  group("Creation", creation);

  // One line per rebounding role, with how many attackers took it (the shooter's own crash counts as a crash).
  const roles = (play.ann?.glass ?? []).filter((g) => g.f === shot.f);
  if (roles.length) {
    const n = (r: string) => roles.filter((g) => g.role === r).length;
    group("Rebounding Roles", ([[n("crash") + n("follow"), "Crash"], [n("back"), "Retreat"], [n("safety"), "Safety"], [n("hold"), "Hold"]] as [number, string][])
      .map(([c, w]) => ({ k: w, v: String(c), tone: c ? undefined : MUTED })));
  }
  if (shot.est) group("Data Note", [{ k: "Shot Context", v: shot.conflict ? `From Tracking, Spot ${shot.three ? "Inside" : "Beyond"} the Arc` : "From Tracking", tone: shot.conflict ? "#F5B02E" : MUTED }]);
  return { title: madeOf(shot), who: nameOf(play, shot.pid), tone: shot.made ? "#2FAE5A" : "#E04848", flag: shot.blocked ? "Blocked" : undefined, lines };
}

// ---- drives and closeouts --------------------------------------------------------------------------

// A number alone (its unit is in the row's label, so values line up), or a dash when missing.
const fmtNum = (v: number | null | undefined, digits: number): string =>
  v == null || Number.isNaN(v) ? "–" : v.toFixed(digits);

/** One player's movement over an action, from the tracking (lightly smoothed; see motion.ts). The rows are not prefixed with
 * his part ("Driver Max Speed"): the card names him in its player rows above. */
function movementLines(play: Play, pid: number, f0: number, f1: number): Line[] {
  const m = stretch(play, pid, f0, f1);
  if (!m) return [];
  return [
    { k: "Duration (s)", v: m.secs.toFixed(1) },
    { k: "Max Speed (ft/s)", v: fmtNum(m.maxSpeed, 1) },
    { k: "Dist Covered (ft)", v: fmtNum(m.dist, 1) },
    { k: "Max Accel (ft/s²)", v: fmtNum(m.accel, 1) },
    { k: "Max Decel (ft/s²)", v: fmtNum(m.decel, 1) },
  ];
}

/** Lines under a subheader, or nothing when there are no lines (as the shot card's groups). */
const grouped = (title: string, rows: Line[]): Line[] => (rows.length ? [head(title), ...rows] : []);

/** How a drive was created (SkillCorner's category), in words. */
const DRIVE_CATEGORY: Record<string, string> = {
  pick: "Pick", handoff: "Handoff", offBallScreen: "Off-ball Screen", iso: "Isolation", closeout: "Closeout",
  miscellaneous: "Other",
};

/** A drive, grouped. Drive: how it was created, where it went and how it ended. Defense: his defender, the blow-by and
 * the gap to his defender at the start and end. Movement: how he ran (tracking). */
export function driveLines(play: Play, d: AnnDrive): Line[] {
  const drive: Line[] = [];
  if (d.cat) drive.push({ k: "Created From", v: DRIVE_CATEGORY[d.cat] ?? titleCase(words(d.cat)) });
  if (d.dir) drive.push({ k: "Direction", v: titleCase(d.dir) });
  drive.push({ k: "Drive Length (ft)", v: fmtNum(Math.hypot(d.x1 - d.x0, d.y1 - d.y0), 1) });
  if (d.end) drive.push({ k: "Ended With", v: titleCase(words(d.end)) });
  const defense: Line[] = [];
  if (d.def != null) defense.push({ k: "Defender", v: nameOf(play, d.def) });
  defense.push({ k: "Blow-By", v: d.blowby ? "Yes" : "No" });
  if (d.def != null) {
    const a = gapAt(play, d.pid, d.def, d.f), b = gapAt(play, d.pid, d.def, d.f1);
    defense.push({ k: "Separation (ft)", v: `${fmtNum(a, 1)} → ${fmtNum(b, 1)}` });
  }
  return [...grouped("Drive", drive), ...grouped("Defense", defense), ...grouped("Movement", movementLines(play, d.pid, d.f, d.f1))];
}

/** A cut, grouped. Cut: its kind and whether he got the ball. Defense: his defender, the coverage on a screen and the
 * gap to his defender. Movement: how he ran. His defender is his matchup when the cut starts. */
export function cutLines(play: Play, c: AnnCut): Line[] {
  const m = play.ann?.matchups.find((x) => x.off === c.pid && x.f <= c.f && x.f1 >= c.f);
  const catchAt = play.touches.find((t) => t.pid === c.pid && t.f0 >= c.f && t.f0 <= c.f1 + 12);
  const cut: Line[] = [
    { k: "Type", v: c.kind === "basket" ? "Basket Cut" : `Off-ball Screen, ${c.kind === "in" ? "In" : "Out"}` },
    { k: "Got the Ball", v: catchAt ? "Yes" : "No" },
    ...(catchAt ? [{ k: "Time to Catch (s)", v: ((catchAt.f0 - c.f) / 25).toFixed(1) }] : []),
  ];
  const defense: Line[] = [];
  if (m) defense.push({ k: "Defender", v: nameOf(play, m.def) });
  if (c.cov && c.cov !== "none") defense.push({ k: "Coverage", v: titleCase(COVERAGE[c.cov] ?? c.cov) });
  if (m) {
    const a = gapAt(play, c.pid, m.def, c.f), b = gapAt(play, c.pid, m.def, c.f1);
    defense.push({ k: "Separation (ft)", v: `${fmtNum(a, 1)} → ${fmtNum(b, 1)}` });
  }
  return [...grouped("Cut", cut), ...grouped("Defense", defense), ...grouped("Movement", movementLines(play, c.pid, c.f, c.f1))];
}

/** A closeout, grouped. Closeout: the gap the defender closed (event fields) and what the ball handler did after the
 * catch. Movement: how the defender ran out. */
export function closeoutLines(play: Play, c: AnnCloseout): Line[] {
  const closeout: Line[] = [{ k: "Gap (ft)", v: `${c.d0.toFixed(1)} → ${c.d1.toFixed(1)}` }];
  if (c.act) closeout.push({ k: "After the Catch", v: c.act.charAt(0).toUpperCase() + c.act.slice(1) });
  return [...grouped("Closeout", closeout), ...grouped("Defender Movement", movementLines(play, c.def, c.f, c.f1))];
}

/** The two attackers in a screen, by their parts: the one using it, then the screener (setter). */
const SCREEN_PARTS: Record<AnnScreen["kind"], [string, string]> = {
  pick: ["Ballhandler", "Screener"], handoff: ["Receiver", "Setter"], off_ball_screen: ["Cutter", "Screener"],
};
const SPOT_NAMES: Record<string, string> = { middle: "Middle", wing: "Wing", stepUp: "Step-Up" };

/** A pick, handoff or off-ball screen, grouped. Coverage: for each attacker, his defender (his matchup as the screen
 * is set; "Receiver's Defender") and, on the next row, the coverage that defender played ("Receiver Coverage"), when
 * coverage is shown. Location: the screen's spot (SkillCorner's locationType; picks and handoffs only). */
export function screenLines(play: Play, s: AnnScreen, coverage: boolean): Line[] {
  const defOf = (off: number) => play.ann?.matchups.find((x) => x.off === off && x.f <= s.f && x.f1 >= s.f)?.def;
  const cov: Line[] = [];
  if (coverage) {
    const [usePart, scrPart] = SCREEN_PARTS[s.kind];
    for (const [part, off, c] of [[usePart, s.use, s.covUse], [scrPart, s.scr, s.covScr]] as [string, number, string | undefined][]) {
      const def = defOf(off);
      if (def != null) cov.push({ k: `${part}'s Defender`, v: nameOf(play, def) });
      if (c && c !== "none") cov.push({ k: `${part} Coverage`, v: titleCase(COVERAGE[c] ?? c) });
    }
  }
  const where: Line[] = [];
  if (s.spot && s.spot !== "unknown") where.push({ k: "Spot", v: SPOT_NAMES[s.spot] ?? titleCase(words(s.spot)) });
  return [...grouped("Coverage", cov), ...grouped("Location", where)];
}

// ---- rebounds --------------------------------------------------------------------------------------

/** An attacker's rebounding role while the shot was in the air (web/scripts/glass.R), as the shot card names it. */
const GLASS_ROLE: Record<string, string> = {
  crash: "Crash", back: "Retreat", safety: "Safety", hold: "Hold", follow: "Followed His Shot", shooter: "Shooter",
};

/** A player's tracked spot at frame f (within 2 frames), in the play's frame (offense attacking +x), or null. */
function spotAt(play: Play, pid: number, f: number): { x: number; y: number } | null {
  const p = playerOf(play, pid);
  const i = frameIndex(play, f);
  if (!p || Math.abs(play.frames[i] - f) > 2 || Number.isNaN(p.x[i])) return null;
  return { x: p.x[i], y: p.y[i] };
}

/** A rebound: the shooter of the miss, then grouped. Rebound: offensive or defensive (or a team rebound), the miss and how long after
 * the release. Location: where the rebounder was when he got it (court region, distance to the basket the offense
 * attacks, from the tracking). Glass: for an offensive rebounder, his role while the shot was in the air, how far he
 * was from the basket at the release and when the ball came down, and whether a defender boxed him out; for a
 * defensive rebounder, the attackers he boxed out. The shot it came from is the last one released before it. */
export function reboundLines(play: Play, r: AnnRebound): Line[] {
  const shot = lastShot(play, r.f);
  const reb: Line[] = [{ k: "Type", v: r.team ? `Team, ${r.def ? "Defensive" : "Offensive"}` : r.def ? "Defensive" : "Offensive" }];
  if (shot) {
    reb.push({ k: "Off", v: madeOf(shot).replace("Made", "Missed") });
    reb.push({ k: "After Release (s)", v: ((r.f - shot.f) / 25).toFixed(1) });
  }
  const where: Line[] = [];
  const spot = r.pid != null ? spotAt(play, r.pid, r.f) : null;
  if (spot) {
    where.push({ k: "Region", v: regionName(courtRegion(spot.x, spot.y)) });
    where.push({ k: "To Basket (ft)", v: Math.hypot(HOOP_X - spot.x, spot.y).toFixed(1) });
    const from = shot ? spotAt(play, shot.pid, shot.f) : null;   // the shooter at his release, tracked
    if (from) where.push({ k: "From Shot Spot (ft)", v: Math.hypot(from.x - spot.x, from.y - spot.y).toFixed(1) });
  }
  const glass: Line[] = [];
  const roles = shot ? (play.ann?.glass ?? []).filter((g) => g.f === shot.f) : [];
  const own = roles.find((g) => g.pid === r.pid);
  if (own) {
    glass.push({ k: "Role", v: GLASS_ROLE[own.role] ?? titleCase(own.role) });
    glass.push({ k: "To Basket (ft)", v: `${own.d0.toFixed(1)} → ${own.d1.toFixed(1)}` });
    if (own.boxed != null) glass.push({ k: "Boxed Out", v: own.boxed ? (own.boxer != null ? `By ${nameOf(play, own.boxer)}` : "Yes") : "No" });
  } else if (r.def && r.pid != null) {
    const boxed = roles.filter((g) => g.boxed && g.boxer === r.pid);
    glass.push({ k: "Boxed Out", v: boxed.length ? boxed.map((g) => nameOf(play, g.pid)).join(", ") : "No One", wrap: boxed.length > 1 });
  }
  if (roles.length) {
    glass.push({ k: "Attackers Crashing", v: String(roles.filter((g) => g.role === "crash" || g.role === "follow").length) });
  }
  // The shooter first, outside the groups: the hover card shows him with the players (ActionCard.svelte, PLAYER_KEYS).
  const shooter: Line[] = shot ? [{ k: "Shooter", v: nameOf(play, shot.pid) }] : [];
  return [...shooter, ...grouped("Rebound", reb), ...grouped("Location", where), ...grouped("On the Glass", glass)];
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
  // The current ball handler: the latest touch to have started (while a pass is in the air, the passer's touch).
  // Dribbles and Ball are his alone: dribbles on this touch so far, and how long he has held it.
  const cur = touches.reduce<(typeof touches)[number] | null>((a, t) => (!a || t.f0 >= a.f0 ? t : a), null);
  if (cur) {
    lines.push({ k: "Dribbles", v: String(dribbles.filter((d) => d.pid === cur.pid && d.f >= cur.f0 && d.f <= Math.min(f, cur.f1)).length) });
    lines.push({ k: "Ball", v: nameOf(play, cur.pid) });
    lines.push({ k: "Held (s)", v: ((Math.min(f, cur.f1) - cur.f0) / 25).toFixed(1) });
  } else {
    lines.push({ k: "Dribbles", v: "0" });
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
