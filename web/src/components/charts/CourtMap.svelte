<script lang="ts">
  // Where rebounds were secured, as counts in 2 ft cells on the half court around the hoop (offense attacking
  // right; positions relative to the hoop in feet). One sequential blue ramp; darker is more rebounds.
  import { RAMP } from "./scale";

  let { points, title = "", cell = 2 }: { points: { x: number; y: number }[]; title?: string; cell?: number } = $props();

  const M = 3.28084;
  const X0 = -30, X1 = 5.6, Y0 = -24.6, Y1 = 24.6, S = 7;   // feet relative to the hoop; pixels per foot
  const W = (X1 - X0) * S, H = (Y1 - Y0) * S;
  const px = (x: number) => (x - X0) * S, py = (y: number) => (Y1 - y) * S;
  const bins = $derived.by(() => {
    const m = new Map<string, number>();
    for (const p of points) {
      if (p.x < X0 || p.x > X1 || p.y < Y0 || p.y > Y1) continue;
      const k = `${Math.floor(p.x / cell)},${Math.floor(p.y / cell)}`;
      m.set(k, (m.get(k) ?? 0) + 1);
    }
    return [...m.entries()].map(([k, n]) => { const [i, j] = k.split(",").map(Number); return { i, j, n }; });
  });
  const top = $derived(Math.max(1, ...bins.map((b) => b.n)));
  const shade = (n: number) => RAMP[Math.min(RAMP.length - 1, Math.floor((n / top) * (RAMP.length - 0.01)))];
  const r3 = 6.75 * M, yc = 6.6 * M, xc = -Math.sqrt(r3 * r3 - yc * yc);
  const endline = 1.575 * M, keyX = -(5.8 - 1.575) * M, keyHW = 2.45 * M;
</script>

<figure class="court-map">
  <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${title}: ${points.length} rebound spots`}>
    <rect x="0" y="0" width={W} height={H} class="floor" />
    {#each bins as b (`${b.i},${b.j}`)}
      <rect x={px(b.i * cell)} y={py((b.j + 1) * cell)} width={cell * S} height={cell * S} fill={shade(b.n)}>
        <title>{b.n} rebound{b.n === 1 ? "" : "s"} in this {cell} ft cell</title>
      </rect>
    {/each}
    <g class="lines">
      <rect x={px(keyX)} y={py(keyHW)} width={(endline - keyX) * S} height={2 * keyHW * S} />
      <path d={`M${px(endline)},${py(yc)} H${px(xc)} A${r3 * S},${r3 * S} 0 0 0 ${px(xc)},${py(-yc)} H${px(endline)}`} />
      <line x1={px(0.375 * M)} x2={px(0.375 * M)} y1={py(0.9 * M)} y2={py(-0.9 * M)} />
      <circle cx={px(0)} cy={py(0)} r={0.225 * M * S} />
      <line x1={px(endline)} x2={px(endline)} y1="0" y2={H} />
    </g>
  </svg>
  {#if title}<figcaption>{title} <span>({points.length})</span></figcaption>{/if}
</figure>

<style>
  .court-map { margin: 0; }
  svg { width: 100%; height: auto; display: block; border-radius: 6px; }
  .floor { fill: #F6CFA3; }
  .lines { fill: none; stroke: #2B2622; stroke-width: 1.5; opacity: .7; }
  figcaption { margin-top: 4px; font-size: 12px; color: var(--ink); text-align: center; }
  figcaption span { color: var(--muted); }
</style>
