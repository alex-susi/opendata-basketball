<script lang="ts">
  // The trace panel under the court, and the play's timeline: one number followed over the whole play, with the
  // play's actions marked on it and the current moment as the play runs. Two traces:
  //   Ball height       the ball's z from the tracking (ft).
  //   Nearest opponent  one player's floor distance to the closest player of the other team (ft). Click a player
  //                     on the court or in a roster, or pick one here; the court rings the pair in their teams'
  //                     secondary colours and joins them with a line.
  // Samples are every 0.2 s of playback (lib/trace.ts). Each action is a dashed line, captioned with the action
  // above the plot and the player under the time axis (both hidden when the Display panel's Action Names is off);
  // hovering near one shows its full description. A white line marks the current moment. Click or drag on the
  // chart to move playback there. Shown or hidden from the Display panel.
  import { clamp } from "../lib/geometry";
  import { COLORS } from "../lib/court";
  import { blend, cursorAt, FPS, layoutTimeline, type Tick, type Timeline } from "../lib/sequence";
  import { nearestAt, traceSamples, type TraceKind, type TraceSample } from "../lib/trace";
  import type { Play, PlayerTrack } from "../lib/types";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const M = { left: 38, right: 12 };
  const PLOT_H = 92;
  const AXIS = 20;          // the time axis's numbers, under the plot
  // Captions: the action in a band above the plot, the player in a band under the axis. Captions that crowd tilt
  // away from their line (lib/sequence.ts, layoutTimeline), each joined to it by a short leader.
  const BAND = 43, LEADER = 5;
  const TICK_FONT = '600 11px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';   // matches .tick-label
  const measurer = document.createElement("canvas").getContext("2d")!;
  const measure = (text: string) => {
    measurer.font = TICK_FONT;
    return measurer.measureText(text).width;
  };

  let width = $state(0);
  let svg = $state<SVGSVGElement>();
  let hoverK = $state<number | null>(null);
  let hoverTick = $state<Tick | null>(null);

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

  const empty: Timeline = { ticks: [], cuts: [], marks: [] };
  const timeline = $derived(play && seq.length && plotW > 10 ? layoutTimeline(play, seq, plotW, measure) : empty);
  const top = $derived(viewer.showTickLabels ? BAND + 2 : 12);
  const bottom = $derived(top + PLOT_H);
  const H = $derived(bottom + AXIS + (viewer.showTickLabels ? BAND : 4));
  const Y = (v: number) => bottom - (clamp(v, 0, yMax) / yMax) * PLOT_H;
  const yTicks = $derived(Array.from({ length: Math.floor(yMax / 5) + 1 }, (_, i) => i * 5).filter((v) => yMax <= 20 || v % 10 === 0));
  const xTicks = $derived.by(() => {
    const step = [0.5, 1, 2, 5, 10, 20].find((s) => (s / tEnd) * plotW >= 46) ?? 30;
    return Array.from({ length: Math.floor(tEnd / step + 1e-9) + 1 }, (_, i) => i * step);
  });
  const tilted = $derived(timeline.ticks.filter((tick) => tick.lean !== "flat"));
  const boxWidth = (tick: Tick) => (tick.lean === "flat" ? `${tick.width}px` : null);

  // The current moment, blended between frames like the court.
  const tNow = $derived(viewer.pos / FPS);
  const now = $derived.by(() => {
    if (!play || !seq.length || !kind) return null;
    const c = cursorAt(play, seq, viewer.pos);
    if (kind.kind === "ball") return { v: blend(play.ball.z, c), opp: null as PlayerTrack | null };
    const near = nearestAt(play, kind.pid, c);
    return { v: near?.dist ?? null, opp: near ? play.players.find((p) => p.id === near.pid) ?? null : null };
  });

  // The line runs through the samples already played (and the current moment), broken where a value is missing.
  const pastPath = $derived.by(() => {
    if (!now) return "";
    let d = "", pen = false;
    for (const s of samples) {
      if (s.t > tNow) break;
      if (s.v == null) { pen = false; continue; }
      d += `${pen ? "L" : "M"}${X(s.t).toFixed(1)},${Y(s.v).toFixed(1)}`;
      pen = true;
    }
    if (pen && now.v != null) d += `L${X(tNow).toFixed(1)},${Y(now.v).toFixed(1)}`;
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
  // The sample under the pointer, and the action whose line is within a few pixels of it (for its card).
  function hover(ev: PointerEvent): void {
    const box = svg!.getBoundingClientRect(), x = ev.clientX - box.left, t = tAt(ev);
    hoverK = samples.length ? samples.reduce((a, b) => (Math.abs(b.t - t) < Math.abs(a.t - t) ? b : a)).k : null;
    let best: Tick | null = null, gap = 7;
    for (const tick of timeline.ticks) {
      const d = Math.abs(M.left + tick.frac * plotW - x);
      if (d < gap) { best = tick; gap = d; }
    }
    hoverTick = best;
    if (svg!.hasPointerCapture(ev.pointerId)) seek(ev);
  }
  function leave(): void {
    hoverK = null;
    hoverTick = null;
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
    {:else if width > 0}
      <svg bind:this={svg} {width} height={H} role="slider" aria-label="The play's timeline and trace; click to move playback"
           aria-valuenow={Math.round(viewer.pos)} aria-valuemin={0} aria-valuemax={seq.length - 1} tabindex="-1"
           onpointerdown={(ev) => { svg!.setPointerCapture(ev.pointerId); seek(ev); }} onpointermove={hover}
           onpointerleave={leave}>
        <rect class="plot-hit" x={M.left} y={top} width={plotW} height={PLOT_H} />
        {#each yTicks as v (v)}
          <line class="grid" x1={M.left} x2={M.left + plotW} y1={Y(v)} y2={Y(v)} />
          <text class="axis" x={M.left - 6} y={Y(v)} text-anchor="end" dominant-baseline="middle">{v}</text>
        {/each}
        {#each xTicks as t (t)}
          <text class="axis" x={X(t)} y={bottom + 14} text-anchor="middle">{t % 1 ? t.toFixed(1) : t}</text>
        {/each}
        <text class="axis unit" x={M.left - 6} y={top - 6} text-anchor="end">ft</text>
        <text class="axis unit" x={M.left + plotW} y={bottom + 14} text-anchor="end" dx="12">s</text>
        {#each timeline.cuts as cut}
          <line class="cut" x1={M.left + cut * plotW} x2={M.left + cut * plotW} y1={bottom - 5} y2={bottom + 3}><title>Footage skips here</title></line>
        {/each}
        {#each timeline.ticks as tick, i (i)}
          {@const x = M.left + tick.frac * plotW}
          <line class="mark {tick.event.kind}" class:on={hoverTick === tick} x1={x} x2={x} y1={top - 2} y2={bottom + 2} />
        {/each}
        {#if !kind}
          <text class="trace-prompt" x={M.left + plotW / 2} y={top + PLOT_H / 2} text-anchor="middle" dominant-baseline="middle">
            Click a player on the court or in a roster to follow his distance to the nearest opponent.
          </text>
        {/if}
        {#if hovered}<line class="hover" x1={X(hovered.t)} x2={X(hovered.t)} y1={top} y2={bottom} />{/if}
        <line class="playhead" x1={X(tNow)} x2={X(tNow)} y1={top - 2} y2={bottom + 2} />
        <path d={pastPath} fill="none" stroke={color} stroke-width="2.2" stroke-linejoin="round" />
        {#each samples as s (s.k)}
          {#if s.v != null}
            <circle class="sample" class:faint={s.faint} cx={X(s.t)} cy={Y(s.v)} r="3" />
          {/if}
        {/each}
        {#if now?.v != null}
          <circle cx={X(tNow)} cy={Y(now.v)} r="5.5" fill={color} stroke="#0F1522" stroke-width="1.5" />
        {/if}
      </svg>
      {#if viewer.showTickLabels}
        <!-- The action over its line, above the plot. -->
        <div class="trace-captions" style:left="{M.left}px" style:top="{top - 2 - BAND}px" style:width="{plotW}px"
             style:height="{BAND}px" aria-hidden="true">
          <svg class="leaders">
            {#each tilted as tick}
              <line x1={tick.frac * plotW} y1={BAND} x2={tick.at} y2={BAND - LEADER} />
            {/each}
          </svg>
          {#each timeline.ticks as tick}
            <span class="tick-label above lean-{tick.lean} {tick.event.kind}" class:on={hoverTick === tick}
                  style:left="{tick.at}px" style:width={boxWidth(tick)}>{tick.event.short ?? ""}</span>
          {/each}
        </div>
        <!-- The player under the time axis. -->
        <div class="trace-names" style:left="{M.left}px" style:top="{bottom + AXIS}px" style:width="{plotW}px"
             style:height="{BAND}px" aria-hidden="true">
          <svg class="leaders">
            {#each tilted as tick}
              <line x1={tick.frac * plotW} y1={0} x2={tick.at} y2={LEADER} />
            {/each}
          </svg>
          {#each timeline.ticks as tick}
            <span class="tick-label below lean-{tick.lean}" class:on={hoverTick === tick}
                  style:left="{tick.at}px" style:width={boxWidth(tick)}>{tick.event.who ?? ""}</span>
          {/each}
        </div>
      {/if}
      {#if hoverTick}
        {@const x = M.left + hoverTick.frac * plotW}
        <div class="trace-card" style:left="{clamp(x - 130, 0, Math.max(0, width - 260))}px" style:top="{top + 6}px">
          <span class="trace-card-time">{(hoverTick.k / FPS).toFixed(1)} s</span>
          <b class={hoverTick.event.kind}>{hoverTick.event.label}</b>
        </div>
      {/if}
    {/if}
  </div>
</div>
