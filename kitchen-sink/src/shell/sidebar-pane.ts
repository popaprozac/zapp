import { Events, Window, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";

export function renderSidebarPane(app: HTMLElement) {
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="drag-strip" data-zapp-drag-region></div>
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
      Events.emit("ks:nav", { id: el.dataset.id! });
      // iPhone master-detail: reveal the content column full-screen.
      // No-op on macOS / iPad (panes are side-by-side); gated so the cost
      // is clearly iOS-only and the intent is explicit.
      if (Platform.isIOS) Window.current().sidebar?.showContent();
    }),
  );
  items[0]?.classList.add("active"); // mark Home active on launch (visual only; no emit)
}
