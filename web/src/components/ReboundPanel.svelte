<script lang="ts">
  // Rebounding panel beside the court. While a missed shot is live it shows the latest forecast made from what had
  // been seen by then: which side ends up with the ball (collected or awarded), who is most likely to collect it,
  // the box-outs standing now, and how each player's first half second of movement rated. Otherwise it lists the
  // possession's misses. Every number comes from src/rebounding/ through rebounding/<game>.json.
  import { sides } from "../lib/rebounding";
  import type { Play } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play }: { play: Play | null } = $props();

  const r = $derived(live.rebound);
  const who = $derived(new Map((play?.players ?? []).map((p) => [p.id, p])));
  const name = (id: number | null) => {
    const p = id == null ? null : who.get(id);
    return p ? `#${p.jersey} ${p.last}` : "–";
  };
  const isOff = (id: number) => who.get(id)?.role === "off";
  const pct = (v: number) => `${Math.round(v * 100)}%`;
  const signed = (v: number) => `${v >= 0 ? "+" : "−"}${Math.abs(v * 100).toFixed(1)}`;
  const OUTCOME: Record<string, string> = {
    "off player": "Offensive rebound", "def player": "Defensive rebound",
    "off team award": "Offense awarded the ball", "def team award": "Defense awarded the ball",
  };

  const split = $derived(r ? sides(r.step) : null);
  const probs = $derived(r ? (live.reboundTalent && r.step.pt ? r.step.pt : r.step.p) : []);
  const top = $derived(r ? r.step.pid.map((id, i) => ({ id, p: probs[i] })).sort((a, b) => b.p - a.p).slice(0, 5) : []);
  const boxes = $derived(r ? [...r.step.box].filter((b) => b.s >= 0.2).sort((a, b) => b.s - a.s).slice(0, 4) : []);
  const label = (b: number, o: number) => r?.episode.pairs.find((p) => p.b === b && p.o === o)?.label ?? "";
  const movers = $derived(r ? r.episode.anticipation.filter((a) => a.exposure >= 0.005).sort((a, b) => Math.abs(b.gain) - Math.abs(a.gain)).slice(0, 4) : []);
  const bar = $derived(split && r ? [
    { w: r.step.team[0], c: "var(--off)", t: "Offense collects" }, { w: r.step.team[2], c: "#8DB8F5", t: "Offense awarded" },
    { w: split.unresolved, c: "var(--line)", t: "Unresolved after 3.2 s" },
    { w: r.step.team[3], c: "#F5B79A", t: "Defense awarded" }, { w: r.step.team[1], c: "var(--def)", t: "Defense collects" },
  ] : []);
</script>

<div class="panel display rebound-panel">
  <div class="panel-head">
    <h2>Rebounding</h2>
    <label class="switch" title="Draw the forecast on the court: untouched landing points, box-out links and collection chances">
      <input type="checkbox" role="switch" bind:checked={viewer.showRebound} />
      <span class="switch-track"></span>On court
    </label>
  </div>
  {#if r && split}
    <p class="rb-when">
      Forecast at release + {r.since.toFixed(1)} s · {r.episode.range} · {r.episode.kind}
    </p>
    <div class="readout two">
      <div><span>Offensive ball</span><b style:color="var(--off)">{pct(split.off)}</b></div>
      <div><span>Defensive ball</span><b style:color="var(--def)">{pct(split.def)}</b></div>
    </div>
    <div class="rb-bar" role="img" aria-label={`Offense ${pct(split.off)}, defense ${pct(split.def)}`}>
      {#each bar as seg (seg.t)}<i style:flex-grow={seg.w} style:background={seg.c} title={`${seg.t}: ${pct(seg.w)}`}></i>{/each}
    </div>
    <h3 class="rb-sub">Most likely to collect</h3>
    <ul class="rb-list">
      {#each top as t (t.id)}
        <li class:won={r.resolved && r.episode.rebounder === t.id}>
          <i class="dot" style:background={isOff(t.id) ? "var(--off)" : "var(--def)"}></i>
          <span class="nm">{name(t.id)}</span>
          <span class="meter"><i style:width={pct(Math.min(1, t.p / Math.max(0.01, top[0].p)))}></i></span>
          <b>{pct(t.p)}</b>
        </li>
      {/each}
    </ul>
    {#if boxes.length}
      <h3 class="rb-sub">Box-outs now <span class="rb-hint">spatial proxy</span></h3>
      <ul class="rb-list">
        {#each boxes as b (`${b.b}-${b.o}`)}
          <li>
            <i class="dot" style:background={isOff(b.b) ? "var(--off)" : "var(--def)"}></i>
            <span class="nm">{name(b.b)} <em>on</em> {name(b.o)}</span>
            <span class="tag">{label(b.b, b.o)}</span>
            <b>{pct(b.s)}</b>
          </li>
        {/each}
      </ul>
    {/if}
    {#if movers.length}
      <h3 class="rb-sub">First 0.48 s of movement <span class="rb-hint">vs role-matched moves</span></h3>
      <ul class="rb-list">
        {#each movers as a (a.pid)}
          <li>
            <i class="dot" style:background={isOff(a.pid) ? "var(--off)" : "var(--def)"}></i>
            <span class="nm">{name(a.pid)}</span>
            <span class="tag">{a.moved.toFixed(0)} ft</span>
            <b class:up={a.gain > 0} class:down={a.gain < 0} title="Change in his own collection chance, in points, against the average reference move">{signed(a.gain)}</b>
          </li>
        {/each}
      </ul>
    {/if}
    {#if r.resolved}
      <p class="rb-outcome">{OUTCOME[r.episode.outcome] ?? r.episode.outcome}{r.episode.rebounder != null ? `: ${name(r.episode.rebounder)}` : ""}</p>
    {/if}
    <p class="note">
      Assumes the miss; forecast from the tracking seen so far. Brown dots: where the ball would first land untouched.
      Lines: a player blocking an opponent's route to the ball. {live.reboundTalent ? "Chances include collection effects." : "Population model: no player effects passed their test."}
      <a href="#/rebounding">How it works</a>
    </p>
  {:else if live.reboundEpisodes.length}
    <ul class="rb-list misses">
      {#each live.reboundEpisodes as e (e.id)}
        {@const s0 = sides(e.steps[0])}
        <li>
          <span class="nm">Miss by {name(e.shooter)}</span>
          <span class="tag">{pct(s0.off)} off. at release</span>
          <b class:up={e.outcome.startsWith("off")} class:down={e.outcome.startsWith("def")}>{e.outcome.startsWith("off") ? "OREB" : "DREB"}</b>
        </li>
      {/each}
    </ul>
    <p class="note">The forecast appears from each release until its rebound. <a href="#/rebounding">How it works</a></p>
  {:else}
    <p class="note">No missed shot with a rebound forecast in this possession. <a href="#/rebounding">How it works</a></p>
  {/if}
</div>

<style>
  .rb-when { margin: -2px 0 8px; color: var(--muted); font-size: 12px; }
  .rb-bar { display: flex; height: 8px; margin: -2px 0 10px; overflow: hidden; border-radius: 4px; background: var(--raised); }
  .rb-bar i { flex-basis: 0; min-width: 0; }
  .rb-sub { margin: 10px 0 4px; font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--muted); }
  .rb-hint { margin-left: 4px; font-weight: 400; letter-spacing: 0; text-transform: none; }
  .rb-list { margin: 0; padding: 0; list-style: none; font-size: 13px; }
  .rb-list li { display: grid; grid-template-columns: 10px minmax(0, 1fr) auto 44px; align-items: center; gap: 6px; padding: 2px 0; }
  .rb-list.misses li { grid-template-columns: minmax(0, 1fr) auto 44px; }
  .rb-list .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rb-list em { color: var(--muted); font-style: normal; }
  .rb-list b { text-align: right; font-variant-numeric: tabular-nums; }
  .rb-list .tag { color: var(--muted); font-size: 11px; white-space: nowrap; }
  .rb-list li.won .nm { font-weight: 700; color: var(--made); }
  .dot { width: 8px; height: 8px; border-radius: 50%; }
  .meter { position: relative; width: 56px; height: 6px; border-radius: 3px; background: var(--raised); }
  .meter i { position: absolute; inset: 0 auto 0 0; border-radius: 3px; background: #6F86B5; }
  .up { color: var(--made); }
  .down { color: var(--missed); }
  .rb-outcome { margin-top: 8px; font-weight: 600; }
  .note a { color: var(--off); }
</style>
