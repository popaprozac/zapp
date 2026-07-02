import { Platform, Window } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { sectionForRoute } from "./route-map";

export function renderInspectorPane(app: HTMLElement) {
  // Fully transparent (html + body) so the native inspector glass shows through;
  // the opaque :root/html background would otherwise block it.
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip drag-strip--no-inset" data-zapp-drag-region></div>`;
  app.innerHTML = `
    ${dragStrip}
    <div class="inspector-pane">
      <div class="inspector-title">INSPECTOR</div>
      <div class="inspector-body" data-body>
        <p class="muted">Select a feature to see live state.</p>
      </div>
    </div>`;
  const body = app.querySelector<HTMLElement>("[data-body]")!;
  let teardown: void | (() => void);
  let shownId = "";

  const show = (id: string) => {
    if (id === shownId) return;          // already rendering this section
    shownId = id;
    if (typeof teardown === "function") teardown();
    teardown = undefined;
    const section = findSection(registry, id);
    body.innerHTML = "";
    if (section?.inspector) {
      teardown = section.inspector(body);
    } else {
      body.innerHTML = `<p class="muted">No inspector for this section.</p>`;
    }
  };

  Window.current().router.on((e) => show(sectionForRoute(e.url)));
  // Initial render: use the async authoritative snapshot, not the sync
  // `router.url` getter. A freshly-minted webview (e.g. the iPhone inspector
  // sheet/push) is a COLD JS context whose routerState cache starts empty
  // ("") — the sync getter would render the "no inspector" fallback before the
  // native route seed arrives. router.current() awaits the seed. (Warm panes —
  // iPad/macOS columns — already have the route from live ROUTE_CHANGED events.)
  Window.current().router.current().then((snap) => {
    show(sectionForRoute(snap.url));
    renderSafeAreaProbe(); // TEMP E1 instrumentation
  });
}

// TEMP E1 instrumentation: print env(safe-area-inset-*) as resolved inside
// this webview. Uses a probe element because env() is CSS-only.
function renderSafeAreaProbe(): void {
  const probe = document.createElement("div");
  probe.style.cssText =
    "position:fixed;top:env(safe-area-inset-top);left:env(safe-area-inset-left);" +
    "right:env(safe-area-inset-right);bottom:env(safe-area-inset-bottom);pointer-events:none;";
  document.body.appendChild(probe);
  const r = probe.getBoundingClientRect();
  const out = document.getElementById("e1-probe") ?? (() => {
    const el = document.createElement("pre");
    el.id = "e1-probe";
    el.style.cssText = "position:fixed;bottom:0;left:50%;transform:translateX(-50%);background:#000c;color:#0f0;padding:4px 8px;font-size:11px;z-index:9999;";
    document.body.appendChild(el);
    return el;
  })();
  out.textContent = `E1 env(): top=${Math.round(r.top)} left=${Math.round(r.left)} ` +
    `right=${Math.round(window.innerWidth - r.right)} bottom=${Math.round(window.innerHeight - r.bottom)}`;
  probe.remove();
}
window.addEventListener("resize", renderSafeAreaProbe); // TEMP E1 instrumentation
setInterval(renderSafeAreaProbe, 1000); // TEMP E1 instrumentation
