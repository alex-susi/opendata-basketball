<script lang="ts">
  // Right column, level with the court (the playback controls sit above it, Controls.svelte): the Display panel and
  // the two rosters. Each team keeps its club colours whichever end it plays. A roster row ends with the player's
  // archetype on that side of the ball: its name in an outlined pill of the archetype's colour, full name and
  // probability on hover. Clicking a row makes the trace panel under the court follow that player's distance to his
  // chosen measure (clicking it again lets him go).
  //
  // Hovering a row only rings the player on the court. Clicking it opens his player card (PlayerCard.svelte) under
  // his team's roster (and follows him in the trace panel) until the row is clicked again or the card's × is pressed.
  import PlayerCard from "./PlayerCard.svelte";
  import { logoUrl } from "../lib/logos.svelte";
  import { pageText } from "../lib/theme.svelte";
  import type { Play, PlayerTrack, Role } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, onskip }: { play: Play | null; onskip: (skip: boolean) => void } = $props();

  const sides: { role: Role; title: string }[] = [{ role: "off", title: "Offense" }, { role: "def", title: "Defense" }];
  const area = (role: Role) => (role === "off" ? live.areaOff : live.areaDef);
  const following = (id: number) => viewer.showTrace && viewer.trace === "player" && viewer.focusPid === id;

  const SECTIONS: { key: keyof typeof viewer.ann; label: string; title: string }[] = [
    { key: "events", label: "Event Markers", title: "Where each action happened: shot spots (filled made, ringed missed, coloured by contest), passes, dribbles, drives, screens, closeouts, fouls, rebounds, turnovers, and every player at the last shot's release (dashed)" },
    { key: "defense", label: "Defensive Context", title: "Coverage on screens, matchup lines with switches (SW), the shot's closest defender, and help defenders" },
    { key: "shot", label: "Shot Details", title: "A card for the last shot: distance, SkillCorner shot quality, contest, how it was created, shot clock, passer, free throws" },
    { key: "tracking", label: "Tracking Readouts", title: "Openness of each offensive player (feet to the nearest defender), the followed player's speed, the ball's path and the shot's ball peak" },
    { key: "possession", label: "Possession Context", title: "How the possession began, chances, touches, passes and dribbles so far, who has had the ball, game state, free throws" },
    { key: "glass", label: "Rebounding Roles", title: "While a shot is in the air: which attackers crash the glass, retreat, stay back as the safety or hold their spot, and which defenders box out (? = mostly off camera)" },
    { key: "coverage", label: "Screen Coverage Read", title: "Around each on-ball screen (2 s before to 1 s after): the live model's probability for each defender's call (on the ball: over, under, switch; on the screener: show, soft, switch) and the most likely joint call. The model is a transformer that reads all ten players' last 1.6 s and is never told when the screen comes, held out from this game. The tagged call is ticked once the screen is set" },
    { key: "attention", label: "Model Attention", title: "Around each on-ball screen: a purple ring on each player sized by how much of the live coverage model's attention the four players of the screen give him (last layer, heads averaged), with the top three labelled. Attention shows which players' information the model mixes in, not what caused the call" },
    { key: "lanes", label: "Roll Lanes", title: "Around each on-ball screen (2 s before to 1 s after): the straight lane from the screener to the rim (gold dashes), each off-ball defender's nearest point on it (dotted), an arrow for his last 0.2 s, and the experiment's inputs: his gap to the lane and how fast it closed (+ = moving toward it). These are inputs of an experimental model variant, not the live Coverage Read; a still-approaching screener or a pop makes the lane a poor guide" },
    { key: "quality", label: "Data Quality", title: "Extrapolated players drawn faint, tracking's expected error round each player, the chance's quality index" },
  ];

  // The player whose card is open (clicked).
  let pinned = $state<PlayerTrack | null>(null);

  function follow(p: PlayerTrack): void {
    const on = pinned?.id === p.id;
    pinned = on ? null : p;
    viewer.focusPid = on ? null : p.id;
    viewer.trace = "player";
    viewer.showTrace = true;
  }
  // A new play has new rows: let the open card go.
  $effect(() => {
    void play?.id;
    pinned = null;
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
      <label class="toggle" title="Caption the actions in the trace panel, above the chart">
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
    <div class="toggle-grid by-column five">
      {#each SECTIONS as sec}
        <label class="toggle" title={sec.title}><input type="checkbox" bind:checked={viewer.ann[sec.key]} />{sec.label}</label>
      {/each}
    </div>
  </div>

  {#each sides as side}
    {@const kit = play?.colors[side.role]}
    {@const logo = play ? logoUrl(side.role === "off" ? play.offTeam : play.defTeam) : null}
    <div class="panel roster" style:--kit-fill={kit?.fill} style:--kit-ink={kit?.ink} style:--kit-text={pageText(kit?.text)}>
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
              class:pinned={pinned?.id === p.id}
              title="Click to open his card and follow him in the trace panel"
              onmouseenter={() => (viewer.hoverPid = p.id)} onmouseleave={() => (viewer.hoverPid = null)} onclick={() => follow(p)}>
            <span class="num">{p.jersey}</span><span class="name" title={p.name}>{p.name}</span><span class="ball-mark"></span>
            {#if p.arch}
              <span class="arch" style:--arch-color={`var(--arch-${p.arch.slot})`}
                    title={`${p.arch.name} · ${Math.round(p.arch.p * 100)}% likely`}>{p.arch.short}</span>
            {/if}
          </li>
        {/each}
      </ul>
    </div>
    {#if play && pinned?.role === side.role}
      <PlayerCard p={pinned} kit={play.colors[side.role]} inline onclose={() => { pinned = null; viewer.focusPid = null; }} />
    {/if}
  {/each}
</aside>

