<script lang="ts">
  // A compact multi-select: chosen items show as removable chips; the list opens below with a search box.
  // Stands in for the selectize inputs of the Shiny app. With `pills` (colours by option value), each option and
  // chip is drawn as a team pill (TeamPill.svelte). With `item`, each option (and chip, chip = true) is drawn by that
  // snippet instead (a game on two lines, a player with his team's pill). With `single`, picking an option replaces the
  // choice and closes the list (the Player filter); the search still works.
  import type { Snippet } from "svelte";
  import type { Option } from "../lib/types";
  import TeamPill from "./TeamPill.svelte";

  let { label, options, placeholder, pills, item, single = false, value = $bindable([]) }: {
    label: string; options: Option[]; placeholder: string; pills?: Record<string, [string, string]>;
    item?: Snippet<[Option, boolean]>; single?: boolean; value: string[];
  } = $props();

  let open = $state(false);
  let query = $state("");
  let root: HTMLDivElement;
  const id = `ms-${Math.random().toString(36).slice(2, 8)}`;
  const chosen = $derived(options.filter((o) => value.includes(o.value)));
  const shown = $derived(options.filter((o) => o.label.toLowerCase().includes(query.trim().toLowerCase())));

  function toggle(v: string): void {
    if (single) {
      value = value.includes(v) ? [] : [v];
      close();
      return;
    }
    value = value.includes(v) ? value.filter((x) => x !== v) : [...value, v];
  }

  function close(): void {
    open = false;
    query = "";
  }
</script>

<svelte:window onpointerdown={(ev) => { if (open && !root.contains(ev.target as Node)) close(); }}
               onkeydown={(ev) => { if (open && ev.key === "Escape") close(); }} />

{#snippet face(o: Option, chip: boolean)}
  {#if item}{@render item(o, chip)}{:else if pills?.[o.value]}<TeamPill name={o.label} colors={pills[o.value]} />{:else}{o.label}{/if}
{/snippet}

<div class="field multi" bind:this={root}>
  <span class="field-label" id="{id}-label">{label}</span>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="multi-box" class:open onclick={() => (open = true)}>
    {#each chosen as o (o.value)}
      <span class="chip" class:pill-chip={!!pills?.[o.value] && !item}>{@render face(o, true)}<button type="button" aria-label="Remove {o.label}" onclick={(ev) => { ev.stopPropagation(); toggle(o.value); }}>×</button></span>
    {/each}
    <button type="button" class="multi-open" aria-haspopup="true" aria-expanded={open} aria-labelledby="{id}-label"
            onclick={(ev) => { ev.stopPropagation(); open ? close() : (open = true); }}>
      {chosen.length ? "" : placeholder}<span class="caret" aria-hidden="true"></span>
    </button>
  </div>
  {#if open}
    <div class="multi-list" class:single role="group" aria-labelledby="{id}-label">
      {#if options.length > 8}
        <!-- svelte-ignore a11y_autofocus -->
        <input type="search" class="multi-search" placeholder="Search" aria-label="Search {label}" bind:value={query} autofocus />
      {/if}
      {#each shown as o (o.value)}
        <label class="multi-option" class:on={value.includes(o.value)}>
          <input type={single ? "radio" : "checkbox"} name={single ? id : undefined} checked={value.includes(o.value)}
                 onclick={() => toggle(o.value)} />{@render face(o, false)}
        </label>
      {:else}
        <p class="multi-empty">No matches</p>
      {/each}
    </div>
  {/if}
</div>
