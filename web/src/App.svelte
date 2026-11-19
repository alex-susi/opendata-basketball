<script lang="ts">
  // The tab bar: Play viewer, a Screen Coverage menu (EDA: the "coverage" exploration tab; Model: the live model's readme),
  // then an EDA menu (hover to open) holding Archetypes and Court Control at the top, then Rebounding and the other seven
  // exploration tabs (one per candidate topic, components/explore/). The play viewer: filters and play list on the left (drag its edge to widen or narrow it), the
  // play's header over the court and the trace panel (the play's timeline) in the middle; on the right, the playback
  // controls beside the header, then display options and the rosters level with the court. The Screen Coverage Model
  // tab is the live screen-coverage model's readme (screen_coverage/04_docs, shown in a frame). The Archetypes tab
  // explains the tags beside each player's name; the Rebounding tab is a descriptive look at the ten games' missed
  // shots. Static counterpart of play_viewer/01_app/app.R.
  import { toPage } from "./lib/fit.svelte";
  import { untrack } from "svelte";
  import AppearanceMenus from "./components/AppearanceMenus.svelte";
  import Archetypes from "./components/Archetypes.svelte";
  import DocFrame from "./components/DocFrame.svelte";
  import ThemeSwitch from "./components/ThemeSwitch.svelte";
  import Controls from "./components/Controls.svelte";
  import Rebounding from "./components/Rebounding.svelte";
  import Explore from "./components/explore/Explore.svelte";
  import Filters from "./components/Filters.svelte";
  import PlayList from "./components/PlayList.svelte";
  import SidePanel from "./components/SidePanel.svelte";
  import Stage from "./components/Stage.svelte";
  import TracePanel from "./components/TracePanel.svelte";
  import TimelineStrip from "./components/TimelineStrip.svelte";
  import { loadMeta, loadPlay, loadPlays, loadPlaystyle, loadSample, loadSeason } from "./lib/data";
  import { loadLogos, logoUrl } from "./lib/logos.svelte";
  import { teamAbbr } from "./lib/teams";
  import { emptyFilters, filterPlays } from "./lib/filters";
  import { clamp } from "./lib/geometry";
  import { buildSeq, cursorAt, seqIndexOfFrame } from "./lib/sequence";
  import type { Meta, Play, PlayRow } from "./lib/types";
  import { live, season, viewer } from "./lib/viewer.svelte";

  const ROUTE = "#/play/";
  const COVERAGE_MODEL = "#/coverage-model";
  const COURT_CONTROL = "#/court-control";
  const ARCHETYPES = "#/archetypes";
  const REBOUNDING = "#/rebounding";
  const EXPLORE = "#/explore/";
  // The exploration tabs, one per candidate topic (web/scripts/explore/<id>.R writes explore_<id>.json). Pick coverage
  // sits in the Screen Coverage menu (PICK_TOPIC); the rest sit in the EDA menu.
  const TOPICS = [
    { id: "paint", label: "Paint touches" }, { id: "chains", label: "Pre-shot actions" }, { id: "closeouts", label: "Closeouts" },
    { id: "crash", label: "Crashing" }, { id: "lanes", label: "Driving lanes" }, { id: "advantage", label: "Advantage" },
    { id: "gravity", label: "Gravity" }, { id: "coverage", label: "Pick coverage" },
  ];
  const PICK_TOPIC = "x-coverage";
  // The Screen Coverage menu: the EDA tab and the model's readme.
  const SCREEN = [{ id: PICK_TOPIC, label: "EDA" }, { id: "coverage-model", label: "Model" }];
  // The EDA menu: Archetypes and Court Control, Rebounding, then the exploration tabs other than pick coverage.
  const EDA = [{ id: "archetypes", label: "Archetypes" }, { id: "court-control", label: "Court Control" }, { id: "rebounding", label: "Rebounding" },
               ...TOPICS.filter((t) => `x-${t.id}` !== PICK_TOPIC).map((t) => ({ id: `x-${t.id}`, label: t.label }))];
  type Tab = string;   // "viewer", "coverage-model", "archetypes", "court-control", "rebounding" or "x-<topic>"
  const tabOfHash = (h: string): Tab => {
    if (h === COVERAGE_MODEL) return "coverage-model";
    if (h === COURT_CONTROL) return "court-control";
    if (h === ARCHETYPES) return "archetypes";
    if (h === REBOUNDING) return "rebounding";
    if (h.startsWith(EXPLORE) && TOPICS.some((t) => t.id === h.slice(EXPLORE.length))) return `x-${h.slice(EXPLORE.length)}`;
    return "viewer";
  };

  let meta = $state.raw<Meta | null>(null);
  let plays = $state.raw<PlayRow[]>([]);
  let play = $state.raw<Play | null>(null);
  let selectedId = $state<string | null>(null);
  let filters = $state(emptyFilters());
  let problem = $state("");
  const first = tabOfHash(location.hash);
  let tab = $state<Tab>(first);
  // Each document tab is fetched the first time it is shown.
  let opened = $state<Record<string, boolean>>({ [first]: true });
  let edaOpen = $state(false);
  const edaTab = $derived(EDA.find((t) => t.id === tab) ?? null);
  let screenOpen = $state(false);
  const screenTab = $derived(SCREEN.find((t) => t.id === tab) ?? null);
  viewer.hidden = first !== "viewer";

  // Width of the left column (filters and play list), in px. Remembered in this browser only.
  const LEFT_MIN = 210, LEFT_MAX = 560, LEFT_DEFAULT = 250, LEFT_WIDE = 400, WIDTH_KEY = "acb-viewer-left-width";
  let leftW = $state(LEFT_DEFAULT);
  try {
    const saved = Number(localStorage.getItem(WIDTH_KEY));
    if (saved >= LEFT_MIN && saved <= LEFT_MAX) leftW = saved;
  } catch { /* storage unavailable: keep the default */ }
  function setLeft(w: number): void {
    leftW = Math.round(clamp(w, LEFT_MIN, LEFT_MAX));
    try { localStorage.setItem(WIDTH_KEY, String(leftW)); } catch { /* not remembered */ }
  }
  let leftEl: HTMLElement;
  function dragLeft(ev: PointerEvent): void {
    const handle = ev.currentTarget as HTMLElement;
    if (handle.hasPointerCapture(ev.pointerId)) setLeft(toPage(ev.clientX - leftEl.getBoundingClientRect().left));
  }
  function keyLeft(ev: KeyboardEvent): void {
    if (ev.key === "ArrowLeft" || ev.key === "ArrowRight") {
      ev.preventDefault();
      setLeft(leftW + (ev.key === "ArrowRight" ? 20 : -20));
    }
  }

  const rows = $derived(filterPlays(plays, filters));
  const seq = $derived(play ? buildSeq(play, viewer.skipDead) : []);
  const homeIsOff = $derived(play ? play.off === play.home : true);
  const home = $derived(play ? (homeIsOff ? play.colors.off : play.colors.def) : null);
  const away = $derived(play ? (homeIsOff ? play.colors.def : play.colors.off) : null);
  const homeLogo = $derived(play ? logoUrl(play.homeTeam) : null);
  // How far the court's centre line sits from the middle of the header (the stage and the header share a column).
  let headW = $state(0);
  const courtShift = $derived(live.box && headW ? Math.round(live.box.left + live.box.w / 2 - headW / 2) : 0);
  // Each team box of the score bar is as wide as makes the clock box end level with the court's right sideline end
  // (the floor's right edge): from the centre line, one team box and the clock box (never under 166 px, what the names and scores need; a narrow window gives up the alignment).
  // Capped at BUG_TEAM_MAX so the bar stays a scorebug on a wide screen (it then ends short of the sideline).
  const BUG_TEAM_MAX = 240;
  let bugClockW = $state(96);
  const bugTeamW = $derived(live.box ? Math.min(BUG_TEAM_MAX, Math.max(166, Math.round(live.box.floorRight - (live.box.left + live.box.w / 2) - bugClockW))) : null);
  // A team's three-letter name on the scorebug (lib/teams.ts; its full name is the box's tooltip).
  // The quarter as a broadcast shows it: 1st, 2nd, 3rd, 4th, then OT, 2OT…
  const periodName = (p: number) => (p <= 4 ? `${p}${["st", "nd", "rd", "th"][p - 1]}` : p === 5 ? "OT" : `${p - 4}OT`);
  const awayLogo = $derived(play ? logoUrl(play.homeTeam === play.offTeam ? play.defTeam : play.offTeam) : null);
  loadLogos();
  const note = $derived(problem || (!meta ? "Loading plays…" : !rows.length ? "No possessions match these filters." : ""));

  // The address names the selected play, or the document tab while one is open.
  function address(): string {
    if (tab === "coverage-model") return COVERAGE_MODEL;
    if (tab === "court-control") return COURT_CONTROL;
    if (tab === "archetypes") return ARCHETYPES;
    if (tab === "rebounding") return REBOUNDING;
    if (tab.startsWith("x-")) return EXPLORE + tab.slice(2);
    return selectedId ? ROUTE + selectedId : location.pathname + location.search;
  }

  function show(next: Tab): void {
    tab = next;
    viewer.hidden = next !== "viewer";
    if (next !== "viewer") {
      opened[next] = true;
      viewer.playing = false;
    }
    history.replaceState(null, "", address());
  }

  function select(id: string | null): void {
    selectedId = id;
    history.replaceState(null, "", address());
    const row = plays.find((r) => r.id === id);
    if (!row) {
      play = null;
      viewer.playing = false;
      viewer.recording = false;
      return;
    }
    loadPlay(row).then((loaded) => {
      if (selectedId !== id) return;   // a newer selection overtook this one
      play = loaded;
      viewer.pos = 0;
      viewer.playing = !viewer.hidden;
      viewer.recording = false;
      problem = "";
    }).catch((err: Error) => { problem = err.message; });
  }

  // Autoplay Next: at the end of a play, the next one in the filtered list (it starts playing when it loads); after
  // the last one, stop.
  function playNext(): void {
    const at = rows.findIndex((r) => r.id === selectedId);
    if (at >= 0 && at + 1 < rows.length) select(rows[at + 1].id);
    else viewer.playing = false;
  }

  // Keep the current frame on screen when dead-ball frames are added to or removed from the sequence.
  function setSkip(skip: boolean): void {
    const frame = play ? play.frames[cursorAt(play, seq, viewer.pos).i0] : 0;
    viewer.skipDead = skip;
    if (play) viewer.pos = seqIndexOfFrame(play, buildSeq(play, skip), frame);
  }

  // Like the Shiny app: when the filtered list no longer holds the selected play, show its first play.
  $effect(() => {
    const list = rows;
    untrack(() => {
      if (!meta) return;
      if (!list.length) select(null);
      else if (!list.some((r) => r.id === selectedId)) select(list[0].id);
    });
  });

  // A shared link names its play in the address (#/play/<id>). Open it, clearing filters that would hide it.
  function openLinked(): void {
    const target = tabOfHash(location.hash);
    if (target !== "viewer") return show(target);
    if (tab !== "viewer") show("viewer");
    const linked = location.hash.startsWith(ROUTE) ? decodeURIComponent(location.hash.slice(ROUTE.length)) : null;
    if (!linked || linked === selectedId || !plays.some((r) => r.id === linked)) return;
    if (!rows.some((r) => r.id === linked)) filters = emptyFilters();
    select(linked);
  }

  // Season figures (roster hover cards, the shot card's zone line, pick hovers) load once, in the background.
  loadSeason().then((d) => { season.data = d; }).catch(() => { /* the season lines are left out */ });
  loadSample().then((d) => { season.sample = d; }).catch(() => { /* the tracked-games lines are left out */ });
  loadPlaystyle().then((d) => { season.style = d; }).catch(() => { /* the Playstyle view is left empty */ });

  Promise.all([loadMeta(), loadPlays()]).then(([m, all]) => {
    plays = all;
    openLinked();
    meta = m;
  }).catch((err: Error) => { problem = err.message; });
</script>

<svelte:window onhashchange={openLinked} />

<!-- --left-w here too: on wide windows the first tab starts level with the court's left edge (app.css, .tabs-lead). -->
<nav class="tabs" style:--left-w="{leftW}px">
  <span class="tabs-lead">
    <span class="brand">PySport Analytics Cup</span>
    <span class="tabs-theme"><ThemeSwitch /></span>
  </span>
  <button type="button" class:on={tab === "viewer"} onclick={() => show("viewer")}>Play viewer</button>
  <!-- Screen Coverage: the EDA tab and the live model's readme, in a menu like EDA's. -->
  <div class="tab-menu" class:open={screenOpen} role="presentation" onmouseleave={() => { screenOpen = false; }}>
    <button type="button" class="tab-menu-btn" class:on={screenTab != null} aria-haspopup="true" aria-expanded={screenOpen}
            onclick={() => { screenOpen = !screenOpen; }}>Screen Coverage{#if screenTab} · {screenTab.label}{/if} <span class="tab-caret" aria-hidden="true">▾</span></button>
    <div class="tab-menu-list" role="menu">
      {#each SCREEN as t (t.id)}
        <button type="button" role="menuitem" class:on={tab === t.id} onclick={(ev) => { show(t.id); screenOpen = false; (ev.currentTarget as HTMLElement).blur(); }}>{t.label}</button>
      {/each}
    </div>
  </div>
  <!-- EDA: the descriptive tabs, in a menu that opens on hover (or keyboard focus, or a click on touch screens). -->
  <div class="tab-menu" class:open={edaOpen} role="presentation" onmouseleave={() => { edaOpen = false; }}>
    <button type="button" class="tab-menu-btn" class:on={edaTab != null} aria-haspopup="true" aria-expanded={edaOpen}
            onclick={() => { edaOpen = !edaOpen; }}>EDA{#if edaTab} · {edaTab.label}{/if} <span class="tab-caret" aria-hidden="true">▾</span></button>
    <div class="tab-menu-list" role="menu">
      {#each EDA as t (t.id)}
        <button type="button" role="menuitem" class:on={tab === t.id} onclick={(ev) => { show(t.id); edaOpen = false; (ev.currentTarget as HTMLElement).blur(); }}>{t.label}</button>
      {/each}
    </div>
  </div>
  <!-- Font and Colors: trial typefaces and colour schemes for the whole site (AppearanceMenus.svelte). -->
  <AppearanceMenus />
  <span class="credit">Data: Liga Endesa ACB 2025/2026 via SkillCorner</span>
</nav>

<div class="app" hidden={tab !== "viewer"} style:--left-w="{leftW}px">
  <aside class="left" bind:this={leftEl}>
    <!-- Narrow windows only (app.css): the column hides at the left edge and this tab shows it while hovered. -->
    <div class="left-tab" aria-hidden="true"><span>Filters · Possessions</span></div>
    {#if meta}
      <Filters {meta} bind:filters />
    {/if}
    <PlayList {rows} {selectedId} onselect={select} teamColors={meta?.teamColors} wide={leftW >= LEFT_WIDE}
              ontogglewidth={() => setLeft(leftW >= LEFT_WIDE ? LEFT_DEFAULT : LEFT_WIDE)} />
    <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
    <div class="left-resize" role="separator" aria-orientation="vertical" aria-label="Width of the filter and possession column"
         aria-valuenow={leftW} aria-valuemin={LEFT_MIN} aria-valuemax={LEFT_MAX} tabindex="0"
         title="Drag to widen or narrow (arrow keys work too); double-click to reset"
         onpointerdown={(ev) => { (ev.currentTarget as HTMLElement).setPointerCapture(ev.pointerId); ev.preventDefault(); }}
         onpointermove={dragLeft} ondblclick={() => setLeft(LEFT_DEFAULT)} onkeydown={keyLeft}></div>
  </aside>

  <!-- Above the court only, so the right column starts level with the court. A broadcast-style score bar: the join
       between the two team boxes sits on the court's centre line, the clock box follows the away team's box, and a
       basketball beside a team's name marks the team with the ball (app.css, .bug). -->
  <header class="play-head-box">
    <div class="play-head" style:--court-shift="{courtShift}px" bind:clientWidth={headW}>
      {#if play && home && away}
        <div class="bug" style:--team-w={bugTeamW != null ? `${bugTeamW}px` : null} title={`${play.game} · score at the start of the possession · ${play.off} have the ball`}>
          {#each [{ side: "home", kit: home, name: play.home, logo: homeLogo, score: play.homeScore, ball: homeIsOff },
                  { side: "away", kit: away, name: play.away, logo: awayLogo, score: play.awayScore, ball: !homeIsOff }] as t (t.side)}
            <span class="bug-team {t.side}" style:background-color={t.kit.fill} style:color={t.kit.ink} title={t.name}>
              <span class="bug-logo">{#if t.logo}<img src={t.logo} alt="" />{/if}</span>
              <span class="bug-abbr">{teamAbbr(t.name)}</span>
              {@render ball(t.ball)}
              <span class="bug-score">{t.score}</span>
            </span>
          {/each}
          <span class="bug-clock" bind:offsetWidth={bugClockW}>
            <span class="bug-time" title="Game clock">{live.gameClock}</span>
            <span class="bug-period-line"><span class="shot-clock" title="Shot clock">{live.shotClock}</span><span title="Quarter">{periodName(play.period)}</span></span>
          </span>
        </div>
      {:else}
        <h1 class="play-head-note">{meta ? "No play selected" : "Loading plays…"}</h1>
      {/if}
    </div>
  </header>

  {#snippet ball(on: boolean)}
    <svg class="poss-ball" class:on viewBox="0 0 20 20" aria-hidden={!on} role="img" aria-label="Has the ball">
      <circle cx="10" cy="10" r="8.6" fill="#E8742A" stroke="#1B1208" stroke-width="1.1" />
      <path d="M1.6 10h16.8M10 1.4v17.2M4.2 3.9c2.6 3.4 2.6 8.8 0 12.2M15.8 3.9c-2.6 3.4-2.6 8.8 0 12.2"
            fill="none" stroke="#1B1208" stroke-width="1.1" />
    </svg>
  {/snippet}

  <section class="viewer">
    <!-- At least tall enough for the cards over the court; the trace panel under it scrolls if that squeezes it. -->
    <div class="stage-row" style:min-height={live.annNeed ? `${Math.max(260, live.annNeed + 36)}px` : null}>
      <Stage {play} {seq} {note} onend={playNext} />
    </div>
    {#if viewer.showTrace}
      <TracePanel {play} {seq} />
    {:else}
      <TimelineStrip {play} {seq} />
    {/if}
  </section>

  <!-- Playback, beside the play's header and above the Display panel. -->
  <div class="controls-box">
    <Controls {play} {seq} />
  </div>

  <SidePanel {play} onskip={setSkip} />
</div>

<main class="doc doc-framed" hidden={tab !== "coverage-model"}>
  {#if opened["coverage-model"]}<DocFrame src="docs/screen_coverage_model.html" title="Screen Coverage Model" />{/if}
</main>

<main class="doc" hidden={tab !== "archetypes"}>
  {#if opened.archetypes}<Archetypes />{/if}
</main>

<main class="doc doc-framed" hidden={tab !== "court-control"}>
  {#if opened["court-control"]}<DocFrame src="docs/court_control.html" title="Court Control" />{/if}
</main>

<main class="doc" hidden={tab !== "rebounding"}>
  {#if opened.rebounding}<Rebounding />{/if}
</main>

{#each TOPICS as t (t.id)}
  <main class="doc" hidden={tab !== `x-${t.id}`}>
    {#if opened[`x-${t.id}`]}<Explore topic={t.id} />{/if}
  </main>
{/each}
