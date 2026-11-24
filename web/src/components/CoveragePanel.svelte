<script lang="ts">
  // The Screen Coverage Read: drawn as a card over the backcourt while the court is at least 480 px wide
  // (Annotations.svelte). The copy under a narrower court was taken off on 2026-11-24 at the owner's request.
  //
  // The card is the Classic one: each defender's bars (the live model's forecast for his part of the coverage, from
  // what had happened by this frame), then an Expected / Actual table with right and wrong marks. The recorded
  // coverage (SkillCorner's label for the whole screen) reads "TBD" until the pick frame, then shows. The Panel look
  // (probability strips, screen picker, pause controls), the Predict / Full review switch and the Reveal button were
  // taken off on 2026-11-24 at the owner's request; the strip helpers stay in lib/coverage.ts.
  //
  // The screen is the pinned one, or, when nothing is pinned, the earliest screen whose −2 s to +1 s window holds the
  // frame (lib/coverageView.svelte.ts). The pick frame (picks.frame) is the reference marker of the data, so the
  // status reads "Before pick marker" / "Play unfolding" around it.
  import { defenderParts, loadCoverage, PART_COLORS, partOf, readAt, screenAt, type CoverageFile, type PartRow } from "../lib/coverage";
  import { forecastVisible, rawCoverage, recordedVisible, selectedScreen } from "../lib/coverageView.svelte";
  import type { Play } from "../lib/types";
  import { live } from "../lib/viewer.svelte";

  let { play }: { play: Play | null } = $props();

  let cov = $state<CoverageFile | null>(null);
  $effect(() => { if (!cov) loadCoverage().then((c) => { cov = c; }); });

  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const sel = $derived(selectedScreen(play, frame));
  const scored = $derived(sel && cov && play ? screenAt(cov, play.id, sel.pick.f) : null);
  const showForecast = $derived(!!(sel && play && forecastVisible(play.id, sel.pick.f)));
  const read = $derived(scored && cov && showForecast ? readAt(cov, scored, frame) : null);
  const shown = $derived(!!(sel && play && recordedVisible(play.id, sel.pick.f)));
  // The Actual column shows once the pick frame has passed ("TBD" before it).
  const actualShown = $derived(!!(shown && read && read.t >= 0));

  // A player as the card names him: jersey number, then last name.
  const who = (id: number) => { const p = play?.players.find((q) => q.id === id); return p ? `#${p.jersey} ${p.last}` : "?"; };
  const cap = (s: string) => s.replace(/\b[a-z]/g, (c) => c.toUpperCase());
  const fmtT = (t: number) => `${t >= 0 ? "+" : "−"}${Math.abs(t).toFixed(2)} s`;
  const COVERAGE_WORD: Record<string, string> = { soft: "drop" };
  // The recorded coverage as one of the five (or the raw words for ice, blitz or none).
  const recorded = $derived.by(() => {
    if (!sel || !shown) return null;
    const r = rawCoverage(sel.pick);
    const use = r.use ?? "?", scr = COVERAGE_WORD[r.scr ?? ""] ?? r.scr ?? "?";
    return use === "switch" || scr === "switch" ? "switch" : `${use} + ${scr}`;
  });
  // Why a screen has no forecast. While the recorded coverage is hidden (the blind review) the reason stays general,
  // since naming ice or blitz would give the coverage away (owner's review, 2026-11-23).
  const FIVE = new Set(["over + show", "over + drop", "under + show", "under + drop", "switch"]);
  const noForecastWhy = $derived(!recorded ? "Tracking incomplete or a coverage outside the five the model reads"
    : FIVE.has(recorded) ? "Left out of the model for incomplete tracking around the screen"
    : `${cap([...new Set(recorded.split(" + "))].join(" + "))} is outside the five coverages the model reads`);

  const lead = (rows: PartRow[]) => rows.find((row) => row.top) ?? rows[0];
</script>

{#if play && sel}
  <div class="ann-card cov-card cp-classic">
    <span class="cov-title"><b>Screen Coverage Read</b>
      <i class="event-flag cov-flag" class:set={sel.t >= 0} title={sel.t >= 0 ? "Seconds since the screen was set" : "Seconds until the screen is set"}>{fmtT(sel.t)}</i></span>
    <span class="card-line"><span>Screener</span><span>{who(sel.pick.scr)}</span></span>
    <span class="card-line"><span>Ballhandler</span><span>{who(sel.pick.use)}</span></span>
    {#if read && cov && scored}
      {@const top = read.pct.indexOf(Math.max(...read.pct))}
      {@const dp = defenderParts(cov.calls, read.pct)}
      {@render bars(`On the Ball · ${who(scored.bd)}`, dp.ball)}
      {@render bars(`On the Screener · ${who(scored.sd)}`, dp.big)}
      <!-- Expected (the model's leading option and its %) against Actual (the recorded coverage), with a mark. -->
      <span class="cov-table">
        <span></span><span></span><span class="cov-th">Expected</span><span></span><span class="cov-th">Actual</span>
        {#each [{ label: who(scored.bd), exp: lead(dp.ball).label, pct: lead(dp.ball).pct, act: partOf(scored.call, "ball") },
                { label: who(scored.sd), exp: lead(dp.big).label, pct: lead(dp.big).pct, act: partOf(scored.call, "big") },
                { label: "Combined", exp: cov.calls[top], pct: read.pct[top], act: scored.call }] as row, i (i)}
          <span class="cov-k" class:combined={i === 2}>{row.label}</span>
          <span></span>
          <span class="cov-exp" class:combined={i === 2}>{@render callName(row.exp)}</span>
          <span class="cov-pct" class:combined={i === 2}>{Math.round(row.pct)}%</span>
          <span></span>
          <span class="cov-act" class:tbd={!actualShown} class:combined={i === 2}>{#if actualShown}{@render callName(row.act)}{:else}TBD{/if}</span>
          <span class="cov-mark" class:right={actualShown && row.exp === row.act} class:wrong={actualShown && row.exp !== row.act} class:combined={i === 2}>{actualShown ? (row.exp === row.act ? "✓" : "✗") : " "}</span>
        {/each}
      </span>
    {:else}
      {@render status()}
    {/if}
  </div>
{/if}

{#snippet bars(title: string, rows: PartRow[])}
  <span class="card-head">{title}</span>
  {#each rows as row (row.label)}
    <span class="cov-row" class:top={row.top}>
      <span class="cov-label">{cap(row.label)}</span>
      <span class="cov-bar"><span style:width="{row.pct}%" style:background={PART_COLORS[row.label]}></span></span>
      <span class="cov-pct">{Math.round(row.pct)}%</span>
    </span>
  {/each}
{/snippet}

{#snippet status()}
  {#if sel}
    <span class="cp-status">
      {#if !showForecast}
        <i>Forecast hidden while you review this play</i>
      {:else if !scored}
        <i>No forecast for this screen</i><small>{noForecastWhy}</small>
      {:else if !read}
        <i>Outside prediction range</i><small>The forecast runs from 2 s before to 1 s after the pick marker ({fmtT(sel.t)})</small>
      {:else}
        <i class:after={read.t >= 0}>{read.t < 0 ? "Before pick marker" : "Play unfolding"} · {fmtT(read.t)}</i>
      {/if}
    </span>
  {/if}
{/snippet}

<!-- A coverage with each defender's part in its own colour and the "+" in grey. -->
{#snippet callName(c: string)}
  {#each c.split(" + ") as part, j (j)}{#if j}<span class="cp-plus">{" + "}</span>{/if}<span class="cp-part {part}">{cap(part)}</span>{/each}
{/snippet}

<style>
  .cp-status { display: grid; margin-top: 2px; }
  .cp-status i { font-style: normal; font-weight: 600; }
  .cp-status i.after { color: #F5B02E; }
  .cp-status small { color: var(--muted); white-space: normal; }
  .cp-plus { color: var(--muted); }
  .cp-part.over { color: #3987e5; } .cp-part.under { color: #199e70; } .cp-part.switch { color: #d55181; }
  .cp-part.show { color: #c98500; } .cp-part.drop { color: #d95926; }
</style>
