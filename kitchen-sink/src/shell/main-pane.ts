import { Window, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";
import { sectionForRoute } from "./route-map";

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
  // On iOS this renders as a native UINavigationItem nav bar (N1).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  let teardown: void | (() => void);
  let shownId = "";

  const show = (id: string) => {
    if (id === shownId) return;          // already rendering this section
    if (typeof teardown === "function") teardown();
    teardown = undefined;
    const section = findSection(registry, id);
    if (!section) return;
    shownId = id;
    stage.innerHTML = "";
    teardown = section.render(stage);
  };

  const win = Window.current();
  const syncToolbar = (canGoBack: boolean, canGoForward: boolean) => {
    try {
      win.toolbar.updateItem("back", { enabled: canGoBack });
      win.toolbar.updateItem("fwd",  { enabled: canGoForward });
    } catch { /* toolbar not ready — ignore */ }
  };

  // Render on every route change (sidebar click, toolbar back/forward, etc.).
  win.router.on((e) => {
    show(sectionForRoute(e.url));
    syncToolbar(e.canGoBack, e.canGoForward);
  });

  // First render: show home immediately (cache may be unseeded), then correct to
  // the authoritative route (restores a deep route after reload).
  show(sectionForRoute(win.router.url));
  syncToolbar(win.router.canGoBack, win.router.canGoForward);
  win.router.current().then((snap) => {
    show(sectionForRoute(snap.url));
    syncToolbar(snap.canGoBack, snap.canGoForward);
  }).catch(() => { /* best-effort restore */ });
}
