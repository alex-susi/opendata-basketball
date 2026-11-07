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
      lines.push({ k: "Chance quality", v: `${chance.q} / 5${chance.q < 3 ? " · low" : ""}`, tone: chance.q < 3 ? "#F5B02E" : undefined });
    }
    lines.push({ k: "Extrapolated", v: `${guessed} of ${seen.length} players` });
    if (errs.length) lines.push({ k: "Mean error", v: `${(errs.reduce((a, b) => a + b, 0) / errs.length).toFixed(1)} ft (90% within)` });
    return { title: "Tracking", lines };
  });

  const box = $derived(live.box);
  const width = $derived(box ? Math.max(180, Math.min(270, box.w / 2 - 80)) : 0);
  const side = $derived(box ? (box.backLeft ? { left: `${box.left + 10}px` } : { left: `${box.left + box.w - 10 - width}px` }) : null);
</script>

{#if play && box && side && box.w >= 480}
  {#if shotInfo}
    <div class="ann-cards" style:left={side.left} style:top="{box.top + 10}px" style:width="{width}px">
      {@render card(shotInfo)}
    </div>
  {/if}
  {#if poss || quality}
    <div class="ann-cards bottom" style:left={side.left} style:top="{box.top + box.h - 10}px" style:width="{width}px">
      {#if poss}{@render card(poss)}{/if}
      {#if quality}{@render card(quality)}{/if}
    </div>
  {/if}
{/if}

{#snippet card(c: Card)}
  <div class="ann-card">
    <b style:color={c.tone}>{c.title}</b>
    {#each c.lines as line}
      <span class="card-line"><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>
    {/each}
  </div>
{/snippet}
