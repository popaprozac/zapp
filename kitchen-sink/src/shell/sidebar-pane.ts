import { Events, Window, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";

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
  items.forEach((el) =>
    el.addEventListener("click", () => {
      items.forEach((i) => i.classList.toggle("active", i === el));
      // Scope the route to THIS window — Events.emit fans out across all
      // windows, so a secondary window's nav must not drive the main window.
      Events.emit("ks:nav", { id: el.dataset.id!, windowId: Window.current().id });
      // iPhone master-detail: reveal the content column full-screen.
      // No-op on macOS / iPad (panes are side-by-side); gated so the cost
      // is clearly iOS-only and the intent is explicit.
      if (Platform.isIOS) Window.current().sidebar?.showContent();
    }),
  );
  items[0]?.classList.add("active"); // mark Home active on launch (visual only; no emit)
}
