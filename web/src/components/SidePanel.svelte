<script lang="ts">
  // Right column, level with the court (the playback controls sit above it, Controls.svelte): the Display panel and
  // the two rosters. Each team keeps its club colours whichever end it plays. A roster row ends with the player's
  // archetype on that side of the ball: its name in an outlined pill of the archetype's colour, full name and
  // probability on hover. Clicking a row makes the trace panel under the court follow that player's distance to his
  // nearest opponent (clicking it again lets him go).
  //
  // Annotations add to the rosters: with Tracking Readouts each player's speed and the distance he has covered in
  // the play, the offense's spacing and the defense's rim protector; with Possession Context his minutes played
  // entering the chance; with Season Context a card of his season figures on hover (offense only, from the
  // aggregates, which cover 293 games including these ten).
  import { minutesAt, seasonLines, seasonOf, nameOf } from "../lib/context";
  import { motion, spacing } from "../lib/motion";
  import type { Play, PlayerTrack, Role } from "../lib/types";
  import { live, season, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const area = (role: Role) => (role === "off" ? live.areaOff : live.areaDef);
  const following = (id: number) => viewer.showTrace && viewer.trace === "nearest" && viewer.focusPid === id;

  const SECTIONS: { key: keyof typeof viewer.ann; label: string; title: string }[] = [
    { key: "events", label: "Event markers", title: "Where each action happened: shot spots (filled made, ringed missed, coloured by contest), passes, dribbles, drives, screens, closeouts, fouls, rebounds, turnovers, and every player at the last shot's release (dashed)" },
    { key: "defense", label: "Defensive context", title: "Coverage on screens, matchup lines with switches (SW), the shot's closest defender, and help defenders" },
    { key: "shot", label: "Shot details", title: "A card for the last shot: distance, SkillCorner shot quality, contest, how it was created, shot clock, passer, free throws" },
    { key: "tracking", label: "Tracking readouts", title: "Openness of each offensive player (feet to the nearest defender), speed and distance covered, spacing, the rim protector, the ball's path" },
    { key: "possession", label: "Possession context", title: "How the possession began, chances, passes, dribbles and touches so far, who has had the ball, game state, free throws, minutes played" },
    { key: "quality", label: "Data quality", title: "Extrapolated players drawn faint, tracking's expected error round each player, the chance's quality index" },
    { key: "season", label: "Season context", title: "Season figures from the aggregates (293 games, offense only) on hover in the rosters, for the shot's zone and for picks" },
  ];

  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const moved = $derived(play && viewer.ann.tracking ? motion(play) : null);
  const spaced = $derived(play && viewer.ann.tracking ? spacing(play, Math.min(live.i0, play.frames.length - 1)) : null);
  const minutes = $derived(play && play.ann && viewer.ann.possession ? minutesAt(play, frame) : null);

  // Two short lines: speed now, then distance covered in the play and minutes entering the chance.
  function meta(p: PlayerTrack): [string, string] {
    if (!play) return ["", ""];
    const at = play.players.indexOf(p), lower: string[] = [];
    let upper = "";
    if (moved && at >= 0) {
      const v = moved.speed[at][live.i0];
      upper = `${Number.isNaN(v) ? "–" : v.toFixed(1)} ft/s`;
      lower.push(`${moved.covered[at][live.i0].toFixed(0)} ft`);
    }
    const min = minutes?.get(p.id);
    if (min != null) lower.push(`${min.toFixed(0)} min`);
    return [upper, lower.join(" · ")];
  }

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
    <div class="toggle-grid by-column four">
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.off.fill} bind:checked={viewer.showOff} />Offensive hull</label>
      <label class="toggle"><input type="checkbox" style:accent-color={play?.colors.def.fill} bind:checked={viewer.showDef} />Defensive hull</label>
      <label class="toggle" title="Tag each player on the court with his archetype (abbreviated, in its colour), as beside his name below">
        <input type="checkbox" bind:checked={viewer.showArch} />Player archetypes
      </label>
      <label class="toggle" title="A fading trail behind each player: where he has been over the last 0.6 seconds, so a longer trail means a faster player">
        <input type="checkbox" bind:checked={viewer.showTrails} />Player trails
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
    <h3 class="sub-head">Annotations</h3>
    <div class="toggle-grid by-column four">
      {#each SECTIONS as sec}
        <label class="toggle" title={sec.title}><input type="checkbox" bind:checked={viewer.ann[sec.key]} />{sec.label}</label>
      {/each}
    </div>
  </div>

  {#each sides as side}
    {@const kit = play?.colors[side.role]}
    <div class="panel roster" style:--kit-fill={kit?.fill} style:--kit-ink={kit?.ink} style:--kit-text={kit?.text}>
      <div class="roster-head">
        <h2>{play ? (side.role === "off" ? play.off : play.def) : ""}</h2>
        <p class="roster-sub">
          <span>{side.title}</span>{#if play && area(side.role) != null}<span class="hull" title="Area of the team's convex hull">Hull {area(side.role)} ft²</span>{/if}
        </p>
      </div>
        {#if spaced && side.role === "off"}
          <p class="roster-sub readout" title="Mean distance between the offensive players on court; offensive players in the paint">
            Spacing {spaced.spread == null ? "–" : spaced.spread.toFixed(1)} ft · {spaced.paint} in paint
          </p>
        {:else if spaced && side.role === "def" && play}
          <p class="roster-sub readout" title="The defender closest to the hoop the offense attacks, and his distance to it">
            Rim protector {spaced.rim ? `${nameOf(play, spaced.rim.pid)} ${spaced.rim.dist.toFixed(1)} ft` : "–"}
          </p>
        {/if}
      <ul>
        {#each play?.players.filter((p) => p.role === side.role) ?? [] as p (p.id)}
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
          <li class:bench={!live.onCourt.includes(p.id)} class:has-ball={live.handler === p.id} class:following={following(p.id)}
              title="Click to follow his distance to the nearest opponent"
              onmouseenter={(ev) => enter(ev, p)} onmouseleave={leave} onclick={() => follow(p.id)}>
            <span class="num">{p.jersey}</span><span class="name" title={p.name}>{p.name}</span><span class="ball-mark"></span>
            {#if moved || minutes}
              {@const m = meta(p)}
              <span class="meta" title="Speed now · feet covered in this play · minutes played entering the chance">
                {#if m[0]}<span>{m[0]}</span>{/if}<span>{m[1]}</span>
              </span>
            {/if}
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
