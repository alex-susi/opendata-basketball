<script lang="ts">
  // Columns from one baseline: shares or counts per category (also used as a histogram). One or two series side by
  // side; values on the caps only when `labels` is set. Hover a column for its value.
  import { linear, SERIES, ticks } from "./scale";

  interface Series { name: string; values: number[]; color?: string }
  let { categories, series, format = (v: number) => String(v), labels = false, xlabel = "", ylabel = "", marks = [] }:
    { categories: string[]; series: Series[]; format?: (v: number) => string; labels?: boolean; xlabel?: string; ylabel?: string;
      marks?: { at: number; label: string }[] } = $props();

  const W = 640, H = 230, LEFT = 46, RIGHT = 10, TOP = 14, BOTTOM = 40;
  const top = $derived(Math.max(...series.flatMap((s) => s.values)) * 1.12 || 1);
  const y = $derived(linear(0, top, H - BOTTOM, TOP));
  const band = $derived((W - LEFT - RIGHT) / categories.length);
  const bw = $derived(Math.min(24, (band * 0.7) / series.length));
  const tk = $derived(ticks(0, top, 4));
  const every = $derived(Math.ceil(categories.length / 14));
</script>

<svg viewBox={`0 0 ${W} ${H}`} class="chart" role="img" aria-label={ylabel || "Columns"}>
  {#each tk as t (t)}
    <line x1={LEFT} x2={W - RIGHT} y1={y(t)} y2={y(t)} class="grid" />
    <text x={LEFT - 6} y={y(t) + 4} class="tick" text-anchor="end">{format(t)}</text>
  {/each}
  {#each marks as m (m.label)}
    {@const mx = LEFT + band * (m.at + 0.5)}
    <line x1={mx} x2={mx} y1={TOP} y2={H - BOTTOM} class="ref" />
    <text x={mx + 4} y={TOP + 8} class="tick">{m.label}</text>
  {/each}
  {#each categories as c, i (c)}
    {#each series as s, j (s.name)}
      {@const v = s.values[i]}
      {@const bx = LEFT + band * i + band / 2 - (bw * series.length) / 2 + j * bw + 1}
      <g>
        <title>{c} · {s.name}: {format(v)}</title>
        <rect x={LEFT + band * i} y={TOP} width={band} height={H - BOTTOM - TOP} class="hit" />
        <path d={`M${bx},${H - BOTTOM} V${y(v) + Math.min(4, H - BOTTOM - y(v))} q0,-4 4,-4 h${bw - 10} q4,0 4,4 V${H - BOTTOM} Z`}
              fill={s.color ?? SERIES[j]} />
        {#if labels && v > 0}<text x={bx + (bw - 2) / 2} y={y(v) - 4} class="tick" text-anchor="middle">{format(v)}</text>{/if}
      </g>
    {/each}
    {#if i % every === 0}<text x={LEFT + band * (i + 0.5)} y={H - BOTTOM + 15} class="tick" text-anchor="middle">{c}</text>{/if}
  {/each}
  <line x1={LEFT} x2={W - RIGHT} y1={H - BOTTOM} y2={H - BOTTOM} class="axis" />
  {#if xlabel}<text x={(LEFT + W - RIGHT) / 2} y={H - 4} class="tick" text-anchor="middle">{xlabel}</text>{/if}
</svg>
{#if series.length > 1}
  <div class="legend-row">{#each series as s, j (s.name)}<span><i style:background={s.color ?? SERIES[j]}></i>{s.name}</span>{/each}</div>
{/if}

<style>
  .chart { width: 100%; height: auto; display: block; }
  .grid { stroke: var(--line); stroke-width: 1; }
  .axis { stroke: var(--muted); stroke-width: 1; }
  .ref { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 3 3; }
  .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  .hit { fill: transparent; }
  g:hover .hit { fill: rgba(255, 255, 255, .04); }
  .legend-row { display: flex; gap: 14px; margin-top: 4px; color: var(--muted); font-size: 12px; }
  .legend-row span { display: inline-flex; align-items: center; gap: 6px; }
  .legend-row i { width: 10px; height: 10px; border-radius: 2px; }
</style>
