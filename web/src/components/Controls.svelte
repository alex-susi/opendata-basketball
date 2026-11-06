<script lang="ts">
  // Playback controls, at the top of the Display panel: previous action, play/pause, next action, then the speed
  // (centred between the buttons and the time) and the elapsed time. Also the keyboard: space plays or pauses, the
  // arrow keys step a second back or forward.
  import { clamp, clock } from "../lib/geometry";
  import { eventMarks, FPS, stepAction } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { togglePlay, viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2];
  const marks = $derived(play ? eventMarks(play, seq) : []);
  const end = $derived(Math.max(1, seq.length - 1));

  function step(direction: 1 | -1): void {
    if (play) viewer.pos = stepAction(marks, viewer.pos, direction, seq.length - 1);
  }

  function onKey(ev: KeyboardEvent): void {
    if (!play || viewer.hidden || (ev.target instanceof Element && ev.target.closest("input, select, textarea, .multi-list"))) return;
    if (ev.code === "Space") { ev.preventDefault(); togglePlay(seq.length); }
    if (ev.code === "ArrowLeft") { ev.preventDefault(); viewer.pos = clamp(viewer.pos - FPS, 0, seq.length - 1); }
    if (ev.code === "ArrowRight") { ev.preventDefault(); viewer.pos = clamp(viewer.pos + FPS, 0, seq.length - 1); }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="controls">
  <div class="control-buttons">
    <button type="button" class="icon-btn" title="Previous action" aria-label="Previous action" disabled={!play} onclick={() => step(-1)}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 5h2v14H6zM20 5v14L9 12z" /></svg>
    </button>
    <button type="button" class="icon-btn primary" title="Play or pause (space)" aria-label={viewer.playing ? "Pause" : "Play"}
            disabled={!play} onclick={() => togglePlay(seq.length)}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d={viewer.playing ? "M6 4h4v16H6zM14 4h4v16h-4z" : "M7 4v16l13-8z"} /></svg>
    </button>
    <button type="button" class="icon-btn" title="Next action" aria-label="Next action" disabled={!play} onclick={() => step(1)}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 5h2v14h-2zM4 5v14l11-7z" /></svg>
    </button>
  </div>
  <select class="speed" title="Playback speed" aria-label="Playback speed" bind:value={viewer.speed}>
    {#each SPEEDS as speed}
      <option value={speed}>{speed}×</option>
    {/each}
  </select>
  <span class="time-label">{clock(viewer.pos / FPS)} / {clock(end / FPS)}</span>
</div>
