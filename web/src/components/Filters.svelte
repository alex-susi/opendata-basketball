<script lang="ts">
  // The filter panel. Mirrors the inputs of the Shiny app (same labels, same choices from meta.json).
  import { emptyFilters, type FilterState } from "../lib/filters";
  import type { Meta } from "../lib/types";
  import MultiSelect from "./MultiSelect.svelte";

  let { meta, filters = $bindable() }: { meta: Meta; filters: FilterState } = $props();
</script>

<details class="panel filters" open>
  <summary><span>Filters</span><button type="button" class="link" onclick={(ev) => { ev.preventDefault(); filters = emptyFilters(); }}>Reset</button></summary>
  <MultiSelect label="Game" options={meta.game} placeholder="All games" bind:value={filters.game} />
  <div class="pair">
    <MultiSelect label="Team" options={meta.team} placeholder="All teams" bind:value={filters.team} />
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
  <MultiSelect label="Shot type" options={meta.shotType} placeholder="Any shot type" bind:value={filters.shotType} />
</details>
