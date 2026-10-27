<script lang="ts">
  // Points with optional reference lines (fits, identity) and optional vertical event marks; up to three groups,
  // each in its categorical slot. Also draws connected series (`lines`) for traces over time.
  import { fmt, linear, SERIES, ticks } from "./scale";

  interface Pt { x: number; y: number; g?: number; tip?: string }
  interface Ln { points: [number, number][]; label?: string; color?: string; dashed?: boolean }
  let { points = [], lines = [], groups = [], xlabel = "", ylabel = "", xdomain = null, ydomain = null, events = [],
        radius = 3, opacity = 0.55, xfmt = (v: number) => fmt(v, 1), yfmt = (v: number) => fmt(v, 1) }:
    { points?: Pt[]; lines?: Ln[]; groups?: string[]; xlabel?: string; ylabel?: string; xdomain?: [number, number] | null;
      ydomain?: [number, number] | null; events?: { x: number; label: string }[]; radius?: number; opacity?: number;
      xfmt?: (v: number) => string; yfmt?: (v: number) => string } = $props();

  const W = 640, H = 280, LEFT = 48, RIGHT = 14, BOTTOM = 40;
  // Room above the plot for the y-axis title and, when there are events, two staggered rows of their labels.
  const TOP = $derived((ylabel ? 22 : 10) + (events.length ? 26 : 0));
  const xs = $derived([...points.map((p) => p.x), ...lines.flatMap((l) => l.points.map((q) => q[0]))]);
  const ys = $derived([...points.map((p) => p.y), ...lines.flatMap((l) => l.points.map((q) => q[1]))]);
  const xd = $derived(xdomain ?? [Math.min(...xs), Math.max(...xs)]);
  const yd = $derived(ydomain ?? [Math.min(0, ...ys), Math.max(...ys) * 1.05]);
  const x = $derived(linear(xd[0], xd[1], LEFT, W - RIGHT));
  const y = $derived(linear(yd[0], yd[1], H - BOTTOM, TOP));
  const path = (pts: [number, number][]) => pts.map((q, i) => `${i ? "L" : "M"}${x(q[0]).toFixed(1)},${y(q[1]).toFixed(1)}`).join(" ");
  const uid = $props.id();
</script>

<svg viewBox={`0 0 ${W} ${H}`} class="chart" role="img" aria-label={`${ylabel} against ${xlabel}`}>
  {#each ticks(yd[0], yd[1], 4) as t (t)}
    <line x1={LEFT} x2={W - RIGHT} y1={y(t)} y2={y(t)} class="grid" />
    <text x={LEFT - 6} y={y(t) + 4} class="tick" text-anchor="end">{yfmt(t)}</text>
  {/each}
  {#each ticks(xd[0], xd[1], 6) as t (t)}
    <text x={x(t)} y={H - BOTTOM + 15} class="tick" text-anchor="middle">{xfmt(t)}</text>
  {/each}
  <line x1={LEFT} x2={W - RIGHT} y1={H - BOTTOM} y2={H - BOTTOM} class="axis" />
  {#each events as e (e.label)}
    <line x1={x(e.x)} x2={x(e.x)} y1={TOP} y2={H - BOTTOM} class="ref" />
    <text x={x(e.x) + 3} y={TOP - 4 - 13 * (events.indexOf(e) % 2)} class="tick ev">{e.label}</text>
  {/each}
  <clipPath id={`plot-${uid}`}><rect x={LEFT} y={TOP - 4} width={W - LEFT - RIGHT} height={H - BOTTOM - TOP + 8} /></clipPath>
  <g clip-path={`url(#plot-${uid})`}>
  {#each points as p, i (i)}
    <circle cx={x(p.x)} cy={y(p.y)} r={radius} fill={SERIES[p.g ?? 0]} opacity={opacity}><title>{p.tip ?? `${xfmt(p.x)}, ${yfmt(p.y)}`}</title></circle>
  {/each}
  {#each lines as l, i (i)}
    <path d={path(l.points)} fill="none" stroke={l.color ?? "var(--ink)"} stroke-width="2" stroke-linejoin="round" stroke-linecap="round"
          stroke-dasharray={l.dashed ? "5 4" : undefined} />
    {#if l.label}
      {@const end = l.points[l.points.length - 1]}
      <text x={x(end[0]) - 4} y={y(end[1]) - 6} class="tick" text-anchor="end">{l.label}</text>
    {/if}
  {/each}
  </g>
  {#if xlabel}<text x={(LEFT + W - RIGHT) / 2} y={H - 4} class="tick" text-anchor="middle">{xlabel}</text>{/if}
  {#if ylabel}<text x={LEFT - 40} y={12} class="tick">{ylabel}</text>{/if}
</svg>
{#if groups.length > 1}
  <div class="legend-row">{#each groups as g, j (g)}<span><i style:background={SERIES[j]}></i>{g}</span>{/each}</div>
{/if}

<style>
  .chart { width: 100%; height: auto; display: block; overflow: visible; }
  .grid { stroke: var(--line); stroke-width: 1; }
  .axis { stroke: var(--muted); stroke-width: 1; }
  .ref { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 3 3; }
  .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  .ev { font-size: 10px; }
  .legend-row { display: flex; gap: 14px; margin-top: 4px; color: var(--muted); font-size: 12px; }
  .legend-row span { display: inline-flex; align-items: center; gap: 6px; }
  .legend-row i { width: 10px; height: 10px; border-radius: 50%; }
</style>
