<script lang="ts">
  // Right column, level with the court (the playback controls sit above it, Controls.svelte): the Display panel and
  // the two rosters. Each team keeps its club colours whichever end it plays. A roster row ends with the player's
  // archetype on that side of the ball: its name in an outlined pill of the archetype's colour, full name and
  // probability on hover. Clicking a row makes the trace panel under the court follow that player's distance to his
  // nearest opponent (clicking it again lets him go).
  //
  // Hovering a row opens his player card (PlayerCard.svelte): season and tracked-game figures in four views. The
  // card stays open while the pointer is on it; clicking the row pins it (and follows him in the trace panel) until
  // the row is clicked again or the card's × is pressed. Hovering another row meanwhile shows that player's card,
  // and the pinned one comes back when the pointer leaves.
  import PlayerCard from "./PlayerCard.svelte";
  import { logoUrl } from "../lib/logos.svelte";
  import type { Play, PlayerTrack, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

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
  ];

  // The player card beside a roster row (fixed, so the scrolling column does not clip it): the hovered row's, else
  // the pinned one.
  type At = { p: PlayerTrack; top: number; right: number };
  let hovered = $state<At | null>(null);
  let pinned = $state<At | null>(null);
  const card = $derived(hovered ?? pinned);
  let hideTimer: ReturnType<typeof setTimeout> | undefined;
  const at = (ev: MouseEvent, p: PlayerTrack): At => {
    const box = (ev.currentTarget as HTMLElement).getBoundingClientRect();
    return { p, top: box.top, right: window.innerWidth - box.left + 8 };
  };
  function enter(ev: MouseEvent, p: PlayerTrack): void {
    clearTimeout(hideTimer);
    viewer.hoverPid = p.id;
    hovered = pinned?.p.id === p.id ? null : at(ev, p);
  }
  // A short grace before the card goes, so the pointer can cross the gap onto it.
  function leave(): void {
    viewer.hoverPid = null;
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => { hovered = null; }, 220);
  }
  const keep = () => clearTimeout(hideTimer);

  function follow(ev: MouseEvent, p: PlayerTrack): void {
    const on = pinned?.p.id === p.id;
    pinned = on ? null : at(ev, p);
    hovered = null;
    viewer.focusPid = on ? null : p.id;
    viewer.trace = "nearest";
    viewer.showTrace = true;
  }
  // A new play has new rows: let the pinned card go.
  $effect(() => {
    void play?.id;
    pinned = null;
    hovered = null;
  });
</script>

<aside class="side">
  <div class="panel display">
    <div class="panel-head">
      <h2>Display</h2>
      <!-- What happens at the end of a play: replay it, or go on to the next one in the possession list. -->
      <label class="switch two-way" title="At the end of a play: replay it (left) or play the next one in the possession list (right)">
        <span class:on={viewer.atEnd === "loop"}>Loop</span>
        <input type="checkbox" role="switch" aria-label="Play the next play at the end" checked={viewer.atEnd === "next"}
               onchange={(ev) => (viewer.atEnd = ev.currentTarget.checked ? "next" : "loop")} />
        <span class="switch-track"></span>
        <span class:on={viewer.atEnd === "next"}>Next play</span>
      </label>
      <button type="button" class="text-btn" class:recording={viewer.recording} disabled={!play} title="Record this play once through and save it as a video"
              onclick={() => (viewer.recording = !viewer.recording)}>
        {viewer.recording ? "Cancel recording" : "Save Video"}
      </button>
    </div>
    <!-- Left column: what is drawn on the court. Right column: the trace panel under it, its captions, dead-ball time and court control. -->
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
      <label class="toggle" title="Court control: at every spot, which team would get to the ball first if it were passed there now, allowing for the ball's travel time and each player's speed and direction. Pale is a toss-up.">
        <input type="checkbox" bind:checked={viewer.showControl} />Court control
      </label>
    </div>
    {#if viewer.showControl && play}
      <!-- Each team's share of the court: who would reach the ball first if it went to each spot. -->
      {@const off = live.control ? (viewer.controlScope === "half" ? live.control.half : live.control.court) : null}
      <div class="control-read">
        {#if off != null}
          <div class="control-shares" title={viewer.controlScope === "half"
            ? "Share of the half the offense attacks that each team would reach first if the ball went there now"
            : "Share of the whole court each team would reach first if the ball went there now"}>
            {#each [["off", off], ["def", 1 - off]] as const as [role, share] (role)}
              <i style:background={play.colors[role].fill}></i><span>{role === "off" ? play.off : play.def}</span><b>{Math.round(share * 100)}%</b>
            {/each}
          </div>
        {:else}
          <span class="control-note">Court control needs five players a side and the ball in view.</span>
        {/if}
        <div class="seg control-scope" role="radiogroup" aria-label="Court control over">
          <button type="button" role="radio" aria-checked={viewer.controlScope === "court"} class:on={viewer.controlScope === "court"}
                  title="Shares of the whole court" onclick={() => (viewer.controlScope = "court")}>Full</button>
          <button type="button" role="radio" aria-checked={viewer.controlScope === "half"} class:on={viewer.controlScope === "half"}
                  title="Shares of the half the offense attacks (the one that matters in a half-court set)" onclick={() => (viewer.controlScope = "half")}>Half</button>
        </div>
      </div>
    {/if}
    <h3 class="sub-head">Annotations</h3>
    <div class="toggle-grid by-column">
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
              class:pinned={pinned?.p.id === p.id}
              title="Click to pin his card and follow his distance to the nearest opponent"
              onmouseenter={(ev) => enter(ev, p)} onmouseleave={leave} onclick={(ev) => follow(ev, p)}>
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

{#if card && play}
  <PlayerCard p={card.p} team={card.p.role === "off" ? play.off : play.def} top={card.top} right={card.right}
              pinned={card === pinned} onenter={keep} onleave={leave}
              onclose={() => { pinned = null; hovered = null; viewer.focusPid = null; }} />
{/if}
