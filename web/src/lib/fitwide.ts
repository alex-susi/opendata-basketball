// A Svelte action for wide tables on the reading tabs: when a table needs more room than its text column, its
// wrapper grows past the column into the page's side margins (to the right first, then to the left) instead of
// scrolling, up to the window's width less a small gutter. Narrow tables are left alone, aligned with the text.
// Re-measured when the window or the table changes size (sorting, "Show all").

const GUTTER = 16;

export function fitWide(node: HTMLElement): { destroy(): void } {
  const table = node.querySelector("table");
  let timer = 0;
  function fit(): void {
    if (!table) return;
    node.style.width = "";
    node.style.marginLeft = "";
    const parent = node.parentElement;
    if (!parent) return;
    const box = parent.getBoundingClientRect();
    const page = document.documentElement.clientWidth;
    const need = table.scrollWidth + 2;
    if (need <= box.width + 1) return;
    const target = Math.min(need, page - 2 * GUTTER);
    const extra = target - box.width;
    const right = Math.max(0, page - box.right - GUTTER);
    const left = Math.max(0, box.left - GUTTER);
    const shift = Math.min(left, Math.max(0, extra - right));
    node.style.width = `${Math.round(target)}px`;
    node.style.marginLeft = `${-Math.round(shift)}px`;
  }
  const later = () => { clearTimeout(timer); timer = window.setTimeout(fit, 30); };
  const seen = new ResizeObserver(later);
  if (table) seen.observe(table);
  window.addEventListener("resize", later);
  later();
  return {
    destroy() {
      seen.disconnect();
      window.removeEventListener("resize", later);
      clearTimeout(timer);
    },
  };
}
