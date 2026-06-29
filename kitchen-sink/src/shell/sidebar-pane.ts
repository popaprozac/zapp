import { Window, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { routeForSection, sectionForRoute } from "./route-map";

export function renderSidebarPane(app: HTMLElement) {
  // Chrome panes must be fully transparent (html + body) so the native sidebar
  // glass — and any content mirror behind it (backgroundExtension) — shows
  // through. Body alone isn't enough: the opaque :root/html background blocks it.
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-drag-region></div>`;
  app.innerHTML = `
    ${dragStrip}
    <div class="sidebar-pane">
      <div class="sidebar-title">KITCHEN SINK</div>
      <nav>${registry
        .map(
          (s) =>
            `<button class="nav-item" data-id="${s.id}">${s.label}</button>`,
        )
        .join("")}</nav>
    </div>`;
  const items = app.querySelectorAll<HTMLButtonElement>(".nav-item");

  // Click → router.push the section's route. The native stack fans out
  // ROUTE_CHANGED to every pane; we don't toggle .active here (see below).
  items.forEach((el) =>
    el.addEventListener("click", () => {
      Window.current().router.push(routeForSection(el.dataset.id!));
      // iPhone master-detail: reveal the content column full-screen.
      if (Platform.isIOS) Window.current().sidebar?.showContent();
    }),
  );

  // Highlight follows the current route, so back/forward move it too (#666).
  const applyActive = (url: string) => {
    const sectionId = sectionForRoute(url);
    items.forEach((i) => i.classList.toggle("active", i.dataset.id === sectionId));
  };
  Window.current().router.on((e) => applyActive(e.url));
  applyActive(Window.current().router.url); // initial (cache → "" → home)
}
