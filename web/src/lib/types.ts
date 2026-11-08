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
  /** Club colours by team id: primary, then secondary (TEAM_COLORS in the Shiny app's R/data.R). */
  teamColors?: Record<string, [string, string]>;
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
  /** The possession's last shot was made while fouled: shown as the make (result) with an And-1 tag. */
  and1?: boolean;
  typeLabels: string;
  types: string[];
  shotTypes: string[];
  offTeam: number;
  defTeam: number;
  offIds: number[];
  defIds: number[];
  actors: [string, number][];
  /** Offensive rebounds a player collected in the possession (team rebounds are not counted). */
  oreb: number;
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
  /** Canonical person id (data/player_id_aliases.csv) and team id, for the season figures. */
  canon?: number;
  team?: number;
}

/** How one team is drawn, from its club colours (TEAM_COLORS and team_kit() in the Shiny app's R/data.R). */
export interface TeamColors {
  /** Primary colour: player dots and hull. */
  fill: string;
  /** Secondary colour: the glow round the ball handler, the ring round a selected player. */
  edge: string;
  /** Number on a dot (set on decoding: white, or dark on a light primary). */
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

/** One play's entry in g<game>_p<period>.json. `o` is its byte offset in the matching .bin file. */
export interface PlayHeader {
  id: string;
  o: number;
  n: number;
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
  and1?: boolean;
  types: string[];
  colors: Record<Role, TeamColors>;
  /** The offense attacks the camera's left hoop. Positions are stored top-down (the camera at the bottom) and
   * rotated so the offense attacks +x; the viewer rotates them back to the camera's view, matching the broadcast.
   * Missing from older exports (drawn as stored). */
  leftHoop?: boolean;
  players: PlayerInfo[];
  events: PlayEvent[];
  touches: Touch[];
  /** How the possession began (possessions.startType) and the teams' ids. */
  startType?: string;
  offTeam?: number;
  defTeam?: number;
  homeTeam?: number;
  /** Event locations and context drawn over the court. Missing from older exports. */
  ann?: Annotations;
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
  /** 1 where the position was detected on screen, 0 where it was extrapolated. */
  d: Uint8Array;
  /** Tracking's expected error of the position, in ft (NaN where unknown). */
  e: Series;
}

/** Everything needed to animate one possession: the Shiny app's "play" message, decoded. */
export interface Play extends Omit<PlayHeader, "players" | "o" | "n"> {
  frames: Int32Array;
  gc: Series;
  sc: Series;
  stopped: Uint8Array;
  ball: { x: Series; y: Series; z: Series };
  players: PlayerTrack[];
}

// ---- annotations (web/scripts/annotations.R) ----------------------------------------------------
// Locations are in the play's stored frame (offense attacking +x), in feet. Ids are the game's raw player ids, as
// in the tracking. Optional fields are missing where the event table has no value.

/** A player's position at a shot's release (chance_players.shotLoc). */
export interface Ghost { pid: number; x: number; y: number }

export interface AnnShot {
  /** Release frame and the shot's end frame. */
  f: number; f1: number;
  x: number; y: number;
  pid: number;
  made: boolean; three: boolean; fouled: boolean; blocked: boolean; assisted: boolean;
  /** SkillCorner's assist opportunity: assisted, or shot within 3 s of catching a pass (made or missed). */
  ao?: boolean;
  blocker?: number;
  /** Shooter to hoop at release, ft. */
  dist?: number;
  /** SkillCorner's shot quality, 0-100. */
  sq?: number;
  /** Contest level: open, light, average, plus, blocked. */
  cl?: string;
  defId?: number; defDist?: number;
  /** Seconds from the start of the touch to release. */
  rt?: number;
  drb?: number;
  cns?: boolean;
  /** complexShotType, camelCase. */
  type?: string;
  sc?: number;
  passer?: number;
  region?: string;
  /** Free throws awarded on the shot, made or missed, in order. */
  ft: boolean[];
  ghosts: Ghost[];
}

export interface AnnPass {
  f: number; f1: number; pid: number;
  to?: number;
  /** The defender who intercepted it (passes.toReceiverId). */
  stealer?: number;
  x0?: number; y0?: number; x1?: number; y1?: number;
  lost: boolean;
}

export interface AnnDribble { f: number; pid: number; x: number; y: number }

export interface AnnDrive {
  f: number; f1: number; pid: number; def?: number;
  x0: number; y0: number; x1: number; y1: number;
  blowby: boolean; dir?: string; end?: string;
  /** How the drive was created: pick, handoff, offBallScreen, iso, closeout, miscellaneous. */
  cat?: string;
}

/** A post-up or an isolation: who, when and his defender. */
export interface AnnSolo { kind: "post" | "isolation"; f: number; pid: number; def?: number; section?: string }

export interface AnnScreen {
  f: number;
  kind: "pick" | "handoff" | "off_ball_screen";
  /** The screener's (setter's) spot. */
  x: number; y: number;
  scr: number;
  /** The ball handler, receiver or cutter. */
  use: number;
  /** Coverage on the user (bhrDefType, receiverDefType, cutterDefType) and on the screener. */
  covUse?: string; covScr?: string;
  spot?: string;
}

export interface AnnCloseout {
  f: number; f1: number; def: number; pid: number;
  /** The defender's path. */
  x0: number; y0: number; x1: number; y1: number;
  /** Ball handler to defender at the start and end, ft. */
  d0: number; d1: number;
  /** What the ball handler did after the catch: shot, drive, pass, other. */
  act?: string;
}

export interface AnnFoul { f: number; x?: number; y?: number; by: number; on?: number; shooting: boolean; type?: string; ft: boolean[] }
export interface AnnRebound { f: number; x?: number; y?: number; pid?: number; def: boolean; team: boolean }
export interface AnnTurnover { f: number; x?: number; y?: number; pid?: number; stealer?: number }
export interface AnnMatchup { f: number; f1: number; def: number; off: number }

export interface AnnChance {
  id: string;
  /** The possession it belongs to (a play's id). A play's window can reach into the next possession's chances. */
  poss: string;
  f: number; f1: number;
  start?: string; transition: boolean;
  /** Tracking quality, 0 (lowest) to 5. */
  q?: number;
  pts?: number;
  /** Minutes each player had played entering the chance. */
  mins: { pid: number; min: number }[];
}

export interface Annotations {
  shots: AnnShot[]; passes: AnnPass[]; dribbles: AnnDribble[]; drives: AnnDrive[]; screens: AnnScreen[];
  closeouts: AnnCloseout[]; solos?: AnnSolo[]; fouls: AnnFoul[]; rebounds: AnnRebound[]; turnovers: AnnTurnover[];
  matchups: AnnMatchup[]; chances: AnnChance[];
}

/** season.json: one person's season counts with one team, from data/aggregates/. Pairs are [count, makes or
 * points]; fg, cns and od are [attempts, makes, threes made]; drives are [drives, successful, points]. */
export interface SeasonFigures {
  g?: number;
  /** Offensive possessions on court. */
  poss?: number;
  /** Points, free throws included. */
  pts?: number;
  /** [attempts, makes] */
  fg3?: [number, number];
  ft?: [number, number];
  /** Made field goals assisted by a teammate. */
  astd?: number;
  fg?: [number, number, number];
  cns?: [number, number, number];
  od?: [number, number, number];
  zone?: Record<"ra" | "paint" | "mid" | "c3" | "ab3", [number, number]>;
  drives?: [number, number] | [number, number, number];
  handler?: [number, number];
  screener?: [number, number];
  handlerVs?: Record<string, [number, number]>;
  screenerVs?: Record<string, [number, number]>;
}

/** Points-per-action keys in sample.json: pick handler and screener, drive, handoff receiver, off-ball screen cutter
 * and screener, post-up, isolation, attacking a closeout. */
export type ActKey = "pickH" | "pickS" | "drive" | "handoff" | "obs" | "obsS" | "post" | "iso" | "closeout";

/** sample.json: one person with one team over the tracked games (web/scripts/sample_stats.R has the definitions).
 * Zone vectors are [FGA, makes, threes made, scored attempts, shot quality sum]. Action pairs are [count, points]. */
export interface SampleFigures {
  g: number; min: number; pts: number; fga: number; fgm: number; fg3a: number; fg3m: number; fta: number; ftm: number;
  oreb: number; dreb: number; ast: number; astd: number; stl: number; blk: number; tov: number; pf: number;
  offPoss: number; offPts: number; defPoss: number; defPts: number; plays: number; teamPlays: number;
  orebOpp: number; drebOpp: number;
  zone: Record<"rim" | "mid" | "three", [number, number, number, number, number]>;
  /** His FGA, the summed closest-defender distance on them, and how many were contested. */
  shotDef: [number, number, number];
  /** FGA where he was the closest defender: [attempts, makes, threes made]. */
  guard: [number, number, number];
  /** [touches, seconds on the ball, dribbles] */
  ball?: [number, number, number];
  trk?: {
    secs: number; dist: number; offSecs: number; offDist: number; defSecs: number; defDist: number; paint: number;
    top?: number;
    /** Nearest opponent, sampled every 0.2 s on offense (open) and defense (near): [samples, summed feet]. */
    open: [number, number]; near: [number, number];
  };
  acts?: Partial<Record<ActKey, [number, number]>>;
}

export interface Sample {
  games: number;
  players: Record<string, SampleFigures>;
  league: {
    zone: Record<"rim" | "mid" | "three", [number, number, number, number, number]>;
    acts: Partial<Record<ActKey, { all: [number, number]; by: Record<string, [number, number]> }>>;
  };
}
