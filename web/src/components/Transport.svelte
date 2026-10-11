<script lang="ts">
  // Transport bar: action stepping, play/pause, the timeline with captioned event ticks, then speed over elapsed time.
  import { clamp, clock } from "../lib/geometry";
  import { FPS, layoutTimeline, stepAction, type Timeline } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2];
  const TICK_FONT = '600 11px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';   // matches .tick-label
  const measurer = document.createElement("canvas").getContext("2d")!;
  const measure = (text: string) => {
    measurer.font = TICK_FONT;
    return measurer.measureText(text).width;
  };

  let track: HTMLDivElement;
  let width = $state(0);
  const empty: Timeline = { ticks: [], cuts: [], marks: [] };
  const timeline = $derived(play && width > 0 ? layoutTimeline(play, seq, width, measure) : empty);
  const end = $derived(Math.max(1, seq.length - 1));
  const frac = $derived(clamp(viewer.pos / end, 0, 1));

  function togglePlay(): void {
    if (!play) return;
    if (!viewer.playing && viewer.pos >= seq.length - 1) viewer.pos = 0;
    viewer.playing = !viewer.playing;
  }

  function step(direction: 1 | -1): void {
    if (play) viewer.pos = stepAction(timeline.marks, viewer.pos, direction, seq.length - 1);
  }

  function seek(ev: PointerEvent): void {
    if (!play) return;
    const rail = track.getBoundingClientRect();
    viewer.pos = clamp((ev.clientX - rail.left) / rail.width, 0, 1) * (seq.length - 1);
  }

  function onKey(ev: KeyboardEvent): void {
    if (!play || viewer.hidden || (ev.target as HTMLElement).closest("input, select, textarea, .multi-list")) return;
    if (ev.code === "Space") { ev.preventDefault(); togglePlay(); }
    if (ev.code === "ArrowLeft") { ev.preventDefault(); viewer.pos = clamp(viewer.pos - FPS, 0, seq.length - 1); }
    if (ev.code === "ArrowRight") { ev.preventDefault(); viewer.pos = clamp(viewer.pos + FPS, 0, seq.length - 1); }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="transport">
  <div class="transport-buttons">
    <button type="button" class="icon-btn" title="Previous action" aria-label="Previous action" onclick={() => step(-1)}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 5h2v14H6zM20 5v14L9 12z" /></svg>
    </button>
    <button type="button" class="icon-btn primary" title="Play or pause (space)" aria-label={viewer.playing ? "Pause" : "Play"} onclick={togglePlay}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d={viewer.playing ? "M6 4h4v16H6zM14 4h4v16h-4z" : "M7 4v16l13-8z"} /></svg>
    </button>
    <button type="button" class="icon-btn" title="Next action" aria-label="Next action" onclick={() => step(1)}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 5h2v14h-2zM4 5v14l11-7z" /></svg>
    </button>
  </div>

  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="track" bind:this={track} bind:clientWidth={width}
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
    {#each timeline.ticks as tick}
      {#if tick.row >= 0}
        <span class="tick-label above row{tick.row} {tick.event.kind}" style:left="{tick.left}px" style:width="{tick.width}px">{tick.event.short ?? ""}</span>
        <span class="tick-label below row{tick.row}" style:left="{tick.left}px" style:width="{tick.width}px">{tick.event.who ?? ""}</span>
      {/if}
    {/each}
    <div class="track-thumb" style:left="{frac * 100}%"></div>
  </div>

  <div class="transport-end">
    <select class="speed" title="Playback speed" aria-label="Playback speed" bind:value={viewer.speed}>
      {#each SPEEDS as speed}
        <option value={speed}>{speed}×</option>
      {/each}
    </select>
    <span class="time-label">{clock(viewer.pos / FPS)} / {clock(end / FPS)}</span>
  </div>
</div>
