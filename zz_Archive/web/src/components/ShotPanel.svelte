<script lang="ts">
  // Beside the half court: the steps behind a shot's xFG. The baseline for the shot's kind, then every input of
  // its context model as it stood at release with what it adds to xFG, then the result. Follows playback: the
  // latest shot released, or the possession's first shot while none has been.
  import { clock, pct, quarter } from "../lib/geometry";
  import { seqIndexOfFrame } from "../lib/sequence";
  import { ZONE_NAMES, points, shotNotes, shotRows } from "../lib/shots";
  import type { Play, ShotSteps } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play, seq }: { play: Play | null; seq: number[] } = $props();

  const shots = $derived(play?.shots ?? []);
  const shot = $derived<ShotSteps | null>(shots[live.shot] ?? null);
  const shooter = $derived(play && shot ? (play.players.find((p) => p.id === shot.pid)?.name ?? "") : "");
  const zone = $derived(shot ? ZONE_NAMES[shot.zone] : "");
  const hasShot = $derived(play?.events.some((e) => e.kind === "made" || e.kind === "missed") ?? false);
  const tone = (effect: number) => (points(effect) === "0.0" ? "flat" : effect > 0 ? "up" : "down");

  function when(target: ShotSteps): string {
    const i = play ? play.frames.indexOf(target.f) : -1;
    return play && i >= 0 ? `${quarter(play.period)} ${clock(play.gc[i])}` : "";
  }

  // Stop on the release frame, where the listed values were measured.
  function release(target: ShotSteps): void {
    if (!play) return;
    viewer.pos = seqIndexOfFrame(play, seq, target.f);
    viewer.playing = false;
  }
</script>

<aside class="panel shot-panel" aria-label="Shot quality">
  <div class="panel-head">
    <h2>Shot quality</h2>
    {#if shots.length > 1}
      <div class="shot-picks" title="Shots in this possession: go to a shot's release">
        {#each shots as s, i (s.f)}
          <button type="button" class="text-btn" class:on={i === live.shot} onclick={() => release(s)}>{i + 1}</button>
        {/each}
      </div>
    {/if}
  </div>
  {#if shot}
    <p class="shot-who"><b class={shot.made ? "made" : "missed"}>{shot.made ? "Made" : "Missed"} {shot.three ? 3 : 2}</b> · {shooter}</p>
    <p class="shot-when">
      <span>{when(shot)} · {shot.dist.toFixed(1)} ft</span>
      <button type="button" class="link" onclick={() => release(shot)}>Go to release</button>
    </p>
    <div class="shot-steps">
      <div class="shot-step head"><span></span><span>At release</span><span title="Percentage points of xFG">Effect</span></div>
      <div class="shot-step anchor" title="The model's xFG for an average {zone.toLowerCase()} shot in its training games, close to their make rate. The effects below start from it.">
        <span>{zone} baseline</span><span></span><span>{pct(shot.base, 1)}</span>
      </div>
      {#each shotRows(shot) as row (row.key)}
        <div class="shot-step" title={row.hint}>
          <span>{row.label}</span><span>{row.value}</span><span class={tone(row.effect)}>{points(row.effect)}</span>
        </div>
      {/each}
      <div class="shot-step total" title="Baseline plus the effects"><span>Shot xFG</span><span></span><span>{pct(shot.xfg, 1)}</span></div>
    </div>
    {#each shotNotes(shot) as text (text)}
      <p class="note">{text}</p>
    {/each}
  {:else if play}
    <p class="note">{hasShot ? "No xFG steps for this possession's shot." : "No shot in this possession."}</p>
  {/if}
</aside>
