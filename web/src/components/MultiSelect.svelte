<script lang="ts">
  // A compact multi-select: chosen items show as removable chips; the list opens below with a search box.
  // Stands in for the selectize inputs of the Shiny app.
  import type { Option } from "../lib/types";

  let { label, options, placeholder, value = $bindable([]) }: { label: string; options: Option[]; placeholder: string; value: string[] } = $props();

  let open = $state(false);
  let query = $state("");
  let root: HTMLDivElement;
  const id = `ms-${Math.random().toString(36).slice(2, 8)}`;
  const chosen = $derived(options.filter((o) => value.includes(o.value)));
  const shown = $derived(options.filter((o) => o.label.toLowerCase().includes(query.trim().toLowerCase())));

  function toggle(v: string): void {
    value = value.includes(v) ? value.filter((x) => x !== v) : [...value, v];
  }

  function close(): void {
    open = false;
    query = "";
  }
</script>

<svelte:window onpointerdown={(ev) => { if (open && !root.contains(ev.target as Node)) close(); }}
               onkeydown={(ev) => { if (open && ev.key === "Escape") close(); }} />

<div class="field multi" bind:this={root}>
  <span class="field-label" id="{id}-label">{label}</span>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="multi-box" class:open onclick={() => (open = true)}>
    {#each chosen as o (o.value)}
      <span class="chip">{o.label}<button type="button" aria-label="Remove {o.label}" onclick={(ev) => { ev.stopPropagation(); toggle(o.value); }}>×</button></span>
    {/each}
    <button type="button" class="multi-open" aria-haspopup="true" aria-expanded={open} aria-labelledby="{id}-label"
            onclick={(ev) => { ev.stopPropagation(); open ? close() : (open = true); }}>
      {chosen.length ? "" : placeholder}<span class="caret" aria-hidden="true"></span>
    </button>
  </div>
  {#if open}
    <div class="multi-list" role="group" aria-labelledby="{id}-label">
      {#if options.length > 8}
        <!-- svelte-ignore a11y_autofocus -->
        <input type="search" class="multi-search" placeholder="Search" aria-label="Search {label}" bind:value={query} autofocus />
      {/if}
      {#each shown as o (o.value)}
        <label class="multi-option">
          <input type="checkbox" checked={value.includes(o.value)} onchange={() => toggle(o.value)} />{o.label}
        </label>
      {:else}
        <p class="multi-empty">No matches</p>
      {/each}
    </div>
  {/if}
</div>
