<script lang="ts">
  // The filter panel. Mirrors the inputs of the Shiny app (same labels, same choices from meta.json), with three
  // changes made here on the client: games written as on the possession list (teams abbreviated with the score, the
  // date under them); the Player filter searchable, each player with his team's pill (abbreviated); the actions in
  // alphabetical order, the pick named "On-ball Screen".
  // One filter per row while the left column is narrow; a filter and the drop-down that qualifies it share a row
  // once the column is dragged wide enough (.filters is a size container, see app.css).
  import { emptyFilters, type FilterState } from "../lib/filters";
  import { gameParts, teamAbbr } from "../lib/teams";
  import type { Meta, Option } from "../lib/types";
  import MultiSelect from "./MultiSelect.svelte";
  import TeamPill from "./TeamPill.svelte";

  let { meta, filters = $bindable() }: { meta: Meta; filters: FilterState } = $props();

  const ACTION_NAMES: Record<string, string> = { pick: "On-ball Screen" };
  const actions = $derived(meta.types.map((o) => ({ ...o, label: ACTION_NAMES[o.value] ?? o.label }))
    .sort((a, b) => a.label.localeCompare(b.label)));
  // A player's label is "Name (Team)": split it, and find the team's id for its colours.
  const teamIds = $derived(new Map(meta.team.map((t) => [t.label, t.value])));
  function playerParts(o: Option): { name: string; team: string; colors?: [string, string] } {
    const m = /^(.*) \((.+)\)$/.exec(o.label);
    if (!m) return { name: o.label, team: "" };
    const id = teamIds.get(m[2]);
    return { name: m[1], team: m[2], colors: id ? meta.teamColors?.[id] : undefined };
  }
</script>

{#snippet gameItem(o: Option, chip: boolean)}
  {@const g = gameParts(o.label)}
  {#if chip}<span title={o.label}>{g.teams}</span>{:else}<span class="opt-two" title={o.label}><b>{g.teams}</b>{#if g.date}<span>{g.date}</span>{/if}</span>{/if}
{/snippet}

{#snippet playerItem(o: Option, chip: boolean)}
  {@const p = playerParts(o)}
  <span class="opt-player" class:chip title={o.label}><span class="opt-name">{p.name}</span>{#if p.team}<TeamPill name={teamAbbr(p.team)} colors={p.colors} />{/if}</span>
{/snippet}

<details class="panel filters" open>
  <summary><span>Filters</span><button type="button" class="link" onclick={(ev) => { ev.preventDefault(); filters = emptyFilters(); }}>Reset</button></summary>
  <div class="filter-grid">
    <MultiSelect label="Game" options={meta.game} placeholder="All games" item={gameItem} bind:value={filters.game} />
    <div class="pair">
      <MultiSelect label="Team" options={meta.team} placeholder="All teams" pills={meta.teamColors} bind:value={filters.team} />
      <label class="field"><span class="field-label">Team is</span>
        <select bind:value={filters.teamSide}>
          <option value="any">Either side</option>
          <option value="off">On offense</option>
          <option value="def">On defense</option>
        </select>
      </label>
    </div>
    <div class="pair">
      <MultiSelect label="Player" single options={meta.player} placeholder="Any player" item={playerItem}
                   bind:value={() => (filters.player ? [filters.player] : []), (v) => { filters.player = v[0] ?? ""; }} />
      <label class="field"><span class="field-label">Player is</span>
        <select bind:value={filters.playerRole}>
          <option value="any">On court</option>
          <option value="off">On offense</option>
          <option value="def">On defense</option>
          <option value="actor">In the action</option>
        </select>
      </label>
    </div>
    <div class="pair">
      <MultiSelect label="Action" options={actions} placeholder="Any action" bind:value={filters.types} />
      <label class="field"><span class="field-label">Match</span>
        <select bind:value={filters.typesMode}>
          <option value="any">Any selected</option>
          <option value="all">All selected</option>
        </select>
      </label>
    </div>
    <div class="pair even">
      <MultiSelect label="Quarter" options={meta.period} placeholder="All" bind:value={filters.period} />
      <MultiSelect label="Result" options={meta.result} placeholder="Any result" bind:value={filters.result} />
    </div>
    <div class="pair even">
      <MultiSelect label="Shot type" options={meta.shotType} placeholder="Any shot type" bind:value={filters.shotType} />
      <label class="field" title="Offensive rebounds a player collected in the possession. Team rebounds (the ball went out off the defense) are not counted.">
        <span class="field-label">Offensive rebound</span>
        <select bind:value={filters.oreb}>
          <option value="any">Any</option>
          <option value="with">Yes</option>
          <option value="without">No</option>
        </select>
      </label>
    </div>
  </div>
</details>
