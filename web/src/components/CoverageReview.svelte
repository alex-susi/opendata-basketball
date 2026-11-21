<script lang="ts">
  // The play-review panel (coverage product plan, Phase 3, 2026-11-21), shown above the Display panel when the address
  // has ?review. It walks the review sample (lib/review.svelte.ts) one case at a time:
  //   Open case      loads the possession, pins its screen and pauses 2 s before the pick marker
  //   Blind stage    the forecast and the recorded coverage stay hidden (coverageView.svelte.ts, blind). Stamp each
  //                  moment at the frame on the court, mark it unsure or "none", and pick what each player did
  //   After reveal   the Screen Coverage Read shows the forecast trace and the recorded coverage. Judge the forecast
  //                  and the label
  // Answers are saved in this browser after every change; Export CSV writes review_cases.csv.
  import { covView, picksOf, rawCoverage, screenKey } from "../lib/coverageView.svelte";
  import { CHOICES, entryFor, entryKey, loadReviewSample, MOMENTS, queueOf, review, reviewCsv, saveReview, type ReviewCase } from "../lib/review.svelte";
  import { seqIndexOfFrame } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { live } from "../lib/viewer.svelte";

  let { play, seq, onopen }: { play: Play | null; seq: number[]; onopen: (c: ReviewCase) => void } = $props();

  $effect(() => { if (!review.sample) loadReviewSample().then((s) => { review.sample = s; }); });
  const queue = $derived(queueOf(review.sample, review.pass));
  const at = $derived(Math.min(Math.max(review.at, 0), Math.max(queue.length - 1, 0)));
  const c = $derived(queue[at] ?? null);
  // A case's answers, created the first time it is shown (state cannot change inside a $derived).
  const entry = $derived(c ? review.entries[entryKey(c.id, review.pass)] ?? null : null);
  $effect(() => { if (c && !entry) entryFor(c, review.pass); });
  const here = $derived(!!(c && play && play.id === c.poss));
  const frame = $derived(play ? play.frames[Math.min(live.i0, play.frames.length - 1)] : 0);
  const done = $derived(queue.filter((q) => review.entries[entryKey(q.id, review.pass)]?.stage === "done").length);
  // The case's screen, named so it is never confused with another screen in the same possession. The card's
  // screen picker can move the pin, so the panel warns when the card is reading a different screen.
  const who = (id: number) => { const p = play?.players.find((q) => q.id === id); return p ? `#${p.jersey} ${p.last}` : "?"; };
  const caseScreen = $derived.by(() => {
    if (!c || !here) return null;
    const list = picksOf(play);
    const i = list.findIndex((x) => x.f === c.f0);
    return { n: i + 1, count: list.length, at: play && seq.length ? seqIndexOfFrame(play, seq, c.f0) / 25 : 0 };
  });
  const offPin = $derived(here && c ? covView.pinned[c.poss] !== c.f0 : false);
  // The recorded coverage, for the after-reveal stage only.
  const recorded = $derived.by(() => {
    if (!c || !here || entry?.stage === "blind") return null;
    const s = play?.ann?.screens.find((x) => x.kind === "pick" && x.f === c.f0);
    if (!s) return null;
    const r = rawCoverage(s);
    return `${r.use ?? "?"} / ${r.scr === "soft" ? "drop" : r.scr ?? "?"}`;
  });

  // The blind stage hides this case's forecast and recorded coverage everywhere; after it, they show.
  $effect(() => {
    const k = c ? screenKey(c.poss, c.f0) : null;
    covView.blind = k && entry?.stage === "blind" ? k : null;
    if (k && entry && entry.stage !== "blind") covView.revealed[k] = true;
  });
  // Save every change.
  $effect(() => {
    void JSON.stringify(review.entries);
    void review.reviewer;
    void review.pass;
    void review.at;
    saveReview();
  });

  function open(): void {
    if (!c) return;
    covView.pinned[c.poss] = c.f0;
    onopen(c);
  }
  function go(step: number): void {
    review.at = Math.min(Math.max(at + step, 0), queue.length - 1);
  }
  function stamp(key: string, f: number | "none" | null): void {
    if (!entry) return;
    entry.stamps[key] = { f, unsure: entry.stamps[key]?.unsure ?? false };
  }
  const fmtT = (f: number | "none" | null | undefined) =>
    f == null ? "—" : f === "none" ? "none" : `${f >= c!.f0 ? "+" : "−"}${Math.abs((f - c!.f0) / 25).toFixed(2)} s`;
  function finishBlind(): void {
    if (!entry) return;
    entry.stage = "after";
    entry.blindDone = new Date().toISOString();
  }
  function finish(): void {
    if (!entry) return;
    entry.stage = "done";
    entry.done = new Date().toISOString();
  }
  function exportCsv(): void {
    if (!review.sample) return;
    const blob = new Blob([reviewCsv(review.sample)], { type: "text/csv" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "review_cases.csv";
    a.click();
    URL.revokeObjectURL(a.href);
  }
  function resetAll(): void {
    if (confirm("Delete every review answer saved in this browser? Export the CSV first if you want to keep them.")) {
      review.entries = {};
      review.at = 0;
    }
  }
</script>

<div class="panel review">
  <div class="panel-head">
    <h2>Play Review</h2>
    <span class="rv-pass" role="group" aria-label="Review pass">
      <button type="button" class:on={review.pass === 1} onclick={() => { review.pass = 1; review.at = 0; }} title="First pass over every case">Pass 1</button>
      <button type="button" class:on={review.pass === 2} onclick={() => { review.pass = 2; review.at = 0; }} title="Blind repeat of the marked subset. Pass-1 answers never show here">Pass 2</button>
    </span>
  </div>
  {#if !review.sample}
    <p class="rv-muted">Loading the review sample (coverage_review_sample.json)…</p>
  {:else if c && entry}
    <label class="rv-field">Reviewer <input type="text" bind:value={review.reviewer} placeholder="initials" /></label>
    <div class="rv-nav">
      <button type="button" class="rv-btn" aria-label="Previous case" disabled={at === 0} onclick={() => go(-1)}>‹</button>
      <span>Case {c.case} · {at + 1} of {queue.length}</span>
      <button type="button" class="rv-btn" aria-label="Next case" disabled={at >= queue.length - 1} onclick={() => go(1)}>›</button>
      <span class="rv-muted">{done} done</span>
    </div>
    <div class="rv-nav">
      <button type="button" class="rv-btn strong" onclick={open} title="Load the possession, pin this screen and pause 2 s before the pick marker">{here ? "Back to start" : "Open case"}</button>
      <span class="rv-stage {entry.stage}">{entry.stage === "blind" ? "Blind stage" : entry.stage === "after" ? "After reveal" : "Done"}</span>
    </div>

    {#if !here}
      <p class="rv-muted">Open the case to stamp moments from the court.</p>
    {:else if caseScreen}
      <p class="rv-screen" title="The screen this case is about. Other screens in the possession are context only">
        Review <b>screen {caseScreen.n} of {caseScreen.count}</b> · {who(c.h)} with {who(c.s)} screening · pick marker at {caseScreen.at.toFixed(1)} s
      </p>
      {#if offPin}
        <p class="rv-warn">The card is reading a different screen. <button type="button" class="rv-btn" onclick={() => { covView.pinned[c!.poss] = c!.f0; }}>Pin the case's screen</button></p>
      {/if}
    {/if}

    {#snippet moment(m: (typeof MOMENTS)[number])}
      {@const st = entry!.stamps[m.key]}
      <!-- The moment's name is its Stamp button: a click records the frame on the court. -->
      <div class="rv-moment">
        <button type="button" class="rv-btn rv-stamp" disabled={!here} onclick={() => stamp(m.key, frame)}
                title="{m.title}. Click to stamp the frame on the court" aria-label="Stamp {m.label}">{m.label}</button>
        <span class="rv-val" class:unsure={st?.unsure}>{fmtT(st?.f)}</span>
        <button type="button" class="rv-btn" onclick={() => stamp(m.key, "none")} title="It did not happen in this clip" aria-label="{m.label} did not happen">None</button>
        <label class="rv-unsure" title="The stamp is uncertain"><input type="checkbox" checked={!!st?.unsure} disabled={!st} aria-label="{m.label} unsure"
               onchange={(ev) => { if (st) st.unsure = ev.currentTarget.checked; }} />?</label>
        <button type="button" class="rv-x" aria-label="Clear {m.label}" onclick={() => { delete entry!.stamps[m.key]; }}>×</button>
      </div>
    {/snippet}
    {#snippet choice(ch: (typeof CHOICES)[number])}
      <label class="rv-choice" title={ch.title}>{ch.label}
        <select value={entry!.picks[ch.key] ?? ""} onchange={(ev) => { entry!.picks[ch.key] = ev.currentTarget.value; }}>
          <option value="">—</option>
          {#each ch.options as o (o)}<option value={o}>{o.replaceAll("_", " ")}</option>{/each}
        </select>
      </label>
    {/snippet}

    {#if entry.stage === "blind"}
      <h3 class="sub-head">Moments</h3>
      {#each MOMENTS.filter((m) => !m.after) as m (m.key)}{@render moment(m)}{/each}
      <h3 class="sub-head">What happened</h3>
      {#each CHOICES.filter((ch) => !ch.after) as ch (ch.key)}{@render choice(ch)}{/each}
      <label class="rv-notes">Notes <textarea rows="3" bind:value={entry.notes}></textarea></label>
      <button type="button" class="rv-btn strong" onclick={finishBlind} title="Show the forecast trace and the recorded coverage for this case">Finish blind stage</button>
    {:else}
      <p class="rv-recorded">Recorded coverage · <b>{recorded ?? (here ? "no label" : "open the case")}</b> <span class="rv-muted">(handler's defender / screener's defender)</span></p>
      <h3 class="sub-head">The forecast</h3>
      {#each MOMENTS.filter((m) => m.after) as m (m.key)}{@render moment(m)}{/each}
      {#each CHOICES.filter((ch) => ch.after) as ch (ch.key)}{@render choice(ch)}{/each}
      <label class="rv-notes">Wording, misleading moments, anything else <textarea rows="3" bind:value={entry.notesAfter}></textarea></label>
      {#if entry.stage === "after"}
        <button type="button" class="rv-btn strong" onclick={finish}>Done</button>
      {:else}
        <button type="button" class="rv-btn" onclick={() => { entry!.stage = "after"; }}>Edit again</button>
      {/if}
    {/if}

    <div class="rv-foot">
      <button type="button" class="rv-btn" onclick={exportCsv} title="Download review_cases.csv. Save it in screen_coverage/03_outputs/product_review/">Export CSV</button>
      <button type="button" class="rv-btn" onclick={resetAll}>Reset all</button>
    </div>
  {:else}
    <p class="rv-muted">No cases in this pass.</p>
  {/if}
</div>

<style>
  .review { display: grid; gap: 6px; font-size: 12.5px; }
  .rv-pass { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  .rv-pass button { border: 0; background: none; color: var(--muted); padding: 2px 8px; font: inherit; cursor: pointer; }
  .rv-pass button.on { background: var(--raised); color: var(--ink); font-weight: 600; }
  .rv-nav { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
  .rv-muted { margin: 0; color: var(--muted); }
  .rv-field, .rv-choice { display: grid; grid-template-columns: minmax(0, 1fr) 150px; align-items: center; gap: 6px; }
  .rv-field input, .rv-choice select, .rv-notes textarea {
    font: inherit; background: var(--raised); color: var(--ink); border: 1px solid var(--line); border-radius: 5px; padding: 2px 4px; min-width: 0;
  }
  .rv-notes { display: grid; gap: 3px; }
  .rv-moment { display: grid; grid-template-columns: minmax(0, 1fr) 54px auto auto auto; align-items: center; gap: 4px; }
  .rv-stamp { text-align: left; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rv-val { font-variant-numeric: tabular-nums; text-align: right; }
  .rv-val.unsure { color: #F5B02E; }
  .rv-btn { border: 1px solid var(--line); border-radius: 5px; background: var(--raised); color: var(--ink); font: inherit; font-size: 11.5px; padding: 1px 7px; cursor: pointer; }
  .rv-btn:hover:not(:disabled) { background: var(--hover); }
  .rv-btn:disabled { opacity: .4; cursor: default; }
  .rv-btn.strong { font-weight: 600; justify-self: start; }
  .rv-btn:focus-visible, .rv-pass button:focus-visible, .rv-x:focus-visible { outline: 2px solid var(--ink); outline-offset: 1px; }
  .rv-x { border: 0; background: none; color: var(--muted); cursor: pointer; font: inherit; padding: 0 2px; }
  .rv-unsure { display: inline-flex; align-items: center; gap: 1px; color: var(--muted); }
  .rv-stage { padding: 0 6px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); }
  .rv-stage.blind { color: #F5B02E; border-color: #F5B02E; }
  .rv-recorded { margin: 0; }
  .rv-screen { margin: 0; }
  .rv-warn { margin: 0; color: #D9534F; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
  .rv-foot { display: flex; gap: 6px; margin-top: 4px; padding-top: 6px; border-top: 1px solid var(--line); }
</style>
