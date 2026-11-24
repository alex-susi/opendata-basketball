<script lang="ts">
  // The hover card for one or more actions on a timeline (the trace panel's, or the narrow strip shown when the
  // trace panel is off). Actions within a few pixels of each other share the card, a section each. Fixed to the
  // window, so a scrolling panel never clips it; a card with details opens upward, over the court. Each section opens
  // with the action alone in bold ("Pick"), then one row per player named by his part in it (Screener, Ballhandler,
  // Driver, Defender…), then the action's details in groups, each under a subheader (lib/context.ts).
  //   x     the pointer's tick line, window px (the card centres on it, kept inside the window)
  //   y     the top of the timeline, window px
  import { toPage } from "../lib/fit.svelte";
  import { closeoutLines, cutLines, driveLines, nameOf, reboundLines, screenLines, shotCard, titleCase, type Line } from "../lib/context";
  import { clamp } from "../lib/geometry";
  import { foulLines, turnoverLines } from "../lib/whistles";
  import { FPS, type Tick } from "../lib/sequence";
  import type { Play } from "../lib/types";
  import { season, viewer } from "../lib/viewer.svelte";

  let { play, ticks, x, y, up = false }: { play: Play; ticks: Tick[]; x: number; y: number; up?: boolean } = $props();

  // The players in an action, each named by his part in it. Where the action has no annotation row to name them
  // from (a free throw, say), the player as the label gives him.
  const role = (k: string, pid: number | undefined): Line[] => (pid == null ? [] : [{ k, v: nameOf(play, pid) }]);
  const SCREEN_ROLES: Record<string, [string, string]> = {
    pick: ["Screener", "Ballhandler"], handoff: ["Setter", "Receiver"], off_ball_screen: ["Screener", "Cutter"],
  };
  // Rows the detail lines already carry for a foul, a turnover or a rebound (its shooter): shown with the players
  // instead, above the card's subheaders (as the shot card's Shooter row). A drive's or cut's defender stays in its
  // Defense group.
  const PLAYER_KEYS = new Set(["Fouler", "Fouled", "Lost By", "Stolen By", "Shooter"]);
  function rolesFor(tick: Tick): Line[] {
    const ev = tick.event, ann = play.ann;
    const fallback = (): Line[] => {
      const rest = ev.label.split(": ").slice(1).join(": ").replace(/ ([^)]*)$/, "");
      return rest ? [{ k: "Player", v: rest }] : [];
    };
    if (!ann) return fallback();
    if (ev.kind in SCREEN_ROLES) {
      const sc = ann.screens.find((r) => r.f === ev.f && r.kind === ev.kind);
      const [a, b] = SCREEN_ROLES[ev.kind];
      return sc ? [...role(a, sc.scr), ...role(b, sc.use)] : fallback();
    }
    if (ev.kind === "made" || ev.kind === "missed") {
      const shot = ann.shots.find((r) => r.f === ev.f);
      return shot ? role("Shooter", shot.pid) : fallback();
    }
    if (ev.kind === "drive") {
      const d = ann.drives.find((r) => r.f === ev.f);
      return d ? role("Driver", d.pid) : fallback();
    }
    if (ev.kind === "cut") {
      const c = ann.cuts?.find((r) => r.f === ev.f && play.players.find((p) => p.id === r.pid)?.last === ev.who);
      return c ? role("Cutter", c.pid) : fallback();
    }
    if (ev.kind === "closeout") {
      const c = ann.closeouts.find((r) => r.f === ev.f);
      return c ? [...role("Defender", c.def), ...role("Ballhandler", c.pid)] : fallback();
    }
    if (ev.kind === "post" || ev.kind === "isolation") {
      const solo = ann.solos?.find((r) => r.f === ev.f && r.kind === ev.kind);
      return solo ? [...role("Ballhandler", solo.pid), ...role("Defender", solo.def)] : fallback();
    }
    if (ev.kind === "rebound") {
      const r = ann.rebounds.find((x) => x.f === ev.f);
      return r?.pid != null ? role("Rebounder", r.pid) : fallback();
    }
    if (ev.kind === "foul" || ev.kind === "turnover") return [];   // from the detail lines (PLAYER_KEYS)
    return fallback();
  }

  // More about a hovered action: lines from the annotations that are switched on. (The points-per-action tables of
  // lib/player.ts, actionTable, were taken off the card 2026-11-16 to keep it narrow.)
  function linesFor(tick: Tick): { lines: Line[] } {
    const ev = tick.event, ann = play.ann, none = { lines: [] };
    if (!ann) return none;
    // The shot card shows here on hover, the only place it appears (the card over the court was removed 2026-11-19).
    if (ev.kind === "made" || ev.kind === "missed") {
      const shot = ann.shots.find((s) => s.f === ev.f);
      return shot ? { lines: shotCard(play, shot, { peak: viewer.ann.tracking, season: season.data, xpts: season.sample?.league.xpts }).lines } : none;
    }
    if (ev.kind === "drive") {
      const d = ann.drives.find((r) => r.f === ev.f);
      return d ? { lines: driveLines(play, d) } : none;
    }
    if (ev.kind === "closeout") {
      const c = ann.closeouts.find((r) => r.f === ev.f);
      return c ? { lines: closeoutLines(play, c) } : none;
    }
    if (ev.kind === "foul") {
      const fo = ann.fouls.find((r) => r.f === ev.f);
      return fo ? { lines: foulLines(play, fo) } : none;
    }
    if (ev.kind === "turnover") {
      const t = ann.turnovers.find((r) => r.f === ev.f);
      return t ? { lines: turnoverLines(play, t) } : none;
    }
    if (ev.kind === "cut") {
      const c = ann.cuts?.find((r) => r.f === ev.f && play.players.find((p) => p.id === r.pid)?.last === ev.who);
      return c ? { lines: cutLines(play, c) } : none;
    }
    if (ev.kind === "post" || ev.kind === "isolation") {
      return none;
    }
    if (ev.kind === "rebound") {
      const r = ann.rebounds.find((x) => x.f === ev.f);
      return r ? { lines: reboundLines(play, r) } : none;
    }
    const screen = ann.screens.find((r) => r.f === ev.f && r.kind === ev.kind);
    // Coverage shows here whether or not Defensive Context (the court drawing's toggle) is on, once the screen's recorded
    // coverage may be seen (Predict mode hides a pick's until it is revealed, lib/coverageView.svelte.ts).
    return screen ? { lines: screenLines(play, screen, true) } : none;
  }
  // A tall card (three groups or more and at least TALL rows) puts its groups in two columns, so it is shorter and wider.
  // The groups keep their order (the left column's top to bottom, then the right's), split where the two columns come
  // closest in height. Both columns start and end level: the spare height goes between a column's groups, or between
  // the rows of a column that holds one group (app.css, .tc-cols).
  const TALL = 12;
  interface Group { head: Line | null; rows: Line[] }
  function groupsOf(lines: Line[]): Group[] {
    const out: Group[] = [];
    for (const l of lines) {
      if (l.head) out.push({ head: l, rows: [] });
      else if (out.length) out[out.length - 1].rows.push(l);
      else out.push({ head: null, rows: [l] });
    }
    return out;
  }
  // A group's height in rows: a subheader is about 1.5 rows with its margins.
  const height = (gs: Group[]) => gs.reduce((s, g) => s + g.rows.length + (g.head ? 1.5 : 0), 0);
  function columns(lines: Line[], extra: number): { top: Group[]; cols: Group[][] | null } {
    const all = groupsOf(lines);
    const top = all.length && !all[0].head ? [all[0]] : [];   // rows before the first subheader stay full width
    const gs = all.slice(top.length);
    if (gs.length < 3 || height(all) + extra < TALL) return { top, cols: null };
    let best = 1;
    for (let k = 2; k < gs.length; k++) {
      if (Math.abs(height(gs.slice(0, k)) - height(gs.slice(k))) < Math.abs(height(gs.slice(0, best)) - height(gs.slice(best)))) best = k;
    }
    return { top, cols: [gs.slice(0, best), gs.slice(best)] };
  }
  const cards = $derived(ticks.map((tick) => {
    const { lines } = linesFor(tick);
    const moved = lines.filter((l) => !l.head && PLAYER_KEYS.has(l.k));
    const roles = [...rolesFor(tick), ...moved];
    const rest = lines.filter((l) => !moved.includes(l));
    return { tick, roles, lines: rest, ...columns(rest, roles.length + 1) };
  }));
  const rises = $derived(up || cards.length > 1 || cards.some((c) => c.lines.length > 0 || c.roles.length > 0));
  // The action alone: the label before its players ("Pick", "Made 2", "Shooting Foul"), without a shot type.
  const title = (tick: Tick) => titleCase(tick.event.label.split(": ")[0].replace(/ \([^)]*\)$/, ""));
  let w = $state(260);
</script>

{#if cards.length}
  <div class="trace-card" class:up={rises} bind:clientWidth={w}
       style:left="{clamp(x - w / 2, 4, Math.max(4, toPage(window.innerWidth) - w - 4))}px" style:top="{y + 6}px">
    {#each cards as card, n (n)}
      <span class="trace-card-head" class:next={n > 0}><b class={card.tick.event.kind}>{title(card.tick)}{#if card.tick.event.flag}<i class="event-flag">{card.tick.event.flag === "BLK" ? "Blocked" : "Steal"}</i>{/if}</b><span class="trace-card-time">{(card.tick.k / FPS).toFixed(1)} s</span></span>
      {#each card.roles as line}<span class="card-line"><span>{line.k}</span><span>{line.v}</span></span>{/each}
      {#if card.cols}
        {#each card.top as g}{@render group(g)}{/each}
        <div class="tc-cols">
          {#each card.cols as col, c (c)}
            <div class="tc-col" class:one={col.length === 1}>{#each col as g}<div class="tc-group">{#if g.head}{@render row(g.head)}{/if}<div class="tc-rows">{#each g.rows as line}{@render row(line)}{/each}</div></div>{/each}</div>
          {/each}
        </div>
      {:else}
        {#each card.lines as line}{@render row(line)}{/each}
      {/if}
    {/each}
  </div>
{/if}

{#snippet group(g: Group)}
  {#if g.head}{@render row(g.head)}{/if}
  {#each g.rows as line}{@render row(line)}{/each}
{/snippet}

{#snippet row(line: Line)}
  {#if line.head}<span class="card-head">{line.k}</span>{:else}<span class="card-line"><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>{/if}
{/snippet}
