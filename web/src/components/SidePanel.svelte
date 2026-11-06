<script lang="ts">
  // Right column: display toggles and the two rosters. Each team keeps its club colours whichever end it plays. A
  // roster row ends with the player's archetype on that side of the ball: its name in an outlined pill of the
  // archetype's colour, full name and probability on hover. Clicking a row makes the trace panel under the court
  // follow that player's distance to his nearest opponent (clicking it again lets him go).
  import type { Play, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const area = (role: Role) => (role === "off" ? live.areaOff : live.areaDef);
  const following = (id: number) => viewer.showTrace && viewer.trace === "nearest" && viewer.focusPid === id;

  function follow(id: number): void {
    viewer.focusPid = following(id) ? null : id;
    viewer.trace = "nearest";
    viewer.showTrace = true;
  }
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
    <!-- Left column: what is drawn. Right column: how the play runs and how much court shows. -->
    <div class="toggle-grid by-column four">
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.off.fill} bind:checked={viewer.showOff} />Offensive hull</label>
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.def.fill} bind:checked={viewer.showDef} />Defensive hull</label>
      <label class="toggle" title="Tag each player on the court with his archetype (abbreviated, in its colour), as beside his name below">
        <input type="checkbox" bind:checked={viewer.showArch} />Player archetypes
      </label>
      <label class="toggle" title="The panel under the court: ball height, or a player's distance to his nearest opponent">
        <input type="checkbox" bind:checked={viewer.showTrace} />Trace panel
      </label>
      <label class="toggle"><input type="checkbox" checked={viewer.skipDead} onchange={(ev) => onskip(ev.currentTarget.checked)} />Skip dead ball</label>
      <label class="toggle"><input type="checkbox" bind:checked={viewer.loop} />Loop</label>
      <label class="switch" title="Show only the half the offense attacks">
        <input type="checkbox" role="switch" checked={viewer.view === "half"} onchange={(ev) => (viewer.view = ev.currentTarget.checked ? "half" : "full")} />
        <span class="switch-track"></span>Half court
      </label>
    </div>
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
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
          <li class:bench={!live.onCourt.includes(p.id)} class:has-ball={live.handler === p.id} class:following={following(p.id)}
              title="Click to follow his distance to the nearest opponent"
              onmouseenter={() => (viewer.hoverPid = p.id)} onmouseleave={() => (viewer.hoverPid = null)} onclick={() => follow(p.id)}>
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
