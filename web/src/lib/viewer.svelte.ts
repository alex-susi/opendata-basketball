// Playback and display state shared by the stage, the playback controls, the trace panel and the side panel.

import type { Season } from "./context";
import type { Playstyle, Sample } from "./types";
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
  /** At the end of a play: play it again from the top, or go on to the next play in the list and play that. */
  atEnd: "loop" as "loop" | "next",
  /** Ring each player on the court in his archetype's colour. */
  showArch: true,
  /** A trail behind each player on the court, longer the faster he moves. */
  showTrails: true,
  /** Court control under the players (time-to-ball version, control.ts). */
  showControl: false,
  /** The court control readout: shares of the whole court, or of the half the offense attacks. */
  controlScope: "court" as "court" | "half",
  /** Annotation sections (the Display panel's Annotations toggles; annotate.ts, Annotations.svelte). */
  ann: { events: true, defense: true, shot: true, tracking: false, possession: true, quality: false },
  /** The trace panel under the court. */
  showTrace: true,
  /** What it shows: the ball's height, one player's distance to the closest opponent, or the players on court. */
  trace: "ball" as "ball" | "nearest" | "players",
  /** Which column group the Player Tracking tab shows. */
  trackCols: "movement" as "movement" | "position" | "ball" | "all",
  /** The player the nearest-opponent trace follows (clicked on the court or in a roster), or null. */
  focusPid: null as number | null,
  /** Caption the actions in the trace panel: the action above the plot, the player under the time axis. */
  showTickLabels: true,
  hoverPid: null as number | null,
  /** The player card beside the rosters: which view it shows. */
  cardView: "basic" as "basic" | "advanced" | "tracking" | "actions" | "playstyle",
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
  /** Index into the play's frames of the frame last drawn, refreshed a few times a second while playing. */
  i0: 0,
  /** With court control on: the offense's share of the whole court and of its attacking half at the frame drawn. */
  control: null as { court: number; half: number } | null,
  /** Height (px) the cards over the court need (Annotations.svelte); the court window is kept at least this tall. */
  annNeed: 0,
  /** The court's box on the canvas (CSS px) and which half is the backcourt, for the cards over it. */
  box: null as { left: number; top: number; w: number; h: number; backLeft: boolean } | null,
});

/** Season figures by "<canonical id>:<team id>" (season.json), once loaded. */
export const season = $state({ data: null as Season | null, sample: null as Sample | null, style: null as Playstyle | null });
