<script lang="ts">
  // One block of an exploration document: prose, a takeaway or caveat, stat tiles, a grid or fold of further
  // blocks, or one of the shared charts (dot-and-interval rates, columns, scatter and lines, a court density map) or
  // a sortable table. The charts are the Rebounding tab's components; only their inputs are adapted here.
  import Columns from "../charts/Columns.svelte";
  import CourtMap from "../charts/CourtMap.svelte";
  import RateDots from "../charts/RateDots.svelte";
  import Scatter from "../charts/Scatter.svelte";
  import Block from "./Block.svelte";
  import DataTable from "./DataTable.svelte";
  import GravityRoom from "./GravityRoom.svelte";
  import { format, formatter, inline, type Block as B } from "./types";

  let { block }: { block: B } = $props();

  const isPct = (f: string) => f === "pct" || f === "pct1";
  const cap = (s: string) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
  // Dot charts of means (points, feet, xPts) get a range around their values; shares keep the 0-based default.
  function range(b: Extract<B, { type: "rates" }>): { min: number; max: number | null } {
    if (isPct(b.fmt)) return { min: b.min ?? 0, max: b.max };
    const v = b.rows.flatMap((r) => [r.rate, r.lo ?? r.rate, r.hi ?? r.rate]).concat(b.ref != null ? [b.ref] : []).filter(Number.isFinite);
    const lo = Math.min(...v), hi = Math.max(...v), pad = (hi - lo) * 0.08 || Math.abs(hi) * 0.1 || 1;
    return { min: b.min ?? (lo >= 0 && lo < (hi - lo) * 0.6 ? 0 : lo - pad), max: b.max ?? hi + pad };
  }
  const rateRows = (b: Extract<B, { type: "rates" }>) =>
    b.rows.map((r) => ({ label: r.label, rate: r.rate, lo: r.lo ?? r.rate, hi: r.hi ?? r.rate, n: r.n }));
</script>

{#if block.type === "p"}
  <p>{@html inline(block.text)}</p>
{:else if block.type === "h"}
  <h3 class="x-h">{block.text}</h3>
{:else if block.type === "list"}
  <ul class="x-list">{#each block.items as t, i (i)}<li>{@html inline(t)}</li>{/each}</ul>
{:else if block.type === "takeaway" || block.type === "caveat"}
  <div class={block.type === "takeaway" ? "decision" : "x-caveat"}>
    <b>{block.type === "takeaway" ? "Takeaway" : "Caveat"}</b>
    {#if block.items.length === 1}
      <span>{@html inline(block.items[0])}</span>
    {:else}
      <ul class="x-list in-box">{#each block.items as t, i (i)}<li>{@html inline(t)}</li>{/each}</ul>
    {/if}
  </div>
{:else if block.type === "widget"}
  {#if block.name === "gravity-room"}<GravityRoom />{/if}
{:else if block.type === "kpis"}
  <div class="x-kpis">
    {#each block.items as k (k.label)}
      <div class="x-kpi"><span class="x-kpi-label">{k.label}</span><b>{k.value}</b>{#if k.sub}<span class="x-kpi-sub">{k.sub}</span>{/if}</div>
    {/each}
  </div>
{:else if block.type === "grid"}
  <!-- Tables need their full width, so a grid holding one stacks its blocks. -->
  <div class="x-grid" style:--cols={block.blocks.some((b) => b.type === "table") ? 1 : block.cols}>
    {#each block.blocks as b, i (i)}<div class="x-cell"><Block block={b} /></div>{/each}
  </div>
{:else if block.type === "details"}
  <details class="x-more"><summary>{block.summary}</summary>{#each block.blocks as b, i (i)}<Block block={b} />{/each}</details>
{:else if block.type === "rates"}
  {#if block.rows.length}
    {@const r = range(block)}
    <figure class="x-fig">
      <h4>{cap(block.title)}</h4>
      <RateDots rows={rateRows(block)} reference={block.ref} min={r.min} max={r.max} format={formatter(block.fmt)} unit={block.unit}
                refLabel={block.refLabel} labelWidth={Math.round(block.labelWidth * 1.15)} />
      {#if block.note}<figcaption>{block.note}</figcaption>{/if}
    </figure>
  {/if}
{:else if block.type === "columns"}
  <figure class="x-fig">
    <h4>{cap(block.title)}</h4>
    <Columns categories={block.categories} labels={block.labels} xlabel={block.xlabel} ylabel={block.ylabel} format={(v) => format(v, block.fmt)}
             series={block.series.map((s) => ({ name: s.name, values: s.values.map((v) => (v == null || !Number.isFinite(v) ? 0 : v)), color: s.color ?? undefined }))} />
    {#if block.note}<figcaption>{block.note}</figcaption>{/if}
  </figure>
{:else if block.type === "scatter"}
  {@const named = block.lines.filter((l) => l.name)}
  <figure class="x-fig">
    <h4>{cap(block.title)}</h4>
    <Scatter points={block.points ?? []} groups={block.groups} xlabel={block.xlabel} ylabel={block.ylabel}
             xdomain={block.xdomain} ydomain={block.ydomain} radius={block.radius} opacity={block.opacity}
             xfmt={(v) => format(v, block.xfmt)} yfmt={(v) => format(v, block.yfmt)}
             lines={block.lines.map((l) => ({ points: l.points, label: l.label ?? undefined, color: l.color ?? undefined, dashed: l.dashed }))} />
    {#if named.length}
      <div class="x-legend">{#each named as l (l.name)}<span><i style:background={l.color ?? "var(--ink)"}></i>{l.name}</span>{/each}</div>
    {/if}
    {#if block.note}<figcaption>{block.note}</figcaption>{/if}
  </figure>
{:else if block.type === "court"}
  <figure class="x-fig x-court">
    <CourtMap points={block.points} title={block.title} caption={block.caption} bw={block.bw} noun="spots" />
  </figure>
{:else if block.type === "table"}
  <DataTable title={block.title} cols={block.cols} rows={block.rows} limit={block.limit} note={block.note} />
{/if}

<style>
  .x-h { margin: 28px 0 12px; }
  .x-list { max-width: 900px; margin: 6px 0 16px; padding-left: 22px; }
  .x-list li { margin: 0 0 7px; padding-left: 2px; line-height: 1.5; }
  .x-list li::marker { color: var(--muted); }
  .x-list.in-box { margin: 0; padding-left: 18px; }
  .x-list.in-box li:last-child { margin-bottom: 0; }
  .x-caveat { display: flex; gap: 14px; margin: 22px 0; padding: 12px 16px; border-left: 3px solid #c98500; border-radius: 0 8px 8px 0; background: rgba(201, 133, 0, .08); }
  .x-caveat b { flex: none; color: #c98500; font-size: 13.5px; letter-spacing: .01em; line-height: 1.55; }
  .decision { display: flex; gap: 14px; margin: 22px 0; padding: 12px 16px; border-left: 3px solid var(--off); border-radius: 0 8px 8px 0; background: rgba(76, 154, 255, .08); }
  .decision b { flex: none; color: var(--off); font-size: 13.5px; letter-spacing: .01em; line-height: 1.55; }
  .x-caveat span, .decision span { color: var(--ink); }
  .x-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin: 20px 0; }
  .x-kpi { display: flex; flex-direction: column; gap: 2px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  .x-kpi b { font-size: 23px; font-variant-numeric: tabular-nums; }
  .x-kpi-label { color: var(--muted); font-size: 14px; }
  .x-kpi-sub { color: var(--muted); font-size: 13px; }
  .x-grid { display: grid; grid-template-columns: repeat(var(--cols), minmax(0, 1fr)); gap: 26px 32px; margin: 22px 0; align-items: start; }
  .x-cell { min-width: 0; }
  .x-fig { margin: 18px 0; min-width: 0; max-width: 760px; }
  .x-fig h4 { margin: 0 0 8px; text-transform: none; font-size: 14.5px; color: var(--ink); }
  .x-fig figcaption { margin-top: 4px; color: var(--muted); font-size: 14px; }
  .x-court { max-width: 420px; }
  .x-legend { display: flex; flex-wrap: wrap; gap: 4px 14px; margin-top: 4px; color: var(--muted); font-size: 14px; }
  .x-legend span { display: inline-flex; align-items: center; gap: 6px; }
  .x-legend i { width: 14px; height: 3px; border-radius: 2px; }
  .x-more { margin: 12px 0; }
  .x-more summary { cursor: pointer; color: var(--off); font-size: 15px; }
  @media (max-width: 760px) { .x-grid { grid-template-columns: minmax(0, 1fr); } }
</style>
