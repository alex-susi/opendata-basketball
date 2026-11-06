<script lang="ts">
  // The trace panel between the court and the transport bar: one number followed over the whole play, with the
  // current moment marked as the play runs. Two traces:
  //   Ball height       the ball's z from the tracking (ft).
  //   Nearest opponent  one player's floor distance to the closest player of the other team (ft). Click a player
  //                     on the court or in a roster, or pick one here; the court joins the pair with a pink line.
  // Samples are every 0.2 s of playback (lib/trace.ts), on the transport bar's clock. Click or drag on the chart
  // to move playback there.
  import { clamp } from "../lib/geometry";
  import { COLORS } from "../lib/court";
  import { blend, cursorAt, FPS, LEAD_IN, seqIndexOfFrame } from "../lib/sequence";
  import { nearestAt, traceSamples, type TraceKind, type TraceSample } from "../lib/trace";
  import type { Play, PlayerTrack } from "../lib/types";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const H = 132;
  const M = { left: 38, right: 12, top: 14, bottom: 24 };
  let width = $state(0);
  let svg = $state<SVGSVGElement>();
  let hoverK = $state<number | null>(null);

  // Players who appear on the tracked court at some point in this play, offense first.
  const tracked = $derived((play?.players ?? []).filter((p) => p.x.some((v) => !Number.isNaN(v)))
    .sort((a, b) => (a.role === b.role ? 0 : a.role === "off" ? -1 : 1)));
  const focus = $derived(tracked.find((p) => p.id === viewer.focusPid) ?? null);
  const kind = $derived<TraceKind | null>(viewer.trace === "ball" ? { kind: "ball" } : focus ? { kind: "nearest", pid: focus.id } : null);
  const samples = $derived(play && seq.length && kind ? traceSamples(play, seq, kind) : []);
  const color = $derived(viewer.trace === "ball" ? COLORS.ball : COLORS.pair);
  const tEnd = $derived(Math.max(1, (seq.length - 1) / FPS));
  // Ball heights past 20 ft are tracking noise; distances use whatever the play needs, in steps of 5 ft.
  const yMax = $derived.by(() => {
    const top = Math.max(0, ...samples.map((s) => s.v ?? 0));
    return viewer.trace === "ball" ? clamp(Math.ceil(top / 5) * 5, 10, 20) : Math.max(10, Math.ceil(top / 5) * 5);
  });

  const plotW = $derived(Math.max(10, width - M.left - M.right));
  const plotH = H - M.top - M.bottom;
  const X = (t: number) => M.left + (t / tEnd) * plotW;
  const Y = (v: number) => M.top + plotH - (clamp(v, 0, yMax) / yMax) * plotH;
  const yTicks = $derived(Array.from({ length: Math.floor(yMax / 5) + 1 }, (_, i) => i * 5).filter((v) => yMax <= 20 || v % 10 === 0));
  const xTicks = $derived.by(() => {
    const step = [0.5, 1, 2, 5, 10, 20].find((s) => (s / tEnd) * plotW >= 46) ?? 30;
    return Array.from({ length: Math.floor(tEnd / step + 1e-9) + 1 }, (_, i) => i * step);
  });

  // The current moment, blended between frames like the court.
  const now = $derived.by(() => {
    if (!play || !seq.length || !kind) return null;
    const c = cursorAt(play, seq, viewer.pos), t = viewer.pos / FPS;
    if (kind.kind === "ball") {
      const z = blend(play.ball.z, c);
      return { t, v: z, opp: null as PlayerTrack | null };
    }
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

  // Shots and rebounds marked on the time axis, where they fall inside the sequence.
  const marks = $derived.by(() => {
    if (!play || !seq.length) return [];
    return play.events.filter((e) => e.kind === "made" || e.kind === "missed" || e.kind === "rebound").flatMap((e) => {
      const k = seqIndexOfFrame(play, seq, e.f);
      if (Math.abs(play.frames[seq[k]] - e.f) > LEAD_IN) return [];
      return [{ t: k / FPS, kind: e.kind, label: e.kind === "rebound" ? "reb" : "shot", title: e.label }];
    });
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
    <button type="button" class="text-btn trace-hide" title="Hide this panel (Display, on the right, brings it back)"
            onclick={() => (viewer.showTrace = false)}>Hide</button>
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
        <text class="axis unit" x={M.left - 6} y={M.top - 6} text-anchor="end">ft</text>
        <text class="axis unit" x={M.left + plotW} y={H - 6} text-anchor="end" dx="12">s</text>
        {#each marks as m, i (i)}
          <line class="mark {m.kind}" x1={X(m.t)} x2={X(m.t)} y1={M.top} y2={M.top + plotH}><title>{m.title}</title></line>
          <text class="mark-label {m.kind}" x={X(m.t) + 3} y={M.top + 2} dominant-baseline="hanging">{m.label}</text>
        {/each}
        {#if hovered}<line class="hover" x1={X(hovered.t)} x2={X(hovered.t)} y1={M.top} y2={M.top + plotH} />{/if}
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
  <p class="trace-note">
    {#if viewer.trace === "ball"}
      Height of the ball's centre from the tracking, every 0.2 s of playback. The ball is reconstructed, not seen: it is
      reported about 12.5 times a second with straight lines between, and its height is less accurate than player
      positions (Rebounding tab, section 3).
    {:else}
      Straight-line floor distance between the two players' centres, every 0.2 s of playback. Dashed circles: at least one
      of the two positions was extrapolated, not detected on screen. The nearest opponent can change from one sample to
      the next; he is not necessarily the assigned defender.
    {/if}
  </p>
</div>
