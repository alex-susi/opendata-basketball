// Playback and display state shared by the stage, the transport bar and the side panel.

import type { CourtView } from "./court";

export const viewer = $state({
  /** Playback position: an index into the current play's frame sequence, fractional between frames. */
  pos: 0,
  playing: false,
  speed: 1,
  view: "full" as CourtView,
  showDef: true,
  showOff: false,
  skipDead: true,
  loop: true,
  markExtrap: false,
  showEpv: true,
  showReadout: true,
  showPassValues: true,
  showPassTov: true,
  showBallTov: true,
  showShotPass: true,
  showBestPass: true,
  hoverPid: null as number | null,
  recording: false,
});

/** What is on court in the frame last drawn; the rosters read this. */
export const live = $state({
  onCourt: [] as number[],
  handler: null as number | null,
  areaOff: null as number | null,
  areaDef: null as number | null,
});
