// Playback and display state shared by the stage, the transport bar and the side panel.

import type { CourtView } from "./court";

export const viewer = $state({
  /** Playback position: an index into the current play's frame sequence, fractional between frames. */
  pos: 0,
  playing: false,
  speed: 1,
  view: "full" as CourtView,
  showDef: true,
  showOff: true,
  skipDead: true,
  loop: true,
  /** Ring each player on the court in his archetype's colour. */
  showArch: true,
  /** The EPV labels on the court. The readout beside the court shows whenever the play has prices. */
  showEpv: true,
  showPassValues: true,
  showPassTov: true,
  showBallTov: true,
  showShotPass: true,
  showBestPass: true,
  hoverPid: null as number | null,
  recording: false,
  /** True while another tab covers the viewer: keyboard shortcuts are off. */
  hidden: false,
});

/** The frame last drawn, as the page shows it around the canvas: rosters, header clocks, the EPV readout and the shot panel. */
export const live = $state({
  onCourt: [] as number[],
  handler: null as number | null,
  areaOff: null as number | null,
  areaDef: null as number | null,
  gameClock: "",
  shotClock: "",
  /** Readout cells (label, value); values are dashes where nothing is priced. */
  readout: [] as [string, string][],
  /** Index in the play's shots of the one the shot panel shows, or -1. */
  shot: -1,
});
