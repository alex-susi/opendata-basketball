// Playback and display state shared by the stage, the transport bar, the trace panel and the side panel.

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
  /** The trace panel under the court. */
  showTrace: true,
  /** What it follows: the ball's height, or one player's distance to the closest opponent. */
  trace: "ball" as "ball" | "nearest",
  /** The player the nearest-opponent trace follows (clicked on the court or in a roster), or null. */
  focusPid: null as number | null,
  /** Caption each tick on the timeline with its action and player. Off, the timeline is a thin bar. */
  showTickLabels: true,
  hoverPid: null as number | null,
  recording: false,
  /** True while another tab covers the viewer: keyboard shortcuts are off. */
  hidden: false,
});

/** Play or pause; a play that has reached its end starts again from the top. */
export function togglePlay(seqLength: number): void {
  if (!seqLength) return;
  if (!viewer.playing && viewer.pos >= seqLength - 1) viewer.pos = 0;
  viewer.playing = !viewer.playing;
}

/** The frame last drawn, as the page shows it around the canvas: rosters, header clocks and the trace panel. */
export const live = $state({
  onCourt: [] as number[],
  handler: null as number | null,
  areaOff: null as number | null,
  areaDef: null as number | null,
  gameClock: "",
  shotClock: "",
});
