<script lang="ts">
  // Right column, level with the court (the playback controls sit above it, Controls.svelte): the Display panel and
  // the two rosters. Each team keeps its club colours whichever end it plays. A roster row ends with the player's
  // archetype on that side of the ball: its name in an outlined pill of the archetype's colour, full name and
  // probability on hover. Clicking a row makes the trace panel under the court follow that player's distance to his
  // nearest opponent (clicking it again lets him go).
  //
  // With Season Context on, hovering a row opens a card of his season figures (offense only, from the aggregates,
  // which cover 293 games including these ten). Speeds, distances, minutes and spacing are in the trace panel's
  // Players tab.
  import { seasonLines, seasonOf } from "../lib/context";
  import { logoUrl } from "../lib/logos.svelte";
  import type { Play, PlayerTrack, Role } from "../lib/types";
  import { live, season, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const area = (role: Role) => (role === "off" ? live.areaOff : live.areaDef);
  const following = (id: number) => viewer.showTrace && viewer.trace === "nearest" && viewer.focusPid === id;

  const SECTIONS: { key: keyof typeof viewer.ann; label: string; title: string }[] = [
    { key: "events", label: "Event Markers", title: "Where each action happened: shot spots (filled made, ringed missed, coloured by contest), passes, dribbles, drives, screens, closeouts, fouls, rebounds, turnovers, and every player at the last shot's release (dashed)" },
    { key: "defense", label: "Defensive Context", title: "Coverage on screens, matchup lines with switches (SW), the shot's closest defender, and help defenders" },
    { key: "shot", label: "Shot Details", title: "A card for the last shot: distance, SkillCorner shot quality, contest, how it was created, shot clock, passer, free throws" },
    { key: "tracking", label: "Tracking Readouts", title: "Openness of each offensive player (feet to the nearest defender), the followed player's speed, the ball's path and the shot's ball peak" },
    { key: "possession", label: "Possession Context", title: "How the possession began, chances, touches, passes and dribbles so far, who has had the ball, game state, free throws" },
    { key: "quality", label: "Data Quality", title: "Extrapolated players drawn faint, tracking's expected error round each player, the chance's quality index" },
    { key: "season", label: "Season Context", title: "Season figures from the aggregates (293 games, offense only) on hover in the rosters, for the shot's zone and for picks" },
  ];

  // The season card beside a hovered roster row (fixed, so the scrolling column does not clip it).
  let card = $state<{ p: PlayerTrack; top: number; right: number } | null>(null);
  function enter(ev: MouseEvent, p: PlayerTrack): void {
    viewer.hoverPid = p.id;
    const box = (ev.currentTarget as HTMLElement).getBoundingClientRect();
    card = { p, top: box.top, right: window.innerWidth - box.left + 8 };
  }
  function leave(): void {
    viewer.hoverPid = null;
    card = null;
  }

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
    <!-- Left column: what is drawn on the court. Right column: the trace panel under it, its captions and how the plays run. -->
    <div class="toggle-grid by-column five">
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.off.fill} bind:checked={viewer.showOff} />Offensive hull</label>
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.def.fill} bind:checked={viewer.showDef} />Defensive hull</label>
      <label class="toggle" title="Tag each player on the court with his archetype (abbreviated, in its colour), as beside his name below">
        <input type="checkbox" bind:checked={viewer.showArch} />Player archetypes
      </label>
      <label class="toggle" title="A fading trail behind each player: where he has been over the last 0.6 seconds, so a longer trail means a faster player">
        <input type="checkbox" bind:checked={viewer.showTrails} />Player trails
      </label>
      <label class="toggle" title="Court control: at every spot, which team would get to the ball first if it were passed there now, allowing for the ball's travel time and each player's speed and direction. Pale is a toss-up.">
        <input type="checkbox" bind:checked={viewer.showControl} />Court control
      </label>
      <label class="toggle" title="The panel under the court: the play's actions and either the ball's height or a player's distance to his nearest opponent">
        <input type="checkbox" bind:checked={viewer.showTrace} />Trace panel
      </label>
      <label class="toggle" title="Caption the actions in the trace panel: the action above, the player below">
        <input type="checkbox" bind:checked={viewer.showTickLabels} />Action names
      </label>
      <label class="toggle"><input type="checkbox" checked={viewer.skipDead} onchange={(ev) => onskip(ev.currentTarget.checked)} />Skip dead ball</label>
      <!-- What happens at the end of a play: replay it, or go on to the next one in the possession list. -->
      <label class="switch two-way" title="At the end of a play: replay it (left) or play the next one in the possession list (right)">
        <span class:on={viewer.atEnd === "loop"}>Loop</span>
        <input type="checkbox" role="switch" aria-label="Play the next play at the end" checked={viewer.atEnd === "next"}
               onchange={(ev) => (viewer.atEnd = ev.currentTarget.checked ? "next" : "loop")} />
        <span class="switch-track"></span>
        <span class:on={viewer.atEnd === "next"}>Next play</span>
      </label>
    </div>
    {#if viewer.showControl && play}
      <p class="control-read">
        {#if live.control != null}
          <span class="legend"><i style:background={play.colors.off.fill}></i>{play.off}</span>
          <span class="legend"><i style:background={play.colors.def.fill}></i>{play.def}</span>
          <span>Offense controls <b>{Math.round(live.control * 100)}%</b> of its half</span>
        {:else}
          Court control needs five players a side and the ball in view.
        {/if}
      </p>
    {/if}
    <h3 class="sub-head">Annotations</h3>
    <div class="toggle-grid by-column four">
      {#each SECTIONS as sec}
        <label class="toggle" title={sec.title}><input type="checkbox" bind:checked={viewer.ann[sec.key]} />{sec.label}</label>
      {/each}
    </div>
  </div>

  {#each sides as side}
    {@const kit = play?.colors[side.role]}
    {@const logo = play ? logoUrl(side.role === "off" ? play.offTeam : play.defTeam) : null}
    <div class="panel roster" style:--kit-fill={kit?.fill} style:--kit-ink={kit?.ink} style:--kit-text={kit?.text}>
      <div class="roster-head">
        <h2>{#if logo}<img class="roster-logo" src={logo} alt="" />{/if}{play ? (side.role === "off" ? play.off : play.def) : ""}</h2>
        <p class="roster-sub">
          <span>{side.title}</span>{#if play && area(side.role) != null}<span class="hull" title="Area of the team's convex hull">Hull {area(side.role)} ft²</span>{/if}
        </p>
      </div>
      <ul>
        {#each play?.players.filter((p) => p.role === side.role) ?? [] as p (p.id)}
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
          <li class:bench={!live.onCourt.includes(p.id)} class:has-ball={live.handler === p.id} class:following={following(p.id)}
              title="Click to follow his distance to the nearest opponent"
              onmouseenter={(ev) => enter(ev, p)} onmouseleave={leave} onclick={() => follow(p.id)}>
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

{#if card && viewer.ann.season && play}
  <div class="season-card" style:top="{card.top}px" style:right="{card.right}px">
    <b>{card.p.name}</b>
    <span class="season-sub">Season, {card.p.role === "off" ? play.off : play.def} · offense</span>
    {#each seasonLines(seasonOf(season.data, card.p)) as line}
      <span class="card-line"><span>{line.k}</span><span>{line.v}</span></span>
    {/each}
  </div>
{/if}
