import { mount } from "svelte";
import "./app.css";
import "./unslop.css";
import App from "./App.svelte";
import { applyLook, initialLook } from "./lib/look";

// Set before the first render, so the page never flashes the other look.
applyLook(initialLook());

mount(App, { target: document.getElementById("app")! });
