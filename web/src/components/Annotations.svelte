<script lang="ts">
  // Cards over the backcourt (the half the offense is not attacking, so they rarely cover a player), from the
  // Display panel's Annotations toggles:
  //   Shot Details        the last shot so far: distance, SkillCorner's shot quality, contest and closest defender,
  //                       how it was created, type, shot clock, passer, free throws; with Tracking Readouts the
  //                       ball's peak, with Season Context the shooter's season from that zone.
  //   Possession Context  how the possession began, chances and offensive rebounds, passes, dribbles and touches so
  //                       far, who has had the ball, the game state, free throws.
  //   Data Quality        the chance's tracking quality index and how many players are extrapolated now.
  //   Coverage Read       from 2 s before an on-ball screen to 1 s after it: the live screen-coverage model's probability for
  //                       each defender (ball: over/under/switch; screener: show/soft/switch) and the most likely joint
  //                       call at this frame (lib/coverage.ts); the tagged call is ticked once the screen is set.
  // The court's drawing is in lib/annotate.ts; the text in lib/context.ts.
  import { chanceAt, lastShot, possessionCard, shotCard, type Card } from "../lib/context";
  import { coverageAt, defenderParts, loadCoverage, partOf, PART_COLORS, type CoverageFile, type PartRow } from "../lib/coverage";
  import type { Play } from "../lib/types";
  import { live, season, viewer } from "../lib/viewer.svelte";

  let { play }: { play: Play | null } = $props();

  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const shot = $derived(play && viewer.ann.shot ? lastShot(play, frame) : null);
  const shotInfo = $derived(play && shot ? shotCard(play, shot, { peak: viewer.ann.tracking, season: season.data, xpts: season.sample?.league.xpts }) : null);
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

  let cov = $state<CoverageFile | null>(null);
  $effect(() => { if (viewer.ann.coverage && !cov) loadCoverage().then((c) => { cov = c; }); });
  const covRead = $derived(play && cov && viewer.ann.coverage ? coverageAt(cov, play.id, frame) : null);
  // A player as the card names him: jersey number, then last name ("#12 Steinbergs").
  const who = (id: number) => { const p = play?.players.find((q) => q.id === id); return p ? `#${p.jersey} ${p.last}` : "?"; };
  // Calls coloured as in the strips (src/screen_coverage/02_per_frame.R), stepped for the dark card.
  const COV_COL: Record<string, string> = { "over + show": "#3987e5", "over + soft": "#d95926", "under + soft": "#199e70",
                                            "under + show": "#c98500", switch: "#d55181" };
  const fmtT = (t: number) => `${t >= 0 ? "+" : "−"}${Math.abs(t).toFixed(2)} s`;

  const box = $derived(live.box);
  // The cards never resize the court. The shot card sits in the top corner on the backcourt side, the possession and
  // tracking cards in the bottom corner. When the two would overlap (a tall shot card on a short court), the bottom
  // stack slides toward center court, beside the shot card, instead of the court growing.
  const PAD = 10, GAP = 8;
  let topH = $state(0), topW = $state(0), botH = $state(0);
  const shift = $derived(box && topH && botH && topH + botH + GAP + 2 * PAD > box.h ? topW + GAP : 0);
  // Earlier versions grew the court window to fit both cards in one column (live.annNeed); nothing asks for that now.
  $effect(() => { if (live.annNeed) live.annNeed = 0; });
</script>

{#if play && box && box.w >= 480 && (shotInfo || poss || quality || covRead)}
  <!-- Cards sit against the backcourt's sideline end; each is as wide as its longest line. -->
  <div class="ann-cards {box.backLeft ? 'on-left' : 'on-right'}" style:left="{box.left}px" style:top="{box.top}px"
       style:width="{box.w}px" style:height="{box.h}px" style:--pad="{PAD}px">
    <div class="ann-stack top" class:low={shift > 0} bind:clientHeight={topH} bind:offsetWidth={topW} style:max-height="{box.h - 2 * PAD}px">
      {#if covRead && cov}{@render coverage(covRead, cov.calls)}{/if}
      {#if shotInfo}{@render card(shotInfo)}{/if}
    </div>
    <div class="ann-stack bottom" bind:clientHeight={botH} style:--shift="{shift}px">
      {#if poss}{@render card(poss)}{/if}
      {#if quality}{@render card(quality)}{/if}
    </div>
  </div>
{/if}

{#snippet card(c: Card)}
  <div class="ann-card">
    <b style:color={c.tone}>{c.title}{#if c.flag}<i class="event-flag">{c.flag}</i>{/if}</b>
    {#each c.lines as line}
      {#if line.head}<span class="card-head">{line.k}</span>{:else}<span class="card-line" class:wrap={line.wrap}><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>{/if}
    {/each}
  </div>
{/snippet}

{#snippet coverage(r: NonNullable<typeof covRead>, calls: string[])}
  {@const top = r.pct.indexOf(Math.max(...r.pct))}
  {@const dp = defenderParts(calls, r.pct)}
  {@const shown = r.t >= 0}
  {@const right = calls[top] === r.screen.call}
  <div class="ann-card cov-card">
    <b>Screen Coverage Read<i class="event-flag">{fmtT(r.t)}</i></b>
    <span class="card-line"><span>{who(r.screen.s)} screens for {who(r.screen.h)}</span><span>{shown ? "screen set" : "before the screen"}</span></span>
    {@render bars(`On the ball · ${who(r.screen.bd)}`, dp.ball, shown ? partOf(r.screen.call, "ball") : null)}
    {@render bars(`On the screener · ${who(r.screen.sd)}`, dp.big, shown ? partOf(r.screen.call, "big") : null)}
    <!-- The model's most likely joint call and, from the screen on, the tagged call under it, the two call names in
         one column; the mark says whether the model's call at this frame was the tagged one. -->
    <span class="cov-joint">
      <span class="cov-k">Most likely together</span>
      <span style:color={COV_COL[calls[top]]}>{calls[top]}</span>
      <span class="cov-pct">{Math.round(r.pct[top])}%</span>
      {#if shown}
        <span class="cov-k">Called</span>
        <span style:color={COV_COL[r.screen.call]}>{r.screen.call}</span>
        <span class="cov-mark" class:right class:wrong={!right} title={right ? "The model's most likely call is the tagged call" : "The model's most likely call is not the tagged call"}>{right ? "✓" : "✗"}</span>
      {/if}
    </span>
    {#if !shown}<span class="cov-note">Actual call shown at the screen</span>{/if}
  </div>
{/snippet}

{#snippet bars(title: string, rows: PartRow[], called: string | null)}
  <span class="card-head">{title}</span>
  {#each rows as row}
    <span class="cov-row" class:top={row.top}>
      <span class="cov-label">{row.label}{#if called === row.label}<i class="cov-tick" title="The call SkillCorner tagged">✓</i>{/if}</span>
      <span class="cov-bar"><span style:width="{row.pct}%" style:background={PART_COLORS[row.label]}></span></span>
      <span class="cov-pct">{Math.round(row.pct)}%</span>
    </span>
  {/each}
{/snippet}

