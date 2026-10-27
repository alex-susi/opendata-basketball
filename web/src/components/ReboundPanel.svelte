<script lang="ts">
  // Rebounding panel beside the court. While a missed shot is live it shows the latest forecast made from what had
  // been seen by then: which side ends up with the ball, split into collected by a player or awarded to the team,
  // who is most likely to collect it, the box-outs standing now, and how each player's first half second of movement
  // rated. Otherwise it lists the possession's misses. Every number comes from src/rebounding/ through
  // rebounding/<game>.json; the Rebounding tab explains each one.
  import type { LandingView } from "../lib/rebounding";
  import { sides } from "../lib/rebounding";
  import type { Play } from "../lib/types";
  import { live, viewer } from "../lib/viewer.svelte";

  let { play }: { play: Play | null } = $props();

  const r = $derived(live.rebound);
  const who = $derived(new Map((play?.players ?? []).map((p) => [p.id, p])));
  // Every mark wears its team's kit, as the player dots and court labels do: primary fill, secondary edge.
  const kits = $derived(play ? play.colors : null);
  const NONE = { fill: "var(--muted)", edge: "var(--muted)" };
  const kitOf = (role: "off" | "def") => kits?.[role] ?? NONE;
  const name = (id: number | null) => {
    const p = id == null ? null : who.get(id);
    return p ? `#${p.jersey} ${p.last}` : "–";
  };
  const isOff = (id: number) => who.get(id)?.role === "off";
  const side = (id: number) => kitOf(isOff(id) ? "off" : "def");
  const pct = (v: number) => `${Math.round(v * 100)}%`;
  const signed = (v: number) => `${v >= 0 ? "+" : "−"}${Math.abs(v * 100).toFixed(1)}`;
  const OUTCOME: Record<string, string> = {
    "off player": "Offensive rebound", "def player": "Defensive rebound",
    "off team award": "Offense awarded the ball", "def team award": "Defense awarded the ball",
  };
  const views: { value: LandingView; label: string; title: string }[] = [
    { value: "heat", label: "Heatmap", title: "Density of where the ball would first hit the floor if nobody touched it" },
    { value: "dots", label: "Dots", title: "Forty of the simulated miss paths' first floor landings" },
    { value: "off", label: "Off", title: "Hide the landing forecast" },
  ];

  const split = $derived(r ? sides(r.step) : null);
  const probs = $derived(r ? (live.reboundTalent && r.step.pt ? r.step.pt : r.step.p) : []);
  const top = $derived(r ? r.step.pid.map((id, i) => ({ id, p: probs[i] })).sort((a, b) => b.p - a.p).slice(0, 5) : []);
  const boxes = $derived(r ? [...r.step.box].filter((b) => b.s >= 0.2).sort((a, b) => b.s - a.s).slice(0, 4) : []);
  const label = (b: number, o: number) => r?.episode.pairs.find((p) => p.b === b && p.o === o)?.label ?? "";
  const movers = $derived(r ? r.episode.anticipation.filter((a) => a.exposure >= 0.005).sort((a, b) => Math.abs(b.gain) - Math.abs(a.gain)).slice(0, 4) : []);
</script>

<div class="panel display rebound-panel">
  <div class="panel-head">
    <h2>Rebounding</h2>
    <label class="switch" title="Draw the forecast on the court: landing forecast, box-out links and collection chances">
      <input type="checkbox" role="switch" bind:checked={viewer.showRebound} />
      <span class="switch-track"></span>On court
    </label>
  </div>
  <div class="mode-picks" class:dim={!viewer.showRebound} role="radiogroup" aria-label="Landing forecast">
    {#each views as v (v.value)}
      <button type="button" class="text-btn" class:on={viewer.reboundLanding === v.value} title={v.title} role="radio"
              aria-checked={viewer.reboundLanding === v.value} onclick={() => (viewer.reboundLanding = v.value)}>{v.label}</button>
    {/each}
  </div>
  {#if r && split && play}
    <p class="rb-when" title="Each forecast uses only the tracking up to its moment; a new one is made every 0.2 s until the rebound">
      Forecast made {r.since.toFixed(1)} s after release · {r.episode.range} · {r.episode.kind}
    </p>
    <div class="rb-sides">
      <div><span><i class="sw" style:background={kitOf("off").fill} style:border-color={kitOf("off").edge}></i>{play.off}</span><b>{pct(split.off)}</b></div>
      <div><span><i class="sw" style:background={kitOf("def").fill} style:border-color={kitOf("def").edge}></i>{play.def}</span><b>{pct(split.def)}</b></div>
    </div>
    <div class="rb-bar" role="img" aria-label={`${play.off} ${pct(split.off)}, ${play.def} ${pct(split.def)}`}>
      <i style:flex-grow={r.step.team[0]} style:background={kitOf("off").fill} style:--edge={kitOf("off").edge} title={`${play.off}, a player collects: ${pct(r.step.team[0])}`}></i>
      <i class="award" style:flex-grow={r.step.team[2]} style:background={kitOf("off").fill} style:--edge={kitOf("off").edge} title={`${play.off}, awarded the ball: ${pct(r.step.team[2])}`}></i>
      <i style:flex-grow={split.unresolved} style:background="var(--line)" title={`Still loose after 3.2 s: ${pct(split.unresolved)}`}></i>
      <i class="award" style:flex-grow={r.step.team[3]} style:background={kitOf("def").fill} style:--edge={kitOf("def").edge} title={`${play.def}, awarded the ball: ${pct(r.step.team[3])}`}></i>
      <i style:flex-grow={r.step.team[1]} style:background={kitOf("def").fill} style:--edge={kitOf("def").edge} title={`${play.def}, a player collects: ${pct(r.step.team[1])}`}></i>
    </div>
    <p class="rb-key">
      Solid: a player <b>collects</b> it ({pct(r.step.team[0])} / {pct(r.step.team[1])}). Striped: nobody secures it and the
      team is <b>awarded</b> the ball, usually out of bounds ({pct(r.step.team[2])} / {pct(r.step.team[3])}).
      {pct(r.step.out ?? 0)} of simulated misses would first land out of bounds.
    </p>
    <h3 class="rb-sub">Most likely to collect</h3>
    <ul class="rb-list">
      {#each top as t (t.id)}
        <li class:won={r.resolved && r.episode.rebounder === t.id}>
          <i class="dot" style:background={side(t.id).fill} style:border-color={side(t.id).edge}></i>
          <span class="nm">{name(t.id)}</span>
          <span class="meter"><i style:width={pct(Math.min(1, t.p / Math.max(0.01, top[0].p)))} style:background={side(t.id).fill} style:--edge={side(t.id).edge}></i></span>
          <b>{pct(t.p)}</b>
        </li>
      {/each}
    </ul>
    {#if boxes.length}
      <h3 class="rb-sub" title="A player standing between an opponent and where the ball can be reached. Spatial only: no video or body orientation.">Box-outs now <span class="rb-hint">blocker on opponent, strength</span></h3>
      <ul class="rb-list">
        {#each boxes as b (`${b.b}-${b.o}`)}
          <li>
            <i class="dot" style:background={side(b.b).fill} style:border-color={side(b.b).edge}></i>
            <span class="nm">{name(b.b)} <em>on</em> {name(b.o)}</span>
            <span class="tag">{label(b.b, b.o)}</span>
            <b>{pct(b.s)}</b>
          </li>
        {/each}
      </ul>
    {/if}
    {#if movers.length}
      <h3 class="rb-sub" title="His collection chance at where he actually was 0.48 s after release, minus its average over 16 moves typical of his role">First 0.48 s of movement <span class="rb-hint">points vs typical moves</span></h3>
      <ul class="rb-list">
        {#each movers as a (a.pid)}
          <li>
            <i class="dot" style:background={side(a.pid).fill} style:border-color={side(a.pid).edge}></i>
            <span class="nm">{name(a.pid)}</span>
            <span class="tag">{a.moved.toFixed(0)} ft</span>
            <b class:up={a.gain > 0} class:down={a.gain < 0}>{signed(a.gain)}</b>
          </li>
        {/each}
      </ul>
    {/if}
    {#if r.resolved}
      <p class="rb-outcome">{OUTCOME[r.episode.outcome] ?? r.episode.outcome}{r.episode.rebounder != null ? `: ${name(r.episode.rebounder)}` : ""}</p>
    {/if}
    <p class="note">
      Assumes the miss. Violet: where the ball would first land if nobody touched it (a model illustration, not validated).
      Lines: a player blocking an opponent's route to the ball. {live.reboundTalent ? "Chances include collection effects." : "Same rules for every player: no player effects passed their test."}
      <a href="#/rebounding">How it works</a>
    </p>
  {:else if live.reboundEpisodes.length && play}
    <ul class="rb-list misses">
      {#each live.reboundEpisodes as e (e.id)}
        {@const s0 = sides(e.steps[0])}
        <li>
          <span class="nm">Miss by {name(e.shooter)}</span>
          <span class="tag">{play.off} {pct(s0.off)} at release</span>
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
  .rb-when { margin: 0 0 8px; color: var(--muted); font-size: 12px; }
  .rb-sides { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); margin-bottom: 6px; border-radius: 8px; background: #0F1522; }
  .rb-sides div { display: grid; justify-items: center; gap: 2px; padding: 6px 4px 7px; min-width: 0; }
  .rb-sides span { display: flex; align-items: center; gap: 5px; max-width: 100%; color: var(--muted); font-size: 11px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .rb-sides b { font-size: 18px; font-variant-numeric: tabular-nums; }
  .sw { width: 10px; height: 10px; flex: none; border: 2px solid; border-radius: 3px; }
  .rb-bar { display: flex; gap: 2px; height: 10px; margin: 0 0 6px; overflow: hidden; border-radius: 4px; }
  .rb-bar i { flex-basis: 0; min-width: 0; box-shadow: inset 0 0 0 1.5px var(--edge); }
  .rb-bar i:first-child { border-radius: 4px 0 0 4px; }
  .rb-bar i:last-child { border-radius: 0 4px 4px 0; }
  .rb-bar .award { background-image: repeating-linear-gradient(135deg, rgba(15, 21, 34, .55) 0 2px, transparent 2px 5px); }
  .rb-key { margin: 0 0 4px; color: var(--muted); font-size: 11.5px; line-height: 1.45; }
  .rb-key b { color: var(--ink); font-weight: 600; }
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
  .dot { width: 10px; height: 10px; border: 2px solid; border-radius: 50%; }
  .meter { position: relative; width: 56px; height: 6px; border-radius: 3px; background: var(--raised); }
  .meter i { position: absolute; inset: 0 auto 0 0; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--edge); }
  .up { color: var(--made); }
  .down { color: var(--missed); }
  .rb-outcome { margin-top: 8px; font-weight: 600; }
  .note a { color: var(--off); }
</style>
