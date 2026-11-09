<script lang="ts">
  // A sortable table for the exploration tabs. Columns with a reference value tint each cell: blue above the
  // reference, red below, stronger the further away (full strength at `scale`); the tooltip gives the reference and
  // says when lower is the better side. The first `limit` rows show until "Show all" is pressed.
  import { format, type Col, type Row } from "./types";

  let { title = "", cols, rows, limit = 15, note = null }: { title?: string; cols: Col[]; rows: Row[]; limit?: number; note?: string | null } = $props();

  let sortKey = $state<string | null>(null);
  let desc = $state(true);
  let all = $state(false);
  const sorted = $derived.by(() => {
    if (!sortKey) return rows;
    const k = sortKey, s = desc ? -1 : 1;
    return [...rows].sort((a, b) => {
      const x = a[k], y = b[k];
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return (typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y))) * s;
    });
  });
  const shown = $derived(all ? sorted : sorted.slice(0, limit));
  function sortBy(k: string): void {
    if (sortKey === k) desc = !desc;
    else { sortKey = k; desc = true; }
  }
  function tint(c: Col, v: unknown): string | null {
    if (c.ref == null || !c.scale || typeof v !== "number" || !Number.isFinite(v)) return null;
    const d = (v - c.ref) / c.scale, a = Math.min(0.42, Math.abs(d) * 0.42);
    if (a < 0.04) return null;
    return d > 0 ? `rgba(57, 135, 229, ${a.toFixed(2)})` : `rgba(230, 103, 103, ${a.toFixed(2)})`;
  }
  // Column groups (consecutive columns with the same `group`) get a header row of their own, like a spreadsheet's
  // merged cells; the first column of each named group gets a divider.
  const groups = $derived(cols.reduce<{ name: string; span: number }[]>((out, c) => {
    const name = c.group ?? "";
    const last = out[out.length - 1];
    if (last && last.name === name) last.span++;
    else out.push({ name, span: 1 });
    return out;
  }, []));
  const startsGroup = (c: Col) => {
    const i = cols.indexOf(c);
    return !!c.group && (i === 0 || cols[i - 1].group !== c.group);
  };
  function tip(c: Col, v: unknown): string | undefined {
    if (c.ref == null || typeof v !== "number" || !Number.isFinite(v)) return undefined;
    return `${c.label} ${format(v, c.fmt)}\nAll ${format(c.ref, c.fmt)}${c.low ? "\nLower is better here" : ""}`;
  }
</script>

<div class="dt">
  {#if title}<h4>{title}</h4>{/if}
  <div class="table-wrap">
    <table class="scores dt-table">
      <thead>
        {#if groups.some((g) => g.name)}
          <tr class="dt-groups">
            {#each groups as g, i (i)}<th colspan={g.span} class:named={!!g.name}>{g.name}</th>{/each}
          </tr>
        {/if}
        <tr>
          {#each cols as c (c.key)}
            <th class:count={c.fmt !== "text"} class:group-start={startsGroup(c)} title={c.title ?? c.label}>
              <button type="button" class="sort" onclick={() => sortBy(c.key)}>
                {c.label}{#if sortKey === c.key}<span class="arrow">{desc ? "▾" : "▴"}</span>{/if}
              </button>
            </th>
          {/each}
        </tr>
      </thead>
      <tbody>
        {#each shown as r, i (i)}
          <tr>
            {#each cols as c (c.key)}
              <td class:count={c.fmt !== "text"} class:group-start={startsGroup(c)} style:background={tint(c, r[c.key])} title={tip(c, r[c.key])}>{format(r[c.key], c.fmt)}</td>
            {/each}
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
  <div class="dt-foot">
    {#if rows.length > limit}
      <button type="button" class="link" onclick={() => (all = !all)}>{all ? `Show the first ${limit}` : `Show all ${rows.length} rows`}</button>
    {/if}
    {#if note}<span class="dt-note">{note}</span>{/if}
  </div>
</div>

<style>
  .dt { margin: 24px 0; min-width: 0; }
  .dt h4 { margin: 0 0 8px; }
  .dt-table { min-width: 0; font-size: 14.5px; }
  .dt-table th, .dt-table td { padding: 6px 9px; font-size: 14.5px; white-space: nowrap; }
  .dt-table td:first-child { white-space: normal; min-width: 120px; }
  .sort { padding: 0; border: 0; background: none; color: inherit; font: inherit; text-transform: inherit; cursor: pointer; text-align: inherit; }
  .sort:hover { color: var(--ink); }
  .arrow { margin-left: 3px; font-size: 10px; }
  .dt-foot { display: flex; flex-wrap: wrap; gap: 4px 14px; align-items: baseline; margin-top: 6px; }
  .dt-note { color: var(--muted); font-size: 14px; }
  .dt-groups th { padding-bottom: 2px; border-bottom: 0; text-align: center; font-size: 12.5px; letter-spacing: .04em; text-transform: uppercase; }
  .dt-groups th.named { color: var(--ink); border-bottom: 2px solid var(--line); }
  .group-start { border-left: 1px solid var(--line); }
</style>
