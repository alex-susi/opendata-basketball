<script lang="ts">
  // The Archetypes tab: how the playstyle clusters are built and what each archetype and component means.
  // The content is the Shiny app's own page (src/play_viewer/R/archetype_page.R), exported as an HTML fragment
  // by web/scripts/export_data.R, so the two never drift apart. It is our own build output, not user input.
  import { loadArchetypes } from "../lib/data";

  let html = $state("");
  let problem = $state("");

  loadArchetypes().then((text) => { html = text; }).catch((err: Error) => { problem = err.message; });
</script>

<!-- eslint-disable-next-line svelte/no-at-html-tags -->
{#if html}{@html html}{:else}<div class="doc-inner"><p class="lead">{problem || "Loading…"}</p></div>{/if}
