import { readFileSync } from "node:fs";
import { defineConfig } from "vitest/config";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// The export's stamp is built into the page and sent with every data request, so a browser never pairs a new
// build with data files it cached from an older export (they keep their names, and Pages caches them).
const stamp: string = JSON.parse(readFileSync(new URL("./public/data/meta.json", import.meta.url), "utf8")).generated;

// Relative base so the same build works at a GitHub Pages project path (/<repo>/) and from `vite preview`.
export default defineConfig({
  base: "./",
  plugins: [svelte()],
  define: { __DATA_STAMP__: JSON.stringify(stamp) },
  test: {
    include: ["tests/**/*.test.ts"],
  },
});
