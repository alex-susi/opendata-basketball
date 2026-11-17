<script lang="ts">
  // A reading tab that shows a standalone page from public/docs/ in a frame filling the tab, following the site's
  // night/day theme, its reading-tab font and its colour scheme (Font and Colors menus, lib/appearance.svelte.ts).
  // Used for the Screen Coverage Model tab (a copy of screen_coverage/04_docs/screen_coverage_model.html, so the site
  // and the shared document never drift apart) and the Court Control tab.
  import { appearance, fontOf, frameCss, loadFonts } from "../lib/appearance.svelte";
  import { page } from "../lib/theme.svelte";

  let { src, title }: { src: string; title: string } = $props();
  let frame = $state<HTMLIFrameElement | null>(null);
  let loads = $state(0);   // counts page loads, so the theme is set again after each one

  // The page reads data-theme on its root element (dark or light), the same attribute the site sets on its own. The
  // font and scheme go in as one style element of overrides on the page's own variables.
  $effect(() => {
    const theme = page.light ? "light" : "dark";
    void [appearance.docFont, appearance.dark, appearance.light];
    if (!loads || !frame) return;
    try {
      const doc = frame.contentDocument;
      if (!doc) return;
      doc.documentElement.dataset.theme = theme;
      loadFonts(doc, [fontOf(appearance.docFont).id]);
      let style = doc.getElementById("site-appearance");
      if (!style) {
        style = doc.createElement("style");
        style.id = "site-appearance";
        doc.head.appendChild(style);
      }
      style.textContent = frameCss();
    } catch { /* another origin: the page keeps its own look */ }
  });
</script>

<iframe bind:this={frame} class="doc-frame" {src} {title} onload={() => { loads += 1; }}></iframe>
