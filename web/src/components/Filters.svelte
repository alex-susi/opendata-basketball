<script lang="ts">
  // The filter panel. Mirrors the inputs of the Shiny app (same labels, same choices from meta.json).
  // One filter per row while the left column is narrow; a filter and the drop-down that qualifies it share a row
  // once the column is dragged wide enough (.filters is a size container, see app.css).
  import { emptyFilters, type FilterState } from "../lib/filters";
  import type { Meta } from "../lib/types";
  import MultiSelect from "./MultiSelect.svelte";

  let { meta, filters = $bindable() }: { meta: Meta; filters: FilterState } = $props();
</script>

<details class="panel filters" open>
  <summary><span>Filters</span><button type="button" class="link" onclick={(ev) => { ev.preventDefault(); filters = emptyFilters(); }}>Reset</button></summary>
  <div class="filter-grid">
    <MultiSelect label="Game" options={meta.game} placeholder="All games" bind:value={filters.game} />
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
      <label class="field"><span class="field-label">Player</span>
        <select bind:value={filters.player}>
          <option value="">Any player</option>
          {#each meta.player as o (o.value)}
            <option value={o.value}>{o.label}</option>
          {/each}
        </select>
      </label>
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
      <MultiSelect label="Play type" options={meta.types} placeholder="Any play type" bind:value={filters.types} />
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
