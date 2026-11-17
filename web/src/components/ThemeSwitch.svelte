<script lang="ts">
  // The moon / sun switch between the night and day themes, in the tab bar left of the first tab.
  import { applyTheme } from "../lib/look";
  import { page } from "../lib/theme.svelte";
</script>

<label class="switch two-way theme-switch" title="Night or day theme">
  <svg class:on={!page.light} viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z" /></svg>
  <input type="checkbox" role="switch" aria-label="Use the light day theme" checked={page.light}
         onchange={(ev) => applyTheme(ev.currentTarget.checked ? "light" : "dark")} />
  <span class="switch-track"></span>
  <svg class:on={page.light} viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5" /><path d="M12 1.5v3M12 19.5v3M1.5 12h3M19.5 12h3M4.6 4.6l2.1 2.1M17.3 17.3l2.1 2.1M4.6 19.4l2.1-2.1M17.3 6.7l2.1-2.1" stroke-width="2" stroke-linecap="round" /></svg>
</label>
