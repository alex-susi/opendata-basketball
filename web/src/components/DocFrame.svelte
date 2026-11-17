<script lang="ts">
  // A reading tab that shows a standalone page from public/docs/ in a frame filling the tab, following the site's
  // night/day theme. Used for the Screen Coverage Model tab (a copy of screen_coverage/04_docs/
  // screen_coverage_model.html, so the site and the shared document never drift apart) and the Court Control tab.
  import { page } from "../lib/theme.svelte";

  let { src, title }: { src: string; title: string } = $props();
  let frame = $state<HTMLIFrameElement | null>(null);
  let loads = $state(0);   // counts page loads, so the theme is set again after each one

  // The page reads data-theme on its root element (dark or light), the same attribute the site sets on its own.
  $effect(() => {
    const theme = page.light ? "light" : "dark";
    if (!loads || !frame) return;
    try {
      const root = frame.contentDocument?.documentElement;
      if (root) root.dataset.theme = theme;
    } catch { /* another origin: the page keeps the viewer's system theme */ }
  });
</script>

<iframe bind:this={frame} class="doc-frame" {src} {title} onload={() => { loads += 1; }}></iframe>
