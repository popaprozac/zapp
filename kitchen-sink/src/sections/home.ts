import { Services } from "@zappdev/runtime";
import type { Section } from "./types";

// The landing / welcome view, modeled as a normal section so the sidebar can
// navigate back to it like any other. render() can't be async (Section.render
// returns void|teardown), so greet uses .then/.catch.
export const homeSection: Section = {
  id: "home",
  label: "Home",
  render(host) {
    host.innerHTML = `
      <div class="home">
        <h1>Kitchen Sink</h1>
        <p>A showcase + smoke surface for Zapp's native features. Pick a feature
           in the sidebar — each has a trigger and a visible result, and the
           inspector (right) shows live state. Click <b>Home</b> anytime to return here.</p>
        <p class="muted" data-greet>greet: …</p>
      </div>`;
    const greetEl = host.querySelector("[data-greet]")!;
    Services.invoke("greet", { name: "Kitchen Sink" })
      .then((msg) => {
        greetEl.textContent = `greet → ${msg}`;
      })
      .catch((e) => {
        greetEl.textContent = `greet error: ${e}`;
      });
  },
};
