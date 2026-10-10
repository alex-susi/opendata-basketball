<script lang="ts">
  // The list of possessions that match the filters, grouped by game.
  import { tick } from "svelte";
  import { quarter } from "../lib/geometry";
  import type { PlayRow } from "../lib/types";

  let { rows, selectedId, onselect }: { rows: PlayRow[]; selectedId: string | null; onselect: (id: string) => void } = $props();

  let list: HTMLDivElement;
  const outcome = (row: PlayRow) => (row.result.startsWith("Made") ? "made" : row.result.startsWith("Missed") ? "missed" : "");

  // Keep the selected play in view when the selection or the list changes.
  $effect(() => {
    void [selectedId, rows];
    tick().then(() => list?.querySelector(".play-item.active")?.scrollIntoView({ block: "nearest" }));
  });
</script>

<div class="panel plays">
  <div class="plays-head"><span>Possessions</span><span class="count">{rows.length.toLocaleString()}</span></div>
  <div class="play-list" bind:this={list}>
    {#each rows as row, i (row.id)}
      {#if i === 0 || rows[i - 1].game !== row.game}
        <div class="game-head">{row.game}</div>
      {/if}
      <button type="button" class="play-item" class:active={row.id === selectedId} onclick={() => onselect(row.id)}>
        <span class="pi-top"><b>{quarter(row.q)} {row.clock}</b><span class="pi-team">{row.off}</span><span class="pi-secs">{row.secs}s</span></span>
        <span class="pi-result {outcome(row)}">{row.who ? `${row.result} · ${row.who}` : row.result}</span>
        {#if row.typeLabels}
          <span class="pi-tags">{#each row.typeLabels.split("|") as type}<i>{type}</i>{/each}</span>
        {/if}
      </button>
    {/each}
  </div>
</div>
