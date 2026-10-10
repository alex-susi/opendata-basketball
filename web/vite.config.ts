import { defineConfig } from "vitest/config";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// Relative base so the same build works at a GitHub Pages project path (/<repo>/) and from `vite preview`.
export default defineConfig({
  base: "./",
  plugins: [svelte()],
  test: {
    include: ["tests/**/*.test.ts"],
  },
});
