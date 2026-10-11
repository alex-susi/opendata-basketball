// Decodes one play from a period's binary file. No DOM or fetch here, so tests can run it in Node.
// Layout is documented at the top of web/scripts/export_data.R.

import type { Epv, OptionPrices, Play, PlayHeader, Role, Series, TeamColors } from "./types";

const NULL16 = -32768;
// Colours for a play exported before team colours existed: the blue offense and orange defense used until then.
const PLAIN_COLORS: Record<Role, TeamColors> = {
  off: { fill: "#1F6FE5", edge: "#FFFFFF", ink: "#FFFFFF", text: "#4C9AFF", mark: "#1F6FE5" },
  def: { fill: "#F26A36", edge: "#FFFFFF", ink: "#FFFFFF", text: "#FF8552", mark: "#F26A36" },
};

/** A cursor over consecutive int16 blocks that turns each block into scaled float64 values. */
function reader16(values: Int16Array) {
  let at = 0;
  return (length: number, scale: number): Series => {
    const out = new Float64Array(length);
    for (let i = 0; i < length; i++) {
      const raw = values[at + i];
      out[i] = raw === NULL16 ? NaN : raw / scale;
    }
    at += length;
    return out;
  };
}

export function decodePlay(buffer: ArrayBuffer, h: PlayHeader): Play {
  const { n, m } = h;
  const players = h.players.length;
  const priced = h.priced.length;
  const count32 = n + 3 * m;
  const count16 = 5 * n + 2 * n * players + 6 * m + 3 * m * priced;
  const i32 = new Int32Array(buffer, h.o, count32);
  const next = reader16(new Int16Array(buffer, h.o + 4 * count32, count16));
  const u8 = new Uint8Array(buffer, h.o + 4 * count32 + 2 * count16, n + n * players);

  const gc = next(n, 10);
  const sc = next(n, 10);
  const ball = { x: next(n, 100), y: next(n, 100), z: next(n, 100) };
  const tracks = h.players.map((info, k) => ({
    ...info,
    x: next(n, 100),
    y: next(n, 100),
    d: u8.subarray(n * (k + 1), n * (k + 2)),
  }));

  let epv: Epv | null = null;
  if (m > 0) {
    const v = next(m, 1000);
    const shot = next(m, 1000);
    const pass = next(m, 1000);
    const haz = next(m, 10000);
    const rop = next(m, 10000);
    const cum = next(m, 10000);
    const options = new Map<number, OptionPrices>();
    for (const pid of h.priced) options.set(pid, { sv: next(m, 1000), pv: next(m, 1000), tov: next(m, 10000) });
    epv = {
      f: i32.subarray(n, n + m),
      to: i32.subarray(n + m, n + 2 * m),
      holder: i32.subarray(n + 2 * m, n + 3 * m),
      v, shot, pass, haz, rop, cum,
      players: options,
    };
  }

  return {
    id: h.id, game: h.game, period: h.period, off: h.off, def: h.def, home: h.home, away: h.away,
    homeScore: h.homeScore, awayScore: h.awayScore, result: h.result, who: h.who, types: h.types,
    colors: h.colors ?? PLAIN_COLORS, events: h.events, touches: h.touches,
    frames: i32.subarray(0, n), gc, sc, stopped: u8.subarray(0, n), ball, players: tracks, epv, shots: h.shots ?? [],
  };
}
