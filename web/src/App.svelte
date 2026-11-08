<script lang="ts">
  // Three tabs. The play viewer: filters and play list on the left (drag its edge to widen or narrow it), the
  // play's header over the court and the trace panel (the play's timeline) in the middle; on the right, the playback
  // controls beside the header, then display options and the rosters level with the court. The Archetypes tab
  // explains the tags beside each player's name; the Rebounding tab is a descriptive look at the ten games' missed
  // shots. Static counterpart of src/play_viewer/app.R.
  import { untrack } from "svelte";
  import Archetypes from "./components/Archetypes.svelte";
  import Controls from "./components/Controls.svelte";
  import Rebounding from "./components/Rebounding.svelte";
  import Filters from "./components/Filters.svelte";
  import PlayList from "./components/PlayList.svelte";
  import SidePanel from "./components/SidePanel.svelte";
  import Stage from "./components/Stage.svelte";
  import TracePanel from "./components/TracePanel.svelte";
  import TimelineStrip from "./components/TimelineStrip.svelte";
  import { loadMeta, loadPlay, loadPlays, loadSample, loadSeason } from "./lib/data";
  import { loadLogos, logoUrl } from "./lib/logos.svelte";
  import { emptyFilters, filterPlays } from "./lib/filters";
  import { clamp, quarter } from "./lib/geometry";
  import { buildSeq, cursorAt, seqIndexOfFrame } from "./lib/sequence";
  import type { Meta, Play, PlayRow } from "./lib/types";
  import { live, season, viewer } from "./lib/viewer.svelte";

  const ROUTE = "#/play/";
  const ARCHETYPES = "#/archetypes";
  const REBOUNDING = "#/rebounding";
  type Tab = "viewer" | "archetypes" | "rebounding";
  const tabOfHash = (h: string): Tab => (h === ARCHETYPES ? "archetypes" : h === REBOUNDING ? "rebounding" : "viewer");

  let meta = $state.raw<Meta | null>(null);
  let plays = $state.raw<PlayRow[]>([]);
  let play = $state.raw<Play | null>(null);
  let selectedId = $state<string | null>(null);
  let filters = $state(emptyFilters());
  let problem = $state("");
  const first = tabOfHash(location.hash);
  let tab = $state<Tab>(first);
  // Each document tab is fetched the first time it is shown.
  let opened = $state({ archetypes: first === "archetypes", rebounding: first === "rebounding" });
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
    if (handle.hasPointerCapture(ev.pointerId)) setLeft(ev.clientX - leftEl.getBoundingClientRect().left);
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
  const awayLogo = $derived(play ? logoUrl(play.homeTeam === play.offTeam ? play.defTeam : play.offTeam) : null);
  loadLogos();
  const note = $derived(problem || (!meta ? "Loading plays…" : !rows.length ? "No possessions match these filters." : ""));

  // The address names the selected play, or the document tab while one is open.
  function address(): string {
    if (tab === "archetypes") return ARCHETYPES;
    if (tab === "rebounding") return REBOUNDING;
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

  Promise.all([loadMeta(), loadPlays()]).then(([m, all]) => {
    plays = all;
    openLinked();
    meta = m;
  }).catch((err: Error) => { problem = err.message; });
</script>

<svelte:window onhashchange={openLinked} />

<nav class="tabs">
  <span class="brand">PySport Analytics Cup</span>
  <button type="button" class:on={tab === "viewer"} onclick={() => show("viewer")}>Play viewer</button>
  <button type="button" class:on={tab === "archetypes"} onclick={() => show("archetypes")}>Archetypes</button>
  <button type="button" class:on={tab === "rebounding"} onclick={() => show("rebounding")}>Rebounding</button>
  <span class="credit">Data: Liga Endesa ACB 2025/2026 via SkillCorner</span>
</nav>

<div class="app" hidden={tab !== "viewer"} style:--left-w="{leftW}px">
  <aside class="left" bind:this={leftEl}>
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

  <!-- Above the court only, so the right column starts level with the court. The scorebug's score sits on the
       court's centre line; the running clocks to its right. A basketball outside the logo and a glow on the name mark
       the team with the ball. -->
  <header class="play-head-box">
    <div class="play-head" style:--court-shift="{courtShift}px" bind:clientWidth={headW}>
      {#if play && home && away}
        <div class="scorebug" title={`${play.game} · score at the start of the possession · ${play.off} have the ball`}>
          <span class="team home" class:has-ball={homeIsOff} style:color={home.text} style:--glow={home.text}>
            {@render ball(homeIsOff)}
            {#if homeLogo}<img class="logo" src={homeLogo} alt="" />{:else}<span class="kit" style:background={home.fill}></span>{/if}<span class="team-name">{play.home}</span>
          </span>
          <b>{play.homeScore} – {play.awayScore}</b>
          <span class="team away" class:has-ball={!homeIsOff} style:color={away.text} style:--glow={away.text}>
            <span class="team-name">{play.away}</span>{#if awayLogo}<img class="logo" src={awayLogo} alt="" />{:else}<span class="kit" style:background={away.fill}></span>{/if}
            {@render ball(!homeIsOff)}
          </span>
        </div>
        <!-- The game clock is centred on the gap between the quarter and the shot clock. -->
        <div class="game-clock">
          <span class="game-time" title="Game clock">{live.gameClock}</span>
          <span class="period-line"><span class="period">{quarter(play.period)}</span><span><span class="shot-clock" title="Shot clock">{live.shotClock}</span></span></span>
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

<main class="doc" hidden={tab !== "archetypes"}>
  {#if opened.archetypes}<Archetypes />{/if}
</main>

<main class="doc" hidden={tab !== "rebounding"}>
  {#if opened.rebounding}<Rebounding />{/if}
</main>
