// Cuts: off-ball runs by an attacker, found from the tracking at export (web/scripts/cuts.R, where the rules are)
// and delivered as `ann.cuts`. SkillCorner marks only the cuts that use an off-ball screen; basket cuts without a
// screen are found from the tracking. Kinds:
//   basket   toward the hoop without a screen
//   in       through an off-ball screen, finishing closer to the basket (a curl, a back screen, ...)
//   out      through an off-ball screen, finishing further from it (a pin-down, a flare, ...)
//   pop      a pick-and-pop: the screener moving out to mid-range or the arc after his screen instead of rolling
// Run on decode: adds a "cut" event per cut to the play's timeline. Pure, so the tests can run it.

import type { AnnCut, Play, PlayEvent } from "./types";

/** The timeline and caption name of each kind (the trace panel and play list shorten "Screen" to "Scr"). */
export const CUT_LABEL: Record<AnnCut["kind"], string> = { basket: "Basket Cut", in: "Screen Cut In", out: "Screen Cut Out", pop: "Pick and Pop" };
/** The tag on the court. */
export const CUT_TAG: Record<AnnCut["kind"], string> = { basket: "Cut · basket", in: "Cut · in", out: "Cut · out", pop: "Pop" };

export function addCutEvents(play: Play): void {
  if (!play.ann?.cuts?.length) return;
  // A cut near the edge of the viewing window can belong to the neighbouring possession: keep this offense's only.
  const cuts = (play.ann.cuts = play.ann.cuts.filter((c) => play.players.find((q) => q.id === c.pid)?.role === "off"));
  const events: PlayEvent[] = cuts.map((c) => {
    const p = play.players.find((q) => q.id === c.pid);
    return { f: c.f, kind: "cut", label: `${CUT_LABEL[c.kind]}: ${p ? `#${p.jersey} ${p.last}` : "unknown"}`, short: CUT_LABEL[c.kind], who: p?.last ?? null };
  });
  play.events = [...play.events, ...events].sort((x, y) => x.f - y.f);
}
