<script lang="ts">
  // The card beside a roster row: one player's figures in five views (Basic, Advanced, Tracking, Actions,
  // Playstyle), from the season aggregates, the ten tracked games and the archetype model (lib/player.ts). Tinted
  // with his team's primary colour; the chosen view's button in its secondary colour. It stays open while the
  // pointer is on it, and while pinned (clicking the row); the × closes a pinned card.
  import StatTable from "./StatTable.svelte";
  import { CARD_VIEWS, playerSections, playstyleOf } from "../lib/player";
  import type { PlayerTrack, TeamColors } from "../lib/types";
  import { season, viewer } from "../lib/viewer.svelte";

  let { p, kit, top, right, pinned, onenter, onleave, onclose }: {
    p: PlayerTrack; kit: TeamColors; top: number; right: number; pinned: boolean;
    onenter: () => void; onleave: () => void; onclose: () => void;
  } = $props();

  let h = $state(0);
  // Level with the row, but kept inside the window.
  const y = $derived(Math.max(8, Math.min(top, window.innerHeight - h - 8)));
  const sections = $derived(viewer.cardView === "playstyle" ? [] : playerSections(viewer.cardView, season.data, season.sample, p));
  const style = $derived(viewer.cardView === "playstyle" ? playstyleOf(season.style, p) : []);
  const games = $derived(season.sample?.games ?? 10);

  // Dark or light text, whichever reads on the secondary colour.
  function inkOn(hex: string): string {
    const n = parseInt(hex.replace("#", "").padEnd(6, "0").slice(0, 6), 16);
    const lin = (c: number) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    const L = 0.2126 * lin((n >> 16) & 255) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
    return L > 0.4 ? "#0F1522" : "#FFFFFF";
  }
  const pctOf = (v: number) => `${Math.round(v * 100)}%`;
  const FULL = 2.5;   // a component score this far from 0 fills its half of the bar
  const barOf = (v: number) => Math.min(Math.abs(v) / FULL, 1) * 50;
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="season-card player-card" class:pinned style:top="{y}px" style:right="{right}px" bind:clientHeight={h}
     style:--team-fill={kit.fill} style:--team-edge={kit.edge} style:--team-edge-ink={inkOn(kit.edge)}
     onmouseenter={onenter} onmouseleave={onleave}>
  <div class="pc-head">
    <b>#{p.jersey} {p.name}</b>
    {#if pinned}<button type="button" class="pc-close" aria-label="Close the card" title="Close (or click his row again)" onclick={onclose}>×</button>{/if}
  </div>
  <div class="pc-views" role="radiogroup" aria-label="Figures shown">
    {#each CARD_VIEWS as v (v.key)}
      <button type="button" role="radio" aria-checked={viewer.cardView === v.key} class:on={viewer.cardView === v.key}
              onclick={() => (viewer.cardView = v.key)}>{v.label}</button>
    {/each}
  </div>
  {#if viewer.cardView === "playstyle"}
    {#if style.length}
      {#each style as side (side.side)}
        <div class="ps-side">
          <span class="stat-title">{side.title}</span>
          <div class="ps-arch">
            {#each side.archetypes.filter((a, i) => i < 4 && a.p >= 0.01) as a (a.name)}
              <span class="ps-name" class:top={a.name === side.top}>
                <i style:background={a.slot ? `var(--arch-${a.slot})` : "var(--muted)"}></i>{a.name}
              </span>
              <span class="ps-bar"><span style:width="{a.p * 100}%" style:background={a.slot ? `var(--arch-${a.slot})` : "var(--muted)"}></span></span>
              <span class="ps-pct">{pctOf(a.p)}</span>
            {/each}
          </div>
          <div class="ps-comps">
            {#each side.components as c (c.j)}
              <span class="ps-end minus" title={c.context}>{c.minus}</span>
              <span class="ps-axis" title={`Component ${c.j} (${Math.round(c.share * 100)}% of variance): ${c.context}`}>
                {#if c.score != null}
                  <span class="ps-fill" class:neg={c.score < 0} style:width="{barOf(c.score)}%" style:left="{c.score < 0 ? 50 - barOf(c.score) : 50}%"></span>
                {/if}
              </span>
              <span class="ps-end plus" title={c.context}>{c.plus}</span>
              <span class="ps-score">{c.score == null ? "–" : `${c.score > 0 ? "+" : ""}${c.score.toFixed(2)}`}</span>
            {/each}
          </div>
          {#if !side.defines}
            <p class="pc-foot">Not one of the players the model was fitted on (too few tracked chances or season shots): his archetype comes from the data he has.</p>
          {/if}
        </div>
      {/each}
      <p class="pc-foot">Archetype probabilities from the archetype model; component scores in standard deviations from the average fitted player, as on the Archetypes tab. Hover a component for what it measures.</p>
    {:else}
      <span class="pc-empty">{season.style ? "This player is not in the archetype model." : "Loading…"}</span>
    {/if}
  {:else if !season.data && !season.sample}
    <span class="pc-empty">Loading…</span>
  {:else if sections.length}
    <StatTable {sections} />
  {:else}
    <span class="pc-empty">No figures for this view.</span>
  {/if}
  {#if viewer.cardView !== "playstyle"}
    <p class="pc-foot">
      <b>Season</b>: the aggregates over 293 games, offense only (shots, drives, picks).
      <b>Tracked</b>: the {games} games in this viewer, with this team. Hover a row's name for its definition.
    </p>
  {/if}
</div>
