<script lang="ts">
  // The court canvas: runs the animation clock, draws each frame and records video on request. Clicking a player
  // makes the trace panel follow his distance to the nearest opponent; clicking him again lets him go.
  import { onMount } from "svelte";
  import { drawScene } from "../lib/draw";
  import Annotations from "./Annotations.svelte";
  import { FPS } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { live, season, viewer } from "../lib/viewer.svelte";

  /** onend: called once when a play has run to its end and the Display panel says to go on to the next play. */
  let { play, seq, note, onend }: { play: Play | null; seq: number[]; note: string; onend?: () => void } = $props();

  const END_HOLD = 1.2;   // seconds to rest on the last frame before looping
  let canvas: HTMLCanvasElement;
  let stage: HTMLDivElement;
  let recorder: MediaRecorder | null = null;
  let hold = 0, lastTs = 0, drawn = 0;
  let ended: Play | null = null;   // the play onend was last called for
  let framed = false;   // the canvas carries its own header: from the start of a recording until its last frame is flushed
  let pointer = $state(false);   // the pointer is over a player
  let hits: { id: number; x: number; y: number; r: number }[] = [];   // player dots last drawn, for clicks

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
    else if (hold < END_HOLD) return;
    else if (viewer.atEnd === "next" && onend) {
      // Once per play: the next one loads asynchronously and this frame may come round again meanwhile.
      if (ended !== play) {
        ended = play;
        onend();
      }
    }
    else viewer.pos = 0;
  }

  function render(ctx: CanvasRenderingContext2D): void {
    const focusPid = viewer.showTrace && viewer.trace === "nearest" ? viewer.focusPid : null;
    const info = drawScene(ctx, stage.clientWidth, stage.clientHeight, window.devicePixelRatio || 1, play, seq, viewer.pos,
                           { ...viewer, focusPid, sample: season.sample }, framed);
    if (!info) return;
    if (info.gameClock !== live.gameClock) live.gameClock = info.gameClock;
    if (info.shotClock !== live.shotClock) live.shotClock = info.shotClock;
    if (info.handler !== live.handler) live.handler = info.handler;
    const round = (v: number) => Math.round(v * 100) / 100;
    const ctl = info.control == null ? null : { court: round(info.control.court), half: round(info.control.half) };
    const had = live.control;
    if ((ctl?.court !== had?.court || ctl?.half !== had?.half) && (drawn % 6 === 0 || !viewer.playing)) live.control = ctl;
    hits = info.hits;
    const b = info.box, was = live.box;
    if (!was || was.left !== b.left || was.top !== b.top || was.w !== b.w || was.h !== b.h || was.backLeft !== b.backLeft) live.box = b;
    // The cards and rosters follow the frame a few times a second while playing (every frame when paused).
    if ((drawn % 4 === 0 || !viewer.playing) && info.i0 !== live.i0) live.i0 = info.i0;
    if (info.onCourt.length !== live.onCourt.length || info.onCourt.some((id, i) => id !== live.onCourt[i])) live.onCourt = info.onCourt;
    // Areas change every frame; refresh the text a few times a second, or at once when paused.
    if (drawn++ % 6 === 0 || !viewer.playing) {
      const round = (v: number | null) => (v == null ? null : Math.round(v));
      if (round(info.areaOff) !== live.areaOff) live.areaOff = round(info.areaOff);
      if (round(info.areaDef) !== live.areaDef) live.areaDef = round(info.areaDef);
    }
  }

  // The player under a click, if any (the nearest dot whose disc holds the point).
  function playerAt(ev: MouseEvent): number | null {
    const box = canvas.getBoundingClientRect(), x = ev.clientX - box.left, y = ev.clientY - box.top;
    let best: number | null = null, bestD = Infinity;
    for (const h of hits) {
      const d = Math.hypot(h.x - x, h.y - y);
      if (d <= h.r + 4 && d < bestD) { best = h.id; bestD = d; }
    }
    return best;
  }

  function onClick(ev: MouseEvent): void {
    const pid = playerAt(ev);
    if (pid == null) return;
    const same = viewer.trace === "nearest" && viewer.focusPid === pid && viewer.showTrace;
    viewer.focusPid = same ? null : pid;
    viewer.trace = "nearest";
    viewer.showTrace = true;
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
      framed = false;
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
      setTimeout(() => {
        if (active.state === "inactive") framed = false; else active.stop();
      }, save ? 250 : 0);
    };
    recorder = active;
    framed = true;
    viewer.pos = 0;
    viewer.playing = true;
    // Start on the next frame, once the canvas has been redrawn with its header.
    requestAnimationFrame(() => { if (recorder === active) active.start(); });
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

<div class="stage" class:half={viewer.view === "half"} bind:this={stage}>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
  <canvas bind:this={canvas} aria-label="Animated court view of the selected possession. Click a player to follow his nearest opponent."
          class:pointer={pointer} onclick={onClick} onmousemove={(ev) => (pointer = playerAt(ev) != null)} onmouseleave={() => (pointer = false)}></canvas>
  <Annotations {play} />
  {#if note}
    <div class="stage-note">{note}</div>
  {/if}
</div>
