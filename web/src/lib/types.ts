// Shapes of every file written by web/scripts/export_data.R, and of a decoded play.

export interface Option {
  value: string;
  label: string;
}

/** meta.json: the filter choices exactly as the Shiny inputs list them. */
export interface Meta {
  generated: string;
  plays: number;
  files: number;
  game: Option[];
  team: Option[];
  player: Option[];
  period: Option[];
  types: Option[];
  result: Option[];
  shotType: Option[];
}

/** plays.json: one possession's list text plus the fields the filters read. */
export interface PlayRow {
  id: string;
  file: string;
  gameId: number;
  game: string;
  q: number;
  clock: string;
  off: string;
  def: string;
  secs: number;
  result: string;
  who: string;
  typeLabels: string;
  types: string[];
  shotTypes: string[];
  offTeam: number;
  defTeam: number;
  offIds: number[];
  defIds: number[];
  actors: [string, number][];
}

export type Role = "off" | "def";

export interface PlayerInfo {
  id: number;
  jersey: string;
  name: string;
  last: string;
  role: Role;
}

export interface PlayEvent {
  f: number;
  kind: string;
  label: string;
  short: string | null;
  who: string | null;
}

export interface Touch {
  pid: number;
  f0: number;
  f1: number;
}

/** One play's entry in g<game>_p<period>.json. `o` is its byte offset in the matching .bin file. */
export interface PlayHeader {
  id: string;
  o: number;
  n: number;
  m: number;
  game: string;
  period: number;
  off: string;
  def: string;
  home: string;
  away: string;
  homeScore: number;
  awayScore: number;
  result: string;
  who: string;
  types: string[];
  players: PlayerInfo[];
  priced: number[];
  events: PlayEvent[];
  touches: Touch[];
}

export interface PeriodIndex {
  bytes: number;
  plays: Record<string, PlayHeader>;
}

/** A per-frame series. NaN stands for a missing value (JSON null in the Shiny payload). */
export type Series = Float64Array;

export interface PlayerTrack extends PlayerInfo {
  x: Series;
  y: Series;
  d: Uint8Array;
}

export interface OptionPrices {
  sv: Series;
  pv: Series;
  tov: Series;
}

/** EPV prices on the pricing grid (about every third frame). */
export interface Epv {
  f: Int32Array;
  to: Int32Array;
  holder: Int32Array;
  v: Series;
  shot: Series;
  pass: Series;
  haz: Series;
  rop: Series;
  cum: Series;
  players: Map<number, OptionPrices>;
}

/** Everything needed to animate one possession: the Shiny app's "play" message, decoded. */
export interface Play extends Omit<PlayHeader, "players" | "o" | "n" | "m" | "priced"> {
  frames: Int32Array;
  gc: Series;
  sc: Series;
  stopped: Uint8Array;
  ball: { x: Series; y: Series; z: Series };
  players: PlayerTrack[];
  epv: Epv | null;
}
