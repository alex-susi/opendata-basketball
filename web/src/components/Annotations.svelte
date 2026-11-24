<script lang="ts">
  // Cards over the backcourt (the half the offense is not attacking, so they rarely cover a player), from the
  // Display panel's Annotations toggles. (The shot card no longer opens by itself when a shot goes up; hovering a
  // shot in the trace panel shows it at any time, ActionCard.svelte.)
  //   Possession Context  how the possession began, chances and offensive rebounds, passes, dribbles and touches so
  //                       far, who has had the ball, the game state, free throws.
  //   Data Quality        the chance's tracking quality index and how many players are extrapolated now.
  //   Coverage Read       CoveragePanel.svelte, drawn here as a card while the court is at least 480 px wide (below the
  //                       court in App.svelte otherwise): the selected screen, the live model's forecast, its time trace
  //                       up to this moment, and the recorded coverage only once revealed.
  // The court's drawing is in lib/annotate.ts; the text in lib/context.ts.
  import { chanceAt, possessionCard, type Card } from "../lib/context";
  import { selectedScreen } from "../lib/coverageView.svelte";
  import type { Play } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";
  import CoveragePanel from "./CoveragePanel.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const poss = $derived(play && play.ann && viewer.ann.possession ? possessionCard(play, frame, play.gc[live.i0] ?? 0) : null);
  const quality = $derived.by((): Card | null => {
    if (!play || !viewer.ann.quality) return null;
    const chance = chanceAt(play, frame);
    const seen = play.players.filter((p) => !Number.isNaN(p.x[live.i0]));
    const guessed = seen.filter((p) => p.d[live.i0] === 0).length;
    const errs = seen.map((p) => p.e[live.i0]).filter((v) => !Number.isNaN(v));
    const lines = [];
    if (chance?.q != null) {
      lines.push({ k: "Chance Quality", v: `${chance.q} / 5${chance.q < 3 ? " · Low" : ""}`, tone: chance.q < 3 ? "#F5B02E" : undefined });
    }
    lines.push({ k: "Extrapolated", v: `${guessed} of ${seen.length} Players` });
    if (errs.length) lines.push({ k: "Mean Error (ft, 90% within)", v: (errs.reduce((a, b) => a + b, 0) / errs.length).toFixed(1) });
    return { title: "Tracking", lines };
  });

  // The coverage card shows while a screen is selected (pinned, or a window holds this frame).
  const covOn = $derived(!!(play && viewer.ann.coverage && selectedScreen(play, frame)));

  const box = $derived(live.box);
  // The cards never resize the court. The coverage card sits in the top corner on the backcourt side, the possession and
  // tracking cards in the bottom corner. When the two would overlap (a tall top card on a short court), the bottom
  // stack slides toward center court, beside the top card, instead of the court growing.
  const PAD = 10, GAP = 8;
  let topH = $state(0), topW = $state(0), botH = $state(0);
  const shift = $derived(box && topH && botH && topH + botH + GAP + 2 * PAD > box.h ? topW + GAP : 0);
  // Earlier versions grew the court window to fit both cards in one column (live.annNeed); nothing asks for that now.
  $effect(() => { if (live.annNeed) live.annNeed = 0; });
</script>

{#if play && box && box.w >= 480 && (poss || quality || covOn)}
  <!-- Cards sit against the backcourt's sideline end; each is as wide as its longest line. -->
  <div class="ann-cards {box.backLeft ? 'on-left' : 'on-right'}" style:left="{box.left}px" style:top="{box.top}px"
       style:width="{box.w}px" style:height="{box.h}px" style:--pad="{PAD}px">
    <div class="ann-stack top" class:low={shift > 0} bind:clientHeight={topH} bind:offsetWidth={topW} style:max-height="{box.h - 2 * PAD}px">
      {#if covOn}<CoveragePanel {play} {seq} layout="card" />{/if}
    </div>
    <div class="ann-stack bottom" bind:clientHeight={botH} style:--shift="{shift}px">
      {#if poss}{@render card(poss)}{/if}
      {#if quality}{@render card(quality)}{/if}
    </div>
  </div>
{/if}

{#snippet card(c: Card)}
  <div class="ann-card fixed-w">
    <!-- The title, and for a shot the shooter at the line's right end. -->
    <span class="card-title"><b style:color={c.tone}>{c.title}{#if c.flag}<i class="event-flag">{c.flag}</i>{/if}</b>{#if c.who}<b style:color={c.tone}>{c.who}</b>{/if}</span>
    {#each c.lines as line}
      {#if line.head}<span class="card-head">{line.k}</span>{:else}<span class="card-line" class:wrap={line.wrap}><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>{/if}
    {/each}
  </div>
{/snippet}

