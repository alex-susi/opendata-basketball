// The tracked-games figures (sample.json, scripts/sample_stats.R), the season figures (season.json) and the player
// card and hover tables built from them (lib/player.ts).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { passLine, seasonOf, type Season } from "../src/lib/context";
import { decodePlay } from "../src/lib/decode";
import { actionTable, CARD_VIEWS, playerSections, playstyleOf, sampleOf } from "../src/lib/player";
import type { PeriodIndex, Play, PlayRow, Playstyle, Sample } from "../src/lib/types";

const ROOT = join(__dirname, "..");
const DATA = join(ROOT, "public", "data");
const json = <T>(name: string): T => JSON.parse(readFileSync(join(DATA, name), "utf8"));
const bytes = (name: string): ArrayBuffer => {
  const b = readFileSync(join(DATA, name));
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
};
const sample = json<Sample>("sample.json");
const season = json<Season>("season.json");
const style = json<Playstyle>("playstyle.json");
const matches = JSON.parse(readFileSync(join(ROOT, "..", "data", "matches.json"), "utf8")) as
  { id: number; home_team: { id: number }; away_team: { id: number }; home_score: number; away_score: number }[];
const plays = json<PlayRow[]>("plays.json");
const loadPlay = (row: PlayRow): Play => decodePlay(bytes(`${row.file}.bin`), json<PeriodIndex>(`${row.file}.json`).plays[row.id]);
const period = plays.filter((r) => r.file === plays[0].file).map(loadPlay);

const byTeam = (f: (p: Sample["players"][string]) => number) => {
  const out = new Map<number, number>();
  for (const [key, p] of Object.entries(sample.players)) {
    const team = Number(key.split(":")[1]);
    out.set(team, (out.get(team) ?? 0) + f(p));
  }
  return out;
};

describe("tracked-games figures", () => {
  it("cover the ten games", () => {
    expect(sample.games).toBe(10);
    expect(Object.keys(sample.players).length).toBeGreaterThan(150);
  });

  it("add up to each team's final scores", () => {
    const want = new Map<number, number>();
    for (const m of matches) {
      want.set(m.home_team.id, (want.get(m.home_team.id) ?? 0) + m.home_score);
      want.set(m.away_team.id, (want.get(m.away_team.id) ?? 0) + m.away_score);
    }
    expect(byTeam((p) => p.pts)).toEqual(want);
  });

  it("give each team about five players' worth of minutes a game", () => {
    const games = new Map<number, number>();
    for (const m of matches) for (const t of [m.home_team.id, m.away_team.id]) games.set(t, (games.get(t) ?? 0) + 1);
    for (const [team, min] of byTeam((p) => p.min)) {
      const perGame = min / games.get(team)!;
      expect(perGame).toBeGreaterThan(190);
      expect(perGame).toBeLessThan(230);   // two games went to overtime
    }
  });

  it("keep the league's zones as the sum of the players'", () => {
    for (const z of ["rim", "mid", "three"] as const) {
      const sum = Object.values(sample.players).reduce((a, p) => a + p.zone[z][0], 0);
      expect(sum).toBe(sample.league.zone[z][0]);
    }
  });

  it("have plausible tracking: average speeds of a few ft/s, top speeds under 30 ft/s", () => {
    for (const p of Object.values(sample.players)) {
      if (!p.trk || p.trk.secs < 300) continue;
      const avg = p.trk.dist / p.trk.secs;
      expect(avg).toBeGreaterThan(2);
      expect(avg).toBeLessThan(10);
      expect(p.trk.top!).toBeLessThan(30);
    }
  });
});

describe("player card", () => {
  const p = period[0].players.find((q) => sampleOf(sample, q) && seasonOf(season, q)?.pts)!;

  it("has figures in every table view", () => {
    for (const v of CARD_VIEWS.filter((x) => x.key !== "playstyle")) {
      const sections = playerSections(v.key, season, sample, p);
      expect(sections.length, v.key).toBeGreaterThan(0);
      for (const sec of sections) for (const r of sec.rows) expect(r.cells.length).toBe(sec.cols.length);
    }
  });

  it("puts sample sizes in count columns, never in brackets", () => {
    for (const v of CARD_VIEWS) {
      for (const sec of playerSections(v.key, season, sample, p)) {
        for (const r of sec.rows) {
          r.cells.forEach((c, j) => {
            if (c?.n != null) expect(sec.cols[j].count, `${sec.title} ${r.k}`).toBeTruthy();
            if (c) expect(c.v).not.toMatch(/^\d[\d.]* \(\d+\)$/);
          });
        }
      }
    }
  });

  it("shows shot quality on his shots and on the shots he guarded, by zone", () => {
    const adv = playerSections("advanced", season, sample, p);
    for (const title of ["SkillCorner Shot Quality, His Shots", "SkillCorner Shot Quality, Shots He Guarded"]) {
      const sec = adv.find((s) => s.title === title);
      expect(sec, title).toBeDefined();
      expect(sec!.rows[0].k).toBe("Overall");
    }
    // Every guarded FGA belongs to someone (shots without a closest defender are left out).
    const guarded = Object.values(sample.players).reduce((a, q) => a + q.guardZone.rim[0] + q.guardZone.mid[0] + q.guardZone.three[0], 0);
    const all = sample.league.zone.rim[0] + sample.league.zone.mid[0] + sample.league.zone.three[0];
    expect(guarded).toBeLessThanOrEqual(all);
    expect(guarded).toBeGreaterThan(0.9 * all);
  });

  it("has a playstyle on both sides for players in the archetype model", () => {
    const sides = playstyleOf(style, p);
    expect(sides.map((s) => s.side)).toEqual(["off", "def"]);
    for (const side of sides) {
      expect(side.archetypes[0].name).toBe(side.top);
      expect(side.archetypes.reduce((a, x) => a + x.p, 0)).toBeCloseTo(1, 1);
      for (const c of side.components) expect(c.score).not.toBeNull();
    }
  });

  it("shows season points per game from the aggregates", () => {
    const rows = playerSections("basic", season, sample, p)[0].rows;
    const pts = rows.find((r) => r.k === "Points")!;
    expect(pts.cells[0]).not.toBeNull();
    expect(pts.cells[1]).not.toBeNull();
  });
});

describe("hover tables", () => {
  it("give a points-per-action row for every pick, with a single PPP column", () => {
    let seen = 0;
    for (const play of period) {
      for (const s of play.ann!.screens.filter((x) => x.kind === "pick")) {
        const t = actionTable(play, season, sample, { kind: "screen", s });
        expect(t).not.toBeNull();
        expect(t!.cols).toEqual([{ label: "PPP", count: "Chances" }]);
        expect(t!.rows.some((r) => r.k === "All Handlers")).toBe(true);
        for (const r of t!.rows) expect(Number(r.cells[0]!.v)).toBeGreaterThanOrEqual(0);
        seen++;
      }
    }
    expect(seen).toBeGreaterThan(5);
  });

  it("cover drives, closeouts, post-ups and isolations", () => {
    const all = plays.slice(0, 400);
    let drives = 0, solos = 0;
    for (const play of period) {
      for (const d of play.ann!.drives) if (actionTable(play, season, sample, { kind: "drive", d })) drives++;
    }
    for (const file of [...new Set(all.map((r) => r.file))].slice(0, 4)) {
      for (const row of plays.filter((r) => r.file === file)) {
        const play = loadPlay(row);
        for (const s of play.ann!.solos ?? []) {
          const t = actionTable(play, season, sample, { kind: "solo", s });
          expect(t?.rows.length).toBeGreaterThan(0);
          solos++;
        }
      }
    }
    expect(drives).toBeGreaterThan(5);
    expect(solos).toBeGreaterThan(0);
  });
});

describe("shot card pass line", () => {
  it("names the passer on assist chances, made or missed", () => {
    const shots = period.flatMap((play) => play.ann!.shots.map((shot) => ({ play, shot })));
    let missed = 0;
    for (const { play, shot } of shots) {
      const v = passLine(play, shot).v;
      if (shot.passer != null && (shot.assisted || shot.ao)) {
        expect(v).not.toBe("Unassisted");
        if (!shot.made) { expect(v).toMatch(/^From .+ \(Potential Assist\)$/); missed++; }
      } else expect(v).toBe("Unassisted");
    }
    expect(missed).toBeGreaterThan(0);
  });
});
