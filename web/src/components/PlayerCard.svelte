<script lang="ts">
  // The card beside a roster row: one player's figures in four views (Basic, Advanced, Tracking, Actions), from the
  // season aggregates and the ten tracked games (lib/player.ts). It stays open while the pointer is on it, and while
  // pinned (clicking the row); the × closes a pinned card.
  import StatTable from "./StatTable.svelte";
  import { CARD_VIEWS, playerSections } from "../lib/player";
  import type { PlayerTrack } from "../lib/types";
  import { season, viewer } from "../lib/viewer.svelte";

  let { p, team, top, right, pinned, onenter, onleave, onclose }: {
    p: PlayerTrack; team: string; top: number; right: number; pinned: boolean;
    onenter: () => void; onleave: () => void; onclose: () => void;
  } = $props();

  let h = $state(0);
  // Level with the row, but kept inside the window.
  const y = $derived(Math.max(8, Math.min(top, window.innerHeight - h - 8)));
  const sections = $derived(playerSections(viewer.cardView, season.data, season.sample, p));
  const games = $derived(season.sample?.games ?? 10);
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="season-card player-card" class:pinned style:top="{y}px" style:right="{right}px" bind:clientHeight={h}
     onmouseenter={onenter} onmouseleave={onleave}>
  <div class="pc-head">
    <b>#{p.jersey} {p.name}</b>
    {#if pinned}<button type="button" class="pc-close" aria-label="Close the card" title="Close (or click his row again)" onclick={onclose}>×</button>{/if}
  </div>
  <span class="season-sub">{team} · {p.role === "off" ? "offense" : "defense"} in this play</span>
  <div class="seg pc-views" role="radiogroup" aria-label="Figures shown">
    {#each CARD_VIEWS as v (v.key)}
      <button type="button" role="radio" aria-checked={viewer.cardView === v.key} class:on={viewer.cardView === v.key}
              onclick={() => (viewer.cardView = v.key)}>{v.label}</button>
    {/each}
  </div>
  {#if !season.data && !season.sample}
    <span class="pc-empty">Loading…</span>
  {:else if sections.length}
    <StatTable {sections} />
  {:else}
    <span class="pc-empty">No figures for this view.</span>
  {/if}
  <p class="pc-foot">
    <b>Season</b>: the aggregates over 293 games, offense only (shots, drives, picks).
    <b>Tracked</b>: the {games} games in this viewer, with this team. Hover a row's name for its definition.
  </p>
</div>
