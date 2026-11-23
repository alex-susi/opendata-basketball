// The documents behind the exploration tabs (web/public/data/explore_<topic>.json, written by
// web/scripts/explore/build.R and its topic scripts). A document is sections of blocks; every number in a block's
// text comes from the same R code that computed its charts and tables.

export type Cell = number | string | boolean | null | undefined;
export type Row = Record<string, Cell>;
export type Fmt = "text" | "int" | "num1" | "num2" | "pct" | "pct1";

export interface RateRow { label: string; rate: number; lo: number | null; hi: number | null; n: number }
export interface Line { points: [number, number][]; label?: string | null; name?: string; color?: string | null; dashed?: boolean }
/** One switchable view of a table: its button label and the column keys it shows, in order. */
export interface View { label: string; keys: string[] }
export interface Col { key: string; label: string; fmt: Fmt; ref?: number | null; scale?: number | null; low?: boolean; title?: string | null; group?: string | null }

export type Block =
  | { type: "p" | "h"; text: string }
  | { type: "list" | "takeaway" | "caveat"; items: string[] }
  | { type: "widget"; name: string; data?: string | null }
  | { type: "kpis"; items: { label: string; value: string; sub: string }[] }
  | { type: "grid"; cols: number; blocks: Block[] }
  | { type: "details"; summary: string; blocks: Block[] }
  | { type: "rates"; title: string; rows: RateRow[]; ref: number | null; fmt: Fmt; unit: string; refLabel: string;
      max: number | null; min: number | null; labelWidth: number; note?: string | null }
  | { type: "columns"; title: string; categories: string[]; series: { name: string; values: (number | null)[]; color?: string | null }[];
      fmt: Fmt; xlabel: string; ylabel: string; labels: boolean; note?: string | null }
  | { type: "scatter"; title: string; points: { x: number; y: number; g?: number; tip?: string }[] | null; lines: Line[]; groups: string[];
      xlabel: string; ylabel: string; xfmt: Fmt; yfmt: Fmt; xdomain: [number, number] | null; ydomain: [number, number] | null;
      note?: string | null; radius: number; opacity: number }
  | { type: "court"; title: string; points: { x: number; y: number; w?: number }[]; caption: string | null; bw: number }
  | { type: "table"; title: string; cols: Col[]; rows: Row[]; limit: number; note?: string | null; views?: View[] | null };

export interface Section { id: string; title: string; blocks: Block[] }
export interface ExploreDoc { id: string; title: string; lead: string; built: string; sections: Section[]; meta?: string | null }

const finite = (v: Cell): v is number => typeof v === "number" && Number.isFinite(v);

/** A value in one of the documents' formats; missing values are a dash. */
export function format(v: Cell, fmt: Fmt): string {
  if (fmt === "text") return v == null || v === "" ? "–" : String(v);
  if (!finite(v)) return "–";
  switch (fmt) {
    case "int": return Math.round(v).toLocaleString("en-US");
    case "num1": return v.toFixed(1);
    case "num2": return v.toFixed(2);
    case "pct": return `${(100 * v).toFixed(0)}%`;
    case "pct1": return `${(100 * v).toFixed(1)}%`;
  }
}
export const formatter = (fmt: Fmt) => (v: number, d?: number) =>
  d != null && (fmt === "pct" || fmt === "pct1") ? `${(100 * v).toFixed(d)}%` : format(v, fmt);

// Title case for chart, table and axis titles: every word capitalised except short articles, conjunctions and
// prepositions (unless first), units, and words that already carry a capital or digit (xPts, eFG%, 3PA, PnR).
const SMALL = new Set(["a", "an", "the", "and", "or", "but", "nor", "of", "on", "in", "at", "to", "by", "for", "vs", "per", "from", "with", "as", "into"]);
const KEEP = new Set(["ft", "s", "sq", "ft/s", "m", "xpts"]);
export function titleCase(s: string | null | undefined): string {
  if (!s) return s ?? "";
  let first = true;
  return s.replace(/[A-Za-z][\w'%/.+]*/g, (w: string) => {
    const lead = first;
    first = false;
    if (/[A-Z0-9]/.test(w) || KEEP.has(w)) return w;
    if (!lead && SMALL.has(w)) return w;
    return w.charAt(0).toUpperCase() + w.slice(1);
  });
}

/** **bold** in the documents' prose. Text is escaped first, so the documents cannot inject markup. */
export function inline(text: string): string {
  const esc = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return esc.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");
}
