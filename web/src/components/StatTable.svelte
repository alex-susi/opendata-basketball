<script lang="ts">
  // Aligned stat tables (lib/player.ts): a label, then per column a right-aligned value and, for a column with a
  // count heading (Chances, Possessions, FGA), the sample size in a column of its own; then an optional note (the
  // figure's source and what it was split by). Used by the player card and the trace panel's hover cards.
  import type { StatSection } from "../lib/player";

  let { sections }: { sections: StatSection[] } = $props();
</script>

{#each sections as sec, i (i)}
  {@const notes = sec.rows.some((r) => r.note)}
  {#if sec.title}
    <span class="stat-title">{sec.title}{#if sec.note}<span class="stat-info" title={sec.note.join("\n")}>i</span>{/if}</span>
  {/if}
  <div class="stat-grid" style:grid-template-columns="minmax(max-content, 1fr) {sec.cols.map((c) => (c.count ? 'auto auto' : 'auto')).join(' ')} {notes ? 'auto' : ''}">
    <span></span>
    {#each sec.cols as c (c.label)}
      <span class="stat-head">{c.label}</span>{#if c.count}<span class="stat-head count">{c.count}</span>{/if}
    {/each}
    {#if notes}<span></span>{/if}
    {#each sec.rows as r (r.k + (r.note ?? ""))}
      <span class="stat-k" title={r.title}>{r.k}</span>
      {#each r.cells as c, j (j)}
        <span class="stat-v" class:none={!c} style:color={c?.tone}>{c ? c.v : "–"}</span>
        {#if sec.cols[j]?.count}<span class="stat-n">{c?.n != null ? c.n.toLocaleString("en-US") : ""}</span>{/if}
      {/each}
      {#if notes}<span class="stat-note">{r.note ?? ""}</span>{/if}
    {/each}
  </div>
  {#if sec.note && !sec.title}<ul class="stat-foot">{#each sec.note as n (n)}<li>{n}</li>{/each}</ul>{/if}
{/each}
