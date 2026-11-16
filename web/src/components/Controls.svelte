<script lang="ts">
  // Playback controls, above the Display panel: previous action, play/pause, next action; the speed over the elapsed
  // and total time; then Save Video (records the play once through) and the moon / sun switch between the night and
  // day themes. Also the keyboard: space plays or pauses, the arrow keys step one frame back or forward.
  import { clamp, clock } from "../lib/geometry";
  import { eventMarks, FPS, stepAction } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { applyTheme } from "../lib/look";
  import { page } from "../lib/theme.svelte";
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
    if (ev.code === "ArrowLeft") { ev.preventDefault(); viewer.playing = false; viewer.pos = clamp(Math.round(viewer.pos) - 1, 0, seq.length - 1); }
    if (ev.code === "ArrowRight") { ev.preventDefault(); viewer.playing = false; viewer.pos = clamp(Math.round(viewer.pos) + 1, 0, seq.length - 1); }
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
  <div class="speed-time">
    <select class="speed" title="Playback speed" aria-label="Playback speed" bind:value={viewer.speed}>
      {#each SPEEDS as speed}
        <option value={speed}>{speed}×</option>
      {/each}
    </select>
    <span class="time-label">{clock(viewer.pos / FPS)} / {clock(end / FPS)}</span>
  </div>
  <button type="button" class="text-btn save-video" class:recording={viewer.recording} disabled={!play}
          title="Record this play once through and save it as a video" onclick={() => (viewer.recording = !viewer.recording)}>
    {viewer.recording ? "Cancel" : "Save Video"}
  </button>
  <label class="switch two-way theme-switch" title="Night or day theme">
    <svg class:on={!page.light} viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z" /></svg>
    <input type="checkbox" role="switch" aria-label="Use the light day theme" checked={page.light}
           onchange={(ev) => applyTheme(ev.currentTarget.checked ? "light" : "dark")} />
    <span class="switch-track"></span>
    <svg class:on={page.light} viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5" /><path d="M12 1.5v3M12 19.5v3M1.5 12h3M19.5 12h3M4.6 4.6l2.1 2.1M17.3 17.3l2.1 2.1M4.6 19.4l2.1-2.1M17.3 6.7l2.1-2.1" stroke-width="2" stroke-linecap="round" /></svg>
  </label>
</div>
