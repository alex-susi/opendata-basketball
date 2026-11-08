<script lang="ts">
  // A narrow timeline under the court, shown while the trace panel is off: the play's actions as small marks
  // (made shots green, missed shots and turnovers red, the rest grey), no captions, the part already played filled
  // and a white playhead. Hovering a mark opens its card (ActionCard.svelte); clicking or dragging seeks.
  import ActionCard from "./ActionCard.svelte";
  import { clamp } from "../lib/geometry";
  import { layoutTimeline, type Tick, type Timeline } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const PAD = 12, H = 26, MID = 15;
  let width = $state(0);
  let svg = $state<SVGSVGElement>();
  let hoverTicks = $state<Tick[]>([]);
  let box = $state<DOMRect | null>(null);

  const plotW = $derived(Math.max(10, width - 2 * PAD));
  const empty: Timeline = { ticks: [], cuts: [], marks: [] };
  const timeline = $derived(play && seq.length && plotW > 10 ? layoutTimeline(play, seq, plotW, () => 0) : empty);
  const end = $derived(Math.max(1, seq.length - 1));
  const xNow = $derived(PAD + (viewer.pos / end) * plotW);
  const shot = (t: Tick) => t.event.kind === "made" || t.event.kind === "missed";

  const fracAt = (ev: PointerEvent) => clamp((ev.clientX - svg!.getBoundingClientRect().left - PAD) / plotW, 0, 1);
  function seek(ev: PointerEvent): void {
    if (seq.length) viewer.pos = fracAt(ev) * (seq.length - 1);
  }
  function hover(ev: PointerEvent): void {
    box = svg!.getBoundingClientRect();
    const x = ev.clientX - box.left;
    const near = timeline.ticks.filter((t) => Math.abs(PAD + t.frac * plotW - x) < 6).sort((a, b) => a.k - b.k);
    if (near.length !== hoverTicks.length || near.some((t, n) => t !== hoverTicks[n])) hoverTicks = near;
    if (svg!.hasPointerCapture(ev.pointerId)) seek(ev);
  }
</script>

<div class="panel strip" bind:clientWidth={width}>
  {#if play && width > 0}
    <svg bind:this={svg} {width} height={H} role="slider" aria-label="The play's timeline; click to move playback" tabindex="-1"
         aria-valuenow={Math.round(viewer.pos)} aria-valuemin={0} aria-valuemax={seq.length - 1}
         onpointerdown={(ev) => { svg!.setPointerCapture(ev.pointerId); seek(ev); }} onpointermove={hover}
         onpointerleave={() => (hoverTicks = [])}>
      <rect class="strip-hit" x="0" y="0" {width} height={H} />
      <line class="strip-rail" x1={PAD} x2={PAD + plotW} y1={MID} y2={MID} />
      <line class="strip-played" x1={PAD} x2={xNow} y1={MID} y2={MID} />
      {#each timeline.cuts as c}
        <line class="strip-cut" x1={PAD + c * plotW} x2={PAD + c * plotW} y1={MID + 3} y2={MID + 7}><title>Footage skips here</title></line>
      {/each}
      {#each timeline.ticks as t, i (i)}
        {@const x = PAD + t.frac * plotW}
        {#if shot(t)}
          <circle class="strip-shot {t.event.kind}" class:on={hoverTicks.includes(t)} cx={x} cy={MID} r="4.5" />
        {:else}
          <line class="strip-mark {t.event.kind}" class:on={hoverTicks.includes(t)} x1={x} x2={x} y1={MID - 6} y2={MID + 6} />
        {/if}
      {/each}
      <line class="strip-head" x1={xNow} x2={xNow} y1={2} y2={H - 2} />
    </svg>
    {#if hoverTicks.length && box}
      <ActionCard {play} ticks={hoverTicks} x={box.left + PAD + hoverTicks[0].frac * plotW} y={box.top} up />
    {/if}
  {/if}
</div>
