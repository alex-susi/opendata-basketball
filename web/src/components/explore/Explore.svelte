<script lang="ts">
  // One exploration tab: a topic's document (explore_<topic>.json) rendered section by section. The wording and
  // the numbers both come from the topic's R script (web/scripts/explore/<topic>.R), so this component only lays
  // them out: a title, a lead, a list of sections and their blocks.
  import { loadExplore } from "../../lib/data";
  import Block from "./Block.svelte";
  import type { ExploreDoc } from "./types";

  let { topic }: { topic: string } = $props();
  let doc = $state.raw<ExploreDoc | null>(null);
  let problem = $state("");
  $effect(() => {
    const t = topic;
    loadExplore<ExploreDoc>(t).then((d) => { if (t === topic) doc = d; }).catch((err: Error) => { problem = err.message; });
  });
  // Plain scrolling: the address names the tab, so section links must not change it.
  const go = (id: string) => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
</script>

{#if !doc}
  <div class="doc-inner"><p class="lead">{problem || "Loading…"}</p></div>
{:else}
  <div class="doc-inner x-doc">
    <h1>{doc.title}</h1>
    <p class="lead">{doc.lead}</p>
    <p class="meta">Exploratory data analysis of the ten tracked Liga ACB games (season aggregates where labelled). Built {doc.built}. Descriptive only: no model is fitted.</p>
    <nav class="x-toc" aria-label="On this page">
      {#each doc.sections as s, i (s.id)}<button type="button" class="link" onclick={() => go(`${doc?.id}-${s.id}`)}>{i + 1}. {s.title}</button>{/each}
    </nav>
    {#each doc.sections as s, i (s.id)}
      <section id={`${doc.id}-${s.id}`}>
        <h2>{i + 1}. {s.title}</h2>
        {#each s.blocks as b, j (j)}<Block block={b} />{/each}
      </section>
    {/each}
  </div>
{/if}

<style>
  .x-doc { max-width: 1180px; }
  .x-toc { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 14px 0 6px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  .x-toc .link { font-size: 13px; }
</style>
