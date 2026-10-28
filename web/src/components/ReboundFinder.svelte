<script lang="ts">
  // Click a shot location; the map shows where misses from shots like it were rebounded. A conditional kernel
  // density: every real miss votes for the spot where its rebound was secured, with a say that falls off (as a
  // Gaussian of sd `width` ft) with the distance between its shot and the clicked one. No model is fitted; this is
  // the ten games' data, smoothed. Positions are relative to the hoop in feet, offense attacking right.
  import CourtMap from "./charts/CourtMap.svelte";

  interface Spot { sx: number; sy: number; rx: number; ry: number; off: boolean }
  let { spots }: { spots: Spot[] } = $props();

  const PRESETS: [string, number, number][] = [
    ["At the rim", -2, 0], ["Elbow", -13.9, -8], ["Baseline 2", -3, 14], ["Top of the key 3", -24.5, 0],
    ["Wing 3", -17, -17], ["Corner 3", -2, 22.5],
  ];
  const BW = 1.5;   // smoothing of the rebound spots themselves, as on the maps above

  let shot = $state({ x: -24.5, y: 0 });
  let width = $state(4);
  let mirror = $state(true);

  // Each real miss (and, with mirroring, its left-right reflection) weighted by how alike its shot is.
  const weighted = $derived.by(() => {
    const out: { x: number; y: number; w: number; sx: number; sy: number; off: boolean }[] = [];
    const k = 1 / (2 * width * width);
    for (const s of spots) {
      const copies = mirror ? [1, -1] : [1];
      for (const m of copies) {
        const w = Math.exp(-((s.sx - shot.x) ** 2 + (m * s.sy - shot.y) ** 2) * k);
        if (w > 1e-4) out.push({ x: s.rx, y: m * s.ry, w, sx: s.sx, sy: m * s.sy, off: s.off });
      }
    }
    return out;
  });
  const total = $derived(weighted.reduce((a, p) => a + p.w, 0));
  // Effective sample size: how many equally weighted misses the weights are worth.
  const nEff = $derived(total > 0 ? total ** 2 / weighted.reduce((a, p) => a + p.w * p.w, 0) : 0);
  const wmax = $derived(Math.max(1e-9, ...weighted.map((p) => p.w)));
  const marks = $derived(weighted.filter((p) => p.w / wmax > 0.08).map((p) => ({ x: p.sx, y: p.sy, o: 0.15 + 0.75 * (p.w / wmax) })));
  const stats = $derived.by(() => {
    if (!(total > 0)) return null;
    const by = [...weighted].map((p) => ({ r: Math.hypot(p.x, p.y), w: p.w })).sort((a, b) => a.r - b.r);
    let acc = 0, med = NaN;
    for (const q of by) { acc += q.w; if (acc >= total / 2) { med = q.r; break; } }
    // The rebound's direction from the hoop against the shot's, as in the angle chart (0° = straight back at the shooter).
    const aim = Math.atan2(shot.y, shot.x);
    const line = weighted.reduce((a, p) => {
      const d = Math.abs(((Math.atan2(p.y, p.x) - aim + 3 * Math.PI) % (2 * Math.PI)) - Math.PI);
      return a + (d <= Math.PI / 6 ? p.w : 0);
    }, 0) / total;
    const off = weighted.reduce((a, p) => a + (p.off ? p.w : 0), 0) / total;
    return { med, line, off, far: by.filter((q) => q.r > 10).reduce((a, q) => a + q.w, 0) / total };
  });
  const dist = $derived(Math.hypot(shot.x, shot.y));
  const pick = (x: number, y: number) => { shot = { x: Math.min(5, Math.max(-40, x)), y: Math.min(24.5, Math.max(-24.5, y)) }; };
</script>

<div class="finder">
  <div class="finder-map">
    <CourtMap points={weighted} x0={-41} bw={BW} {marks} target={shot} onpick={pick}
              title="Rebound spots after shots like the one marked" caption={`worth about ${Math.round(nEff)} misses`} />
  </div>
  <div class="finder-side">
    <div class="presets">
      {#each PRESETS as [label, x, y] (label)}
        <button type="button" class:on={Math.abs(shot.x - x) < 0.01 && Math.abs(shot.y - y) < 0.01} onclick={() => pick(x, y)}>{label}</button>
      {/each}
    </div>
    <label class="slider">
      <span>How alike a shot must be: <b>{width} ft</b></span>
      <input type="range" min="2" max="8" step="0.5" bind:value={width} />
    </label>
    <label class="check"><input type="checkbox" bind:checked={mirror} /> Borrow mirror-image shots (left ↔ right)</label>
    <dl class="finder-stats">
      <div><dt>Shot</dt><dd>{dist.toFixed(0)} ft from the hoop</dd></div>
      <div><dt>Evidence</dt><dd>worth {Math.round(nEff)} misses</dd></div>
      <div><dt>Median rebound distance</dt><dd>{stats ? `${stats.med.toFixed(1)} ft` : "–"}</dd></div>
      <div><dt>Rebounds over 10 ft out</dt><dd>{stats ? `${Math.round(100 * stats.far)}%` : "–"}</dd></div>
      <div title="Share of rebounds whose direction from the hoop is within 30° of the shot's own direction: straight back toward the shooter. A sixth of rebounds would be if direction were random.">
        <dt>Back along the shot's line (±30°)</dt><dd>{stats ? `${Math.round(100 * stats.line)}%` : "–"}</dd></div>
      <div><dt>Offense gets it</dt><dd>{stats ? `${Math.round(100 * stats.off)}%` : "–"}</dd></div>
    </dl>
    {#if nEff < 15}
      <p class="warn">Few misses came from shots like this one, so the map is mostly smoothing. Widen the similarity or pick a more common spot.</p>
    {/if}
    <p class="rb-note">Click anywhere on the court. Rings mark the real shots that count, darker the more alike they are.</p>
  </div>
</div>

<style>
  .finder { display: grid; grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr); gap: 18px; align-items: start; margin: 12px 0; }
  .finder-side { display: flex; flex-direction: column; gap: 12px; }
  .presets { display: flex; flex-wrap: wrap; gap: 6px; }
  .presets button { padding: 4px 9px; border: 1px solid var(--line); border-radius: 999px; background: var(--raised); color: var(--ink); font-size: 12px; cursor: pointer; }
  .presets button:hover { background: var(--hover); }
  .presets button.on { border-color: var(--off); color: var(--ink); background: var(--hover); }
  .slider { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--muted); }
  .slider b { color: var(--ink); }
  .check { display: flex; align-items: center; gap: 6px; font-size: 13px; }
  .finder-stats { margin: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .finder-stats div { padding: 7px 9px; border: 1px solid var(--line); border-radius: 8px; background: var(--raised); }
  .finder-stats dt { color: var(--muted); font-size: 11px; }
  .finder-stats dd { margin: 2px 0 0; font-size: 14px; font-weight: 700; font-variant-numeric: tabular-nums; }
  .warn { margin: 0; padding: 7px 9px; border-left: 3px solid #F5B02E; background: var(--raised); font-size: 12.5px; }
  @media (max-width: 860px) { .finder { grid-template-columns: 1fr; } .finder-map { max-width: 520px; } }
</style>
