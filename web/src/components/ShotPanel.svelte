<script lang="ts">
  // Beside the half court: the steps behind a shot's xFG. The baseline for the shot's zone, then every input of
  // the context model as it stood at release with what it adds to xFG, then the result. Follows playback: the
  // latest shot released, or the possession's first shot while none has been.
  import { clock, pct, quarter } from "../lib/geometry";
  import { seqIndexOfFrame } from "../lib/sequence";
  import { ZONE_NAMES, points, shotRows } from "../lib/shots";
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
      <div class="shot-step anchor" title="The {zone.toLowerCase()} context model's average over its training shots, close to their make rate. The effects below start from it.">
        <span>{zone} baseline</span><span></span><span>{pct(shot.base, 1)}</span>
      </div>
      {#each shotRows(shot) as row (row.label)}
        <div class="shot-step" title={row.hint}>
          <span>{row.label}</span><span>{row.value}</span><span class={tone(row.effect)}>{points(row.effect)}</span>
        </div>
      {/each}
      <div class="shot-step total" title="Baseline plus the effects"><span>Shot xFG</span><span></span><span>{pct(shot.xfg, 1)}</span></div>
    </div>
    {#if shot.rounds === 0}
      <p class="note">No context effect held up for {zone.toLowerCase()} shots when this game was left out of the fit, so xFG is their make rate and no feature moves it.</p>
    {/if}
    {#if shot.fouled}
      <p class="note">Fouled on the shot. xFG is the make chance of an unfouled attempt.</p>
    {/if}
    <p class="note">Effects are percentage points of xFG in a model fitted on the other nine games. They describe the model, not cause and effect.</p>
  {:else if play}
    <p class="note">{hasShot ? "No xFG steps for this possession's shot." : "No shot in this possession."}</p>
  {/if}
</aside>
