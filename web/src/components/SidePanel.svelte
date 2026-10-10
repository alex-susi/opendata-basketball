<script lang="ts">
  // Right column: display toggles, EPV overlay toggles and the two rosters.
  import type { Play, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const area = (role: Role) => (role === "off" ? live.areaOff : live.areaDef);
</script>

<aside class="side">
  <div class="panel display">
    <h2>Display</h2>
    <div class="toggle-grid">
      <label class="toggle wide"><input type="checkbox" class="off" bind:checked={viewer.showOff} />Offensive hull</label>
      <label class="toggle wide"><input type="checkbox" class="def" bind:checked={viewer.showDef} />Defensive hull</label>
      <label class="toggle"><input type="checkbox" checked={viewer.skipDead} onchange={(ev) => onskip(ev.currentTarget.checked)} />Skip dead ball</label>
      <label class="toggle"><input type="checkbox" bind:checked={viewer.loop} />Loop</label>
      <label class="toggle wide"><input type="checkbox" bind:checked={viewer.markExtrap} />Mark extrapolated positions</label>
    </div>
    <div class="segmented" role="group" aria-label="Court view">
      <button type="button" class:on={viewer.view === "full"} onclick={() => (viewer.view = "full")}>Full court</button>
      <button type="button" class:on={viewer.view === "half"} onclick={() => (viewer.view = "half")}>Half court</button>
    </div>
    <button type="button" class="text-btn" class:recording={viewer.recording} disabled={!play} onclick={() => (viewer.recording = !viewer.recording)}>
      {viewer.recording ? "Recording… click to cancel" : "Save animation as video"}
    </button>
  </div>

  <div class="panel display">
    <h2>Expected Possession Value</h2>
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
    <div class="panel roster {side.role}">
      <h2><span class="role">{side.title}</span><span class="team">{play ? (side.role === "off" ? play.off : play.def) : ""}</span></h2>
      <ul>
        {#each play?.players.filter((p) => p.role === side.role) ?? [] as p (p.id)}
          <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
          <li class:bench={!live.onCourt.includes(p.id)} class:has-ball={live.handler === p.id}
              onmouseenter={() => (viewer.hoverPid = p.id)} onmouseleave={() => (viewer.hoverPid = null)}>
            <span class="num">{p.jersey}</span><span class="name">{p.name}</span><span class="ball-mark"></span>
          </li>
        {/each}
      </ul>
      <p class="hull-area">{play && area(side.role) != null ? `Hull area ${area(side.role)} sq ft` : ""}</p>
    </div>
  {/each}
</aside>
