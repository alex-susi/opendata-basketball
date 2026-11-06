<script lang="ts">
  // The timeline under the court: the play's progress with a tick for each event, captioned with the action above
  // and the player below (captions can be turned off in the Display panel, leaving a thin bar; so can the whole
  // timeline). Click or drag to move playback. Its rail lines up with the trace panel's time axis above it. The
  // play/pause, action-stepping and speed controls and the keyboard shortcuts are in the Display panel (Controls.svelte).
  import { clamp } from "../lib/geometry";
  import { layoutTimeline, type Tick, type Timeline } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const TICK_FONT = '600 11px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';   // matches .tick-label
  // Where a tick's ends sit in the track, and how far beyond them a tilted caption starts (the leader line between).
  // These follow .track-rail and .tick in app.css.
  const TICK_TOP = 43, TICK_BOTTOM = 57, LEADER = 5;
  const measurer = document.createElement("canvas").getContext("2d")!;
  const measure = (text: string) => {
    measurer.font = TICK_FONT;
    return measurer.measureText(text).width;
  };

  let track: HTMLDivElement;
  let width = $state(0);
  const empty: Timeline = { ticks: [], cuts: [], marks: [] };
  const timeline = $derived(play && width > 0 ? layoutTimeline(play, seq, width, measure) : empty);
  const tilted = $derived(timeline.ticks.filter((tick) => tick.lean !== "flat"));
  // A flat caption is centred in a box of its measured width; a tilted one takes the width of its own text.
  const boxWidth = (tick: Tick) => (tick.lean === "flat" ? `${tick.width}px` : null);
  const end = $derived(Math.max(1, seq.length - 1));
  const frac = $derived(clamp(viewer.pos / end, 0, 1));

  function seek(ev: PointerEvent): void {
    if (!play) return;
    const rail = track.getBoundingClientRect();
    viewer.pos = clamp((ev.clientX - rail.left) / rail.width, 0, 1) * (seq.length - 1);
  }
</script>

<div class="transport">
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="track" class:bare={!viewer.showTickLabels} bind:this={track} bind:clientWidth={width}
       onpointerdown={(ev) => { track.setPointerCapture(ev.pointerId); seek(ev); }}
       onpointermove={(ev) => { if (track.hasPointerCapture(ev.pointerId)) seek(ev); }}>
    <div class="track-rail">
      <div class="track-fill" style:width="{frac * 100}%"></div>
      {#each timeline.cuts as cut}
        <i class="tick cut" style:left="{cut * 100}%" title="Footage skips here"></i>
      {/each}
      {#each timeline.ticks as tick}
        <i class="tick {tick.event.kind}" style:left="{tick.frac * 100}%" title={tick.event.label}></i>
      {/each}
    </div>
    {#if viewer.showTickLabels}
      <svg class="leaders" aria-hidden="true">
        {#each tilted as tick}
          <line x1={tick.frac * width} y1={TICK_TOP} x2={tick.at} y2={TICK_TOP - LEADER} />
          <line x1={tick.frac * width} y1={TICK_BOTTOM} x2={tick.at} y2={TICK_BOTTOM + LEADER} />
        {/each}
      </svg>
      {#each timeline.ticks as tick}
        <span class="tick-label above lean-{tick.lean} {tick.event.kind}" style:left="{tick.at}px" style:width={boxWidth(tick)}>{tick.event.short ?? ""}</span>
        <span class="tick-label below lean-{tick.lean}" style:left="{tick.at}px" style:width={boxWidth(tick)}>{tick.event.who ?? ""}</span>
      {/each}
    {/if}
    <div class="track-thumb" style:left="{frac * 100}%"></div>
  </div>
</div>
