// Team names as the viewer shortens them: a club's three-letter abbreviation (the scorebug, the possession list), and a
// game's label ("BAXI Manresa 83-68 Coviran Granada (11 Oct 2025)") split into its parts. Pure, so the tests can run it.

const ABBR: Record<string, string> = {
  "BAXI Manresa": "MAN", "Coviran Granada": "GRA", "Casademont Zaragoza": "ZAR", "Leche Rio Breogan": "BRE",
  "CB UCAM Murcia": "MUR", "Club Joventut Badalona": "JOV", "Basquet Girona": "GIR", "San Pablo Burgos": "BUR",
  "Dreamland Gran Canaria": "GCA", "Bitci Baskonia": "BKN", "BC MoraBanc Andorra": "AND", "Bilbao Basket": "BIL",
  Malaga: "MAL", "Valencia BC": "VAL", "Real Madrid": "RMA", "Lenovo Tenerife": "TEN", "BC Barcelona": "BAR",
};

/** A team's three-letter name. Unlisted names fall back to the first three letters of their last word. */
export const teamAbbr = (name: string): string => ABBR[name] ?? (name.split(" ").at(-1) ?? name).slice(0, 3).toUpperCase();

/** A game's label with both teams abbreviated ("MAN 83-68 GRA") and its date apart ("11 Oct 2025"), or the label as it
 * is (no date) when it does not have that shape. */
export function gameParts(label: string): { teams: string; date: string } {
  const m = /^(.+?) (\d+)-(\d+) (.+?) \(([^)]+)\)$/.exec(label);
  return m ? { teams: `${teamAbbr(m[1])} ${m[2]}-${m[3]} ${teamAbbr(m[4])}`, date: m[5] } : { teams: label, date: "" };
}
