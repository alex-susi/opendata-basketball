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

/** A player's playstyle archetype on the side of the ball he is on in this play (built by src/archetypes/). */
export interface Archetype {
  name: string;
  /** Short label for the roster tag. */
  short: string;
  /** Colour slot: `--arch-<slot>` in app.css. */
  slot: string;
  /** Probability that he belongs to this archetype. */
  p: number;
}

export interface PlayerInfo {
  id: number;
  jersey: string;
  name: string;
  last: string;
  role: Role;
  arch: Archetype | null;
}

/** How one team is drawn, from its club colours (TEAM_COLORS and team_kit() in the Shiny app's R/data.R). */
export interface TeamColors {
  /** Primary colour: player dots and hull. */
  fill: string;
  /** Secondary colour: the ring around a dot. */
  edge: string;
  /** Number on a dot. */
  ink: string;
  /** Team name on the dark panels. */
  text: string;
  /** Outlines drawn on the floor. */
  mark: string;
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

/** The steps behind one tracked shot's xFG at its release (explain_xfg() in src/epv/R/models.R). */
export interface ShotSteps {
  /** Release frame. */
  f: number;
  pid: number;
  made: boolean;
  fouled: boolean;
  three: boolean;
  /** The kind of shot: jump shots are split into midrange and three. */
  zone: "rim" | "mid" | "three";
  /** Which context model priced it. */
  model: "rim" | "jump";
  /** Feet from the hoop. */
  dist: number;
  /** Trees in that context model; 0 means only fixed effects move xFG from the baseline. */
  rounds: number;
  /** The model's xFG for an average shot of this kind: where the effects start from. */
  base: number;
  /** Features whose effect includes one set from the season aggregates, not fitted (null if none). */
  fixed: Record<string, boolean> | null;
  xfg: number;
  /** Each input of the shot's context model at release, by its name in the model; null where it was not measured. */
  v: Record<string, number | null>;
  /** What each feature adds to xFG. The effects sum to xfg - base. */
  e: Record<string, number | null>;
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
  colors: Record<Role, TeamColors>;
  /** The offense attacks the camera's left hoop. Positions are stored rotated so the offense attacks +x; the
   * viewer rotates them back to the camera's view. Missing from older exports (drawn as stored). */
  leftHoop?: boolean;
  players: PlayerInfo[];
  priced: number[];
  events: PlayEvent[];
  touches: Touch[];
  /** Missing from exports made before shots were priced one by one. */
  shots?: ShotSteps[];
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
export interface Play extends Omit<PlayHeader, "players" | "o" | "n" | "m" | "priced" | "shots"> {
  frames: Int32Array;
  gc: Series;
  sc: Series;
  stopped: Uint8Array;
  ball: { x: Series; y: Series; z: Series };
  players: PlayerTrack[];
  epv: Epv | null;
  /** Tracked shots of the possession in order of release. */
  shots: ShotSteps[];
}
