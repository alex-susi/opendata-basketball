<script lang="ts">
  // The list of possessions that match the filters, grouped by game (each game's header: the teams abbreviated with
  // the final score, its date on the line below). With Show Details off (the default) each entry is one
  // line: quarter, clock and length, the team on offense abbreviated, the result (the player who ended it is in the
  // tooltip). With it on: quarter, clock and length with the result and the player right-aligned on the same line, the
  // team's full name, then the play's actions (screens, drives, offensive rebounds and so on). Fields wrap instead of
  // being cut off, so an entry stays readable however narrow the column is.
  import { tick } from "svelte";
  import { quarter } from "../lib/geometry";
  import { shortScreen } from "../lib/sequence";
  import { gameParts, teamAbbr } from "../lib/teams";
  import type { PlayRow } from "../lib/types";
  import TeamPill from "./TeamPill.svelte";

  let { rows, selectedId, onselect, wide = false, ontogglewidth, teamColors = {} }: {
    rows: PlayRow[]; selectedId: string | null; onselect: (id: string) => void; wide?: boolean; ontogglewidth?: () => void;
    teamColors?: Record<string, [string, string]>;
  } = $props();

  // Show Details: the actions in each play. Off by default, remembered in this browser only.
  const DETAILS_KEY = "acb-viewer-show-details";
  let details = $state(false);
  try { details = localStorage.getItem(DETAILS_KEY) === "1"; } catch { /* storage unavailable: keep the default */ }
  function setDetails(on: boolean): void {
    details = on;
    try { localStorage.setItem(DETAILS_KEY, on ? "1" : "0"); } catch { /* not remembered */ }
  }

  let list: HTMLDivElement;
  const outcome = (row: PlayRow) => (row.result.startsWith("Made") ? "made" : row.result.startsWith("Missed") ? "missed" : "");
  const oreb = (row: PlayRow) => (row.oreb > 1 ? `Off. Reb ×${row.oreb}` : "Off. Reb");

  // Keep the selected play in view when the selection or the list changes.
  $effect(() => {
    void [selectedId, rows];
    // Scroll the list only (scrollIntoView would also scroll the page when the list sits below the viewer, in tall
    // narrow windows). Below the sticky game header when the row is above the visible part.
    tick().then(() => {
      const row = list?.querySelector<HTMLElement>(".play-item.active");
      if (!row) return;
      const top = row.offsetTop - list.offsetTop, head = list.querySelector<HTMLElement>(".game-head")?.offsetHeight ?? 0;
      if (top - head < list.scrollTop) list.scrollTop = top - head;
      else if (top + row.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = top + row.offsetHeight - list.clientHeight;
    });
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
  <div class="plays-sub">
    <label class="switch" title="Show the actions in each play (screens, drives, offensive rebounds)">
      <input type="checkbox" role="switch" checked={details} onchange={(ev) => setDetails((ev.currentTarget as HTMLInputElement).checked)} />
      <span class="switch-track"></span>
      <span>Show Details</span>
    </label>
  </div>
  <div class="play-list" bind:this={list}>
    {#each rows as row, i (row.id)}
      {#if i === 0 || rows[i - 1].game !== row.game}
        {@const g = gameParts(row.game)}
        <div class="game-head" title={row.game}><span>{g.teams}</span>{#if g.date}<span class="game-date">{g.date}</span>{/if}</div>
      {/if}
      <button type="button" class="play-item" class:compact={!details} class:active={row.id === selectedId} onclick={() => onselect(row.id)}>
        <span class="pi-top"><b>{quarter(row.q)} {row.clock}</b><span class="pi-secs">{row.secs}s</span></span>
        <span class="pi-team" title={details ? null : row.off}><TeamPill name={details ? row.off : teamAbbr(row.off)} colors={teamColors[String(row.offTeam)]} /></span>
        <span class="pi-result {outcome(row)}" title={!details && row.who ? `${row.result} · ${row.who}` : null}>{details && row.who ? `${row.result} · ${row.who}` : row.result}{#if row.and1}<i class="pi-and1" title="Made while fouled: a basket plus a free throw">And-1</i>{/if}</span>
        {#if details && (row.typeLabels || row.oreb > 0)}
          <span class="pi-tags">
            {#if row.oreb > 0}<i class="oreb" title="Offensive rebounds collected by a player in this possession">{oreb(row)}</i>{/if}
            {#if row.typeLabels}{#each row.typeLabels.split("|") as type, k}<i>{shortScreen(type)}{#if (row.typeCounts?.[k] ?? 1) > 1}&nbsp;×{row.typeCounts?.[k]}{/if}</i>{/each}{/if}
          </span>
        {/if}
      </button>
    {/each}
  </div>
</div>
