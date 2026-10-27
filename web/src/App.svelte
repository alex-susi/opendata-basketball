<script lang="ts">
  // Three tabs. The play viewer: filters and play list on the left, court and transport in the middle,
  // display options, the rebounding forecast and rosters on the right. The Archetypes tab explains the tags beside
  // each player's name; the Rebounding tab documents the rebounding models, their validation and their limits.
  // Static counterpart of src/play_viewer/app.R.
  import { untrack } from "svelte";
  import Archetypes from "./components/Archetypes.svelte";
  import Rebounding from "./components/Rebounding.svelte";
  import Filters from "./components/Filters.svelte";
  import PlayList from "./components/PlayList.svelte";
  import ShotPanel from "./components/ShotPanel.svelte";
  import SidePanel from "./components/SidePanel.svelte";
  import Stage from "./components/Stage.svelte";
  import Transport from "./components/Transport.svelte";
  import { loadMeta, loadPlay, loadPlays } from "./lib/data";
  import { emptyFilters, filterPlays } from "./lib/filters";
  import { quarter } from "./lib/geometry";
  import { buildSeq, cursorAt, seqIndexOfFrame } from "./lib/sequence";
  import type { Meta, Play, PlayRow } from "./lib/types";
  import { live, viewer } from "./lib/viewer.svelte";

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

  const rows = $derived(filterPlays(plays, filters));
  const seq = $derived(play ? buildSeq(play, viewer.skipDead) : []);
  const homeIsOff = $derived(play ? play.off === play.home : true);
  const home = $derived(play ? (homeIsOff ? play.colors.off : play.colors.def) : null);
  const away = $derived(play ? (homeIsOff ? play.colors.def : play.colors.off) : null);
  const subtitle = $derived(play ? [play.who ? `${play.result} (${play.who})` : play.result, ...play.types].join(" · ") : "");
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

  Promise.all([loadMeta(), loadPlays()]).then(([m, all]) => {
    plays = all;
    openLinked();
    meta = m;
  }).catch((err: Error) => { problem = err.message; });
</script>

<svelte:window onhashchange={openLinked} />

<nav class="tabs">
  <span class="brand">ACB play viewer</span>
  <button type="button" class:on={tab === "viewer"} onclick={() => show("viewer")}>Play viewer</button>
  <button type="button" class:on={tab === "archetypes"} onclick={() => show("archetypes")}>Archetypes</button>
  <button type="button" class:on={tab === "rebounding"} onclick={() => show("rebounding")}>Rebounding</button>
</nav>

<div class="app" hidden={tab !== "viewer"}>
  <aside class="left">
    {#if meta}
      <Filters {meta} bind:filters />
    {/if}
    <PlayList {rows} {selectedId} onselect={select} />
  </aside>

  <section class="viewer">
    <!-- Title over its subtitle on the left; the score and the running clocks centred in the space beside them. -->
    <header class="play-head">
      <div class="play-head-text">
        {#if play}
          <h1>{play.off} possession</h1>
          <p title={subtitle}>{subtitle}</p>
        {:else}
          <h1>{meta ? "No play selected" : "Loading plays…"}</h1>
        {/if}
      </div>
      {#if play && home && away}
        <div class="play-head-score">
        <div class="scorebug" title={`${play.game} · score at the start of the possession`}>
          <span class="team home" style:color={home.text}><span class="kit" style:background={home.fill} style:border-color={home.edge}></span>{play.home}</span>
          <b>{play.homeScore} – {play.awayScore}</b>
          <span class="team away" style:color={away.text}>{play.away}<span class="kit" style:background={away.fill} style:border-color={away.edge}></span></span>
        </div>
        <div class="game-clock">
          <span class="game-time" title="Game clock">{live.gameClock}</span>
          <span class="period-line"><span>{quarter(play.period)}</span><span class="shot-clock" title="Shot clock">{live.shotClock}</span></span>
        </div>
        </div>
      {/if}
    </header>
    <!-- The half court leaves room beside it: the steps behind the shot's xFG go there. -->
    <div class="stage-row" class:split={viewer.view === "half"}>
      <Stage {play} {seq} {note} />
      {#if viewer.view === "half"}
        <ShotPanel {play} {seq} />
      {/if}
    </div>
    <Transport {play} {seq} />
  </section>

  <SidePanel {play} onskip={setSkip} />
</div>

<main class="doc" hidden={tab !== "archetypes"}>
  {#if opened.archetypes}<Archetypes />{/if}
</main>

<main class="doc" hidden={tab !== "rebounding"}>
  {#if opened.rebounding}<Rebounding />{/if}
</main>
