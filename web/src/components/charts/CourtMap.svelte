<script lang="ts">
  // Where rebounds were secured, as a smoothed density on the half court around the hoop (offense attacking right;
  // positions relative to the hoop in feet). One sequential blue ramp: darker is a larger share of rebounds per
  // square foot. Points may carry weights (the click-a-shot map weights each miss by how alike its shot is).
  // Hovering reads the share of rebounds within 3 ft of the pointer; with `onpick`, a click picks a court spot.
  import { gridOf, heatImage, kde, peak, type Pt } from "./kde";

  let { points, title = "", caption = null, bw = 1.5, vmax = null, x0 = -30, marks = [], target = null, onpick = null }:
    { points: Pt[]; title?: string; caption?: string | null; bw?: number; vmax?: number | null; x0?: number;
      marks?: { x: number; y: number; o: number }[]; target?: { x: number; y: number } | null;
      onpick?: ((x: number, y: number) => void) | null } = $props();

  const M = 3.28084, NEAR = 3;
  const X1 = 5.6, Y0 = -24.6, Y1 = 24.6, S = 7;   // feet relative to the hoop; pixels per foot
  const W = $derived((X1 - x0) * S), H = (Y1 - Y0) * S;
  const px = (x: number) => (x - x0) * S, py = (y: number) => (Y1 - y) * S;
  const grid = $derived(gridOf(x0, X1, Y0, Y1));
  const dens = $derived(kde(points, grid, bw));
  const image = $derived(heatImage(dens, grid, vmax ?? peak(dens)));
  const r3 = 6.75 * M, yc = 6.6 * M, xc = -Math.sqrt(r3 * r3 - yc * yc);
  const endline = 1.575 * M, keyX = -(5.8 - 1.575) * M, keyHW = 2.45 * M, half = -(14 - 1.575) * M;

  let hover = $state<{ x: number; y: number } | null>(null);
  const feet = (e: MouseEvent) => {
    const box = (e.currentTarget as SVGSVGElement).getBoundingClientRect();
    return { x: x0 + ((e.clientX - box.left) / box.width) * (W / S), y: Y1 - ((e.clientY - box.top) / box.height) * (H / S) };
  };
  const near = $derived.by(() => {
    if (!hover) return null;
    let all = 0, inside = 0, count = 0;
    for (const p of points) {
      const w = p.w ?? 1;
      all += w;
      if (Math.hypot(p.x - hover.x, p.y - hover.y) <= NEAR) { inside += w; count++; }
    }
    return all > 0 ? { share: inside / all, count } : null;
  });
</script>

<figure class="court-map" class:pick={!!onpick}>
  <!-- The pointer readout is an extra; with `onpick` the arrow keys move the picked spot 1 ft at a time. -->
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions, a11y_no_noninteractive_tabindex -->
  <svg viewBox={`0 0 ${W} ${H}`} role={onpick ? "application" : "img"} tabindex={onpick ? 0 : -1}
       aria-label={onpick ? `${title}: click or use the arrow keys to move the shot` : `${title}: smoothed density of ${points.length} rebound spots`}
       onmousemove={(e) => { hover = feet(e); }} onmouseleave={() => { hover = null; }}
       onclick={(e) => { if (onpick) { const q = feet(e); onpick(q.x, q.y); } }}
       onkeydown={(e) => {
         const step = ({ ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, 1], ArrowDown: [0, -1] } as Record<string, number[]>)[e.key];
         if (!onpick || !target || !step) return;
         e.preventDefault();
         onpick(target.x + step[0], target.y + step[1]);
       }}>
    <rect x="0" y="0" width={W} height={H} class="floor" />
    {#if image}<image href={image} x="0" y="0" width={grid.nx * grid.cell * S} height={grid.ny * grid.cell * S} preserveAspectRatio="none" />{/if}
    <g class="lines">
      <rect x={px(keyX)} y={py(keyHW)} width={(endline - keyX) * S} height={2 * keyHW * S} />
      <path d={`M${px(endline)},${py(yc)} H${px(xc)} A${r3 * S},${r3 * S} 0 0 0 ${px(xc)},${py(-yc)} H${px(endline)}`} />
      <line x1={px(0.375 * M)} x2={px(0.375 * M)} y1={py(0.9 * M)} y2={py(-0.9 * M)} />
      <circle cx={px(0)} cy={py(0)} r={0.225 * M * S} />
      <line x1={px(endline)} x2={px(endline)} y1="0" y2={H} />
      {#if x0 <= half}
        <line x1={px(half)} x2={px(half)} y1="0" y2={H} />
        <circle cx={px(half)} cy={py(0)} r={1.8 * M * S} />
      {/if}
    </g>
    {#each marks as m, i (i)}
      <circle cx={px(m.x)} cy={py(m.y)} r="2.6" class="mark" opacity={m.o} />
    {/each}
    {#if target}
      <circle cx={px(target.x)} cy={py(target.y)} r="7" class="target" />
      <circle cx={px(target.x)} cy={py(target.y)} r="2.2" class="target-dot" />
    {/if}
    {#if hover && near}
      <circle cx={px(hover.x)} cy={py(hover.y)} r={NEAR * S} class="probe" />
      <text x="8" y={H - 10} class="readout">{`${Math.round(100 * near.share)}% of rebounds within ${NEAR} ft of here${points.some((p) => p.w != null) ? "" : ` (${near.count})`}`}</text>
    {/if}
  </svg>
  {#if title}<figcaption>{title} <span>({caption ?? points.length})</span></figcaption>{/if}
</figure>

<style>
  .court-map { margin: 0; }
  svg { width: 100%; height: auto; display: block; border-radius: 6px; }
  .pick svg { cursor: crosshair; }
  .floor { fill: #F1F3F6; }   /* a cool neutral floor: the blue ramp turns grey over the viewer's tan */
  .lines { fill: none; stroke: #2B2622; stroke-width: 1.5; opacity: .7; pointer-events: none; }
  .mark { fill: none; stroke: #2B2622; stroke-width: 1.4; pointer-events: none; }
  .target { fill: none; stroke: #0B0E14; stroke-width: 3; pointer-events: none; }
  .target-dot { fill: #0B0E14; pointer-events: none; }
  .probe { fill: none; stroke: #0B0E14; stroke-width: 1.2; stroke-dasharray: 4 3; pointer-events: none; }
  .readout { fill: #0B0E14; font-size: 13px; font-weight: 600; paint-order: stroke; stroke: #F1F3F6; stroke-width: 4px; pointer-events: none; }
  figcaption { margin-top: 4px; font-size: 12px; color: var(--ink); text-align: center; }
  figcaption span { color: var(--muted); }
</style>
