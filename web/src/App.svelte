<script lang="ts">
  // Two tabs. The play viewer: filters and play list on the left, court and transport in the middle,
  // display options and rosters on the right. The Archetypes tab explains the tags beside each player's name.
  // Static counterpart of src/play_viewer/app.R.
  import { untrack } from "svelte";
  import Archetypes from "./components/Archetypes.svelte";
  import Filters from "./components/Filters.svelte";
  import PlayList from "./components/PlayList.svelte";
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
  type Tab = "viewer" | "archetypes";

  let meta = $state.raw<Meta | null>(null);
  let plays = $state.raw<PlayRow[]>([]);
  let play = $state.raw<Play | null>(null);
  let selectedId = $state<string | null>(null);
  let filters = $state(emptyFilters());
  let problem = $state("");
  let tab = $state<Tab>(location.hash === ARCHETYPES ? "archetypes" : "viewer");
  let opened = $state(location.hash === ARCHETYPES);   // the Archetypes page is fetched the first time it is shown
  viewer.hidden = location.hash === ARCHETYPES;

  const rows = $derived(filterPlays(plays, filters));
  const seq = $derived(play ? buildSeq(play, viewer.skipDead) : []);
  const homeIsOff = $derived(play ? play.off === play.home : true);
  const home = $derived(play ? (homeIsOff ? play.colors.off : play.colors.def) : null);
  const away = $derived(play ? (homeIsOff ? play.colors.def : play.colors.off) : null);
  const note = $derived(problem || (!meta ? "Loading plays…" : !rows.length ? "No possessions match these filters." : ""));

  // The address names the selected play, or the Archetypes tab while it is open.
  function address(): string {
    if (tab === "archetypes") return ARCHETYPES;
    return selectedId ? ROUTE + selectedId : location.pathname + location.search;
  }

  function show(next: Tab): void {
    tab = next;
    viewer.hidden = next !== "viewer";
    if (viewer.hidden) {
      opened = true;
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
    if (location.hash === ARCHETYPES) return show("archetypes");
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
</nav>

<div class="app" hidden={tab !== "viewer"}>
  <aside class="left">
    {#if meta}
      <Filters {meta} bind:filters />
    {/if}
    <PlayList {rows} {selectedId} onselect={select} />
  </aside>

  <section class="viewer">
    <!-- Title on the left, then the running clocks beside the score, which sits over the middle of the court. -->
    <header class="play-head">
      <div class="play-head-lead">
        <div class="play-head-text">
          {#if play}
            <h1>{play.off} possession</h1>
            <p>{[play.who ? `${play.result} (${play.who})` : play.result, ...play.types].join(" · ")}</p>
          {:else}
            <h1>{meta ? "No play selected" : "Loading plays…"}</h1>
          {/if}
        </div>
        {#if play}
          <div class="game-clock">
            <b>{quarter(play.period)}</b><span class="shot-clock" title="Shot clock">{live.shotClock}</span><b title="Game clock">{live.gameClock}</b>
          </div>
        {/if}
      </div>
      {#if play && home && away}
        <div class="scorebug" title={`${play.game} · score at the start of the possession`}>
          <span class="team home" style:color={home.text}><span class="kit" style:background={home.fill} style:border-color={home.edge}></span>{play.home}</span>
          <b>{play.homeScore} – {play.awayScore}</b>
          <span class="team away" style:color={away.text}>{play.away}<span class="kit" style:background={away.fill} style:border-color={away.edge}></span></span>
        </div>
      {/if}
    </header>
    <Stage {play} {seq} {note} />
    <Transport {play} {seq} />
  </section>

  <SidePanel {play} onskip={setSkip} />
</div>

<main class="doc" hidden={tab !== "archetypes"}>
  {#if opened}<Archetypes />{/if}
</main>
