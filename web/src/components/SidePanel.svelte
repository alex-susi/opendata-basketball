<script lang="ts">
  // Right column: display toggles, the EPV readout and overlay toggles, and the two rosters. Each team keeps its
  // club colours whichever end it plays. A roster row ends with the player's archetype on that side of the ball:
  // a colour swatch and a short label, full name on hover.
  import type { Play, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const area = (role: Role) => (role === "off" ? live.areaOff : live.areaDef);
</script>

<aside class="side">
  <div class="panel display">
    <div class="panel-head">
      <h2>Display</h2>
      <button type="button" class="text-btn" class:recording={viewer.recording} disabled={!play} title="Record this play once through and save it as a video"
              onclick={() => (viewer.recording = !viewer.recording)}>
        {viewer.recording ? "Cancel recording" : "Save Video"}
      </button>
    </div>
    <div class="hull-row">
      <div>
        <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.off.fill} bind:checked={viewer.showOff} />Offensive hull</label>
        <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.def.fill} bind:checked={viewer.showDef} />Defensive hull</label>
      </div>
      <label class="switch" title="Show only the half the offense attacks">
        <input type="checkbox" role="switch" checked={viewer.view === "half"} onchange={(ev) => (viewer.view = ev.currentTarget.checked ? "half" : "full")} />
        <span class="switch-track"></span>Half court
      </label>
    </div>
    <div class="toggle-grid">
      <label class="toggle"><input type="checkbox" checked={viewer.skipDead} onchange={(ev) => onskip(ev.currentTarget.checked)} />Skip dead ball</label>
      <label class="toggle"><input type="checkbox" bind:checked={viewer.loop} />Loop</label>
      <label class="toggle wide"><input type="checkbox" bind:checked={viewer.markExtrap} />Mark extrapolated positions</label>
    </div>
  </div>

  <div class="panel display">
    <h2>Expected Possession Value</h2>
    {#if play?.epv && viewer.showEpv && viewer.showReadout}
      <div class="readout" title="EPV, turnover odds for the rest of the possession, cumulative turnover risk so far">
        {#each live.readout as [label, value] (label)}
          <div><span>{label}</span><b>{value}</b></div>
        {/each}
      </div>
    {/if}
    <label class="toggle"><input type="checkbox" bind:checked={viewer.showEpv} />Show EPV overlay</label>
    <div class="toggle-grid" class:dim={!viewer.showEpv}>
      <label class="toggle" title="EPV, turnover odds for the rest of the possession, cumulative turnover risk so far"><input type="checkbox" bind:checked={viewer.showReadout} />Readout</label>
      <label class="toggle" title="Value of a pass to each teammate, coloured against current EPV, and the EPV under the ball handler"><input type="checkbox" bind:checked={viewer.showPassValues} />Pass values</label>
      <label class="toggle" title="Chance each pass is turned over"><input type="checkbox" bind:checked={viewer.showPassTov} />Pass TOV %</label>
      <label class="toggle" title="Chance the possession is lost in the next two seconds"><input type="checkbox" bind:checked={viewer.showBallTov} />Ball TOV risk</label>
      <label class="toggle" title="Value of shooting now against the best available pass"><input type="checkbox" bind:checked={viewer.showShotPass} />Shot / pass</label>
      <label class="toggle" title="Line to the most valuable pass"><input type="checkbox" bind:checked={viewer.showBestPass} />Best pass</label>
    </div>
    {#if play && !play.epv}
      <p class="note">No EPV prices for this play.</p>
    {/if}
  </div>

  {#each sides as side}
    {@const kit = play?.colors[side.role]}
    <div class="panel roster" style:--kit-fill={kit?.fill} style:--kit-edge={kit?.edge} style:--kit-ink={kit?.ink} style:--kit-text={kit?.text}>
      <h2><span class="role">{side.title}</span><span class="team">{play ? (side.role === "off" ? play.off : play.def) : ""}</span></h2>
      <ul>
        {#each play?.players.filter((p) => p.role === side.role) ?? [] as p (p.id)}
          <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
          <li class:bench={!live.onCourt.includes(p.id)} class:has-ball={live.handler === p.id}
              onmouseenter={() => (viewer.hoverPid = p.id)} onmouseleave={() => (viewer.hoverPid = null)}>
            <span class="num">{p.jersey}</span><span class="name" title={p.name}>{p.name}</span><span class="ball-mark"></span>
            {#if p.arch}
              <span class="arch" title={`${p.arch.name} · ${Math.round(p.arch.p * 100)}% likely`}>
                <span class="swatch" style:background={`var(--arch-${p.arch.slot})`}></span><span class="arch-label">{p.arch.short}</span>
              </span>
            {/if}
          </li>
        {/each}
      </ul>
      <p class="hull-area">{play && area(side.role) != null ? `Hull area ${area(side.role)} sq ft` : ""}</p>
    </div>
  {/each}
</aside>
