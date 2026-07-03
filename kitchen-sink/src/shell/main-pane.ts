import { Window, Platform, Services } from "@zappdev/runtime";
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
        <p>Pushed with <code>title: "Detail"</code> + a per-route <code>toolbar</code> override (R2′ #771):
        on iOS the nav bar shows the route title and a Share button instead of the window toolbar.
        Back-then-forward re-enters with the same chrome.</p>
        <p class="muted" data-detail-greet>greet: (tap the button)</p>
        <button id="ks-detail-greet">Invoke greet (bridge from route)</button>
        <button id="ks-pop">Back (router.pop)</button></div>`;
      stage.querySelector("#ks-pop")?.addEventListener("click", () => Window.current().router.pop());
      // G1: human-checkable proof that a pushed route webview has its own
      // live bridge transport slot (#771 G1-C/D) — Services.invoke works
      // from here exactly like it does from the home section.
      const detailGreetEl = stage.querySelector<HTMLElement>("[data-detail-greet]")!;
      stage.querySelector("#ks-detail-greet")?.addEventListener("click", () => {
        detailGreetEl.textContent = "greet: …";
        Services.invoke("greet", { name: "Detail route" })
          .then((msg) => {
            detailGreetEl.textContent = `greet → ${msg}`;
          })
          .catch((e) => {
            detailGreetEl.textContent = `greet error: ${e}`;
          });
      });
      console.log(`[ks] route /detail rendered (+${(performance.now() - t0).toFixed(0)}ms boot)`);
      return;
    }
    if (url === "/detail-clean") {
      // #771 R2' demo: navbar:{hidden:true} route — NO native chrome; the page
      // brings its own Back. Edge swipe-back must still work (research recipe).
      shownId = "";
      if (typeof teardown === "function") teardown();
      teardown = undefined;
      stage.innerHTML = `<div class="detail-page" style="padding:24px;padding-top:calc(var(--zapp-safe-area-top, 24px) + 8px)">
        <h2>Chrome-less route (/detail-clean)</h2>
        <p>The native nav bar is hidden for this route. Swipe from the left edge to go back — it must NOT freeze the UI.</p>
        <button id="ks-pop-clean">Back (router.pop)</button></div>`;
      stage.querySelector("#ks-pop-clean")?.addEventListener("click", () => Window.current().router.pop());
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

  // N3a per-route identity. On iOS native routing a PUSHED route VC's webview is
  // created with zapp.route set → it renders ITS fixed route and ignores
  // ROUTE_CHANGED (it's a depth snapshot). The ROOT content webview (no
  // zapp.route) re-renders only on LATERAL changes (section switch via replace /
  // collapse-to-root via popToRoot); drill-down push/pop is handled by the
  // pushed route webview. On desktop (N2b) there is one webview and content
  // swaps on every change.
  const g = globalThis as unknown as Record<symbol, unknown>;
  const myRoute = g[Symbol.for("zapp.route")] as string | undefined;

  win.router.on((e) => {
    if (Platform.isIOS) {
      if (myRoute) {
        // Fixed-route webview: never re-renders, but its toolbar back/fwd
        // items must still track live router state (#771 datum 3 sibling —
        // without this, pushed pages render back/fwd permanently disabled).
        syncToolbar(e.canGoBack, e.canGoForward);
        return;
      }
      // Root content webview re-renders only when the stack is at its ROOT depth
      // (canGoBack === false → a lateral section switch via replace, or a
      // collapse-to-root via popToRoot/pop). Drill-down pushes (canGoBack === true)
      // are owned by the pushed route VC's own webview, so the root stays put.
      if (!e.canGoBack) renderRoute(e.url);
    } else {
      renderRoute(e.url);             // desktop (N2b): content swaps on every change
    }
    syncToolbar(e.canGoBack, e.canGoForward);
  });

  if (Platform.isIOS && myRoute) {
    // Pushed route VC: render its own fixed route once, then seed the toolbar
    // back/fwd enabled state from the authoritative router snapshot (#771).
    renderRoute(myRoute);
    win.router.current()
      .then((snap) => syncToolbar(snap.canGoBack, snap.canGoForward))
      .catch(() => { /* best-effort */ });
  } else {
    // Root content webview (or desktop): show the current route immediately,
    // then correct to the authoritative route (restores a deep route on reload).
    renderRoute(win.router.url);
    syncToolbar(win.router.canGoBack, win.router.canGoForward);
    win.router.current().then((snap) => {
      renderRoute(snap.url);
      syncToolbar(snap.canGoBack, snap.canGoForward);
    }).catch(() => { /* best-effort restore */ });
  }

  // N3a demo: on iOS this pushes a real native VC (native routing is
  // default-on, #771 R3'); on macOS it's an in-window route (N2b). Isolated
  // from the section nav — lives in demoStrip, outside stage, so section
  // renders don't clear it.
  // R2' (#771 T8): the push carries per-route chrome — a `title` (stamped as
  // the pushed VC's navigationItem.title) and a `toolbar` override that
  // REPLACES the window toolbar for this route only (falls back on pop).
  // macOS ignores route chrome; the in-window SPA swap is unchanged.
  const detailBtn = document.createElement("button");
  detailBtn.textContent = "Push native route (/detail)";
  detailBtn.onclick = () =>
    Window.current().router.push({
      url: "/detail",
      title: "Detail",
      toolbar: [
        {
          id: "d-share",
          icon: "sf:square.and.arrow.up",
          label: "Share",
          placement: "trailing",
          action: () => console.log("[ks] /detail per-route Share tapped"),
        },
      ],
    });
  demoStrip.appendChild(detailBtn);

  const cleanBtn = document.createElement("button");
  cleanBtn.textContent = "Push chrome-less route";
  cleanBtn.onclick = () =>
    Window.current().router.push({ url: "/detail-clean", navbar: { hidden: true } });
  demoStrip.appendChild(cleanBtn);
}
