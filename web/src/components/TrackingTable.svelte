<script lang="ts">
  // The trace panel's Players tab: the ten players on court at the current frame, one table per team, with each
  // player's speed, the distance he has covered in this play, his minutes played entering the chance, his distance
  // to the nearest opponent and whether he is in the paint; over each table the team's spacing (mean distance
  // between its players on court) and, for the defense, the rim protector. Speeds and distances are smoothed
  // tracking (lib/motion.ts). Hovering a row rings the player on the court; clicking it follows his nearest
  // opponent in the Nearest Opponent tab.
  import { minutesAt, nameOf } from "../lib/context";
  import { motion, spacing } from "../lib/motion";
  import type { Play, PlayerTrack, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play }: { play: Play } = $props();

  const i = $derived(Math.min(live.i0, play.frames.length - 1));
  const moved = $derived(motion(play));
  const spaced = $derived(spacing(play, i));
  const minutes = $derived(play.ann ? minutesAt(play, play.frames[i]) : null);
  const here = (p: PlayerTrack) => !Number.isNaN(p.x[i]);

  function nearest(p: PlayerTrack): { d: number; opp: PlayerTrack } | null {
    let best: { d: number; opp: PlayerTrack } | null = null;
    for (const q of play.players) {
      if (q.role === p.role || !here(q)) continue;
      const d = Math.hypot(q.x[i] - p.x[i], q.y[i] - p.y[i]);
      if (!best || d < best.d) best = { d, opp: q };
    }
    return best;
  }

  const rows = (role: Role) => play.players.filter((p) => p.role === role && here(p)).map((p) => {
    const at = play.players.indexOf(p);
    return { p, speed: moved.speed[at][i], covered: moved.covered[at][i], min: minutes?.get(p.id), near: nearest(p),
             paint: spaced.paint[role].includes(p.id) };
  });
  const fixed = (v: number | null | undefined, d = 1) => (v == null || Number.isNaN(v) ? "–" : v.toFixed(d));

  function follow(id: number): void {
    viewer.focusPid = id;
    viewer.trace = "nearest";
  }
</script>

<div class="track-tables">
  {#each ["off", "def"] as const as role (role)}
    {@const kit = play.colors[role]}
    {@const list = rows(role)}
    <div class="track-team">
      <div class="track-head">
        <b style:color={kit.text}>{role === "off" ? play.off : play.def}</b>
        <span>
          Spacing {fixed(spaced.spread[role])} ft · {spaced.paint[role].length} in paint
          {#if role === "def" && spaced.rim} · Rim {nameOf(play, spaced.rim.pid)} {spaced.rim.dist.toFixed(1)} ft{/if}
        </span>
      </div>
      <table>
        <thead>
          <tr>
            <th class="name">Player</th><th title="Smoothed speed now, ft/s">Speed</th>
            <th title="Distance covered in this play so far, ft">Covered</th>
            <th title="Minutes played entering this chance">Min</th>
            <th title="Distance to the nearest player of the other team (ft), and who he is">Nearest Opp.</th>
            <th title="In the paint">Paint</th>
          </tr>
          <tr class="units"><th></th><th>ft/s</th><th>ft</th><th></th><th>ft</th><th></th></tr>
        </thead>
        <tbody>
          {#each list as r (r.p.id)}
            <tr class:has-ball={live.handler === r.p.id} onmouseenter={() => (viewer.hoverPid = r.p.id)}
                onmouseleave={() => (viewer.hoverPid = null)} onclick={() => follow(r.p.id)}
                title="Click to follow his distance to the nearest opponent">
              <td class="name"><span class="num" style:background={kit.fill} style:color={kit.ink}>{r.p.jersey}</span>{r.p.name}</td>
              <td>{fixed(r.speed)}</td>
              <td>{fixed(r.covered, 0)}</td>
              <td>{fixed(r.min)}</td>
              <td>{#if r.near}{r.near.d.toFixed(1)} <span class="opp" style:color={play.colors[r.near.opp.role].text}>#{r.near.opp.jersey}</span>{:else}–{/if}</td>
              <td>{#if r.paint}<span class="paint-dot" style:background={kit.fill} title="In the paint"></span>{/if}</td>
            </tr>
          {/each}
          {#if !list.length}<tr><td colspan="6" class="empty">Not tracked at this moment.</td></tr>{/if}
        </tbody>
      </table>
    </div>
  {/each}
</div>
