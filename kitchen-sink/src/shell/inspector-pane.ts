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

  const show = (id: string) => {
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
  show(sectionForRoute(Window.current().router.url)); // initial
}
