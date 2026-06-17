import { Window, Events } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";

export function renderMainPane(app: HTMLElement) {
  app.innerHTML = `<div class="main-pane"><div class="stage" data-stage></div></div>`;

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  let teardown: void | (() => void);

  const show = (id: string) => {
    if (typeof teardown === "function") teardown();
    teardown = undefined;
    const section = findSection(registry, id);
    if (!section) return;
    stage.innerHTML = "";
    teardown = section.render(stage);
  };

  Events.on("ks:nav", ({ id }: any) => show(id));
  if (registry[0]) show(registry[0].id);   // self-init to Home (race-free, in-pane)
}
