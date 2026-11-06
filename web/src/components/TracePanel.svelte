<script lang="ts">
  // The trace panel between the court and the timeline: one number followed over the whole play, with the
  // current moment marked as the play runs. Two traces:
  //   Ball height       the ball's z from the tracking (ft).
  //   Nearest opponent  one player's floor distance to the closest player of the other team (ft). Click a player
  //                     on the court or in a roster, or pick one here; the court rings the pair in their teams'
  //                     secondary colours and joins them with a line.
  // Samples are every 0.2 s of playback (lib/trace.ts), on the timeline's clock; the time axis lines up with the
  // timeline under it. Every action on the timeline is marked here too. Click or drag on the chart to move
  // playback there. Shown or hidden from the Display panel.
  import { clamp } from "../lib/geometry";
  import { COLORS } from "../lib/court";
  import { blend, cursorAt, eventsInSeq, FPS } from "../lib/sequence";
  import { nearestAt, traceSamples, type TraceKind, type TraceSample } from "../lib/trace";
  import type { Play, PlayerTrack } from "../lib/types";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  // Left and right margins match the timeline's track (.transport and .track in app.css), so a time sits at the
  // same x in both.
  const M = { left: 38, right: 12, bottom: 22 };
  const PLOT_H = 92;
  const ROW = 12;          // height of one row of action labels above the plot
  const MAX_ROWS = 3;
  const LABEL_FONT = '600 9.5px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';   // matches .mark-label
  const measurer = document.createElement("canvas").getContext("2d")!;
  const measure = (text: string) => {
    measurer.font = LABEL_FONT;
    return measurer.measureText(text).width;
  };

  let width = $state(0);
  let svg = $state<SVGSVGElement>();
  let hoverK = $state<number | null>(null);

  // Players who appear on the tracked court at some point in this play, offense first.
  const tracked = $derived((play?.players ?? []).filter((p) => p.x.some((v) => !Number.isNaN(v)))
    .sort((a, b) => (a.role === b.role ? 0 : a.role === "off" ? -1 : 1)));
  const focus = $derived(tracked.find((p) => p.id === viewer.focusPid) ?? null);
  const kind = $derived<TraceKind | null>(viewer.trace === "ball" ? { kind: "ball" } : focus ? { kind: "nearest", pid: focus.id } : null);
  const samples = $derived(play && seq.length && kind ? traceSamples(play, seq, kind) : []);
  // The ball in its own orange; a followed player in his team's colour as written on the dark panels.
  const color = $derived(viewer.trace === "ball" || !focus || !play ? COLORS.ball : play.colors[focus.role].text);
  const tEnd = $derived(Math.max(1, (seq.length - 1) / FPS));
  // Ball heights past 20 ft are tracking noise; distances use whatever the play needs, in steps of 5 ft.
  const yMax = $derived.by(() => {
    const top = Math.max(0, ...samples.map((s) => s.v ?? 0));
    return viewer.trace === "ball" ? clamp(Math.ceil(top / 5) * 5, 10, 20) : Math.max(10, Math.ceil(top / 5) * 5);
  });

  const plotW = $derived(Math.max(10, width - M.left - M.right));
  const X = (t: number) => M.left + (t / tEnd) * plotW;

  // Every action on the timeline, as a dashed line across the plot with its caption above. Captions take the first
  // of up to three rows where they clear the one before; a caption with no room keeps its line (and its tooltip).
  const marks = $derived.by(() => {
    if (!play || !seq.length || !plotW) return { rows: 1, list: [] };
    const ends = Array<number>(MAX_ROWS).fill(-Infinity);
    let rows = 1;
    const list = eventsInSeq(play, seq).map(({ k, event }) => {
      const x = X(k / FPS), text = event.short ?? event.kind, w = measure(text);
      const flip = x + 3 + w > M.left + plotW + M.right;   // no room to the right: the caption ends at the line
      const [from, to] = flip ? [x - 3 - w, x - 3] : [x + 3, x + 3 + w];
      const row = ends.findIndex((end) => from >= end + 4);
      if (row >= 0) {
        ends[row] = to;
        rows = Math.max(rows, row + 1);
      }
      return { k, x, kind: event.kind, text, row, flip, title: event.label };
    });
    return { rows, list };
  });
  const top = $derived(6 + marks.rows * ROW);
  const H = $derived(top + PLOT_H + M.bottom);
  const Y = (v: number) => top + PLOT_H - (clamp(v, 0, yMax) / yMax) * PLOT_H;
  const yTicks = $derived(Array.from({ length: Math.floor(yMax / 5) + 1 }, (_, i) => i * 5).filter((v) => yMax <= 20 || v % 10 === 0));
  const xTicks = $derived.by(() => {
    const step = [0.5, 1, 2, 5, 10, 20].find((s) => (s / tEnd) * plotW >= 46) ?? 30;
    return Array.from({ length: Math.floor(tEnd / step + 1e-9) + 1 }, (_, i) => i * step);
  });

  // The current moment, blended between frames like the court.
  const now = $derived.by(() => {
    if (!play || !seq.length || !kind) return null;
    const c = cursorAt(play, seq, viewer.pos), t = viewer.pos / FPS;
    if (kind.kind === "ball") return { t, v: blend(play.ball.z, c), opp: null as PlayerTrack | null };
    const near = nearestAt(play, kind.pid, c);
    return { t, v: near?.dist ?? null, opp: near ? play.players.find((p) => p.id === near.pid) ?? null : null };
  });

  // The line runs through the samples already played (and the current moment), broken where a value is missing.
  const pastPath = $derived.by(() => {
    if (!now) return "";
    let d = "", pen = false;
    for (const s of samples) {
      if (s.t > now.t) break;
      if (s.v == null) { pen = false; continue; }
      d += `${pen ? "L" : "M"}${X(s.t).toFixed(1)},${Y(s.v).toFixed(1)}`;
      pen = true;
    }
    if (pen && now.v != null) d += `L${X(now.t).toFixed(1)},${Y(now.v).toFixed(1)}`;
    return d;
  });

  const hovered = $derived<TraceSample | null>(hoverK == null ? null : samples.find((s) => s.k === hoverK) ?? null);
  const name = (p: PlayerTrack | null | undefined) => (p ? `#${p.jersey} ${p.name}` : "–");
  const teamOf = (p: PlayerTrack) => (play ? (p.role === "off" ? play.off : play.def) : "");
  const kitText = (p: PlayerTrack | null | undefined) => (p && play ? play.colors[p.role].text : undefined);
  const fmt = (v: number | null | undefined) => (v == null || Number.isNaN(v) ? "–" : `${v.toFixed(1)} ft`);

  function tAt(ev: PointerEvent): number {
    const box = svg!.getBoundingClientRect();
    return clamp(((ev.clientX - box.left - M.left) / plotW) * tEnd, 0, tEnd);
  }
  function seek(ev: PointerEvent): void {
    if (!play || !seq.length) return;
    viewer.pos = clamp(tAt(ev) * FPS, 0, seq.length - 1);
  }
  function hover(ev: PointerEvent): void {
    if (!samples.length) return;
    const t = tAt(ev);
    hoverK = samples.reduce((a, b) => (Math.abs(b.t - t) < Math.abs(a.t - t) ? b : a)).k;
    if (svg!.hasPointerCapture(ev.pointerId)) seek(ev);
  }
  function pick(ev: Event): void {
    const v = (ev.currentTarget as HTMLSelectElement).value;
    viewer.focusPid = v === "" ? null : Number(v);
  }
</script>

<div class="panel trace">
  <div class="trace-head">
    <div class="seg" role="radiogroup" aria-label="What the panel follows">
      <button type="button" role="radio" aria-checked={viewer.trace === "ball"} class:on={viewer.trace === "ball"}
              onclick={() => (viewer.trace = "ball")}>Ball height</button>
      <button type="button" role="radio" aria-checked={viewer.trace === "nearest"} class:on={viewer.trace === "nearest"}
              onclick={() => (viewer.trace = "nearest")}>Nearest opponent</button>
    </div>
    {#if viewer.trace === "nearest"}
      <label class="trace-pick">
        <span>Player</span>
        <select value={focus ? String(focus.id) : ""} onchange={pick} style:color={kitText(focus)}>
          <option value="">Click a player…</option>
          {#each ["off", "def"] as role (role)}
            {@const group = tracked.filter((p) => p.role === role)}
            {#if group.length}
              <optgroup label={role === "off" ? play?.off : play?.def}>
                {#each group as p (p.id)}<option value={String(p.id)}>#{p.jersey} {p.name}</option>{/each}
              </optgroup>
            {/if}
          {/each}
        </select>
      </label>
      {#if focus}
        <span class="trace-read">
          {#if hovered}
            {@const opp = play?.players.find((p) => p.id === hovered.opp)}
            at {hovered.t.toFixed(1)} s: <b>{fmt(hovered.v)}</b> to <b style:color={kitText(opp)}>{name(opp)}</b>
          {:else}
            nearest: <b style:color={kitText(now?.opp)}>{name(now?.opp)}</b>{#if now?.opp}&nbsp;<span>({teamOf(now.opp)})</span>{/if} · <b>{fmt(now?.v)}</b>
          {/if}
        </span>
      {/if}
    {:else}
      <span class="trace-read">
        {#if hovered}at {hovered.t.toFixed(1)} s: <b>{fmt(hovered.v)}</b>{:else}ball height <b>{fmt(now?.v)}</b>{/if}
      </span>
    {/if}
  </div>

  <div class="trace-chart" bind:clientWidth={width}>
    {#if !play}
      <p class="trace-empty">No play selected.</p>
    {:else if !kind}
      <p class="trace-empty">Click a player on the court (or in a roster, or the list above) to follow his distance to the nearest opponent.</p>
    {:else if width > 0}
      <svg bind:this={svg} {width} height={H} role="slider" aria-label="Trace over the play; click to move playback" aria-valuenow={Math.round(viewer.pos)}
           aria-valuemin={0} aria-valuemax={seq.length - 1} tabindex="-1"
           onpointerdown={(ev) => { svg!.setPointerCapture(ev.pointerId); seek(ev); }} onpointermove={hover}
           onpointerleave={() => (hoverK = null)}>
        {#each yTicks as v (v)}
          <line class="grid" x1={M.left} x2={M.left + plotW} y1={Y(v)} y2={Y(v)} />
          <text class="axis" x={M.left - 6} y={Y(v)} text-anchor="end" dominant-baseline="middle">{v}</text>
        {/each}
        {#each xTicks as t (t)}
          <text class="axis" x={X(t)} y={H - 6} text-anchor="middle">{t % 1 ? t.toFixed(1) : t}</text>
        {/each}
        <text class="axis unit" x={M.left - 6} y={top - 6} text-anchor="end">ft</text>
        <text class="axis unit" x={M.left + plotW} y={H - 6} text-anchor="end" dx="12">s</text>
        {#each marks.list as m, i (i)}
          <line class="mark {m.kind}" x1={m.x} x2={m.x} y1={top - 2} y2={top + PLOT_H}><title>{m.title}</title></line>
          {#if m.row >= 0}
            <text class="mark-label {m.kind}" x={m.flip ? m.x - 3 : m.x + 3} y={4 + m.row * ROW} text-anchor={m.flip ? "end" : "start"}
                  dominant-baseline="hanging"><title>{m.title}</title>{m.text}</text>
          {/if}
        {/each}
        {#if hovered}<line class="hover" x1={X(hovered.t)} x2={X(hovered.t)} y1={top} y2={top + PLOT_H} />{/if}
        <path d={pastPath} fill="none" stroke={color} stroke-width="2.2" stroke-linejoin="round" />
        {#each samples as s (s.k)}
          {#if s.v != null}
            <circle class="sample" class:faint={s.faint} cx={X(s.t)} cy={Y(s.v)} r="3" />
          {/if}
        {/each}
        {#if now?.v != null}
          <circle cx={X(now.t)} cy={Y(now.v)} r="5.5" fill={color} stroke="#0F1522" stroke-width="1.5" />
        {/if}
      </svg>
    {/if}
  </div>
</div>
