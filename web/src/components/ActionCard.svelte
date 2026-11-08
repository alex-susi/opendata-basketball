<script lang="ts">
  // The hover card for one or more actions on a timeline (the trace panel's, or the narrow strip shown when the
  // trace panel is off). Actions within a few pixels of each other share the card, a section each. Fixed to the
  // window, so a scrolling panel never clips it; a card with details opens upward, over the court.
  //   x     the pointer's tick line, window px (the card centres on it, kept inside the window)
  //   y     the top of the timeline, window px
  import StatTable from "./StatTable.svelte";
  import { closeoutLines, coverageText, cutLines, driveLines, shotCard, type Line } from "../lib/context";
  import { clamp } from "../lib/geometry";
  import { actionTable, type StatSection } from "../lib/player";
  import { foulLines, turnoverLines } from "../lib/whistles";
  import { FPS, type Tick } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { season, viewer } from "../lib/viewer.svelte";

  let { play, ticks, x, y, up = false }: { play: Play; ticks: Tick[]; x: number; y: number; up?: boolean } = $props();

  // More about a hovered action: lines from the annotations that are switched on, and for an action (screen,
  // drive, closeout, post-up, isolation) a table of points per action for its players (lib/player.ts).
  function linesFor(tick: Tick): { lines: Line[]; table: StatSection | null } {
    const ev = tick.event, ann = play.ann, none = { lines: [], table: null };
    if (!ann) return none;
    if ((ev.kind === "made" || ev.kind === "missed") && viewer.ann.shot) {
      const shot = ann.shots.find((s) => s.f === ev.f);
      return shot ? { lines: shotCard(play, shot, { peak: viewer.ann.tracking, season: season.data, xpts: season.sample?.league.xpts }).lines, table: null } : none;
    }
    if (ev.kind === "drive") {
      const d = ann.drives.find((r) => r.f === ev.f);
      return d ? { lines: driveLines(play, d), table: actionTable(play, season.data, season.sample, { kind: "drive", d }) } : none;
    }
    if (ev.kind === "closeout") {
      const c = ann.closeouts.find((r) => r.f === ev.f);
      return c ? { lines: closeoutLines(play, c), table: actionTable(play, season.data, season.sample, { kind: "closeout", c }) } : none;
    }
    if (ev.kind === "foul") {
      const fo = ann.fouls.find((r) => r.f === ev.f);
      return fo ? { lines: foulLines(play, fo), table: null } : none;
    }
    if (ev.kind === "turnover") {
      const t = ann.turnovers.find((r) => r.f === ev.f);
      return t ? { lines: turnoverLines(play, t), table: null } : none;
    }
    if (ev.kind === "cut") {
      const c = ann.cuts?.find((r) => r.f === ev.f && play.players.find((p) => p.id === r.pid)?.last === ev.who);
      return c ? { lines: cutLines(play, c), table: null } : none;
    }
    if (ev.kind === "post" || ev.kind === "isolation") {
      const solo = ann.solos?.find((r) => r.f === ev.f && r.kind === ev.kind);
      return solo ? { lines: [], table: actionTable(play, season.data, season.sample, { kind: "solo", s: solo }) } : none;
    }
    const screen = ann.screens.find((r) => r.f === ev.f && r.kind === ev.kind);
    if (!screen) return none;
    const lines: Line[] = [];
    const cov = coverageText(screen);
    if (viewer.ann.defense && cov) lines.push({ k: "Coverage", v: cov });
    return { lines, table: actionTable(play, season.data, season.sample, { kind: "screen", s: screen }) };
  }
  const cards = $derived(ticks.map((tick) => ({ tick, ...linesFor(tick) })));
  const rises = $derived(up || cards.length > 1 || cards.some((c) => c.lines.length > 0 || c.table));
  // A field goal's label without its shot type (the card's Type line has it).
  const title = (tick: Tick) =>
    tick.event.kind === "made" || tick.event.kind === "missed" ? tick.event.label.replace(/ \([^)]*\)$/, "") : tick.event.label;
  let w = $state(260);
</script>

{#if cards.length}
  <div class="trace-card" class:up={rises} bind:clientWidth={w}
       style:left="{clamp(x - w / 2, 4, Math.max(4, window.innerWidth - w - 4))}px" style:top="{y + 6}px">
    {#each cards as card, n (n)}
      <span class="trace-card-head" class:next={n > 0}><b class={card.tick.event.kind}>{title(card.tick)}{#if card.tick.event.flag}<i class="event-flag">{card.tick.event.flag === "BLK" ? "Blocked" : "Steal"}</i>{/if}</b><span class="trace-card-time">{(card.tick.k / FPS).toFixed(1)} s</span></span>
      {#each card.lines as line}
        <span class="card-line"><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>
      {/each}
      {#if card.table}<StatTable sections={[card.table]} />{/if}
    {/each}
  </div>
{/if}
