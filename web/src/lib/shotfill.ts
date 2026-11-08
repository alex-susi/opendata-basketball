// Shots SkillCorner left without context. On 26 of the ten games' 1,459 shot events every tracking-derived field is
// blank (location, distance, region, shot quality, contest, closest defender, shot type), although the tracking
// has the shooter and the defenders at the release frame on all but one. Here the measurable ones are rebuilt from
// that tracking, and the shot is marked `est`:
//   location          the shooter's tracked position at release (nearest frame within 0.12 s)
//   distance, region  from that spot (regions.ts, which matches SkillCorner's labels on 98.8% of located events)
//   closest defender  the nearest opponent at release, and his distance
//   contest           the distance-based stand-in (regions.ts, contestOf), shown as an estimate
// Shot quality, shot type and release time cannot be rebuilt and stay blank.
//
// Why SkillCorner left them blank, judging by the tracked spots: 14 of the 17 such threes were released within
// half a foot of the line (so the tracked spot and the official three disagree, or nearly), six of the twos are
// tip-ins and putbacks right at the rim, and a few spots plainly contradict the official value (a "three" from
// 10.9 ft, "twos" from 27-40 ft), which suggests a mistimed release frame or a mixed-up player. So:
//   within LINE_SLACK of the line   the region takes the official value's side of it (two or three)
//   further on the wrong side       the spot is kept as tracked and the shot is flagged `conflict`
// For shots SkillCorner did locate, the tracked spot at the release frame matches its distance to 0.03 ft (median),
// so the rebuilt spot is the one SkillCorner would have used. Pure, so the tests can run it.

import { HOOP_X } from "./court";
import { frameIndex } from "./context";
import { contestOf, courtRegion, isThree, lineGap } from "./regions";
import type { AnnShot, Play } from "./types";

const REACH = 3;   // frames either side of release to look for the shooter
const LINE_SLACK = 1.5;   // ft

export function fillShots(play: Play): void {
  for (const s of play.ann?.shots ?? []) {
    if (s.x != null && Number.isFinite(s.x) && s.dist != null) continue;
    fillShot(play, s);
  }
}

function fillShot(play: Play, s: AnnShot): void {
  const shooter = play.players.find((p) => p.id === s.pid);
  if (!shooter) return;
  const i0 = frameIndex(play, s.f);
  let i = -1;
  for (let d = 0; d <= REACH && i < 0; d++) {
    for (const j of [i0 + d, i0 - d]) {
      if (j >= 0 && j < play.frames.length && Math.abs(play.frames[j] - s.f) <= REACH && !Number.isNaN(shooter.x[j])) { i = j; break; }
    }
  }
  if (i < 0) return;
  const x = shooter.x[i], y = shooter.y[i];
  s.x = x;
  s.y = y;
  s.dist = Math.round(10 * Math.hypot(x - HOOP_X, y)) / 10;
  let region = courtRegion(x, y);
  const three = region === "far" || region === "backcourt" ? true : isThree(x, y);
  if (three !== s.three) {
    if (lineGap(x, y) <= LINE_SLACK && /(two|three)$/.test(region)) region = region.replace(/(two|three)$/, s.three ? "three" : "two");
    else s.conflict = true;
  }
  s.region = region;
  let best: { id: number; d: number } | null = null;
  for (const p of play.players) {
    if (p.role === shooter.role || Number.isNaN(p.x[i])) continue;
    const d = Math.hypot(p.x[i] - x, p.y[i] - y);
    if (!best || d < best.d) best = { id: p.id, d };
  }
  if (best) {
    s.defId = best.id;
    s.defDist = Math.round(10 * best.d) / 10;
    s.cl ??= contestOf(best.d);
  }
  s.est = true;
}
