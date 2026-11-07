<script lang="ts">
  // The list of possessions that match the filters, grouped by game. Each entry: quarter, clock and length with the
  // result right-aligned on the same line, then the team on offense and the tags. Every field wraps instead of
  // being cut off, so the whole entry stays readable however narrow the column is.
  import { tick } from "svelte";
  import { quarter } from "../lib/geometry";
  import type { PlayRow } from "../lib/types";
  import TeamPill from "./TeamPill.svelte";

  let { rows, selectedId, onselect, wide = false, ontogglewidth, teamColors = {} }: {
    rows: PlayRow[]; selectedId: string | null; onselect: (id: string) => void; wide?: boolean; ontogglewidth?: () => void;
    teamColors?: Record<string, [string, string]>;
  } = $props();

  let list: HTMLDivElement;
  const outcome = (row: PlayRow) => (row.result.startsWith("Made") ? "made" : row.result.startsWith("Missed") ? "missed" : "");
  const oreb = (row: PlayRow) => (row.oreb > 1 ? `Off. Reb ×${row.oreb}` : "Off. Reb");

  // Keep the selected play in view when the selection or the list changes.
  $effect(() => {
    void [selectedId, rows];
    tick().then(() => list?.querySelector(".play-item.active")?.scrollIntoView({ block: "nearest" }));
  });
</script>

<div class="panel plays">
  <div class="plays-head">
    <span>Possessions</span>
    <span class="plays-head-end">
      <span class="count">{rows.length.toLocaleString()}</span>
      {#if ontogglewidth}
        <button type="button" class="link width-btn" title={wide ? "Narrow this column (or drag its right edge)" : "Widen this column (or drag its right edge)"}
                onclick={ontogglewidth}>{wide ? "« Narrower" : "Wider »"}</button>
      {/if}
    </span>
  </div>
  <div class="play-list" bind:this={list}>
    {#each rows as row, i (row.id)}
      {#if i === 0 || rows[i - 1].game !== row.game}
        <div class="game-head">{row.game}</div>
      {/if}
      <button type="button" class="play-item" class:active={row.id === selectedId} onclick={() => onselect(row.id)}>
        <span class="pi-top"><b>{quarter(row.q)} {row.clock}</b><span class="pi-secs">{row.secs}s</span></span>
        <span class="pi-team"><TeamPill name={row.off} colors={teamColors[String(row.offTeam)]} /></span>
        <span class="pi-result {outcome(row)}">{row.who ? `${row.result} · ${row.who}` : row.result}{#if row.and1}<i class="pi-and1" title="Made while fouled: a basket plus a free throw">And-1</i>{/if}</span>
        {#if row.typeLabels || row.oreb > 0}
          <span class="pi-tags">
            {#if row.oreb > 0}<i class="oreb" title="Offensive rebounds collected by a player in this possession">{oreb(row)}</i>{/if}
            {#if row.typeLabels}{#each row.typeLabels.split("|") as type}<i>{type}</i>{/each}{/if}
          </span>
        {/if}
      </button>
    {/each}
  </div>
</div>
