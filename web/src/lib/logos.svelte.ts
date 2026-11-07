// Team logos, from public/logos/: logos.json maps a team id to its image file in that folder. Everything that shows
// a logo (the scoreboard, the rosters, the court's midcourt) shows nothing while the manifest or an image is
// missing, so the site works without them.

const BASE = import.meta.env.BASE_URL;

export const logos = $state({ files: {} as Record<string, string> });

let requested = false;

/** Load the manifest once. */
export function loadLogos(): void {
  if (requested) return;
  requested = true;
  fetch(`${BASE}logos/logos.json`)
    .then((r) => (r.ok ? r.json() : {}))
    .then((files: Record<string, string>) => { logos.files = files ?? {}; })
    .catch(() => { /* no logos */ });
}

/** URL of a team's logo, or null. */
export function logoUrl(teamId: number | null | undefined): string | null {
  const file = teamId == null ? undefined : logos.files[String(teamId)];
  return file ? `${BASE}logos/${file}` : null;
}

const images = new Map<string, HTMLImageElement>();

/** The team's logo as an image for the canvas (it draws once loaded), or null. */
export function logoImage(teamId: number | null | undefined): HTMLImageElement | null {
  const url = logoUrl(teamId);
  if (!url) return null;
  let img = images.get(url);
  if (!img) {
    img = new Image();
    img.src = url;
    images.set(url, img);
  }
  return img;
}
