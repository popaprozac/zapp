import { Window, Events, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";

export function renderMainPane(app: HTMLElement) {
  // iPhone master-detail: there's no native toolbar to host a sidebar toggle,
  // so render an in-page "‹ Menu" control that drives the split view back to
  // the sidebar (showSidebar). Not rendered on macOS / iPad — both panes are
  // visible there, so a back affordance would be meaningless.
  const backControl = Platform.isIOS
    ? `<button data-back-to-sidebar
         style="position:fixed;top:12px;left:12px;z-index:10;padding:6px 12px;
                font:inherit;border-radius:8px;border:1px solid rgba(0,0,0,0.15);
                background:rgba(255,255,255,0.85);cursor:pointer">‹ Menu</button>`
    : "";
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-drag-region>
      <span class="drag-strip-label">⠿ Kitchen Sink — drag to move</span>
    </div>`;
  app.innerHTML = `
    ${dragStrip}
    ${backControl}
    <div class="main-pane"><div class="stage" data-stage></div></div>`;

  // iOS back-to-sidebar: reveal the primary (sidebar) column. No-op elsewhere
  // (the control isn't rendered off-iOS).
  app
    .querySelector<HTMLButtonElement>("[data-back-to-sidebar]")
    ?.addEventListener("click", () => Window.current().sidebar?.showSidebar());

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
  if (registry[0]) show(registry[0].id); // self-init to Home (race-free, in-pane)
}
