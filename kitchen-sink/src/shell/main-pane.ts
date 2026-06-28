import { Window, Events, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";

export function renderMainPane(app: HTMLElement) {
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-drag-region>
      <span class="drag-strip-label">⠿ Kitchen Sink — drag to move</span>
    </div>`;
  app.innerHTML = `
    ${dragStrip}
    <div class="main-pane"><div class="stage" data-stage></div></div>`;

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  // On iOS this renders as a native UINavigationItem nav bar (T1/T1.5/T2).
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

  // Only act on this window's own sidebar (ks:nav is a global emit; match windowId).
  Events.on("ks:nav", ({ id, windowId }: any) => { if (windowId === Window.current().id) show(id); });

  if (registry[0]) show(registry[0].id); // self-init to Home (race-free, in-pane)
}
