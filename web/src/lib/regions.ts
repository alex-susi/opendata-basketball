// Court regions and a distance-based contest level, for the trace panel's Player Tracking tab. Pure.
//
// Regions use SkillCorner's vocabulary (docs/data_dictionary/README.md): left/right corner, wing, middle, each two
// or three, plus key, ra (restricted area), far and backcourt. Their boundaries were read off the event tables'
// labelled locations in the ten games (about 30,000 shots, dribbles, passes, rebounds and turnovers):
//   backcourt  x < 0 (the half the offense is not attacking)
//   far        frontcourt, more than 31.5 ft from the basket
//   ra         within the 1.25 m no-charge semicircle (4.1 ft)
//   key        inside the painted key
//   corner     at least 76° from straight out (0° points from the basket to midcourt, 90° is level with it)
//   middle     under 23°; wing in between
//   three      beyond the FIBA line: 6.75 m, or 6.6 m from the centre line along the corners
// Left is +y (the offense's left as it attacks +x).
//
// Contest: SkillCorner's contestLevel is not a function of distance alone (its "light" shots have their closest
// defender nearer, on median, than its "average" ones), so this is a stand-in from the nearest defender's distance,
// with cut-offs at 3.5, 5.5 and 6.5 ft. On the ten games' shots it gives SkillCorner's level on 50% of them and is
// within one level on 81%.

import { HOOP_X, KEY_HALF_W, KEY_X, NO_CHARGE_R, THREE_R, THREE_Y } from "./court";

const FAR = 31.5, CORNER_DEG = 76, MIDDLE_DEG = 23;
const CORNER_X = HOOP_X - Math.sqrt(THREE_R * THREE_R - THREE_Y * THREE_Y);   // where the arc meets the corner lines

export function isThree(x: number, y: number): boolean {
  if (Math.abs(y) >= THREE_Y && x >= CORNER_X) return true;
  return Math.hypot(x - HOOP_X, y) > THREE_R;
}

/** The SkillCorner region of a spot in the play's stored frame (offense attacking +x), lower case. */
export function courtRegion(x: number, y: number): string {
  if (x < 0) return "backcourt";
  const r = Math.hypot(x - HOOP_X, y);
  if (r > FAR) return "far";
  if (r <= NO_CHARGE_R) return "ra";
  if (x >= KEY_X && Math.abs(y) <= KEY_HALF_W) return "key";
  const angle = (Math.atan2(Math.abs(y), HOOP_X - x) * 180) / Math.PI;
  const zone = angle >= CORNER_DEG ? "corner" : angle < MIDDLE_DEG ? "middle" : "wing";
  const side = zone === "middle" ? "" : y > 0 ? "left " : "right ";
  return `${side}${zone} ${isThree(x, y) ? "three" : "two"}`;
}

/** A contest level from the nearest defender's distance (ft): plus, average, light or open. */
export function contestOf(dist: number): "plus" | "average" | "light" | "open" {
  return dist < 3.5 ? "plus" : dist < 5.5 ? "average" : dist < 6.5 ? "light" : "open";
}
