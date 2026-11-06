<script lang="ts">
  // A team's name dressed like its players' dots on the court: a pill of the club's primary colour, outlined in its
  // secondary colour, the name in white (dark on a light primary). Club colours as entered in the Shiny app's
  // R/data.R (TEAM_COLORS); a team without colours is plain text.
  import { dotInk } from "../lib/teamColors";

  let { name, colors }: { name: string; colors?: [string, string] } = $props();
</script>

{#if colors}
  <span class="team-pill" style:background={colors[0]} style:border-color={colors[1]} style:color={dotInk(colors[0])}>{name}</span>
{:else}
  <span>{name}</span>
{/if}
