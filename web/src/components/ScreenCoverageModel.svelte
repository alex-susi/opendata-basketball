<script lang="ts">
  // The Screen Coverage Model tab: the live screen-coverage model's readme. The page itself is the standalone
  // screen_coverage/04_docs/screen_coverage_model.html, copied to public/docs/ so the site and the shared document
  // never drift apart. It is shown in a frame filling the tab, and follows the site's night/day theme.
  import { page } from "../lib/theme.svelte";

  const SRC = "docs/screen_coverage_model.html";
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

<iframe bind:this={frame} class="doc-frame" src={SRC} title="Screen Coverage Model" onload={() => { loads += 1; }}></iframe>
