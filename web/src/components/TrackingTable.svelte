<script lang="ts" module>
  export type TrackGroup = "movement" | "position" | "ball" | "all";
  /** The column groups, picked in the trace panel's header (TracePanel.svelte). */
  export const TRACK_GROUPS: { key: TrackGroup; label: string }[] = [
    { key: "movement", label: "Movement" }, { key: "position", label: "Position" }, { key: "ball", label: "Ball" }, { key: "all", label: "All" },
  ];
</script>

<script lang="ts">
  // The trace panel's Player Tracking tab: the ten players on court at the current frame in one table, the offense's
  // five then the defense's, each under a heading row with the team's spacing (mean distance between its players on
  // court), its players in the paint and, for the defense, the rim protector. An orange dot marks the ball handler.
  // The columns come in three groups, picked in the panel's header (All shows every column and scrolls sideways):
  //   Movement  speed, acceleration, speed toward the basket and across it, top speed so far and distance covered
  //             (smoothed tracking, lib/motion.ts)
  //   Position  court region (lib/regions.ts), distance to the basket, in the paint, the nearest opponent and how
  //             that gap changed over the last second, a contest level for the offense from that gap
  //             (lib/regions.ts), and the matchup: the defender assigned to an offensive player, or the player a
  //             defender is assigned to (matchups table), with the gap between them
  //   Ball      minutes played entering the chance, and this possession's touches, dribbles and seconds on the ball
  // "The basket" is the one the offense attacks, which the defense defends. Hovering a row rings the player on the
  // court; clicking it follows his nearest opponent in the Nearest Opponent tab.
  import { CONTEST_COLORS, minutesAt, nameOf, ownChances, regionName, titleCase } from "../lib/context";
  import { HOOP_X } from "../lib/court";
  import { accelAt, motion, spacing } from "../lib/motion";
  import { contestOf, courtRegion } from "../lib/regions";
  import type { Play, PlayerTrack, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play }: { play: Play } = $props();

  interface Column { key: string; head: string; unit?: string; title: string; group: Exclude<TrackGroup, "all">; left?: boolean }
  const COLUMNS: Column[] = [
    { key: "speed", head: "Speed", unit: "ft/s", title: "Smoothed speed now", group: "movement" },
    { key: "accel", head: "Acceleration", unit: "ft/s²", title: "Change in smoothed speed over 0.4 s; negative while slowing down", group: "movement" },
    { key: "toward", head: "Toward Basket", unit: "ft/s", title: "Speed toward the basket (negative: away from it)", group: "movement" },
    { key: "across", head: "Sideways", unit: "ft/s", title: "Speed across the line to the basket", group: "movement" },
    { key: "top", head: "Top Speed", unit: "ft/s", title: "Fastest smoothed speed so far in this play", group: "movement" },
    { key: "covered", head: "Distance Covered", unit: "ft", title: "Distance covered so far in this play", group: "movement" },
    { key: "region", head: "Court Region", title: "Where he stands, in SkillCorner's regions", group: "position", left: true },
    { key: "hoop", head: "To Basket", unit: "ft", title: "Distance to the basket the offense attacks", group: "position" },
    { key: "paint", head: "In Paint", title: "In the paint", group: "position" },
    { key: "near", head: "Nearest Opp.", unit: "ft", title: "Distance to the nearest player of the other team, and who he is", group: "position" },
    { key: "sep", head: "Separation Change, 1 s", unit: "ft", title: "How the gap to the nearest opponent changed over the last second (positive: more space)", group: "position" },
    { key: "contest", head: "Contest", title: "Offense only: a contest level from the nearest defender's distance (under 3.5 ft plus, 3.5-5.5 average, 5.5-6.5 light, else open), a stand-in for SkillCorner's shot contest levels", group: "position" },
    { key: "match", head: "Matchup", unit: "ft", title: "The defender assigned to him (offense) or the player he is assigned to (defense), and the gap between them", group: "position" },
    { key: "min", head: "Minutes Played", title: "Minutes played entering this chance", group: "ball" },
    { key: "touches", head: "Touches", title: "Touches this possession so far", group: "ball" },
    { key: "dribbles", head: "Dribbles", title: "Dribbles this possession so far", group: "ball" },
    { key: "ballTime", head: "Time on Ball", unit: "s", title: "Seconds with the ball this possession so far", group: "ball" },
  ];
  const shown = $derived(viewer.trackCols === "all" ? COLUMNS : COLUMNS.filter((c) => c.group === viewer.trackCols));

  const i = $derived(Math.min(live.i0, play.frames.length - 1));
  const frame = $derived(play.frames[i]);
  const moved = $derived(motion(play));
  const spaced = $derived(spacing(play, i));
  const minutes = $derived(play.ann ? minutesAt(play, frame) : null);
  const start = $derived(ownChances(play)[0]?.f ?? play.frames[0]);
  const here = (p: PlayerTrack, j: number) => !Number.isNaN(p.x[j]);

  function nearest(p: PlayerTrack, j: number): { d: number; opp: PlayerTrack } | null {
    if (!here(p, j)) return null;
    let best: { d: number; opp: PlayerTrack } | null = null;
    for (const q of play.players) {
      if (q.role === p.role || !here(q, j)) continue;
      const d = Math.hypot(q.x[j] - p.x[j], q.y[j] - p.y[j]);
      if (!best || d < best.d) best = { d, opp: q };
    }
    return best;
  }

  // The player he is matched with now: his assigned defender (offense) or the man he guards (defense).
  function matchOf(p: PlayerTrack): PlayerTrack | null {
    const m = (play.ann?.matchups ?? []).find((r) => r.f <= frame && frame <= r.f1 && (p.role === "off" ? r.off : r.def) === p.id);
    const other = m ? (p.role === "off" ? m.def : m.off) : null;
    return play.players.find((q) => q.id === other) ?? null;
  }

  interface Cell { v: string; tone?: string; tag?: string; tagTone?: string; dot?: string }
  interface Row { p: PlayerTrack; cells: Record<string, Cell> }

  function fixed(v: number | null | undefined, d = 1): string {
    if (v == null || Number.isNaN(v)) return "–";
    const out = v.toFixed(d);
    return Number(out) === 0 ? (0).toFixed(d) : out;   // no "-0.0"
  }
  const signed = (v: number) => { const t = fixed(v); return Number(t) > 0 ? `+${t}` : t; };
  const tagged = (d: number | null, q: PlayerTrack): Cell => ({ v: fixed(d), tag: `#${q.jersey}`, tagTone: play.colors[q.role].text });

  function rowOf(p: PlayerTrack, role: Role): Row {
    const at = play.players.indexOf(p), kit = play.colors[role];
    const x = p.x[i], y = p.y[i], toHoop = Math.hypot(HOOP_X - x, y);
    const vx = moved.vx[at][i], vy = moved.vy[at][i];
    const ux = (HOOP_X - x) / toHoop, uy = -y / toHoop;
    const near = nearest(p, i);
    const back = i >= 25 && play.frames[i] - play.frames[i - 25] === 25 ? nearest(p, i - 25) : null;
    const match = matchOf(p);
    const matchGap = match && here(match, i) ? Math.hypot(match.x[i] - x, match.y[i] - y) : null;
    const touches = play.touches.filter((t) => t.pid === p.id && t.f1 >= start && t.f0 <= frame);
    const ballTime = touches.reduce((s, t) => s + Math.max(0, Math.min(frame, t.f1) - Math.max(start, t.f0)), 0) / 25;
    const dribbles = (play.ann?.dribbles ?? []).filter((d) => d.pid === p.id && d.f >= start && d.f <= frame).length;
    const level = role === "off" && near ? contestOf(near.d) : null;
    return {
      p,
      cells: {
        speed: { v: fixed(moved.speed[at][i]) },
        accel: { v: fixed(accelAt(play, moved.speed[at], i)) },
        toward: { v: fixed(vx * ux + vy * uy) },
        across: { v: fixed(Math.abs(vx * uy - vy * ux)) },
        top: { v: fixed(moved.top[at][i]) },
        covered: { v: fixed(moved.covered[at][i], 0) },
        region: { v: regionName(courtRegion(x, y)) },
        hoop: { v: fixed(toHoop) },
        paint: { v: "", dot: spaced.paint[role].includes(p.id) ? kit.fill : undefined },
        near: near ? tagged(near.d, near.opp) : { v: "–" },
        sep: { v: near && back ? signed(near.d - back.d) : "–" },
        contest: level ? { v: titleCase(level), tone: CONTEST_COLORS[level] } : { v: "–" },
        match: match ? tagged(matchGap, match) : { v: "–" },
        min: { v: fixed(minutes?.get(p.id)) },
        touches: { v: String(touches.length) },
        dribbles: { v: String(dribbles) },
        ballTime: { v: ballTime.toFixed(1) },
      },
    };
  }

  const rows = (role: Role) => play.players.filter((p) => p.role === role && here(p, i)).map((p) => rowOf(p, role));

  function follow(id: number): void {
    viewer.focusPid = id;
    viewer.trace = "nearest";
  }
</script>

<div class="track-scroll">
  <table class="track-table">
    <thead>
      <tr>
        <th class="name">Player</th>
        {#each shown as c (c.key)}
          {@const words = c.head.split(" ")}
          <th class:al={c.left} title={c.title}>{words.slice(0, -1).join(" ")}{words.length > 1 ? " " : ""}<span class="keep">{words.at(-1)}{#if c.unit}&nbsp;({c.unit}){/if}</span></th>
        {/each}
      </tr>
    </thead>
    {#each ["off", "def"] as const as role (role)}
      {@const kit = play.colors[role]}
      {@const list = rows(role)}
      <tbody>
        <tr class="group">
          <td colspan={shown.length + 1}>
            <b style:color={kit.text}>{role === "off" ? play.off : play.def}</b>
            <span>{role === "off" ? "Offense" : "Defense"} · Spacing {fixed(spaced.spread[role])} ft · {spaced.paint[role].length} in paint{#if role === "def" && spaced.rim}{" · "}Rim protector {nameOf(play, spaced.rim.pid)} {spaced.rim.dist.toFixed(1)} ft{/if}</span>
          </td>
        </tr>
        {#each list as r (r.p.id)}
          <tr class="player" class:has-ball={live.handler === r.p.id} onmouseenter={() => (viewer.hoverPid = r.p.id)}
              onmouseleave={() => (viewer.hoverPid = null)} onclick={() => follow(r.p.id)}
              title="Click to follow his distance to the nearest opponent">
            <td class="name"><span class="num" style:background={kit.fill} style:color={kit.ink}>{r.p.jersey}</span>{r.p.name}{#if live.handler === r.p.id}<span class="ball-dot" title="Has the ball"></span>{/if}</td>
            {#each shown as c (c.key)}
              {@const cell = r.cells[c.key]}
              <td class:al={c.left} style:color={cell.tone}>
                {#if cell.dot}<span class="paint-dot" style:background={cell.dot} title="In the paint"></span>{:else}{cell.v}{#if cell.tag}&nbsp;<span class="opp" style:color={cell.tagTone}>{cell.tag}</span>{/if}{/if}
              </td>
            {/each}
          </tr>
        {/each}
        {#if !list.length}<tr><td colspan={shown.length + 1} class="empty">Not tracked at this moment.</td></tr>{/if}
      </tbody>
    {/each}
  </table>
</div>
