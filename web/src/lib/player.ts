// The player card beside the rosters (four views) and the points-per-action tables in the trace panel's hover
// cards. Two sources, always labelled:
//   Season    season.json, the aggregates over 293 games: offense only, shots, drives and picks.
//   Tracked   sample.json, the ten tracked games this site plays (web/scripts/sample_stats.R has every definition).
// Pure, so the tests can run it in Node.

import { nameOf, playerOf, seasonOf, titleCase, words, type Season } from "./context";
import type { ActKey, AnnCloseout, AnnDrive, AnnScreen, AnnSolo, Play, PlayerTrack, Sample, SampleFigures, SeasonFigures } from "./types";

/** A table cell: a value, optionally with its sample size shown after it, or nothing. */
export type Cell = { v: string; n?: number; tone?: string } | null;
export interface StatRow { k: string; cells: Cell[]; note?: string; title?: string }
export interface StatSection { title?: string; cols: string[]; rows: StatRow[]; note?: string }

export type CardView = "basic" | "advanced" | "tracking" | "actions";
export const CARD_VIEWS: { key: CardView; label: string }[] = [
  { key: "basic", label: "Basic" }, { key: "advanced", label: "Advanced" },
  { key: "tracking", label: "Tracking" }, { key: "actions", label: "Actions" },
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
const perGame = (v: number, g: number | undefined, d = 1): string | null => fixed(ratio(v, g), d);
/** Points per action with its count, e.g. 0.89 (255). */
const pppCell = (pair: [number, number] | readonly number[] | undefined): Cell =>
  pair && pair[0] ? { v: (pair[1] / pair[0]).toFixed(2), n: pair[0] } : null;

/** Drop rows with no value at all. */
const kept = (rows: StatRow[]): StatRow[] => rows.filter((r) => r.cells.some((c) => c != null));

function basic(s: SeasonFigures | null, t: SampleFigures | null): StatSection[] {
  const tg = t?.g;
  const rows: StatRow[] = [
    { k: "Games", cells: [cell(s?.g != null ? String(s.g) : null), cell(t ? String(t.g) : null)] },
    { k: "Minutes", title: "Per game: game clock over the chances he was on court for", cells: [null, cell(t ? perGame(t.min, tg) : null)] },
    { k: "Points", title: "Per game, free throws included", cells: [cell(s?.pts != null ? perGame(s.pts, s.g) : null), cell(t ? perGame(t.pts, tg) : null)] },
    { k: "Rebounds", title: "Per game (offensive in brackets)", cells: [null, cell(t ? `${perGame(t.oreb + t.dreb, tg)} (${perGame(t.oreb, tg)} Off)` : null)] },
    { k: "Assists", title: "Per game: made shots he passed to (tracking's assist judgement)", cells: [null, cell(t ? perGame(t.ast, tg) : null)] },
    { k: "Steals", cells: [null, cell(t ? perGame(t.stl, tg) : null)] },
    { k: "Blocks", cells: [null, cell(t ? perGame(t.blk, tg) : null)] },
    { k: "Turnovers", cells: [null, cell(t ? perGame(t.tov, tg) : null)] },
    { k: "Fouls", title: "Personal fouls per game (technicals left out)", cells: [null, cell(t ? perGame(t.pf, tg) : null)] },
    { k: "FG", title: "Made / attempted (FIBA: misses while fouled are not attempts)", cells: [cell(s?.fg ? frac(s.fg[1], s.fg[0]) : null), cell(t ? frac(t.fgm, t.fga) : null)] },
    { k: "3PT", cells: [cell(s?.fg3 ? frac(s.fg3[1], s.fg3[0]) : null), cell(t ? frac(t.fg3m, t.fg3a) : null)] },
    { k: "FT", cells: [cell(s?.ft ? frac(s.ft[1], s.ft[0]) : null), cell(t ? frac(t.ftm, t.fta) : null)] },
  ];
  return [{ cols: ["Season", "Tracked"], rows: kept(rows) }];
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

function advanced(s: SeasonFigures | null, t: SampleFigures | null, league: Sample["league"] | null): StatSection[] {
  const out: StatSection[] = [];
  if (t) {
    const ortg = ratio(100 * t.offPts, t.offPoss), drtg = ratio(100 * t.defPts, t.defPoss);
    const net = ortg != null && drtg != null ? ortg - drtg : null;
    out.push({
      title: "On Court", cols: ["Tracked"],
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
    title: "Shooting", cols: ["Season", "Tracked"],
    rows: kept([
      { k: "True Shooting", title: "Points / (2 × (FGA + 0.44 FTA))", cells: [cell(sv?.ts ?? null), cell(tv?.ts ?? null)] },
      { k: "Effective FG", title: "(FG + 0.5 × 3PT made) / FGA", cells: [cell(sv?.efg ?? null), cell(tv?.efg ?? null)] },
      { k: "3PA Rate", title: "Share of his FGA that were threes", cells: [cell(sv?.par3 ?? null), cell(tv?.par3 ?? null)] },
      { k: "FT Rate", title: "Free throw attempts per FGA", cells: [cell(sv?.ftr ?? null), cell(tv?.ftr ?? null)] },
      { k: "Assisted Makes", title: "Share of his made field goals that a teammate assisted", cells: [cell(sv?.astd ?? null), cell(tv?.astd ?? null)] },
    ]),
  });
  if (t) {
    const sq = (z: readonly number[] | undefined): Cell => (z && z[3] ? { v: (z[4] / z[3]).toFixed(0), n: z[3] } : null);
    const zones = ["rim", "mid", "three"] as const;
    const sum = (src: Record<string, readonly number[]> | undefined) =>
      src ? zones.reduce((acc, z) => acc.map((v, i) => v + src[z][i]), [0, 0, 0, 0, 0]) : undefined;
    out.push({
      title: "SkillCorner Shot Quality", cols: ["Player", "League"],
      note: "Mean SkillCorner shot quality (0-100) of the FGA, tracked games only; League is every FGA in them. Rim is the restricted area, Mid-Range every other two.",
      rows: kept([
        { k: "Overall", cells: [sq(sum(t.zone)), sq(sum(league?.zone))] },
        { k: "Rim", cells: [sq(t.zone.rim), sq(league?.zone.rim)] },
        { k: "Mid-Range", cells: [sq(t.zone.mid), sq(league?.zone.mid)] },
        { k: "Three", cells: [sq(t.zone.three), sq(league?.zone.three)] },
      ]),
    });
    out.push({
      title: "Defense", cols: ["Tracked"],
      rows: kept([
        { k: "Shots as Closest Def.", title: "Opponents' FGA per game where he was the closest defender at release", cells: [cell(perGame(t.guard[0], t.g))] },
        { k: "Opp. Effective FG", title: "Opponents' eFG on those shots", cells: [cell(pct(t.guard[1] + 0.5 * t.guard[2], t.guard[0]), t.guard[0])] },
      ]),
    });
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
    title: "Movement", cols: ["All", "Offense", "Defense"],
    note: "Live play only (game clock running); positions smoothed over 0.2 s.",
    rows: kept([
      { k: "Live Minutes / Game", cells: [cell(perGame(k.secs / 60, t.g)), cell(perGame(k.offSecs / 60, t.g)), cell(perGame(k.defSecs / 60, t.g))] },
      { k: "Avg Speed (ft/s)", cells: [cell(speed(k.dist, k.secs)), cell(speed(k.offDist, k.offSecs)), cell(speed(k.defDist, k.defSecs))] },
      { k: "Distance / Game (ft)", cells: [cell(perGame(k.dist, t.g, 0)), cell(perGame(k.offDist, t.g, 0)), cell(perGame(k.defDist, t.g, 0))] },
      { k: "Distance / Minute (ft)", cells: [cell(perMin(k.dist, k.secs)), cell(perMin(k.offDist, k.offSecs)), cell(perMin(k.defDist, k.defSecs))] },
      { k: "Top Speed (ft/s)", title: "Fastest 0.5 s average", cells: [cell(k.top != null ? k.top.toFixed(1) : null), null, null] },
      { k: "Nearest Opp. (ft)", title: "Average distance to the closest opponent: how open he was on offense, how tight on defense", cells: [null, cell(avg(k.open)), cell(avg(k.near))] },
      { k: "Time in Paint", title: "Share of his time on offense spent inside the key he attacks", cells: [null, cell(pct(k.paint, k.offSecs)), null] },
    ]),
  }];
  const b = t.ball;
  out.push({
    title: "Ball and Shots", cols: ["Tracked"],
    rows: kept([
      { k: "Touches / Game", cells: [cell(b ? perGame(b[0], t.g) : null)] },
      { k: "Time on Ball / Game (s)", cells: [cell(b ? perGame(b[1], t.g) : null)] },
      { k: "Seconds / Touch", cells: [cell(b ? fixed(ratio(b[1], b[0])) : null)] },
      { k: "Dribbles / Touch", cells: [cell(b ? fixed(ratio(b[2], b[0])) : null)] },
      { k: "Closest Def. on Shots (ft)", title: "Average distance of the closest defender at his release", cells: [cell(fixed(ratio(t.shotDef[1], t.shotDef[0])), t.shotDef[0])] },
      { k: "Contested Shots", title: "Share of his FGA with an average, plus or blocked contest", cells: [cell(pct(t.shotDef[2], t.shotDef[0]))] },
    ]),
  });
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
    cols: ["Season", "Tracked"], rows,
    note: "Points per action (number of actions in brackets): his own made shot plus the shot he assisted; free throws are left out, as in the season aggregates. Picks count direct picks only.",
  }];
}

/** The player card's sections for one view. */
export function playerSections(view: CardView, season: Season | null, sample: Sample | null, p: PlayerTrack): StatSection[] {
  const s = seasonOf(season, p), t = sampleOf(sample, p);
  if (view === "basic") return basic(s, t);
  if (view === "advanced") return advanced(s, t, sample?.league ?? null);
  if (view === "tracking") return tracking(t);
  return actions(s, t);
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
  return rows.length ? { cols: ["PPP"], rows } : null;
}
