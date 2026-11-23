<script lang="ts">
  // The Screen Coverage Read (coverage product plan, Phase 3, 2026-11-21): one panel, drawn as a card over the
  // backcourt on a wide court (Annotations.svelte) and below the court when the court is narrower than 480 px
  // (App.svelte), so the read never disappears on a phone.
  //
  // It keeps three things apart:
  //   - the forecast: the live model's probability of each of the five coverages for the selected screen, from what
  //     had happened by this frame. A coverage is "favored" only with a clear lead (lib/coverage.ts, favorite()),
  //     otherwise the panel says "No clear favorite"
  //   - the probability strips: those probabilities stacked from 2 s before the pick frame, drawn like the film-check
  //     strips (screen_coverage/03_outputs/evaluation/figures/strips): one strip of the five coverages, or one per
  //     defender side by side. Later frames stay blank until the recorded coverage is shown, so a strip never shows
  //     where the play ends up
  //   - the recorded coverage: SkillCorner's label for the whole screen, hidden until Reveal (Predict mode) or shown
  //     throughout (Full review mode)
  //
  // Two looks: the panel above, or the Classic card used until 2026-11-21 (each defender's bars, then an Expected /
  // Actual table with right and wrong marks). The Classic card keeps its old rule in Full review (Actual once the pick
  // frame passes) and waits for Reveal in Predict.
  //
  // The screen is picked with ‹ › (pinned: it stays the same while scrubbing) or, when nothing is pinned, the earliest
  // screen whose −2 s to +1 s window holds the frame (lib/coverageView.svelte.ts). The pick frame (picks.frame) is the
  // reference marker of the data, so the status reads "Before pick marker" / "Play unfolding" around it.
  import { BALL_PARTS, BIG_PARTS, defenderParts, favorite, loadCoverage, PART_COLORS, partOf, partSeries, readAt, screenAt, STRIP_COLORS,
           stripPolygons, traceOf, type CoverageFile, type PartRow } from "../lib/coverage";
  import { covView, forecastVisible, picksOf, recordedVisible, rawCoverage, screenKey, selectedScreen, setLook, setMode,
           setStrip } from "../lib/coverageView.svelte";
  import { seqIndexOfFrame } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, seq, layout }: { play: Play | null; seq: number[]; layout: "card" | "panel" } = $props();

  let cov = $state<CoverageFile | null>(null);
  $effect(() => { if (!cov) loadCoverage().then((c) => { cov = c; }); });

  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const sel = $derived(selectedScreen(play, frame));
  const picks = $derived(picksOf(play));
  const scored = $derived(sel && cov && play ? screenAt(cov, play.id, sel.pick.f) : null);
  const key = $derived(sel && play ? screenKey(play.id, sel.pick.f) : "");
  const showForecast = $derived(!!(sel && play && forecastVisible(play.id, sel.pick.f)));
  const read = $derived(scored && cov && showForecast ? readAt(cov, scored, frame) : null);
  const shown = $derived(!!(sel && play && recordedVisible(play.id, sel.pick.f)));
  // The strips' points: up to this frame, or the whole window once the recorded coverage is shown.
  const trace = $derived(scored && cov && showForecast ? traceOf(cov, scored, shown ? null : frame) : []);
  // The bars list the top two coverages (All five opens the rest): the strip already shows all five over time.
  const compact = true;
  let allFive = $state(false);

  // A player as the panel names him: jersey number, then last name.
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
  // Why a screen has no forecast. Before Reveal the reason stays general, since naming ice or blitz would give the
  // coverage away (owner's review, 2026-11-23).
  const FIVE = new Set(["over + show", "over + drop", "under + show", "under + drop", "switch"]);
  const noForecastWhy = $derived(!recorded ? "Tracking incomplete or a coverage outside the five the model reads"
    : FIVE.has(recorded) ? "Left out of the model for incomplete tracking around the screen"
    : `${cap([...new Set(recorded.split(" + "))].join(" + "))} is outside the five coverages the model reads`);

  // Move playback to a frame and pause there.
  function jump(f: number): void {
    if (!play || !seq.length) return;
    viewer.playing = false;
    viewer.pos = seqIndexOfFrame(play, seq, f);
  }
  // Pin a screen of this possession and pause before it.
  function choose(i: number): void {
    if (!play || i < 0 || i >= picks.length) return;
    covView.pinned[play.id] = picks[i].f;
    jump(picks[i].f + Math.round(covView.pause * 25));
  }
  function unpin(): void {
    if (play) delete covView.pinned[play.id];
  }
  const reveal = () => { covView.revealed[key] = true; };
  const PAUSES = [-2, -1.5, -1, -0.5];

  // Strips: −2 s to +1 s across, 0-100% up, in viewBox units (they scale to the card's width).
  const SH = 54;
  const tx = (t: number, w: number) => ((t + 2) / 3) * w;
  // Each strip's series bottom to top: the five coverages, or one defender's three options.
  const strips = $derived.by(() => {
    if (!cov || trace.length < 2) return [];
    const calls = cov.calls;
    if (covView.strip === "combined") {
      return [{ title: "", w: 264, labels: calls, polys: stripPolygons(trace, 264, SH) }];
    }
    const side = (labels: string[], title: string) =>
      ({ title, w: 128, labels, polys: stripPolygons(trace.map(([t, p]) => [t, partSeries(calls, p, labels)] as [number, number[]]), 128, SH) });
    return [side(BALL_PARTS, "On the ball"), side(BIG_PARTS, "On the screener")];
  });

  // Classic card: the Actual column shows once the recorded coverage may be seen, and in Full review only after the
  // pick frame (its old rule).
  const classicShown = $derived(!!(shown && read && (covView.mode === "predict" || read.t >= 0)));
  const lead = (rows: PartRow[]) => rows.find((row) => row.top) ?? rows[0];
</script>

{#if play && (sel || layout === "panel")}
  {#if covView.look === "classic"}
    {@render classic()}
  {:else}
    {@render panel()}
  {/if}
{/if}

<!-- ═══ The panel ═══ -->
{#snippet panel()}
  <div class="cov-panel {layout}" class:ann-card={layout === "card"} class:compact>
    <div class="cp-head">
      <b>Screen Coverage Read</b>
      {@render modeSwitch()}
    </div>

    {#if !sel}
      <span class="cp-muted">No screen near this moment.</span>
      {#if picks.length}
        <span class="cp-row">
          <span class="cp-muted">Screens in this possession</span>
          {#each picks as p, i (p.f)}<button type="button" class="cp-btn" onclick={() => choose(i)} title="Pin this screen and pause before it">{i + 1}</button>{/each}
        </span>
      {/if}
    {:else}
      <!-- Which screen: ‹ › pins one; the pin keeps it while scrubbing. -->
      <span class="cp-row">
        <button type="button" class="cp-btn" aria-label="Previous screen" disabled={sel.index === 0} onclick={() => choose(sel.index - 1)}>‹</button>
        <span>Screen {sel.index + 1} of {sel.count}</span>
        <button type="button" class="cp-btn" aria-label="Next screen" disabled={sel.index >= sel.count - 1} onclick={() => choose(sel.index + 1)}>›</button>
        {#if sel.pinned}
          <span class="cp-tag" title="This screen stays selected while you scrub">Pinned <button type="button" class="cp-x" aria-label="Unpin" onclick={unpin}>×</button></span>
        {:else}
          <span class="cp-muted" title="Nothing pinned: the read follows the earliest screen whose window holds this moment">Following</span>
        {/if}
      </span>
      <span class="cp-line"><span>Handler · Screener</span><span>{who(sel.pick.use)} · {who(sel.pick.scr)}</span></span>
      {#if scored}
        <span class="cp-line"><span>Their defenders</span><span>{who(scored.bd)} · {who(scored.sd)}</span></span>
      {/if}

      {@render status()}

      {#if read && cov}
        {@const fav = favorite(cov.calls, read.pct)}
        {@const dp = defenderParts(cov.calls, read.pct)}
        <span class="cp-lead" title="Favored only when the leading coverage has at least 45% and leads the next by 10 points (provisional display rule)">
          {#if fav.clear}{@render callName(cov.calls[fav.top])} favored{:else}No clear favorite{/if}
        </span>
        <div class="cp-bars">
          {#each cov.calls as c, j (c)}
            {#if !compact || allFive || j === fav.top || j === fav.second}
              <span class="cp-bar-row" class:top={j === fav.top}>
                <span class="cp-label">{@render callName(c)}</span>
                <span class="cp-bar"><span style:width="{read.pct[j]}%" style:background={STRIP_COLORS[c]}></span></span>
                <span class="cp-pct">{read.pct[j]}%</span>
              </span>
            {/if}
          {/each}
          {#if compact}
            <button type="button" class="cp-link" onclick={() => (allFive = !allFive)}>{allFive ? "Top two only" : "All five"}</button>
          {/if}
        </div>
        <span class="cp-line small"><span>On the ball</span><span>{#each dp.ball as r, i (r.label)}{i ? " · " : ""}<i class="sw" style:background={STRIP_COLORS[r.label]}></i>{cap(r.label)} {Math.round(r.pct)}%{/each}</span></span>
        <span class="cp-line small"><span>On the screener</span><span>{#each dp.big as r, i (r.label)}{i ? " · " : ""}<i class="sw" style:background={STRIP_COLORS[r.label]}></i>{cap(r.label)} {Math.round(r.pct)}%{/each}</span></span>
      {/if}

      {#if strips.length}
        <!-- The strip's switch on the left, the card's look on the right. -->
        <div class="cp-strip-head">
          <span class="cp-mode" role="group" aria-label="Probability strip">
            <button type="button" class:on={covView.strip === "combined"} onclick={() => setStrip("combined")} title="One strip of the five coverages">Combined</button>
            <button type="button" class:on={covView.strip === "defenders"} onclick={() => setStrip("defenders")} title="One strip per defender: over / under / switch and show / drop / switch">By defender</button>
          </span>
          {@render lookSwitch()}
        </div>
        <div class="cp-strips" class:two={strips.length === 2}>
          {#each strips as s (s.title)}
            <figure class="cp-strip">
              {#if s.title}<figcaption class="cp-muted">{s.title}</figcaption>{/if}
              <svg viewBox="0 -2 {s.w} {SH + 14}" role="img"
                   aria-label="{s.title || 'Five coverages'}: probabilities stacked from 2 s before the pick marker {shown ? 'to 1 s after it' : 'up to this moment'}">
                <rect x="0" y="0" width={s.w} height={SH} class="bg" />
                {#each s.polys as pts, k (k)}<polygon points={pts} fill={STRIP_COLORS[s.labels[k]]} stroke="white" stroke-width="0.4" />{/each}
                <line x1={tx(0, s.w)} x2={tx(0, s.w)} y1="0" y2={SH} class="pick" />
                {#if read}<line x1={tx(read.t, s.w)} x2={tx(read.t, s.w)} y1="0" y2={SH} class="now" />{/if}
                <text x="0" y={SH + 11} class="lbl">−2 s</text>
                <text x={tx(0, s.w)} y={SH + 11} class="lbl mid">Pick</text>
                <text x={s.w} y={SH + 11} class="lbl end">+1 s</text>
              </svg>
            </figure>
          {/each}
        </div>
      {/if}

      <!-- The recorded coverage: hidden until revealed (Predict), always shown (Full review). -->
      <span class="cp-row recorded">
        {#if recorded}
          <span class="cp-muted">Recorded</span><b>{@render callName(recorded)}</b>
          <small class="cp-muted" title="SkillCorner's label for the whole screen, written after the play. It does not describe every earlier moment">label for the whole screen</small>
        {:else if showForecast}
          <button type="button" class="cp-btn strong" onclick={reveal}
                  title="Show SkillCorner's recorded coverage for this screen and the whole strip">Reveal recorded coverage</button>
        {/if}
      </span>

      {@render controls()}

      {#if sel.other}
        <span class="cp-row cp-muted">Another screen at {fmtT((sel.other.f - sel.pick.f) / 25)}
          <button type="button" class="cp-btn" onclick={() => choose(picks.indexOf(sel.other!))}>Read it</button></span>
      {/if}
    {/if}
    {#if !strips.length}<span class="cp-row cp-look-row">{@render lookSwitch()}</span>{/if}
  </div>
{/snippet}

<!-- ═══ The Classic card (until 2026-11-21) ═══ -->
{#snippet classic()}
  <div class="ann-card cov-card cp-classic" class:cp-wide={layout === "panel"}>
    <span class="cov-title"><b>Screen Coverage Read</b>
      {#if sel}<i class="event-flag cov-flag" class:set={sel.t >= 0} title={sel.t >= 0 ? "Seconds since the screen was set" : "Seconds until the screen is set"}>{fmtT(sel.t)}</i>{/if}</span>
    {#if !sel}
      <span class="cp-muted">No screen near this moment.</span>
    {:else}
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
            <span class="cov-act" class:tbd={!classicShown} class:combined={i === 2}>{#if classicShown}{@render callName(row.act)}{:else}{covView.mode === "full" ? "TBD" : "Hidden"}{/if}</span>
            <span class="cov-mark" class:right={classicShown && row.exp === row.act} class:wrong={classicShown && row.exp !== row.act} class:combined={i === 2}>{classicShown ? (row.exp === row.act ? "✓" : "✗") : " "}</span>
          {/each}
        </span>
      {:else}
        {@render status()}
      {/if}
      <span class="cp-row cp-classic-foot">
        {@render modeSwitch()}
        {#if read && !classicShown && covView.mode === "predict"}<button type="button" class="cp-btn" onclick={reveal}>Reveal</button>{/if}
      </span>
    {/if}
    <span class="cp-row cp-look-row">{@render lookSwitch()}</span>
  </div>
{/snippet}

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

<!-- ═══ Shared pieces ═══ -->
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

{#snippet modeSwitch()}
  <span class="cp-mode" role="group" aria-label="Recorded coverage">
    <button type="button" class:on={covView.mode === "predict"} onclick={() => setMode("predict")}
            title="Predict: the recorded coverage stays hidden until you press Reveal, and the strip stops at the current moment">Predict</button>
    <button type="button" class:on={covView.mode === "full"} onclick={() => setMode("full")}
            title="Full review: the recorded coverage and the whole strip show throughout">Full review</button>
  </span>
{/snippet}

{#snippet lookSwitch()}
  <span class="cp-mode" role="group" aria-label="Card look">
      <button type="button" class:on={covView.look === "panel"} onclick={() => setLook("panel")} title="Forecast, probability strips, screen picker and pause controls">Panel</button>
      <button type="button" class:on={covView.look === "classic"} onclick={() => setLook("classic")} title="The card used until 2026-11-21: each defender's bars and an Expected / Actual table">Classic</button>
  </span>
{/snippet}

{#snippet controls()}
  {#if sel}
    <span class="cp-row controls">
      <label class="cp-muted">Pause
        <select bind:value={covView.pause} aria-label="Seconds before the pick marker">
          {#each PAUSES as s (s)}<option value={s}>{s.toFixed(1)} s</option>{/each}
        </select>
      </label>
      <button type="button" class="cp-btn" onclick={() => jump(sel.pick.f + Math.round(covView.pause * 25))} title="Pause this many seconds before the pick marker">Go</button>
      <button type="button" class="cp-btn" onclick={() => jump(frame + 5)} title="Step forward 0.2 s">+0.2 s</button>
      <button type="button" class="cp-btn" onclick={() => { viewer.playing = !viewer.playing; }}>{viewer.playing ? "Pause" : "Play"}</button>
    </span>
  {/if}
{/snippet}

<!-- A coverage with each defender's part in its own colour and the "+" in grey. -->
{#snippet callName(c: string)}
  {#each c.split(" + ") as part, j (j)}{#if j}<span class="cp-plus">{" + "}</span>{/if}<span class="cp-part {part}">{cap(part)}</span>{/each}
{/snippet}

<style>
  .cov-panel { display: grid; gap: 4px; font-size: 11.5px; line-height: 1.35; color: var(--ink); }
  /* Over the court it is an annotation card (app.css .ann-card: its surface, border and day-theme colours). */
  .cov-panel.card { width: 284px; min-width: 0; box-sizing: border-box; gap: 4px; }
  .cp-head b, .cp-mode button { white-space: nowrap; }
  .cov-panel.panel { padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); font-size: 13px; }
  .cp-head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .cp-head b { font-size: 12.5px; }
  .panel .cp-head b { font-size: 14px; }
  .cp-mode { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  .cp-mode button { border: 0; background: none; color: var(--muted); padding: 2px 7px; font: inherit; font-size: 10.5px; cursor: pointer; }
  .cp-mode button.on { background: var(--raised); color: var(--ink); font-weight: 600; }
  .cp-row { display: flex; flex-wrap: wrap; align-items: center; gap: 5px; }
  .cp-line { display: flex; justify-content: space-between; gap: 12px; white-space: nowrap; }
  .cp-line > span:first-child { color: var(--muted); }
  .cp-line.small { font-size: 10.5px; }
  .cp-muted { color: var(--muted); }
  .cp-btn {
    border: 1px solid var(--line); border-radius: 5px; background: var(--raised); color: var(--ink); font: inherit;
    font-size: 11px; padding: 1px 7px; cursor: pointer;
  }
  .panel .cp-btn { font-size: 12.5px; padding: 3px 9px; }
  .cp-btn:hover:not(:disabled) { background: var(--hover); }
  .cp-btn:disabled { opacity: .4; cursor: default; }
  .cp-btn.strong { font-weight: 600; }
  .cp-btn:focus-visible, .cp-mode button:focus-visible, .cp-link:focus-visible, .cp-x:focus-visible { outline: 2px solid var(--ink); outline-offset: 1px; }
  .cp-tag { display: inline-flex; align-items: center; gap: 3px; padding: 0 5px; border: 1px solid var(--line); border-radius: 999px; color: var(--muted); }
  .cp-x { border: 0; background: none; color: var(--muted); cursor: pointer; padding: 0 2px; font: inherit; }
  .cp-status { display: grid; margin-top: 2px; }
  .cp-status i { font-style: normal; font-weight: 600; }
  .cp-status i.after { color: #F5B02E; }
  .cp-status small { color: var(--muted); white-space: normal; }
  .cp-lead { font-weight: 700; font-size: 12.5px; margin-top: 2px; }
  .panel .cp-lead { font-size: 14px; }
  .cp-bars { display: grid; gap: 2px; }
  .cp-bar-row { display: grid; grid-template-columns: 92px minmax(0, 1fr) 32px; align-items: center; gap: 6px; }
  .cp-bar-row.top .cp-label, .cp-bar-row.top .cp-pct { font-weight: 700; }
  .cp-bar { height: 7px; border-radius: 2px; background: var(--raised); overflow: hidden; }
  .cp-bar > span { display: block; height: 100%; }
  .cp-pct { text-align: right; font-variant-numeric: tabular-nums; }
  .cp-link { justify-self: start; border: 0; background: none; padding: 0; color: var(--muted); text-decoration: underline; font: inherit; font-size: 10.5px; cursor: pointer; }
  .cp-plus { color: var(--muted); }
  .cp-part.over { color: #3987e5; } .cp-part.under { color: #199e70; } .cp-part.switch { color: #d55181; }
  .cp-part.show { color: #c98500; } .cp-part.drop { color: #d95926; }
  .sw { display: inline-block; width: 7px; height: 7px; margin-right: 3px; border-radius: 2px; vertical-align: 0; }
  .cp-strip-head { display: flex; justify-content: space-between; align-items: center; gap: 6px; margin-top: 3px; }
  .cp-strips { display: grid; gap: 8px; }
  .cp-strips.two { grid-template-columns: 1fr 1fr; }
  .cp-strip { margin: 0; display: grid; gap: 1px; }
  .cp-strip figcaption { font-size: 10px; }
  .cp-strip svg { width: 100%; height: auto; display: block; }
  .cp-strip .bg { fill: var(--raised); }
  .cp-strip .pick { stroke: #1a1a1a; stroke-dasharray: 3 2; stroke-width: 1; }
  .cp-strip .now { stroke: var(--ink); stroke-width: 1.2; }
  .cp-strip .lbl { fill: var(--muted); font-size: 8.5px; }
  .cp-strip .lbl.mid { text-anchor: middle; }
  .cp-strip .lbl.end { text-anchor: end; }
  .recorded small { white-space: nowrap; }
  .controls select { font: inherit; font-size: 11px; background: var(--raised); color: var(--ink); border: 1px solid var(--line); border-radius: 5px; }
  .cp-look-row { justify-content: flex-end; margin-top: 2px; padding-top: 4px; border-top: 1px solid var(--line); }
  .cp-classic .cp-look-row { margin-top: 5px; }
  .cp-classic-foot { margin-top: 5px; justify-content: space-between; }
  .cp-classic.cp-wide { width: auto; }
</style>
