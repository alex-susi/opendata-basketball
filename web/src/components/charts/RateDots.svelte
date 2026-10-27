<script lang="ts">
  // A rate per category as a dot with its 90% interval, one row each, against a dashed reference rate. The count
  // sits at the right so small groups are visibly small. Hover a row for the exact numbers.
  import { linear, pctFmt, ticks } from "./scale";

  interface Row { label: string; rate: number; lo: number; hi: number; n: number }
  let { rows, reference = null, max = null, min = 0, color = "#3987e5", unit = "offensive ball", format = pctFmt, refLabel = "all", labelWidth = 150 }:
    { rows: Row[]; reference?: number | null; max?: number | null; min?: number; color?: string; unit?: string;
      format?: (v: number, d?: number) => string; refLabel?: string; labelWidth?: number } = $props();

  const W = 640, RIGHT = 56, ROW = 26, TOP = 20, AXIS = 24;
  const LEFT = $derived(labelWidth);
  const H = $derived(TOP + rows.length * ROW + AXIS);
  const hi = $derived(max ?? Math.min(1, Math.max(...rows.map((r) => r.hi), reference ?? 0) * 1.1));
  const x = $derived(linear(min, hi, LEFT, W - RIGHT));
  const tk = $derived(ticks(min, hi, 5));
</script>

<svg viewBox={`0 0 ${W} ${H}`} class="chart" role="img" aria-label={`Share with ${unit}, by group, with 90% intervals`}>
  {#each tk as t (t)}
    <line x1={x(t)} x2={x(t)} y1={TOP} y2={H - AXIS} class="grid" />
    <text x={x(t)} y={H - AXIS + 15} class="tick" text-anchor="middle">{format(t)}</text>
  {/each}
  {#if reference != null}
    <line x1={x(reference)} x2={x(reference)} y1={TOP} y2={H - AXIS} class="ref" />
    <text x={x(reference) + 4} y={TOP - 7} class="tick">{refLabel} {format(reference)}</text>
  {/if}
  {#each rows as r, i (r.label)}
    {@const cy = TOP + i * ROW + ROW / 2}
    <g class="row">
      <title>{r.label}: {format(r.rate, 1)} {unit} (90% interval {format(r.lo, 1)} to {format(r.hi, 1)}), n = {r.n}</title>
      <rect x="0" y={cy - ROW / 2} width={W} height={ROW} class="hit" />
      <text x={LEFT - 10} y={cy + 4} class="label" text-anchor="end">{r.label}</text>
      <line x1={x(r.lo)} x2={x(r.hi)} y1={cy} y2={cy} stroke={color} stroke-width="2" stroke-linecap="round" opacity="0.55" />
      <circle cx={x(r.rate)} cy={cy} r="5" fill={color} stroke="var(--panel)" stroke-width="2" />
      <text x={W - 4} y={cy + 4} class="tick" text-anchor="end">n {r.n}</text>
    </g>
  {/each}
</svg>

<style>
  .chart { width: 100%; height: auto; display: block; }
  .grid { stroke: var(--line); stroke-width: 1; }
  .ref { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 3 3; }
  .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  .label { fill: var(--ink); font-size: 12px; }
  .hit { fill: transparent; }
  .row:hover .hit { fill: rgba(255, 255, 255, .04); }
</style>
