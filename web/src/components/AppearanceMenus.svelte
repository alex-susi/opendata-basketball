<script lang="ts">
  // The Font and Colors menus in the tab bar, between EDA and the data credit. Each opens like the EDA menu (hover,
  // keyboard focus or a click) and stays open while the pointer is over it, so the options can be tried in turn.
  //   Font     two lists, Play Viewer and Reading Tabs, each option written in its own typeface.
  //   Colors   a vibrancy slider (muted, standard, vivid) at the top right, then the schemes for the theme in force
  //            (night or day), each row drawn in that scheme's own colours at that vibrancy: its
  //            page background around a panel with text and muted text, then its raised, hover and line colours.
  // Choices are remembered in this browser (lib/appearance.svelte.ts).
  import { FONTS, SCHEMES, VIBRANCY, appearance, choose, loadFonts, tuned, type Scheme } from "../lib/appearance.svelte";
  import { page } from "../lib/theme.svelte";

  let open = $state<"" | "font" | "colors">("");
  const mode = $derived(page.light ? "light" : "dark");
  const current = $derived(SCHEMES[mode].find((s) => s.id === appearance[mode]) ?? SCHEMES[mode][0]);
  // Every face is fetched the first time the Font menu is shown, so its options preview in their own type.
  const preview = () => loadFonts(document, FONTS.map((f) => f.id));
</script>

<div class="tab-menu" class:open={open === "font"} role="presentation" onmouseenter={preview} onmouseleave={() => { open = ""; }}>
  <button type="button" class="tab-menu-btn" aria-haspopup="true" aria-expanded={open === "font"}
          onfocus={preview} onclick={() => { open = open === "font" ? "" : "font"; }}>Font <span class="tab-caret" aria-hidden="true">▾</span></button>
  <div class="tab-menu-list font-menu" role="menu">
    {#each [{ key: "viewerFont", title: "Play Viewer" }, { key: "docFont", title: "Reading Tabs" }] as group (group.key)}
      {@const key = group.key as "viewerFont" | "docFont"}
      <span class="menu-head">{group.title}</span>
      {#each FONTS as f (f.id)}
        <button type="button" role="menuitemradio" aria-checked={appearance[key] === f.id} class:on={appearance[key] === f.id}
                style:font-family={f.family} onclick={() => choose(key, f.id)}>
          {f.label}{#if f.id === "default"}<span class="menu-note">{key === "docFont" ? "each page's own" : "system"}</span>{/if}
        </button>
      {/each}
    {/each}
  </div>
</div>

<div class="tab-menu" class:open={open === "colors"} role="presentation" onmouseleave={() => { open = ""; }}>
  <button type="button" class="tab-menu-btn" aria-haspopup="true" aria-expanded={open === "colors"}
          onclick={() => { open = open === "colors" ? "" : "colors"; }}>Colors <span class="tab-caret" aria-hidden="true">▾</span></button>
  <div class="tab-menu-list scheme-menu" role="menu">
    <!-- The heading, with the vibrancy slider at its right (three steps, the same for night and day). -->
    <span class="menu-head scheme-head">
      <span>{page.light ? "Day" : "Night"} Schemes</span>
      <label class="vibrancy" title="Colour vibrancy for every scheme, night and day">
        <span>{VIBRANCY[Number(appearance.vibrancy)]?.label ?? "Standard"}</span>
        <input type="range" min="0" max="2" step="1" value={appearance.vibrancy} aria-label="Colour vibrancy"
               oninput={(ev) => choose("vibrancy", (ev.currentTarget as HTMLInputElement).value)} />
      </label>
    </span>
    {#each SCHEMES[mode] as s, n (s.id)}
      {@render row(tuned(s), n === 0)}
    {/each}
  </div>
</div>

{#snippet row(s: Scheme, own: boolean)}
  <button type="button" role="menuitemradio" aria-checked={current.id === s.id} class="scheme-row" class:on={current.id === s.id}
          style:background={s.bg} style:border-color={current.id === s.id ? s.ink : s.line} onclick={() => choose(mode, s.id)}>
    <span class="scheme-card" style:background={s.panel} style:border-color={s.line}>
      <b style:color={s.ink}>{s.label}{#if own}<span style:color={s.muted}> · Site</span>{/if}</b>
      <span style:color={s.muted}>Muted text</span>
    </span>
    <span class="scheme-chips" aria-hidden="true">
      <i style:background={s.raised} style:border-color={s.line}></i><i style:background={s.hover} style:border-color={s.line}></i><i style:background={s.line}></i>
    </span>
  </button>
{/snippet}
