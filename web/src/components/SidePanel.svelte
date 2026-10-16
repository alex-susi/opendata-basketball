<script lang="ts">
  // Right column: display toggles, the EPV readout and overlay toggles, and the two rosters. Each team keeps its
  // club colours whichever end it plays. A roster row ends with the player's archetype on that side of the ball:
  // its name in an outlined pill of the archetype's colour, full name and probability on hover.
  import { CONTROL_COLORS, type ControlMode } from "../lib/controlLayer";
  import type { Play, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const modes: { value: ControlMode; label: string; title: string }[] = [
    { value: "control", label: "Control", title: "Who would get to the ball first if it went to each spot, allowing for its travel time" },
    { value: "relevant", label: "Relevant", title: "Control, shown where the ball is likely to be in about 1.5 seconds" },
    { value: "scoring", label: "Scoring", title: "Relevant offensive control times the expected points of a shot from each spot" },
  ];
  // What the shading means, by the surface showing. While a shot is in the air the rebound surface replaces the layer.
  const notes: Record<string, string> = {
    control: "Who would get to the ball first if it went there; pale is a toss-up. Spots far from the ball are less certain because it takes longer to get there.",
    relevant: "Control, faded where the ball is unlikely to be in the next 1.5 seconds.",
    scoring: "Blue: offensive control where the ball is likely to go, times the expected points of a shot from there.",
    rebound: "Shot in the air: where a miss is likely to be rebounded, and which team would get there first. The chance assumes a miss.",
  };
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
    <!-- Left column: what is drawn on the court. Right column: how the play runs and how much court shows. -->
    <div class="toggle-grid by-column">
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.off.fill} bind:checked={viewer.showOff} />Offensive hull</label>
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.def.fill} bind:checked={viewer.showDef} />Defensive hull</label>
      <label class="toggle" title="Ring each player on the court in the colour of his archetype, as beside his name below">
        <input type="checkbox" bind:checked={viewer.showArch} />Player archetypes
      </label>
      <label class="toggle"><input type="checkbox" checked={viewer.skipDead} onchange={(ev) => onskip(ev.currentTarget.checked)} />Skip dead ball</label>
      <label class="toggle"><input type="checkbox" bind:checked={viewer.loop} />Loop</label>
      <label class="switch" title="Show only the half the offense attacks">
        <input type="checkbox" role="switch" checked={viewer.view === "half"} onchange={(ev) => (viewer.view = ev.currentTarget.checked ? "half" : "full")} />
        <span class="switch-track"></span>Half court
      </label>
    </div>
  </div>

  <div class="panel display">
    <div class="panel-head">
      <h2>Court control</h2>
      <label class="switch" title="Shade the court by which team would get to the ball first">
        <input type="checkbox" role="switch" bind:checked={viewer.showControl} />
        <span class="switch-track"></span>Show
      </label>
    </div>
    <div class="mode-picks" class:dim={!viewer.showControl} role="radiogroup" aria-label="Court control layer">
      {#each modes as m (m.value)}
        <button type="button" class="text-btn" class:on={viewer.controlMode === m.value} title={m.title} role="radio"
                aria-checked={viewer.controlMode === m.value} onclick={() => (viewer.controlMode = m.value)}>{m.label}</button>
      {/each}
    </div>
    {#if viewer.showControl && live.control}
      <div class="readout" class:one={live.control.cells.length === 1} class:two={live.control.cells.length === 2}>
        {#each live.control.cells as [label, value] (label)}
          <div><span title={label}>{label}</span><b>{value}</b></div>
        {/each}
      </div>
      <p class="note">
        {#if live.control.kind !== "scoring"}<span class="legend"><i style:background={CONTROL_COLORS.off}></i>{play?.off ?? "Offense"}</span>
          <span class="legend"><i style:background={CONTROL_COLORS.def}></i>{play?.def ?? "Defense"}</span>{/if}
        {notes[live.control.kind]}
      </p>
    {:else if viewer.showControl}
      <p class="note">Nothing to shade at this moment (dead ball or players missing).</p>
    {/if}
  </div>

  <div class="panel display">
    <h2>Expected Possession Value</h2>
    {#if play?.epv}
      <div class="readout" title="EPV, turnover odds for the rest of the possession, cumulative turnover risk so far">
        {#each live.readout as [label, value] (label)}
          <div><span>{label}</span><b>{value}</b></div>
        {/each}
      </div>
    {/if}
    <label class="toggle" title="Show or hide every EPV label on the court"><input type="checkbox" bind:checked={viewer.showEpv} />Show/hide all</label>
    <!-- Three columns: the pass labels on the first row, the ball handler's on the second. -->
    <div class="toggle-grid three" class:dim={!viewer.showEpv}>
      <label class="toggle" title="Value of a pass to each teammate, coloured against current EPV, and the EPV under the ball handler"><input type="checkbox" bind:checked={viewer.showPassValues} />Pass values</label>
      <label class="toggle" title="Chance each pass is turned over"><input type="checkbox" bind:checked={viewer.showPassTov} />Pass TOV %</label>
      <label class="toggle" title="Line to the most valuable pass"><input type="checkbox" bind:checked={viewer.showBestPass} />Best pass</label>
      <label class="toggle" title="Chance the possession is lost in the next two seconds"><input type="checkbox" bind:checked={viewer.showBallTov} />Ball TOV risk</label>
      <label class="toggle" title="Value of shooting now against the best available pass"><input type="checkbox" bind:checked={viewer.showShotPass} />Shot / pass</label>
    </div>
    {#if play && !play.epv}
      <p class="note">No EPV prices for this play.</p>
    {/if}
  </div>

  {#each sides as side}
    {@const kit = play?.colors[side.role]}
    <div class="panel roster" style:--kit-fill={kit?.fill} style:--kit-edge={kit?.edge} style:--kit-ink={kit?.ink} style:--kit-text={kit?.text}>
      <div class="roster-head">
        <h2>{play ? (side.role === "off" ? play.off : play.def) : ""}</h2>
        <p class="roster-sub">
          <span>{side.title}</span>{#if play && area(side.role) != null}<span class="hull" title="Area of the team's convex hull">Hull {area(side.role)} ft²</span>{/if}
        </p>
      </div>
      <ul>
        {#each play?.players.filter((p) => p.role === side.role) ?? [] as p (p.id)}
          <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
          <li class:bench={!live.onCourt.includes(p.id)} class:has-ball={live.handler === p.id}
              onmouseenter={() => (viewer.hoverPid = p.id)} onmouseleave={() => (viewer.hoverPid = null)}>
            <span class="num">{p.jersey}</span><span class="name" title={p.name}>{p.name}</span><span class="ball-mark"></span>
            {#if p.arch}
              <span class="arch" style:--arch-color={`var(--arch-${p.arch.slot})`}
                    title={`${p.arch.name} · ${Math.round(p.arch.p * 100)}% likely`}>{p.arch.short}</span>
            {/if}
          </li>
        {/each}
      </ul>
    </div>
  {/each}
</aside>
