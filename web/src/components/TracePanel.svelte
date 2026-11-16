<script lang="ts">
  // The trace panel under the court, and the play's timeline: one number followed over the whole play, with the
  // play's actions marked on it and the current moment as the play runs. Two traces:
  //   Ball Height    the ball's z from the tracking (ft).
  //   Player Trace   one player's measure, both picked here (lib/trace.ts, METRICS): distance to the nearest
  //                  opponent, his matchup, the nearest teammate, the basket or the ball, or his speed, acceleration
  //                  or speed toward the basket. Clicking a player on the court or in a roster picks him too. The
  //                  court rings him in his team's secondary colour and, for a paired measure, rings the other
  //                  player and joins them with a line. For a paired measure, a dot on the line marks each moment
  //                  the other player becomes someone else; hovering it names who from and to.
  // Samples are every 0.2 s of playback (lib/trace.ts). Each action is a dashed line, captioned with the action
  // above the plot (hidden when the Display panel's Action Names is off);
  // hovering near one shows its full description, with the shot's details, a screen's coverage and the players'
  // season figures when those annotations are on. A white line marks the current moment. Click or drag on the
  // chart to move playback there. A third tab, Player Tracking, swaps the chart for a table of the ten players on
  // court (TrackingTable.svelte). The header's right end shows the value alone (and, for a paired measure, the other
  // player's number and last name); the playback seconds and tracking frame are under the court (lib/draw.ts).
  // Shown or hidden from the Display panel.
  import ActionCard from "./ActionCard.svelte";
  import TrackingTable, { TRACK_GROUPS } from "./TrackingTable.svelte";
  import { clamp } from "../lib/geometry";
  import { COLORS } from "../lib/court";
  import { blend, cursorAt, FPS, layoutTimeline, shortScreen, type Tick, type Timeline } from "../lib/sequence";
  import { metricInfo, METRICS, partnerChanges, playerValue, traceSamples, type Metric, type PartnerChange, type TraceKind,
           type TraceSample } from "../lib/trace";
  import type { Play, PlayerTrack } from "../lib/types";
  import { pageText } from "../lib/theme.svelte";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  // Room on the left for the y axis's numbers and its title (turned on its side), and under the plot for the time
  // axis's numbers and its title.
  const M = { left: 56, right: 12 };
  const AXIS = 36;
  // Every tab is this tall (app.css, .trace-chart: the Player Tracking table fits it), so switching tabs never moves
  // the court; the chart's plot takes whatever the captions and axes leave.
  const CHART_H = 236;
  // Captions: the action in a band above the plot. Captions that crowd tilt away from their line (lib/sequence.ts,
  // layoutTimeline), each joined to it by a short leader. The players' names that used to sit in a band under the
  // axis are gone (2026-11-16); the plot takes their height, so the panel keeps its size.
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
  // Every action whose line is within a few pixels of the pointer, in time order: actions that happen at almost the
  // same moment (a pick and the drive off it) share one card, a section each.
  let hoverTicks = $state<Tick[]>([]);

  // Players who appear on the tracked court at some point in this play, offense first.
  const tracked = $derived((play?.players ?? []).filter((p) => p.x.some((v) => !Number.isNaN(v)))
    .sort((a, b) => (a.role === b.role ? 0 : a.role === "off" ? -1 : 1)));
  const focus = $derived(tracked.find((p) => p.id === viewer.focusPid) ?? null);
  const info = $derived(metricInfo(viewer.metric));
  const kind = $derived<TraceKind | null>(viewer.trace === "ball" ? { kind: "ball" } : viewer.trace === "player" && focus ? { kind: "player", pid: focus.id, metric: viewer.metric } : null);
  const samples = $derived(play && seq.length && kind ? traceSamples(play, seq, kind) : []);
  // The ball in its own orange; a followed player in his team's colour as written on the panels.
  const color = $derived(viewer.trace === "ball" || !focus || !play ? COLORS.ball : pageText(play.colors[focus.role].text));
  const tEnd = $derived(Math.max(1, (seq.length - 1) / FPS));
  const unit = $derived(viewer.trace === "ball" ? "ft" : info.unit);
  // The y axis: ball heights past 20 ft are tracking noise; other measures use whatever the play needs (at least 0 to
  // 5), with room below zero for the ones that go negative (acceleration, speed toward the basket). Labelled gridlines
  // every 1, 2, 5, 10 or 20 units, the finest step that gives at most eight intervals, and a faint unlabelled line
  // halfway between each pair.
  const yAxis = $derived.by(() => {
    const vals = samples.map((s) => s.v ?? 0);
    const hi = viewer.trace === "ball" ? clamp(Math.max(0, ...vals), 5, 20) : Math.max(5, ...vals);
    const lo = viewer.trace === "ball" ? 0 : Math.min(0, ...vals);
    const step = [1, 2, 5, 10, 20, 50].find((st) => Math.ceil(hi / st) - Math.floor(lo / st) <= 8) ?? 100;
    return { step, min: Math.floor(lo / step) * step, max: Math.ceil(hi / step) * step };
  });
  const yMax = $derived(yAxis.max);
  const yMin = $derived(yAxis.min);

  const plotW = $derived(Math.max(10, width - M.left - M.right));
  const X = (t: number) => M.left + (t / tEnd) * plotW;

  const empty: Timeline = { ticks: [], cuts: [], marks: [] };
  const timeline = $derived(play && seq.length && plotW > 10 ? layoutTimeline(play, seq, plotW, measure) : empty);
  const top = $derived(viewer.showTickLabels ? BAND + 2 : 12);
  const H = CHART_H;
  const bottom = $derived(H - AXIS);
  const PLOT_H = $derived(bottom - top);
  // The axis titles: what is measured and its unit.
  const yTitle = $derived(viewer.trace === "ball" ? "Ball Height (ft)" : `${info.axis} (${info.unit})`);
  const Y = (v: number) => bottom - ((clamp(v, yMin, yMax) - yMin) / (yMax - yMin)) * PLOT_H;
  const yTicks = $derived(Array.from({ length: Math.round((yMax - yMin) / yAxis.step) + 1 }, (_, i) => yMin + i * yAxis.step));
  const yMinor = $derived(yTicks.slice(1).map((v) => v - yAxis.step / 2));
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
    const got = playerValue(play, kind.pid, kind.metric, c);
    return { v: got.v, opp: play.players.find((p) => p.id === got.other) ?? null };
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

  // Paired measures: a dot on the line where the other player becomes someone else, filled in the new player's team
  // colour. Hovering one names who it changed from and to (the action card stays hidden meanwhile).
  const changes = $derived(viewer.trace === "player" && info.pair ? partnerChanges(samples).filter((c) => c.v != null) : []);
  const CHANGE_TITLE: Partial<Record<Metric, string>> = { nearest: "New Nearest Opponent", matchup: "New Matchup", teammate: "New Nearest Teammate" };
  let hoverChange = $state<PartnerChange | null>(null);
  const playerOf = (pid: number) => play?.players.find((p) => p.id === pid) ?? null;
  // The other player of a paired measure: number and last name.
  const name = (p: PlayerTrack | null | undefined) => (p ? `#${p.jersey} ${p.last}` : "–");
  const kitText = (p: PlayerTrack | null | undefined) => (p && play ? pageText(play.colors[p.role].text) : undefined);
  const fmt = (v: number | null | undefined) => (v == null || Number.isNaN(v) ? "–" : `${v.toFixed(1)} ${unit}`);

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
    chartBox = chartEl?.getBoundingClientRect() ?? null;
    const box = svg!.getBoundingClientRect(), x = ev.clientX - box.left, t = tAt(ev);
    hoverK = samples.length ? samples.reduce((a, b) => (Math.abs(b.t - t) < Math.abs(a.t - t) ? b : a)).k : null;
    const y = ev.clientY - box.top;
    let dot: PartnerChange | null = null, dotD = 9;
    for (const c of changes) {
      const d = Math.hypot(X(c.t) - x, Y(c.v!) - y);
      if (d < dotD) { dot = c; dotD = d; }
    }
    hoverChange = dot;
    const near = dot ? [] : timeline.ticks.filter((tick) => Math.abs(M.left + tick.frac * plotW - x) < 7).sort((a, b) => a.k - b.k);
    if (near.length !== hoverTicks.length || near.some((tick, n) => tick !== hoverTicks[n])) hoverTicks = near;
    if (svg!.hasPointerCapture(ev.pointerId)) seek(ev);
  }
  function leave(): void {
    hoverK = null;
    hoverTicks = [];
    hoverChange = null;
  }
  // The card is fixed to the window (not clipped by the scrolling panel), so it can rise over the court.
  let chartEl = $state<HTMLDivElement>();
  let chartBox = $state<DOMRect | null>(null);

  function pick(ev: Event): void {
    const v = (ev.currentTarget as HTMLSelectElement).value;
    viewer.focusPid = v === "" ? null : Number(v);
  }
  function pickMetric(ev: Event): void {
    viewer.metric = (ev.currentTarget as HTMLSelectElement).value as Metric;
  }
</script>

<div class="panel trace">
  <div class="trace-head">
    <div class="seg" role="radiogroup" aria-label="What the panel follows">
      <button type="button" role="radio" aria-checked={viewer.trace === "ball"} class:on={viewer.trace === "ball"}
              onclick={() => (viewer.trace = "ball")}>Ball Height</button>
      <button type="button" role="radio" aria-checked={viewer.trace === "player"} class:on={viewer.trace === "player"}
              onclick={() => (viewer.trace = "player")}>Player Trace</button>
      <button type="button" role="radio" aria-checked={viewer.trace === "players"} class:on={viewer.trace === "players"}
              onclick={() => (viewer.trace = "players")}>Player Tracking</button>
    </div>
    <!-- Each tab's own controls straight after the tabs, so they never move; the value at the right end. -->
    {#if viewer.trace === "players"}
      <div class="seg" role="radiogroup" aria-label="Columns shown">
        {#each TRACK_GROUPS as g (g.key)}
          <button type="button" role="radio" aria-checked={viewer.trackCols === g.key} class:on={viewer.trackCols === g.key}
                  onclick={() => (viewer.trackCols = g.key)}>{g.label}</button>
        {/each}
      </div>
    {:else if viewer.trace === "player"}
      <label class="trace-pick">
        <span>Player</span>
        <select class="pick-player" value={focus ? String(focus.id) : ""} onchange={pick} style:color={kitText(focus)}>
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
      <label class="trace-pick" title={info.title}>
        <span>Track</span>
        <select class="pick-metric" value={viewer.metric} onchange={pickMetric}>
          {#each METRICS as m (m.key)}<option value={m.key} title={m.title}>{m.label}</option>{/each}
        </select>
      </label>
      {#if play && focus}
        {@const v = hovered ? hovered.v : now?.v}
        {@const opp = hovered ? play.players.find((p) => p.id === hovered.opp) : now?.opp}
        <span class="trace-read"><b>{fmt(v)}</b>{#if info.pair && opp}&nbsp;· <b style:color={kitText(opp)}>{name(opp)}</b>{/if}</span>
      {/if}
    {:else if viewer.trace === "ball" && play}
      <span class="trace-read"><b>{fmt(hovered ? hovered.v : now?.v)}</b></span>
    {/if}
  </div>

  <div class="trace-chart" bind:clientWidth={width} bind:this={chartEl}>
    {#if !play}
      <p class="trace-empty">No play selected.</p>
    {:else if viewer.trace === "players"}
      <TrackingTable {play} />
    {:else if width > 0}
      <svg bind:this={svg} {width} height={H} role="slider" aria-label="The play's timeline and trace; click to move playback"
           aria-valuenow={Math.round(viewer.pos)} aria-valuemin={0} aria-valuemax={seq.length - 1} tabindex="-1"
           onpointerdown={(ev) => { svg!.setPointerCapture(ev.pointerId); seek(ev); }} onpointermove={hover}
           onpointerleave={leave}>
        <rect class="plot-hit" x={M.left} y={top} width={plotW} height={PLOT_H} />
        {#each yMinor as v (v)}
          <line class="grid minor" x1={M.left} x2={M.left + plotW} y1={Y(v)} y2={Y(v)} />
        {/each}
        {#each yTicks as v (v)}
          <line class="grid" x1={M.left} x2={M.left + plotW} y1={Y(v)} y2={Y(v)} />
          <text class="axis" x={M.left - 6} y={Y(v)} text-anchor="end" dominant-baseline="middle">{v}</text>
        {/each}
        {#each xTicks as t (t)}
          <text class="axis" x={X(t)} y={bottom + 14} text-anchor="middle">{t % 1 ? t.toFixed(1) : t}</text>
        {/each}
        <text class="axis-title" x={M.left + plotW / 2} y={bottom + 31} text-anchor="middle">Time (s)</text>
        {#if kind}
          <text class="axis-title" transform="translate(12 {top + PLOT_H / 2}) rotate(-90)" text-anchor="middle" dominant-baseline="middle">{yTitle}</text>
        {/if}
        {#each timeline.cuts as cut}
          <line class="cut" x1={M.left + cut * plotW} x2={M.left + cut * plotW} y1={bottom - 5} y2={bottom + 3}><title>Footage skips here</title></line>
        {/each}
        {#each timeline.ticks as tick, i (i)}
          {@const x = M.left + tick.frac * plotW}
          <line class="mark {tick.event.kind}" class:on={hoverTicks.includes(tick)} x1={x} x2={x} y1={top - 2} y2={bottom + 2} />
        {/each}
        {#if !kind}
          <text class="trace-prompt" x={M.left + plotW / 2} y={top + PLOT_H / 2} text-anchor="middle" dominant-baseline="middle">
            Click a player on the court or in a roster, or pick one above, to follow his {info.label.toLowerCase()}.
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
        {#each changes as c (c.k)}
          <circle class="change-dot" class:on={hoverChange === c} cx={X(c.t)} cy={Y(c.v!)} r={hoverChange === c ? 6 : 4.5}
                  fill={kitText(playerOf(c.to))} />
        {/each}
        {#if now?.v != null}
          <circle class="now-dot" cx={X(tNow)} cy={Y(now.v)} r="5.5" fill={color} stroke-width="1.5" />
        {/if}
      </svg>
      {#if hoverChange}
        {@const c = hoverChange}
        {@const from = playerOf(c.from)}
        {@const to = playerOf(c.to)}
        <div class="change-tip" class:at-left={X(c.t) < 110} class:at-right={X(c.t) > width - 110}
             style:left="{X(c.t)}px" style:top="{Y(c.v!) - 10}px" role="tooltip">
          <span class="change-title">{CHANGE_TITLE[viewer.metric] ?? "New Player"}</span>
          <span><b style:color={kitText(from)}>{name(from)}</b> → <b style:color={kitText(to)}>{name(to)}</b></span>
        </div>
      {/if}
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
            <span class="tick-label above lean-{tick.lean} {tick.event.kind}" class:on={hoverTicks.includes(tick)}
                  style:left="{tick.at}px" style:width={boxWidth(tick)}>{shortScreen(tick.event.short ?? "")}{#if tick.event.flag}<i class="event-flag">{tick.event.flag}</i>{/if}</span>
          {/each}
        </div>
      {/if}
      {#if hoverTicks.length && chartBox}
        <ActionCard {play} ticks={hoverTicks} x={chartBox.left + M.left + hoverTicks[0].frac * plotW} y={chartBox.top + top} />
      {/if}
    {/if}
  </div>
</div>

