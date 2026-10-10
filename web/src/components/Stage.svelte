<script lang="ts">
  // The court canvas: runs the animation clock, draws each frame and records video on request.
  import { onMount } from "svelte";
  import { drawScene } from "../lib/draw";
  import { FPS } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, seq, note }: { play: Play | null; seq: number[]; note: string } = $props();

  const END_HOLD = 1.2;   // seconds to rest on the last frame before looping
  let canvas: HTMLCanvasElement;
  let stage: HTMLDivElement;
  let recorder: MediaRecorder | null = null;
  let hold = 0, lastTs = 0, drawn = 0;

  function advance(ts: number): void {
    const dt = Math.min(0.1, (ts - lastTs) / 1000);
    lastTs = ts;
    if (!play || !viewer.playing) return;
    const end = seq.length - 1;
    if (viewer.pos < end) {
      hold = 0;
      viewer.pos = Math.min(end, viewer.pos + dt * FPS * viewer.speed);
      return;
    }
    hold += dt;
    if (recorder) finishRecording(true);
    else if (!viewer.loop) viewer.playing = false;
    else if (hold >= END_HOLD) viewer.pos = 0;
  }

  function render(ctx: CanvasRenderingContext2D): void {
    const info = drawScene(ctx, stage.clientWidth, stage.clientHeight, window.devicePixelRatio || 1, play, seq, viewer.pos, viewer);
    if (!info) return;
    if (info.handler !== live.handler) live.handler = info.handler;
    if (info.onCourt.length !== live.onCourt.length || info.onCourt.some((id, i) => id !== live.onCourt[i])) live.onCourt = info.onCourt;
    // Areas change every frame; refresh the text a few times a second, or at once when paused.
    if (drawn++ % 6 === 0 || !viewer.playing) {
      const round = (v: number | null) => (v == null ? null : Math.round(v));
      if (round(info.areaOff) !== live.areaOff) live.areaOff = round(info.areaOff);
      if (round(info.areaDef) !== live.areaDef) live.areaDef = round(info.areaDef);
    }
  }

  // Record the canvas while the play runs once from the start, then hand the file to the browser.
  function startRecording(): void {
    const mime = ["video/mp4;codecs=avc1", "video/webm;codecs=vp9", "video/webm"].find((m) => window.MediaRecorder && MediaRecorder.isTypeSupported(m));
    if (!play || !mime) {
      viewer.recording = false;
      if (!mime) window.alert("This browser cannot record the canvas. Try a current Chrome, Edge or Firefox.");
      return;
    }
    const chunks: Blob[] = [], name = `${play.id}.${mime.startsWith("video/mp4") ? "mp4" : "webm"}`;
    const active = new MediaRecorder(canvas.captureStream(30), { mimeType: mime, videoBitsPerSecond: 8e6 });
    let keep = false;
    active.ondataavailable = (ev) => { if (ev.data.size) chunks.push(ev.data); };
    active.onstop = () => {
      if (!keep) return;
      const link = document.createElement("a");
      link.href = URL.createObjectURL(new Blob(chunks, { type: mime.split(";")[0] }));
      link.download = name;
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 10000);
    };
    finishRecording = (save: boolean) => {
      keep = save;
      recorder = null;
      viewer.recording = false;
      if (save) viewer.playing = false;
      setTimeout(() => active.stop(), save ? 250 : 0);
    };
    recorder = active;
    viewer.pos = 0;
    viewer.playing = true;
    active.start();
  }
  let finishRecording: (save: boolean) => void = () => {};

  // The side panel flips viewer.recording; a new play also clears it.
  $effect(() => {
    if (viewer.recording && !recorder) startRecording();
    else if (!viewer.recording && recorder) finishRecording(false);
  });

  onMount(() => {
    const ctx = canvas.getContext("2d")!;
    const resize = () => {
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(stage.clientWidth * dpr);
      canvas.height = Math.round(stage.clientHeight * dpr);
    };
    const observer = new ResizeObserver(resize);
    observer.observe(stage);
    resize();
    let frame = requestAnimationFrame(function tick(ts) {
      frame = requestAnimationFrame(tick);
      advance(ts);
      render(ctx);
    });
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  });
</script>

<div class="stage" bind:this={stage}>
  <canvas bind:this={canvas} aria-label="Animated court view of the selected possession"></canvas>
  {#if note}
    <div class="stage-note">{note}</div>
  {/if}
</div>
