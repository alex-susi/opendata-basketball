<script lang="ts">
  // The Screen Coverage Read (coverage product plan, Phase 3, 2026-11-21): one panel, drawn as a card over the
  // backcourt on a wide court (Annotations.svelte) and below the court when the court is narrower than 480 px
  // (App.svelte), so the read never disappears on a phone.
  //
  // It keeps three things apart:
  //   - the forecast: the live model's probability of each of the five coverages for the selected screen, from what
  //     had happened by this frame. A coverage is "favored" only with a clear lead (lib/coverage.ts, favorite()),
  //     otherwise the panel says "No clear favorite"
  //   - the time trace: those probabilities from 2 s before the pick frame up to this frame. Later frames stay hidden
  //     until the recorded coverage is revealed, so the trace never shows where the play ends up
  //   - the recorded coverage: SkillCorner's label for the whole screen, hidden until Reveal (Predict mode) or shown
  //     throughout (Full review mode). No automatic right / wrong marks
  //
  // The screen is picked with ‹ › (pinned: it stays the same while scrubbing) or, when nothing is pinned, the earliest
  // screen whose −2 s to +1 s window holds the frame (lib/coverageView.svelte.ts). The pick frame (picks.frame) is the
  // reference marker of the data, so the status reads "Before pick marker" / "Play unfolding" around it.
  import { defenderParts, favorite, loadCoverage, readAt, screenAt, traceOf, type CoverageFile } from "../lib/coverage";
  import { covView, forecastVisible, picksOf, recordedVisible, rawCoverage, screenKey, selectedScreen, setMode } from "../lib/coverageView.svelte";
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
  // The trace: up to this frame, or the whole window once the recorded coverage is shown.
  const trace = $derived(scored && cov && showForecast ? traceOf(cov, scored, shown ? null : frame) : []);
  const compact = $derived(layout === "panel" || (live.box?.w ?? 1000) < 640);
  let allFive = $state(false);

  // A player as the panel names him: jersey number, then last name.
  const who = (id: number) => { const p = play?.players.find((q) => q.id === id); return p ? `#${p.jersey} ${p.last}` : "?"; };
  const cap = (s: string) => s.replace(/\b[a-z]/g, (c) => c.toUpperCase());
  const fmtT = (t: number) => `${t >= 0 ? "+" : "−"}${Math.abs(t).toFixed(2)} s`;
  // The five coverages' series colours, as on the reads page.
  const CALL_COLORS: Record<string, string> = { "over + show": "#3987e5", "over + drop": "#d95926", "under + drop": "#199e70", "under + show": "#c98500", switch: "#d55181" };
  const COVERAGE_WORD: Record<string, string> = { soft: "drop" };
  // The recorded coverage as one of the five (or the raw words for ice, blitz or none).
  const recorded = $derived.by(() => {
    if (!sel || !shown) return null;
    const r = rawCoverage(sel.pick);
    const use = r.use ?? "?", scr = COVERAGE_WORD[r.scr ?? ""] ?? r.scr ?? "?";
    return use === "switch" || scr === "switch" ? "switch" : `${use} + ${scr}`;
  });

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
  const PAUSES = [-2, -1.5, -1, -0.5];

  // Trace geometry: −2 s to +1 s across, 0-100% up.
  const W = 232, H = 58;
  const tx = (t: number) => ((t + 2) / 3) * W;
  const ty = (p: number) => H - (p / 100) * H;
</script>

{#if play && (sel || layout === "panel")}
  <div class="cov-panel {layout}" class:ann-card={layout === "card"} class:compact>
    <div class="cp-head">
      <b>Screen Coverage Read</b>
      <span class="cp-mode" role="group" aria-label="Recorded coverage">
        <button type="button" class:on={covView.mode === "predict"} onclick={() => setMode("predict")}
                title="Predict: the recorded coverage stays hidden until you press Reveal">Predict</button>
        <button type="button" class:on={covView.mode === "full"} onclick={() => setMode("full")}
                title="Full review: the recorded coverage and the whole time trace show throughout">Full review</button>
      </span>
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

      <!-- Status: where this moment sits for the selected screen. -->
      <span class="cp-status">
        {#if !showForecast}
          <i>Forecast hidden while you review this play</i>
        {:else if !scored}
          <i>No forecast for this screen</i><small>Tracking incomplete or a coverage outside the five the model reads</small>
        {:else if !read}
          <i>Outside prediction range</i><small>The forecast runs from 2 s before to 1 s after the pick marker ({fmtT(sel.t)})</small>
        {:else}
          <i class:after={read.t >= 0}>{read.t < 0 ? "Before pick marker" : "Play unfolding"} · {fmtT(read.t)}</i>
        {/if}
      </span>

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
                <span class="cp-bar"><span style:width="{read.pct[j]}%" style:background={CALL_COLORS[c]}></span></span>
                <span class="cp-pct">{read.pct[j]}%</span>
              </span>
            {/if}
          {/each}
          {#if compact}
            <button type="button" class="cp-link" onclick={() => (allFive = !allFive)}>{allFive ? "Top two only" : "All five"}</button>
          {/if}
        </div>
        <span class="cp-line small"><span>On the ball</span><span>{#each dp.ball as r, i (r.label)}{i ? " · " : ""}{cap(r.label)} {Math.round(r.pct)}%{/each}</span></span>
        <span class="cp-line small"><span>On the screener</span><span>{#each dp.big as r, i (r.label)}{i ? " · " : ""}{cap(r.label)} {Math.round(r.pct)}%{/each}</span></span>
      {/if}

      {#if trace.length > 1 && cov}
        <svg class="cp-trace" viewBox="0 0 {W} {H + 14}" role="img"
             aria-label="Each coverage's probability from 2 s before the pick marker {shown ? 'to 1 s after it' : 'up to this moment'}">
          <line x1="0" x2={W} y1={H} y2={H} class="axis" />
          <line x1={tx(0)} x2={tx(0)} y1="0" y2={H} class="pick" />
          <text x={tx(0) + 3} y="9" class="lbl">Pick</text>
          {#each cov.calls as c, j (c)}
            <polyline fill="none" stroke={CALL_COLORS[c]} stroke-width="1.6" points={trace.map(([t, p]) => `${tx(t).toFixed(1)},${ty(p[j]).toFixed(1)}`).join(" ")} />
          {/each}
          {#if read}<line x1={tx(read.t)} x2={tx(read.t)} y1="0" y2={H} class="now" />{/if}
          <text x="0" y={H + 12} class="lbl">−2 s</text>
          <text x={W} y={H + 12} class="lbl end">+1 s</text>
        </svg>
      {/if}

      <!-- The recorded coverage: hidden until revealed (Predict), always shown (Full review). -->
      <span class="cp-row recorded">
        {#if recorded}
          <span class="cp-muted">Recorded</span><b>{@render callName(recorded)}</b>
          <small class="cp-muted" title="SkillCorner's label for the whole screen, written after the play. It does not describe every earlier moment">label for the whole screen</small>
        {:else if showForecast}
          <button type="button" class="cp-btn strong" onclick={() => { covView.revealed[key] = true; }}
                  title="Show SkillCorner's recorded coverage for this screen and the whole time trace">Reveal recorded coverage</button>
        {/if}
      </span>

      <!-- Pause before the screen, step, play through. -->
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

      {#if sel.other}
        <span class="cp-row cp-muted">Another screen at {fmtT((sel.other.f - sel.pick.f) / 25)}
          <button type="button" class="cp-btn" onclick={() => choose(picks.indexOf(sel.other!))}>Read it</button></span>
      {/if}
    {/if}
  </div>
{/if}

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
  .cp-trace { width: 100%; height: auto; margin-top: 2px; }
  .cp-trace .axis { stroke: var(--line); }
  .cp-trace .pick { stroke: var(--muted); stroke-dasharray: 3 3; }
  .cp-trace .now { stroke: var(--ink); stroke-width: 1; }
  .cp-trace .lbl { fill: var(--muted); font-size: 8.5px; }
  .cp-trace .lbl.end { text-anchor: end; }
  .recorded small { white-space: nowrap; }
  .controls select { font: inherit; font-size: 11px; background: var(--raised); color: var(--ink); border: 1px solid var(--line); border-radius: 5px; }
</style>
