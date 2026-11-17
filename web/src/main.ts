import { mount } from "svelte";
import "./app.css";
import "./unslop.css";
import App from "./App.svelte";
import { initFit } from "./lib/fit.svelte";
import { applyLook, applyTheme, initialLook, initialTheme } from "./lib/look";

// Set before the first render, so the page never flashes the other look or theme (the theme first: the look's canvas
// colours depend on it).
applyTheme(initialTheme());
applyLook(initialLook());
initFit();

mount(App, { target: document.getElementById("app")! });
