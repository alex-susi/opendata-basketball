// Foul types, turnover types, what followed a closeout, and the block and steal flags, on the play's timeline events
// (run on decode, after the cuts). The fouls' types are SkillCorner's (foulType, isTechnical, isBonus); the
// turnovers' are pieced together at export (web/scripts/annotations.R, turnovers); a closeout says what the ball
// handler did after the catch (SkillCorner's bhrAction: shot, drive, pass, other). Each such event gets these in its
// caption and label; a blocked shot gets the flag "BLK", a turnover with a stealer "STL". Pure, so the tests can run it.

import { nameOf } from "./context";
import type { AnnFoul, AnnTurnover, Play } from "./types";

export const TURNOVER_NAMES: Record<string, string> = {
  steal: "Steal", pass_stolen: "Pass Stolen", bad_pass: "Bad Pass", off_foul: "Offensive Foul", team: "Team Violation",
  out: "Out of Bounds", violation: "Violation",
};

/** A foul's type: technical, shooting, offensive, flagrant, or personal (in the bonus or not). */
export function foulName(fo: AnnFoul): string {
  if (fo.tech) return "Technical Foul";
  if (fo.type === "shooting" || fo.shooting) return "Shooting Foul";
  if (fo.type === "offensive") return "Offensive Foul";
  if (fo.type === "flagrant") return "Flagrant Foul";
  return fo.bonus ? "Personal Foul, Bonus" : "Personal Foul";
}

export const turnoverName = (t: AnnTurnover): string => TURNOVER_NAMES[t.kind ?? ""] ?? "Turnover";

/** What the ball handler did after a closeout's catch, in Title Case ("Shot", "Drive", "Pass", "Other"), or null. */
export const afterCloseout = (act: string | undefined): string | null => (act ? act.charAt(0).toUpperCase() + act.slice(1) : null);
const AFTER_WORDS: Record<string, string> = { shot: "a shot", drive: "a drive", pass: "a pass", other: "no shot, drive or pass" };

export function addWhistleDetails(play: Play): void {
  const ann = play.ann;
  if (!ann) return;
  play.events = play.events.map((ev) => {
    if (ev.kind === "foul") {
      const fo = ann.fouls.find((x) => x.f === ev.f);
      if (!fo) return ev;
      const name = foulName(fo);
      return { ...ev, short: name.replace(", Bonus", ""), label: ev.label.replace(/^Foul:/, `${name}:`) };
    }
    if (ev.kind === "turnover") {
      const t = ann.turnovers.find((x) => x.f === ev.f);
      if (!t) return ev;
      const name = turnoverName(t);
      return { ...ev, short: `TO · ${name}`, label: ev.label.replace(/^Turnover:/, `Turnover (${name}):`), flag: t.stealer != null ? "STL" : undefined };
    }
    if (ev.kind === "closeout") {
      const c = ann.closeouts.find((x) => x.f === ev.f);
      const after = afterCloseout(c?.act);
      if (!c || !after) return ev;
      return { ...ev, short: `Closeout · ${after}`, label: `${ev.label}, then ${AFTER_WORDS[c.act!] ?? c.act}` };
    }
    if (ev.kind === "made" || ev.kind === "missed") {
      const shot = ann.shots.find((x) => x.f === ev.f);
      if (shot?.blocked) return { ...ev, flag: "BLK" };
    }
    return ev;
  });
}

/** The hover card's lines for a foul. */
export function foulLines(play: Play, fo: AnnFoul) {
  const lines = [{ k: "Type", v: foulName(fo) }, { k: "Fouler", v: nameOf(play, fo.by) }];
  if (fo.on != null) lines.push({ k: "Fouled", v: nameOf(play, fo.on) });
  if (fo.ft.length) lines.push({ k: "Free Throws", v: `${fo.ft.filter(Boolean).length}/${fo.ft.length}` });
  return lines;
}

/** The hover card's lines for a turnover. */
export function turnoverLines(play: Play, t: AnnTurnover) {
  const lines = [{ k: "Type", v: turnoverName(t) }];
  if (t.pid != null) lines.push({ k: "Lost By", v: nameOf(play, t.pid) });
  if (t.stealer != null) lines.push({ k: "Stolen By", v: nameOf(play, t.stealer) });
  return lines;
}
