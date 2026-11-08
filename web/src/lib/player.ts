// The player card beside the rosters (five views) and the points-per-action tables in the trace panel's hover
// cards. Sources, always labelled:
//   Season     season.json, the aggregates over 293 games: offense only, shots, drives and picks.
//   Tracked    sample.json, the ten tracked games this site plays (web/scripts/sample_stats.R has every definition).
//   Playstyle  playstyle.json, the archetype model's probabilities and component scores (web/scripts/playstyle.R).
// Pure, so the tests can run it in Node.

import { nameOf, playerOf, seasonOf, titleCase, words, type Season } from "./context";
import type {
  ActKey, AnnCloseout, AnnDrive, AnnScreen, AnnSolo, Play, PlayerTrack, Playstyle, Sample, SampleFigures, SeasonFigures,
} from "./types";

/** A table cell: a value, optionally with its sample size (shown in the column's count column), or nothing. */
export type Cell = { v: string; n?: number; tone?: string } | null;
export interface StatRow { k: string; cells: Cell[]; note?: string; title?: string }
/** A column: its heading and, when its cells carry sample sizes, the heading of the count column beside it. */
export interface Col { label: string; count?: string }
/** note: short bullet points (a footnote under an untitled section, the (i) tooltip of a titled one). */
export interface StatSection { title?: string; cols: Col[]; rows: StatRow[]; note?: string[] }

export type CardView = "basic" | "advanced" | "tracking" | "actions" | "playstyle";
export const CARD_VIEWS: { key: CardView; label: string }[] = [
  { key: "basic", label: "Basic" }, { key: "advanced", label: "Advanced" }, { key: "tracking", label: "Tracking" },
  { key: "actions", label: "Actions" }, { key: "playstyle", label: "Playstyle" },
];

export const sampleOf = (sample: Sample | null, p: PlayerTrack | undefined): SampleFigures | null =>
  sample && p?.canon != null && p.team != null ? sample.players[`${p.canon}:${p.team}`] ?? null : null;

const GOOD = "#2FAE5A", BAD = "#E04848";
const cell = (v: string | null, n?: number, tone?: string): Cell => (v == null ? null : { v, n, tone });
const ratio = (a: number, b: number | undefined): number | null => (b ? a / b : null);
const fixed = (v: number | null, d = 1): string | null =>
  v == null || !Number.isFinite(v) ? null : d === 0 ? Math.round(v).toLocaleString("en-US") : v.toFixed(d);
const pct = (a: number, b: number | undefined): string | null => (b ? `${Math.round((100 * a) / b)}%` : null);
const frac = (made: number, att: number | undefined): string | null => (att ? `${made}/${att} (${pct(made, att)})` : null);
const perGame = (v: number | undefined, g: number | undefined, d = 1): string | null => (v == null ? null : fixed(ratio(v, g), d));
/** Points per action, with the number of actions as its count. */
const pppCell = (pair: [number, number] | readonly number[] | undefined): Cell =>
  pair && pair[0] ? { v: (pair[1] / pair[0]).toFixed(2), n: pair[0] } : null;

/** Drop rows with no value at all. */
const kept = (rows: StatRow[]): StatRow[] => rows.filter((r) => r.cells.some((c) => c != null));

const SEASON: Col = { label: "Season" }, TRACKED: Col = { label: "Tracked" };

function basic(s: SeasonFigures | null, t: SampleFigures | null): StatSection[] {
  const tg = t?.g, sg = s?.g;
  const rows: StatRow[] = [
    { k: "Games", cells: [cell(sg != null ? String(sg) : null), cell(t ? String(t.g) : null)] },
    { k: "Minutes", title: "Per game: game clock over the chances he was on court for", cells: [null, cell(perGame(t?.min, tg))] },
    { k: "Off. Possessions", title: "Offensive possessions on court, per game", cells: [cell(perGame(s?.poss, sg)), cell(perGame(t?.offPoss, tg))] },
    { k: "Points", title: "Per game, free throws included", cells: [cell(perGame(s?.pts, sg)), cell(perGame(t?.pts, tg))] },
    { k: "Rebounds", title: "Per game", cells: [null, cell(t ? perGame(t.oreb + t.dreb, tg) : null)] },
    { k: "Off. Rebounds", cells: [null, cell(perGame(t?.oreb, tg))] },
    { k: "Assists", title: "Per game: made shots he passed to (tracking's assist judgement)", cells: [null, cell(perGame(t?.ast, tg))] },
    { k: "Steals", cells: [null, cell(perGame(t?.stl, tg))] },
    { k: "Blocks", cells: [null, cell(perGame(t?.blk, tg))] },
    { k: "Turnovers", cells: [null, cell(perGame(t?.tov, tg))] },
    { k: "Fouls", title: "Personal fouls per game (technicals left out)", cells: [null, cell(perGame(t?.pf, tg))] },
    { k: "Shooting Fouls Drawn", title: "Per game: his shots on which he was fouled (made or missed)", cells: [cell(perGame(s?.fouled, sg)), cell(perGame(t?.fouledShots, tg))] },
    { k: "Shots Blocked", title: "Per game: his field goal attempts that were blocked", cells: [cell(perGame(s?.blkOn, sg)), cell(perGame(t?.blockedOn, tg))] },
    { k: "FG", title: "Made / attempted (FIBA: misses while fouled are not attempts)", cells: [cell(s?.fg ? frac(s.fg[1], s.fg[0]) : null), cell(t ? frac(t.fgm, t.fga) : null)] },
    { k: "3PT", cells: [cell(s?.fg3 ? frac(s.fg3[1], s.fg3[0]) : null), cell(t ? frac(t.fg3m, t.fg3a) : null)] },
    { k: "FT", cells: [cell(s?.ft ? frac(s.ft[1], s.ft[0]) : null), cell(t ? frac(t.ftm, t.fta) : null)] },
  ];
  return [{
    cols: [SEASON, TRACKED], rows: kept(rows),
    note: ["No season minutes, rebounds, steals, blocks or fouls", "Season assists and turnovers only exist within drives and picks"],
  }];
}

/** True shooting, eFG and the rest from attempts, makes, threes made, free throws and points. */
function shooting(fga: number, fgm: number, fg3a: number, fg3m: number, fta: number, pts: number, astd: number | undefined) {
  return {
    ts: pct(pts, 2 * (fga + 0.44 * fta)),
    efg: pct(fgm + 0.5 * fg3m, fga),
    par3: pct(fg3a, fga),
    ftr: pct(fta, fga),
    astd: astd == null ? null : pct(astd, fgm),
  };
}

type ZoneVec = readonly number[];
const ZONES = ["rim", "mid", "three"] as const;
const ZONE_ROWS: [string, (typeof ZONES)[number] | "all"][] = [["Overall", "all"], ["Rim", "rim"], ["Mid-Range", "mid"], ["Three", "three"]];
const zoneSum = (src: Record<string, ZoneVec> | undefined): ZoneVec | undefined =>
  src ? ZONES.reduce((acc, z) => acc.map((v, i) => v + src[z][i]), [0, 0, 0, 0, 0]) : undefined;
const pick = (src: Record<string, ZoneVec> | undefined, z: (typeof ZONES)[number] | "all") => (z === "all" ? zoneSum(src) : src?.[z]);
/** Mean shot quality of a zone vector [FGA, makes, threes made, scored FGA, quality sum], with its FGA. */
const sqCell = (z: ZoneVec | undefined): Cell => (z && z[3] ? { v: (z[4] / z[3]).toFixed(0), n: z[0] } : null);
const efgCell = (z: ZoneVec | undefined): Cell => (z && z[0] ? { v: pct(z[1] + 0.5 * z[2], z[0])! } : null);

/** Shot quality by zone for one set of shots (his own, or those he guarded), with eFG and the league's quality. */
function qualitySection(title: string, own: Record<string, ZoneVec> | undefined, league: Record<string, ZoneVec> | undefined, note: string[]): StatSection {
  return {
    title, note,
    cols: [{ label: "Quality", count: "FGA" }, { label: "eFG" }, { label: "League" }],
    rows: kept(ZONE_ROWS.map(([k, z]) => {
      const lg = sqCell(pick(league, z));
      return { k, cells: [sqCell(pick(own, z)), efgCell(pick(own, z)), lg ? { v: lg.v } : null] };
    })).filter((r) => r.cells[0] != null),
  };
}

function advanced(s: SeasonFigures | null, t: SampleFigures | null, league: Sample["league"] | null): StatSection[] {
  const out: StatSection[] = [];
  if (t) {
    const ortg = ratio(100 * t.offPts, t.offPoss), drtg = ratio(100 * t.defPts, t.defPoss);
    const net = ortg != null && drtg != null ? ortg - drtg : null;
    out.push({
      title: "On Court", cols: [{ label: "Tracked", count: "Possessions" }],
      rows: kept([
        { k: "Off. Rating", title: "His team's points per 100 possessions he was on court for", cells: [cell(fixed(ortg), t.offPoss)] },
        { k: "Def. Rating", title: "Opponents' points per 100 possessions he was on court for", cells: [cell(fixed(drtg), t.defPoss)] },
        { k: "Net Rating", cells: [cell(net == null ? null : `${net > 0 ? "+" : ""}${net.toFixed(1)}`, undefined, net == null ? undefined : net >= 0 ? GOOD : BAD)] },
        { k: "Usage", title: "His FGA + 0.44 FTA + turnovers, as a share of his team's while he was on offense", cells: [cell(pct(t.plays, t.teamPlays))] },
        { k: "Off. Rebound %", title: "Share of his team's offensive rebound chances he grabbed while on court", cells: [cell(pct(t.oreb, t.orebOpp))] },
        { k: "Def. Rebound %", cells: [cell(pct(t.dreb, t.drebOpp))] },
      ]),
    });
  }
  const sv = s?.fg && s.fg3 && s.ft && s.pts != null ? shooting(s.fg[0], s.fg[1], s.fg3[0], s.fg3[1], s.ft[0], s.pts, s.astd) : null;
  const tv = t ? shooting(t.fga, t.fgm, t.fg3a, t.fg3m, t.fta, t.pts, t.astd) : null;
  out.push({
    title: "Shooting", cols: [SEASON, TRACKED],
    rows: kept([
      { k: "True Shooting", title: "Points / (2 × (FGA + 0.44 FTA))", cells: [cell(sv?.ts ?? null), cell(tv?.ts ?? null)] },
      { k: "Effective FG", title: "(FG + 0.5 × 3PT made) / FGA", cells: [cell(sv?.efg ?? null), cell(tv?.efg ?? null)] },
      { k: "3PA Rate", title: "Share of his FGA that were threes", cells: [cell(sv?.par3 ?? null), cell(tv?.par3 ?? null)] },
      { k: "FT Rate", title: "Free throw attempts per FGA", cells: [cell(sv?.ftr ?? null), cell(tv?.ftr ?? null)] },
      { k: "Assisted Makes", title: "Share of his made field goals that a teammate assisted", cells: [cell(sv?.astd ?? null), cell(tv?.astd ?? null)] },
    ]),
  });
  if (t) {
    const zones = "Rim: restricted area · Mid-Range: other twos";
    out.push(qualitySection("SkillCorner Shot Quality, His Shots", t.zone, league?.zone,
      ["Mean quality (0-100) of his FGA, tracked games", "League: every FGA in those games", zones]));
    out.push(qualitySection("SkillCorner Shot Quality, Shots He Guarded", t.guardZone, league?.zone,
      ["Opponents' FGA with him the closest defender at release", "eFG: opponents' on those shots", zones]));
  }
  return out.filter((sec) => sec.rows.length);
}

function tracking(t: SampleFigures | null): StatSection[] {
  const k = t?.trk;
  if (!t || !k) return [];
  const speed = (dist: number, secs: number) => fixed(ratio(dist, secs));
  const perMin = (dist: number, secs: number) => fixed(ratio(dist, secs / 60), 0);
  const avg = (pair: [number, number]) => fixed(ratio(pair[1], pair[0]));
  const out: StatSection[] = [{
    title: "Movement", cols: [{ label: "All" }, { label: "Offense" }, { label: "Defense" }],
    note: ["Live play only (clock running)", "Positions smoothed over 0.2 s"],
    rows: kept([
      { k: "Live Minutes / Game", cells: [cell(perGame(k.secs / 60, t.g)), cell(perGame(k.offSecs / 60, t.g)), cell(perGame(k.defSecs / 60, t.g))] },
      { k: "Avg Speed (ft/s)", cells: [cell(speed(k.dist, k.secs)), cell(speed(k.offDist, k.offSecs)), cell(speed(k.defDist, k.defSecs))] },
      { k: "Distance / Game (ft)", cells: [cell(perGame(k.dist, t.g, 0)), cell(perGame(k.offDist, t.g, 0)), cell(perGame(k.defDist, t.g, 0))] },
      { k: "Distance / Minute (ft)", cells: [cell(perMin(k.dist, k.secs)), cell(perMin(k.offDist, k.offSecs)), cell(perMin(k.defDist, k.defSecs))] },
      { k: "Top Speed (ft/s)", title: "Fastest 0.5 s average", cells: [cell(k.top != null ? k.top.toFixed(1) : null), null, null] },
      { k: "Sprint Speed (ft/s)", title: "99th percentile of his live-play speed", cells: [cell(k.v99 != null ? k.v99.toFixed(1) : null), null, null] },
      { k: "Acceleration (ft/s²)", title: "99th percentile of his speeding up in live play", cells: [cell(k.acc != null ? k.acc.toFixed(1) : null), null, null] },
      { k: "Braking (ft/s²)", title: "99th percentile of his slowing down in live play", cells: [cell(k.dec != null ? k.dec.toFixed(1) : null), null, null] },
      { k: "Nearest Opp. (ft)", title: "Average distance to the closest opponent: how open he was on offense, how tight on defense", cells: [null, cell(avg(k.open)), cell(avg(k.near))] },
      { k: "Time in Paint", title: "Share of his time on offense spent inside the key he attacks", cells: [null, cell(pct(k.paint, k.offSecs)), null] },
    ]),
  }];
  const b = t.ball;
  out.push({
    title: "Ball and Shots", cols: [{ label: "Tracked", count: "FGA" }],
    rows: kept([
      { k: "Touches / Game", cells: [cell(b ? perGame(b[0], t.g) : null)] },
      { k: "Time on Ball / Game (s)", cells: [cell(b ? perGame(b[1], t.g) : null)] },
      { k: "Seconds / Touch", cells: [cell(b ? fixed(ratio(b[1], b[0])) : null)] },
      { k: "Dribbles / Touch", cells: [cell(b ? fixed(ratio(b[2], b[0])) : null)] },
      { k: "Closest Def. on Shots (ft)", title: "Average distance of the closest defender at his release", cells: [cell(fixed(ratio(t.shotDef[1], t.shotDef[0])), t.shotDef[0])] },
      { k: "Contested Shots", title: "Share of his FGA with an average, plus or blocked contest", cells: [cell(pct(t.shotDef[2], t.shotDef[0]), t.shotDef[0])] },
      { k: "FGA Guarded / Game", title: "Opponents' FGA per game where he was the closest defender at release", cells: [cell(perGame(t.guard[0], t.g))] },
    ]),
  });
  const gl = t.glass;
  if (gl && gl[0]) {
    out.push({
      title: "Rebounding Roles", cols: [{ label: "Tracked", count: "Shots" }],
      note: ["Teammates' shots, release to the ball reaching the rim", "Crash: on the glass · Retreat: heading back · Safety: already deep", "Boxed out: a defender got between him and the hoop (rough)"],
      rows: kept([
        { k: "Crash", cells: [cell(pct(gl[1], gl[0]), gl[0])] },
        { k: "Retreat", cells: [cell(pct(gl[2], gl[0]))] },
        { k: "Safety", cells: [cell(pct(gl[3], gl[0]))] },
        { k: "Hold", cells: [cell(pct(gl[4], gl[0]))] },
        { k: "Crashes Boxed Out", cells: [cell(pct(gl[6], gl[5]), gl[5])] },
        { k: "Off. Rebounds per Crash", title: "On missed shots he crashed", cells: [cell(pct(gl[8], gl[7]), gl[7])] },
      ]),
    });
  }
  return out.filter((sec) => sec.rows.length);
}

const ACT_ROWS: { k: string; season?: (s: SeasonFigures) => [number, number] | undefined; act?: ActKey; title?: string }[] = [
  { k: "Pick Handler", season: (s) => s.handler, act: "pickH" },
  { k: "Pick Screener", season: (s) => s.screener, act: "pickS" },
  { k: "Drives", season: (s) => (s.drives && s.drives.length > 2 ? [s.drives[0], s.drives[2] as number] : undefined), act: "drive" },
  { k: "Handoffs", act: "handoff", title: "As the receiver" },
  { k: "Off-Ball Screens", act: "obs", title: "As the cutter" },
  { k: "Off-Ball Screener", act: "obsS" },
  { k: "Post-Ups", act: "post" },
  { k: "Isolations", act: "iso" },
  { k: "Attacking Closeouts", act: "closeout", title: "Catching the ball as a defender closes out" },
];

function actions(s: SeasonFigures | null, t: SampleFigures | null): StatSection[] {
  const rows = kept(ACT_ROWS.map((r) => ({
    k: r.k, title: r.title,
    cells: [s && r.season ? pppCell(r.season(s)) : null, r.act ? pppCell(t?.acts?.[r.act]) : null],
  })));
  if (s?.drives?.[0]) rows.push({ k: "Drive Success", title: "Drives ending in a make, an assist or a foul drawn", cells: [cell(pct(s.drives[1], s.drives[0])), null] });
  return [{
    cols: [{ label: "Season", count: "Chances" }, { label: "Tracked", count: "Chances" }], rows,
    note: ["Points per chance (PPP): own makes + assisted makes, no free throws", "Chance: one pick, drive or other action", "Picks: direct only, as in the season data"],
  }];
}

/** The player card's table sections for one view (Playstyle has its own layout: playstyleOf). */
export function playerSections(view: CardView, season: Season | null, sample: Sample | null, p: PlayerTrack): StatSection[] {
  const s = seasonOf(season, p), t = sampleOf(sample, p);
  if (view === "basic") return basic(s, t);
  if (view === "advanced") return advanced(s, t, sample?.league ?? null);
  if (view === "tracking") return tracking(t);
  if (view === "actions") return actions(s, t);
  return [];
}

// ---- playstyle -----------------------------------------------------------------------------------

export interface StyleSide {
  side: "off" | "def";
  title: string;
  top: string; p: number; defines: boolean;
  /** Every archetype, most likely first. */
  archetypes: { name: string; slot?: string; p: number }[];
  /** His score on each component (component standard deviations, + = the end named `plus`). */
  components: { j: number; score: number | null; share: number; minus: string; plus: string; context: string }[];
}

/** His archetype probabilities and component scores on each side of the ball, as the Archetypes tab names them. */
export function playstyleOf(style: Playstyle | null, p: PlayerTrack): StyleSide[] {
  const me = style && p.canon != null ? style.players[String(p.canon)] : undefined;
  if (!style || !me) return [];
  return (["off", "def"] as const).flatMap((side) => {
    const mine = me[side], model = style.sides[side];
    if (!mine) return [];
    return [{
      side, title: side === "off" ? "Offense" : "Defense", top: mine.top, p: mine.p, defines: mine.defines,
      archetypes: model.archetypes.map((a, i) => ({ name: a.name, slot: a.slot, p: mine.probs[i] ?? 0 })).sort((a, b) => b.p - a.p),
      components: model.components.map((c, j) => ({ j: j + 1, score: mine.scores[j], share: c.share, minus: c.minus, plus: c.plus, context: c.context })),
    }];
  });
}

// ---- the trace panel's hover cards: points per action ----------------------------------------------

const COV: Record<string, string> = { ice: "ICE", none: "No Coverage" };
const covName = (c: string) => COV[c] ?? titleCase(words(c));
const DRIVE_CAT: Record<string, string> = {
  pick: "Off Picks", handoff: "Off Handoffs", offBallScreen: "Off Off-Ball Screens", iso: "From Isolations",
  closeout: "Attacking Closeouts", miscellaneous: "Other",
};

/** Points per action for the players in a hovered action, and the tracked games' league figure for its type. */
export function actionTable(
  play: Play, season: Season | null, sample: Sample | null,
  a: { kind: "screen"; s: AnnScreen } | { kind: "drive"; d: AnnDrive } | { kind: "closeout"; c: AnnCloseout } | { kind: "solo"; s: AnnSolo },
): StatSection | null {
  const rows: StatRow[] = [];
  const tracked = (pid: number, key: ActKey, k: string) => {
    const c = pppCell(sampleOf(sample, playerOf(play, pid))?.acts?.[key]);
    if (c) rows.push({ k, cells: [c], note: "Tracked" });
  };
  const league = (key: ActKey, k: string, by?: string, note?: (c: string) => string) => {
    const L = sample?.league.acts[key];
    if (!L) return;
    const pair = by != null ? L.by[by] : undefined;
    const c = pppCell(pair ?? L.all);
    if (c) rows.push({ k, cells: [c], note: pair && by != null && note ? note(by) : "Tracked, All" });
  };
  if (a.kind === "screen") {
    const s = a.s, user = nameOf(play, s.use), scr = nameOf(play, s.scr);
    if (s.kind === "pick") {
      const seasonRow = (pid: number, role: "handler" | "screener", cov: string | undefined, k: string) => {
        const fig = seasonOf(season, playerOf(play, pid));
        const vs = cov && cov !== "none" ? fig?.[role === "handler" ? "handlerVs" : "screenerVs"]?.[cov] : undefined;
        const c = pppCell(vs ?? fig?.[role]);
        if (c) rows.push({ k, cells: [c], note: vs && cov ? `Season vs ${covName(cov)}` : "Season, All" });
      };
      seasonRow(s.use, "handler", s.covUse, `${user}, Handler`);
      tracked(s.use, "pickH", `${user}, Handler`);
      seasonRow(s.scr, "screener", s.covScr, `${scr}, Screener`);
      tracked(s.scr, "pickS", `${scr}, Screener`);
      league("pickH", "All Handlers", s.covUse, (c) => `Tracked vs ${covName(c)}`);
    } else if (s.kind === "handoff") {
      tracked(s.use, "handoff", `${user}, Receiver`);
      league("handoff", "All Receivers", s.covUse, (c) => `Tracked vs ${covName(c)}`);
    } else {
      tracked(s.use, "obs", `${user}, Cutter`);
      tracked(s.scr, "obsS", `${scr}, Screener`);
      league("obs", "All Cutters", s.covUse, (c) => `Tracked vs ${covName(c)}`);
    }
  } else if (a.kind === "drive") {
    const d = a.d, who = nameOf(play, d.pid);
    const fig = seasonOf(season, playerOf(play, d.pid));
    const c = fig?.drives && fig.drives.length > 2 ? pppCell([fig.drives[0], fig.drives[2] as number]) : null;
    if (c) rows.push({ k: `${who}, Driver`, cells: [c], note: "Season, All" });
    tracked(d.pid, "drive", `${who}, Driver`);
    league("drive", "All Drives", d.cat, (cat) => `Tracked, ${DRIVE_CAT[cat] ?? titleCase(words(cat))}`);
  } else if (a.kind === "closeout") {
    const c = a.c, who = nameOf(play, c.pid);
    tracked(c.pid, "closeout", `${who}, Ball Handler`);
    league("closeout", "All Closeouts", c.act, (act) => `Tracked, ${titleCase(act)} After Catch`);
  } else {
    const s = a.s, who = nameOf(play, s.pid);
    if (s.kind === "post") {
      tracked(s.pid, "post", `${who}, Post-Up`);
      league("post", "All Post-Ups", s.section, (sec) => `Tracked, ${titleCase(sec)} Post`);
    } else {
      tracked(s.pid, "iso", `${who}, Isolation`);
      league("iso", "All Isolations");
    }
  }
  return rows.length ? { cols: [{ label: "PPP", count: "Chances" }], rows } : null;
}
