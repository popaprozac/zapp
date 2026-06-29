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
    <div class="main-pane">
      <div class="demo-strip" data-demo-strip></div>
      <div class="stage" data-stage></div>
    </div>`;

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  // On iOS this renders as a native UINavigationItem nav bar (N1).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  const demoStrip = app.querySelector<HTMLElement>("[data-demo-strip]")!;
  let teardown: void | (() => void);
  let shownId = "";

  // Boot-cost timestamp for the N3a /detail render timing signal.
  const t0 = performance.now();

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

  // renderRoute: handles /detail (N3a isolated demo) and delegates everything
  // else to the existing section nav. The section nav (21 sections) is
  // completely unchanged — only the /detail branch is new.
  const renderRoute = (url: string) => {
    if (url === "/detail") {
      // Reset the section idempotency guard — /detail isn't a section.
      shownId = "";
      if (typeof teardown === "function") teardown();
      teardown = undefined;
      stage.innerHTML = `<div class="detail-page" style="padding:24px">
        <h2>Detail route (/detail)</h2>
        <p>This is a native pushed view controller on iOS. Tap ‹ Back or swipe from the left edge to return.</p>
        <button id="ks-pop">Back (router.pop)</button></div>`;
      stage.querySelector("#ks-pop")?.addEventListener("click", () => Window.current().router.pop());
      console.log(`[ks] route /detail rendered (+${(performance.now() - t0).toFixed(0)}ms boot)`);
      return;
    }
    show(sectionForRoute(url));
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
    renderRoute(e.url);
    syncToolbar(e.canGoBack, e.canGoForward);
  });

  // First render: show home immediately (cache may be unseeded), then correct to
  // the authoritative route (restores a deep route after reload).
  renderRoute(win.router.url);
  syncToolbar(win.router.canGoBack, win.router.canGoForward);
  win.router.current().then((snap) => {
    renderRoute(snap.url);
    syncToolbar(snap.canGoBack, snap.canGoForward);
  }).catch(() => { /* best-effort restore */ });

  // N3a demo: on iOS (nativeRouting:true) this pushes a real native VC;
  // on macOS it's an in-window route (N2b). Isolated from the section nav —
  // lives in demoStrip, outside stage, so section renders don't clear it.
  const detailBtn = document.createElement("button");
  detailBtn.textContent = "Push native route (/detail)";
  detailBtn.onclick = () => Window.current().router.push("/detail");
  demoStrip.appendChild(detailBtn);
}
