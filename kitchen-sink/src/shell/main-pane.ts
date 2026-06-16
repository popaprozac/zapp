import { Window, Events, Services } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";

export async function renderMainPane(app: HTMLElement) {
  app.innerHTML = `
    <div class="main-pane">
      <div class="landing" data-landing>
        <h1>Kitchen Sink</h1>
        <p>Pick a feature in the sidebar. Each section has a trigger and a
           visible result; the inspector (right) shows live state.</p>
        <p class="muted" data-greet>greet: …</p>
      </div>
      <div class="stage" data-stage></div>
    </div>`;

  // Prove Services round-trips end-to-end inside the shell.
  const greetEl = app.querySelector("[data-greet]")!;
  try {
    const msg = await Services.invoke("greet", { name: "Kitchen Sink" });
    greetEl.textContent = `greet → ${msg}`;
  } catch (e) {
    greetEl.textContent = `greet error: ${e}`;
  }

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  const landing = app.querySelector<HTMLElement>("[data-landing]")!;
  let teardown: void | (() => void);

  Events.on("ks:nav", ({ id }: any) => {
    if (typeof teardown === "function") teardown();
    teardown = undefined;
    const section = findSection(registry, id);
    if (!section) return;
    landing.style.display = "none";
    stage.innerHTML = "";
    teardown = section.render(stage);
  });
}
