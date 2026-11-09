<script lang="ts">
  // The Gravity tab's room explorer. Pick where an off-ball attacker stands, where the ball is, and how often that
  // kind of player shoots from his spot; the court shows the expected room (distance to the nearest defender) for an
  // off-ball attacker at every spot with the ball there, and the panel gives the number at the chosen spot.
  //
  // Data: explore_gravity_room.json (web/scripts/explore/gravity.R), every 3rd sampled half-court frame of every
  // off-ball attacker in the ten games, with his spot, the ball holder's spot, his room and his shooting tendency
  // from that zone (season attempts per 100 possessions, in thirds of the league's players for that zone). Each
  // frame is also used mirrored left to right. The expected room is a kernel-weighted average of similar moments:
  // weight exp(-d²/2bw²) on the attacker's distance from the chosen spot (bw 2.5 ft) times the same on the ball's
  // (bw 5 ft). It describes these games; it is not a fitted model.
  import { loadExplore } from "../../lib/data";
  import { rampAt } from "../charts/kde";

  interface RoomDoc {
    n: number; scale: { pos: number; room: number }; hoop: number;
    px: number[]; py: number[]; bx: number[]; by: number[]; room: number[]; t: number[];
    cuts: { zone: string; q1: number; q2: number }[];
  }
  type Pt = { x: number; y: number };

  const M = 3.28084, HALF = 14 * M, HW = 7.5 * M, HOOP = HALF - 1.575 * M;
  const KEY_X = HALF - 5.8 * M, KEY_HW = 2.45 * M, R3 = 6.75 * M, Y3 = 6.6 * M, CORNER_X = HOOP - Math.sqrt(R3 * R3 - Y3 * Y3);
  const BW_P = 2.5, BW_B = 5, CELL = 2, MIN_N = 8, LO = 3, HI = 13, S = 9;
  const TEND = ["Rarely", "Sometimes", "Often"];

  let doc = $state.raw<RoomDoc | null>(null);
  let problem = $state("");
  let data: { px: Float32Array; py: Float32Array; bx: Float32Array; by: Float32Array; room: Float32Array; t: Uint8Array } | null = null;
  loadExplore<RoomDoc>("gravity_room").then((d) => {
    const n = d.n, k = d.scale.pos, r = d.scale.room;
    const px = new Float32Array(2 * n), py = new Float32Array(2 * n), bx = new Float32Array(2 * n), by = new Float32Array(2 * n);
    const room = new Float32Array(2 * n), t = new Uint8Array(2 * n);
    for (let i = 0; i < n; i++) {
      for (const [j, s] of [[i, 1], [i + n, -1]] as const) {   // each moment and its left-right mirror
        px[j] = d.px[i] / k; py[j] = (s * d.py[i]) / k; bx[j] = d.bx[i] / k; by[j] = (s * d.by[i]) / k;
        room[j] = d.room[i] / r; t[j] = d.t[i];
      }
    }
    data = { px, py, bx, by, room, t };
    doc = d;
  }).catch((err: Error) => { problem = err.message; });

  let player = $state<Pt>({ x: 41.5, y: -22.5 });
  let ball = $state<Pt>({ x: 17, y: 0 });
  let mode = $state<"player" | "ball">("ball");
  let tend = $state<number | null>(2);

  /** Rows near the ball (within 3 bandwidths) with their ball weight, for a tendency or all. */
  function nearBall(b: Pt, tt: number | null): { idx: Int32Array; w: Float32Array } {
    if (!data) return { idx: new Int32Array(0), w: new Float32Array(0) };
    const idx: number[] = [], w: number[] = [], lim = (3 * BW_B) ** 2, inv = 1 / (2 * BW_B * BW_B);
    for (let i = 0; i < data.bx.length; i++) {
      if (tt != null && data.t[i] !== tt) continue;
      const d2 = (data.bx[i] - b.x) ** 2 + (data.by[i] - b.y) ** 2;
      if (d2 > lim) continue;
      idx.push(i); w.push(Math.exp(-d2 * inv));
    }
    return { idx: Int32Array.from(idx), w: Float32Array.from(w) };
  }
  /** Weighted mean room at a spot from preselected rows, its standard error and effective sample size. */
  function at(p: Pt, rows: { idx: Int32Array; w: Float32Array }) {
    if (!data) return null;
    let sw = 0, sw2 = 0, sr = 0, srr = 0;
    const lim = (3 * BW_P) ** 2, inv = 1 / (2 * BW_P * BW_P);
    for (let k = 0; k < rows.idx.length; k++) {
      const i = rows.idx[k], d2 = (data.px[i] - p.x) ** 2 + (data.py[i] - p.y) ** 2;
      if (d2 > lim) continue;
      const w = rows.w[k] * Math.exp(-d2 * inv), r = data.room[i];
      sw += w; sw2 += w * w; sr += w * r; srr += w * r * r;
    }
    if (!(sw > 0)) return null;
    const m = sr / sw, neff = (sw * sw) / sw2, sd = Math.sqrt(Math.max(0, srr / sw - m * m));
    return { m, se: sd / Math.sqrt(neff), neff };
  }

  const rows = $derived(doc ? nearBall(ball, tend) : null);
  // The heat map: expected room at each 2 ft cell for the chosen ball spot and tendency.
  const cells = $derived.by(() => {
    if (!rows) return [];
    const out: { x: number; y: number; m: number }[] = [];
    for (let x = CELL / 2; x < HALF; x += CELL) {
      for (let y = -HW + CELL / 2; y < HW; y += CELL) {
        const r = at({ x, y }, rows);
        if (r && r.neff >= MIN_N) out.push({ x, y, m: r.m });
      }
    }
    return out;
  });
  const color = (m: number) => { const [r, g, b] = rampAt((m - LO) / (HI - LO)); return `rgb(${r},${g},${b})`; };

  const here = $derived(rows ? at(player, rows) : null);
  const compare = $derived.by(() => {
    if (!doc) return [];
    return [0, 1, 2, null].map((tt) => ({ label: tt == null ? "Any player" : `${TEND[tt]} shoots from here`, tt, r: at(player, nearBall(ball, tt)) }));
  });
  const zoneOf = (p: Pt): string => {
    const d = Math.hypot(HOOP - p.x, p.y);
    if (d <= 4.1) return "restricted area";
    if (p.x >= KEY_X && Math.abs(p.y) <= KEY_HW) return "paint (outside the restricted area)";
    const beyond = p.x >= CORNER_X ? Math.abs(p.y) >= Y3 : d >= R3;
    if (!beyond) return "mid-range";
    return p.x >= CORNER_X ? "corner three" : "above-break three";
  };
  const zone = $derived(zoneOf(player));
  const cut = $derived(doc?.cuts.find((c) => c.zone === zone) ?? null);
  const ballDist = $derived(Math.hypot(player.x - ball.x, player.y - ball.y));

  // ---- pointer: click or drag on the court moves whichever marker is selected ----
  let svg = $state<SVGSVGElement>();
  function place(ev: PointerEvent): void {
    if (!svg) return;
    const box = svg.getBoundingClientRect();
    const x = Math.min(HALF - 0.5, Math.max(0.5, ((ev.clientX - box.left) / box.width) * HALF));
    const y = Math.min(HW - 0.5, Math.max(-HW + 0.5, HW - ((ev.clientY - box.top) / box.height) * 2 * HW));
    if (mode === "player") player = { x, y }; else ball = { x, y };
  }
  let dragging = false, pending: PointerEvent | null = null;
  function down(ev: PointerEvent): void { dragging = true; svg?.setPointerCapture(ev.pointerId); place(ev); }
  function move(ev: PointerEvent): void {
    if (!dragging) return;
    if (!pending) requestAnimationFrame(() => { if (pending) place(pending); pending = null; });
    pending = ev;
  }
  function key(ev: KeyboardEvent): void {
    const step = ({ ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, 1], ArrowDown: [0, -1] } as Record<string, number[]>)[ev.key];
    if (!step) return;
    ev.preventDefault();
    const p = mode === "player" ? player : ball, q = { x: Math.min(HALF - 0.5, Math.max(0.5, p.x + step[0])), y: Math.min(HW - 0.5, Math.max(-HW + 0.5, p.y + step[1])) };
    if (mode === "player") player = q; else ball = q;
  }
  const X = (x: number) => x * S, Y = (y: number) => (HW - y) * S;
  const arc = `M${X(HALF)},${Y(Y3)} H${X(CORNER_X)} A${R3 * S},${R3 * S} 0 0 0 ${X(CORNER_X)},${Y(-Y3)} H${X(HALF)}`;
</script>

<div class="gr">
  {#if !doc}
    <p class="lead">{problem || "Loading the explorer…"}</p>
  {:else}
    <div class="gr-controls">
      <div class="gr-group">
        <span class="gr-label">Click the court to move</span>
        <div class="seg">
          <button type="button" class:on={mode === "player"} onclick={() => (mode = "player")}>The off-ball player</button>
          <button type="button" class:on={mode === "ball"} onclick={() => (mode = "ball")}>The ball</button>
        </div>
      </div>
      <div class="gr-group">
        <span class="gr-label">How often he shoots from his spot</span>
        <div class="seg">
          {#each TEND as l, i (l)}<button type="button" class:on={tend === i} onclick={() => (tend = i)}>{l}</button>{/each}
          <button type="button" class:on={tend == null} onclick={() => (tend = null)}>Any</button>
        </div>
      </div>
    </div>
    <div class="gr-body">
      <figure class="gr-court">
        <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
        <svg bind:this={svg} viewBox={`0 0 ${HALF * S} ${2 * HW * S}`} role="application" tabindex="0"
             aria-label={`Court. Click or use the arrow keys to move ${mode === "player" ? "the off-ball player" : "the ball"}`}
             onpointerdown={down} onpointermove={move} onpointerup={() => (dragging = false)} onkeydown={key}>
          <rect x="0" y="0" width={HALF * S} height={2 * HW * S} class="floor" />
          {#each cells as c (`${c.x},${c.y}`)}
            <rect x={X(c.x - CELL / 2)} y={Y(c.y + CELL / 2)} width={CELL * S + 0.5} height={CELL * S + 0.5} fill={color(c.m)} opacity="0.85">
              <title>{`${c.m.toFixed(1)} ft of room`}</title>
            </rect>
          {/each}
          <g class="lines">
            <rect x={X(KEY_X)} y={Y(KEY_HW)} width={(HALF - KEY_X) * S} height={2 * KEY_HW * S} />
            <path d={arc} />
            <circle cx={X(HOOP)} cy={Y(0)} r={0.225 * M * S} />
            <line x1={X(HOOP + 0.375 * M)} x2={X(HOOP + 0.375 * M)} y1={Y(0.9 * M)} y2={Y(-0.9 * M)} />
            <circle cx={X(0)} cy={Y(0)} r={1.8 * M * S} />
            <line x1="1" x2="1" y1="0" y2={2 * HW * S} />
          </g>
          <line x1={X(ball.x)} y1={Y(ball.y)} x2={X(player.x)} y2={Y(player.y)} class="link" />
          <g class="marker player" class:active={mode === "player"}>
            <circle cx={X(player.x)} cy={Y(player.y)} r={10} />
            <text x={X(player.x)} y={Y(player.y) + 4} text-anchor="middle">P</text>
          </g>
          <g class="marker ball" class:active={mode === "ball"}>
            <circle cx={X(ball.x)} cy={Y(ball.y)} r={9} />
            <path d={`M${X(ball.x) - 9},${Y(ball.y)} h18 M${X(ball.x)},${Y(ball.y) - 9} v18`} />
          </g>
        </svg>
        <figcaption>
          <span class="gr-scale"><span>{LO} ft</span><i style:background={`linear-gradient(90deg, ${color(LO)}, ${color((LO + HI) / 2)}, ${color(HI)})`}></i><span>{HI}+ ft of room</span></span>
          <span class="gr-note">Shaded where at least {MIN_N} similar moments exist. Darker means more room.</span>
        </figcaption>
      </figure>
      <div class="gr-read">
        <div class="gr-big">
          <span class="gr-label">Expected room at P</span>
          <b>{here && here.neff >= MIN_N ? `${here.m.toFixed(1)} ft` : "Too few moments"}</b>
          {#if here && here.neff >= MIN_N}<span class="gr-sub">±{(1.645 * here.se).toFixed(1)} ft (90%) from about {Math.round(here.neff)} similar moments</span>{/if}
        </div>
        <ul class="gr-facts">
          <li>P stands in the <b>{zone}</b>, {ballDist.toFixed(0)} ft from the ball</li>
          {#if cut}<li>Rarely means under {cut.q1} season attempts per 100 possessions from this zone, often means {cut.q2} or more</li>{/if}
        </ul>
        <table class="gr-table">
          <tbody>
            {#each compare as c (c.label)}
              <tr class:on={c.tt === tend}>
                <td>{c.label}</td>
                <td class="num">{c.r && c.r.neff >= MIN_N ? `${c.r.m.toFixed(1)} ft` : "–"}</td>
                <td class="bar">{#if c.r && c.r.neff >= MIN_N}<i style:width={`${Math.max(0, Math.min(1, (c.r.m - LO) / (HI - LO))) * 100}%`}></i>{/if}</td>
                <td class="n">{c.r ? `n ${Math.round(c.r.neff)}` : ""}</td>
              </tr>
            {/each}
          </tbody>
        </table>
        <p class="gr-hint">Less room than "Any player" means defenders stay closer to that kind of player in that spot, which is gravity.</p>
      </div>
    </div>
  {/if}
</div>

<style>
  .gr { margin: 18px 0 8px; padding: 16px; border: 1px solid var(--line); border-radius: 10px; background: var(--panel); }
  .gr-controls { display: flex; flex-wrap: wrap; gap: 14px 28px; margin-bottom: 14px; }
  .gr-group { display: flex; flex-direction: column; gap: 6px; }
  .gr-label { color: var(--muted); font-size: 13px; font-weight: 600; }
  .gr .seg button { font-size: 13.5px; padding: 5px 12px; }
  .gr-body { display: grid; grid-template-columns: minmax(0, 440px) minmax(0, 1fr); gap: 24px; align-items: start; }
  .gr-court { margin: 0; }
  svg { width: 100%; height: auto; display: block; border-radius: 6px; cursor: crosshair; touch-action: none; }
  svg:focus-visible { outline: 2px solid var(--off); outline-offset: 2px; }
  .floor { fill: #F1F3F6; }
  .lines { fill: none; stroke: #2B2622; stroke-width: 1.5; opacity: .7; pointer-events: none; }
  .link { stroke: #2B2622; stroke-width: 1.5; stroke-dasharray: 4 4; opacity: .6; pointer-events: none; }
  .marker { pointer-events: none; }
  .marker circle { stroke: #0B0E14; stroke-width: 2; }
  .player circle { fill: #199e70; }
  .player text { fill: #fff; font-size: 12px; font-weight: 700; }
  .ball circle { fill: #E8742A; }
  .ball path { stroke: #1B1208; stroke-width: 1.2; fill: none; }
  .marker.active circle { stroke-width: 3.5; }
  figcaption { display: flex; flex-direction: column; gap: 4px; margin-top: 8px; color: var(--muted); font-size: 13px; }
  .gr-scale { display: inline-flex; align-items: center; gap: 8px; }
  .gr-scale i { display: inline-block; width: 140px; height: 10px; border-radius: 2px; }
  .gr-big { display: flex; flex-direction: column; gap: 2px; margin-bottom: 12px; }
  .gr-big b { font-size: 30px; font-variant-numeric: tabular-nums; }
  .gr-sub { color: var(--muted); font-size: 13.5px; }
  .gr-facts { margin: 0 0 12px; padding-left: 18px; font-size: 15px; }
  .gr-facts li { margin-bottom: 4px; }
  .gr-table { width: 100%; border-collapse: collapse; font-size: 14.5px; }
  .gr-table td { padding: 6px 8px; border-bottom: 1px solid var(--line); }
  .gr-table tr.on td { color: var(--ink); font-weight: 600; background: rgba(76, 154, 255, .08); }
  .gr-table .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .gr-table .bar { width: 35%; }
  .gr-table .bar i { display: block; height: 8px; border-radius: 2px; background: #3987e5; }
  .gr-table .n { color: var(--muted); font-size: 12.5px; text-align: right; white-space: nowrap; }
  .gr-hint { margin: 10px 0 0; color: var(--muted); font-size: 14px; }
  @media (max-width: 860px) { .gr-body { grid-template-columns: minmax(0, 1fr); } }
</style>
