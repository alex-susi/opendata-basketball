<script lang="ts">
  // The hover card for one or more actions on a timeline (the trace panel's, or the narrow strip shown when the
  // trace panel is off). Actions within a few pixels of each other share the card, a section each. Fixed to the
  // window, so a scrolling panel never clips it; a card with details opens upward, over the court. Each section opens
  // with the action alone in bold ("Pick"), then one row per player named by his part in it (Screener, Ballhandler,
  // Driver, Defender…), then the action's details.
  //   x     the pointer's tick line, window px (the card centres on it, kept inside the window)
  //   y     the top of the timeline, window px
  import { toPage } from "../lib/fit.svelte";
  import { closeoutLines, coverageText, cutLines, driveLines, nameOf, shotCard, titleCase, type Line } from "../lib/context";
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
  // Rows the detail lines already carry for a foul or a turnover: shown with the players instead.
  const PLAYER_KEYS = new Set(["Fouler", "Fouled", "Lost By", "Stolen By"]);
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
    if ((ev.kind === "made" || ev.kind === "missed") && viewer.ann.shot) {
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
    const screen = ann.screens.find((r) => r.f === ev.f && r.kind === ev.kind);
    if (!screen) return none;
    const lines: Line[] = [];
    const cov = coverageText(screen);
    if (viewer.ann.defense && cov) lines.push({ k: "Coverage", v: cov });
    return { lines };
  }
  const cards = $derived(ticks.map((tick) => {
    const { lines } = linesFor(tick);
    const moved = lines.filter((l) => !l.head && PLAYER_KEYS.has(l.k));
    return { tick, roles: [...rolesFor(tick), ...moved], lines: lines.filter((l) => !moved.includes(l)) };
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
      {#each card.lines as line}
        {#if line.head}<span class="card-head">{line.k}</span>{:else}<span class="card-line"><span>{line.k}</span><span style:color={line.tone}>{line.v}</span></span>{/if}
      {/each}
    {/each}
  </div>
{/if}
