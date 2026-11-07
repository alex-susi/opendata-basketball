<script lang="ts">
  // Cards over the backcourt (the half the offense is not attacking, so they rarely cover a player), from the
  // Display panel's Annotations toggles:
  //   Shot Details        the last shot so far: distance, SkillCorner's shot quality, contest and closest defender,
  //                       how it was created, type, shot clock, passer, free throws; with Tracking Readouts the
  //                       ball's peak, with Season Context the shooter's season from that zone.
  //   Possession Context  how the possession began, chances and offensive rebounds, passes, dribbles and touches so
  //                       far, who has had the ball, the game state, free throws.
  //   Data Quality        the chance's tracking quality index and how many players are extrapolated now.
  // The court's drawing is in lib/annotate.ts; the text in lib/context.ts.
  import { chanceAt, lastShot, possessionCard, shotCard, type Card } from "../lib/context";
  import type { Play } from "../lib/types";
  import { live, season, viewer } from "../lib/viewer.svelte";

  let { play }: { play: Play | null } = $props();

  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const shot = $derived(play && viewer.ann.shot ? lastShot(play, frame) : null);
  const shotInfo = $derived(play && shot ? shotCard(play, shot, { peak: viewer.ann.tracking, season: viewer.ann.season ? season.data : null }) : null);
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
    if (errs.length) lines.push({ k: "Mean Error", v: `${(errs.reduce((a, b) => a + b, 0) / errs.length).toFixed(1)} ft (90% within)` });
    return { title: "Tracking", lines };
  });

  const box = $derived(live.box);
</script>

{#if play && box && box.w >= 480 && (shotInfo || poss || quality)}
  <!-- Cards sit against the backcourt's sideline end; each is as wide as its longest line. -->
  <div class="ann-cards {box.backLeft ? 'left' : 'right'}" style:left="{box.left}px" style:top="{box.top}px"
       style:width="{box.w}px" style:height="{box.h}px">
    <div class="ann-stack">{#if shotInfo}{@render card(shotInfo)}{/if}</div>
    <div class="ann-stack">
      {#if poss}{@render card(poss)}{/if}
      {#if quality}{@render card(quality)}{/if}
    </div>
  </div>
{/if}

{#snippet card(c: Card)}
  <div class="ann-card">
    <b style:color={c.tone}>{c.title}</b>
    {#each c.lines as line}
      <span class="card-line"><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>
    {/each}
  </div>
{/snippet}
