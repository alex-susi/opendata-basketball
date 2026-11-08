<script lang="ts">
  // One player's figures in five views (Basic, Advanced, Tracking, Actions, Playstyle), from the season aggregates,
  // the ten tracked games and the archetype model (lib/player.ts). Tinted with his team's primary colour; the chosen
  // view's button in its secondary colour. Two placements:
  //   floating  beside a hovered roster row (fixed to the window), open while the pointer is on the row or the card
  //   inline    pinned (the row was clicked): under his team's roster in the right column, until closed
  import StatTable from "./StatTable.svelte";
  import { CARD_VIEWS, playerSections, playstyleOf } from "../lib/player";
  import type { PlayerTrack, TeamColors } from "../lib/types";
  import { season, viewer } from "../lib/viewer.svelte";

  let { p, kit, top = 0, right = 0, inline = false, onenter, onleave, onclose }: {
    p: PlayerTrack; kit: TeamColors; top?: number; right?: number; inline?: boolean;
    onenter?: () => void; onleave?: () => void; onclose?: () => void;
  } = $props();

  let h = $state(0);
  // Level with the row, but kept inside the window.
  const y = $derived(Math.max(8, Math.min(top, window.innerHeight - h - 8)));
  const sections = $derived(viewer.cardView === "playstyle" ? [] : playerSections(viewer.cardView, season.data, season.sample, p));
  const style = $derived(viewer.cardView === "playstyle" ? playstyleOf(season.style, p) : []);
  const games = $derived(season.sample?.games ?? 10);

  // Dark or light text, whichever reads on the secondary colour.
  function inkOn(hex: string): string {
    const n = parseInt(hex.replace("#", "").padEnd(6, "0").slice(0, 6), 16);
    const lin = (c: number) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    const L = 0.2126 * lin((n >> 16) & 255) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
    return L > 0.4 ? "#0F1522" : "#FFFFFF";
  }
  const pctOf = (v: number) => `${Math.round(v * 100)}%`;
  const swatch = (slot?: string) => (slot ? `var(--arch-${slot})` : "var(--muted)");

  // The archetype pie: one slice per archetype with a probability of at least 1%, its percentage inside when the
  // slice is big enough to hold it.
  const R = 40, C = 44;
  function slices(arch: { name: string; slot?: string; p: number }[]) {
    const shown = arch.filter((a) => a.p >= 0.01);
    const total = shown.reduce((t, a) => t + a.p, 0) || 1;
    let at = -Math.PI / 2;
    return shown.map((a) => {
      const sweep = (a.p / total) * 2 * Math.PI, mid = at + sweep / 2;
      const x0 = C + R * Math.cos(at), y0 = C + R * Math.sin(at);
      at += sweep;
      const x1 = C + R * Math.cos(at), y1 = C + R * Math.sin(at);
      const d = sweep >= 2 * Math.PI - 1e-6 ? null : `M${C},${C} L${x0.toFixed(2)},${y0.toFixed(2)} A${R},${R} 0 ${sweep > Math.PI ? 1 : 0} 1 ${x1.toFixed(2)},${y1.toFixed(2)} Z`;
      const r = sweep > 5 ? 0 : R * 0.62;
      return { ...a, d, lx: C + r * Math.cos(mid), ly: C + r * Math.sin(mid), label: a.p >= 0.09 };
    });
  }

  // Component bars: the fill runs from the centre toward the score's end, never narrower than its number.
  const FULL = 2.5;   // a score this far from 0 fills its half
  const MIN_FILL = 30;   // % of the axis: room for "+1.58"
  const fillOf = (v: number) => Math.max(MIN_FILL / 2, Math.min(Math.abs(v) / FULL, 1) * 50);
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="player-card" class:season-card={!inline} class:inline style:top={inline ? null : `${y}px`}
     style:right={inline ? null : `${right}px`} bind:clientHeight={h}
     style:--team-fill={kit.fill} style:--team-edge={kit.edge} style:--team-edge-ink={inkOn(kit.edge)}
     onmouseenter={onenter} onmouseleave={onleave}>
  <div class="pc-head">
    <b>#{p.jersey} {p.name}</b>
    {#if inline}<button type="button" class="pc-close" aria-label="Close the card" title="Close (or click his row again)" onclick={onclose}>×</button>{/if}
  </div>
  <div class="pc-views" role="radiogroup" aria-label="Figures shown">
    {#each CARD_VIEWS as v (v.key)}
      <button type="button" role="radio" aria-checked={viewer.cardView === v.key} class:on={viewer.cardView === v.key}
              onclick={() => (viewer.cardView = v.key)}>{v.label}</button>
    {/each}
  </div>
  {#if viewer.cardView === "playstyle"}
    {#if style.length}
      {#each style as side (side.side)}
        <div class="ps-side">
          <span class="stat-title">{side.title}</span>
          <div class="ps-arch">
            <svg class="ps-pie" viewBox="0 0 {2 * C} {2 * C}" role="img" aria-label="{side.title} archetype probabilities">
              {#each slices(side.archetypes) as sl (sl.name)}
                {#if sl.d}<path d={sl.d} fill={swatch(sl.slot)} />{:else}<circle cx={C} cy={C} r={R} fill={swatch(sl.slot)} />{/if}
              {/each}
              {#each slices(side.archetypes).filter((sl) => sl.label) as sl (sl.name)}
                <text x={sl.lx} y={sl.ly} text-anchor="middle" dominant-baseline="central">{pctOf(sl.p)}</text>
              {/each}
            </svg>
            <ul class="ps-key">
              {#each side.archetypes.filter((a) => a.p >= 0.01) as a (a.name)}
                <li class:top={a.name === side.top}><i style:background={swatch(a.slot)}></i><span>{a.name}</span><b>{pctOf(a.p)}</b></li>
              {/each}
            </ul>
          </div>
          <div class="ps-comps">
            {#each side.components as c (c.j)}
              <span class="ps-end minus" title={c.context}>{c.minus}</span>
              <span class="ps-axis" title={`Component ${c.j}, ${Math.round(c.share * 100)}% of variance: ${c.context}`}>
                {#if c.score != null}
                  <span class="ps-fill" style:width="{fillOf(c.score)}%" style:left="{c.score < 0 ? 50 - fillOf(c.score) : 50}%">
                    {c.score > 0 ? "+" : ""}{c.score.toFixed(2)}
                  </span>
                {:else}
                  <span class="ps-none">–</span>
                {/if}
              </span>
              <span class="ps-end plus" title={c.context}>{c.plus}</span>
            {/each}
          </div>
          {#if !side.defines}<ul class="pc-foot"><li>Outside the model's fit set (small sample)</li></ul>{/if}
        </div>
      {/each}
    {:else}
      <span class="pc-empty">{season.style ? "Not in the archetype model" : "Loading…"}</span>
    {/if}
  {:else if !season.data && !season.sample}
    <span class="pc-empty">Loading…</span>
  {:else if sections.length}
    <StatTable {sections} />
  {:else}
    <span class="pc-empty">No figures for this view</span>
  {/if}
  {#if viewer.cardView !== "playstyle"}
    <ul class="pc-foot">
      <li><b>Season</b>: aggregates, 293 games, offense only</li>
      <li><b>Tracked</b>: the {games} viewer games, this team</li>
      <li>Hover a label for its definition</li>
    </ul>
  {/if}
</div>
