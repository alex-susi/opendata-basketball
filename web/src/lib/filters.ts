// The sidebar filters. Pure, so the parity test can run it in Node against the Shiny server's results.

import type { PlayRow } from "./types";

export interface FilterState {
  game: string[];
  period: string[];
  result: string[];
  shotType: string[];
  types: string[];
  typesMode: "any" | "all";
  team: string[];
  teamSide: "any" | "off" | "def";
  player: string;
  playerRole: "any" | "off" | "def" | "actor";
}

export function emptyFilters(): FilterState {
  return { game: [], period: [], result: [], shotType: [], types: [], typesMode: "any", team: [], teamSide: "any",
           player: "", playerRole: "any" };
}

// R: filter_plays() in src/play_viewer/R/data.R. Checks run in the same order; an empty selection means
// "no restriction", exactly as length(f[["..."]]) == 0 does there.
export function filterPlays(plays: PlayRow[], f: FilterState): PlayRow[] {
  const games = f.game.map(Number), periods = f.period.map(Number), teams = f.team.map(Number);
  const player = f.player === "" ? null : Number(f.player);
  return plays.filter((p) => {
    if (games.length && !games.includes(p.gameId)) return false;
    if (periods.length && !periods.includes(p.q)) return false;
    if (f.result.length && !f.result.includes(p.result)) return false;
    if (f.shotType.length && !p.shotTypes.some((s) => f.shotType.includes(s))) return false;
    if (f.types.length) {
      const ok = f.typesMode === "all" ? f.types.every((t) => p.types.includes(t)) : p.types.some((t) => f.types.includes(t));
      if (!ok) return false;
    }
    if (teams.length) {
      const onOff = teams.includes(p.offTeam), onDef = teams.includes(p.defTeam);
      if (!(f.teamSide === "off" ? onOff : f.teamSide === "def" ? onDef : onOff || onDef)) return false;
    }
    if (player !== null) {
      const onOff = p.offIds.includes(player), onDef = p.defIds.includes(player);
      // "In the action": named in an action event of a selected play type, or of any type (shots included) when none is selected.
      const acted = p.actors.some(([type, pid]) => pid === player && (!f.types.length || f.types.includes(type)));
      const ok = f.playerRole === "off" ? onOff : f.playerRole === "def" ? onDef : f.playerRole === "actor" ? acted : onOff || onDef;
      if (!ok) return false;
    }
    return true;
  });
}
