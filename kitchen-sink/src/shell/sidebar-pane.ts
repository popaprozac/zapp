import { Window, Platform } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { routeForSection, sectionForRoute } from "./route-map";

export function renderSidebarPane(app: HTMLElement) {
  // Chrome panes must be fully transparent (html + body) so the native sidebar
  // glass — and any content mirror behind it (backgroundExtension) — shows
  // through. Body alone isn't enough: the opaque :root/html background blocks it.
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  // Windows caption buttons live top-RIGHT (over the content/inspector), so the
  // The drag-strip reserves the window-control inset per platform/pane from the
  // framework CSS vars (macOS traffic lights on the leading pane; Windows caption
  // buttons on the rightmost pane) — no per-pane class needed.
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-titlebar></div>`;
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

  // Click → navigate to the section's route.
  //   • Desktop (N2b): router.push — browser-history navigation.
  //   • iOS native routing: sidebar selection is LATERAL (a top-level switch),
  //     NOT a drill-down. popToRoot collapses any pushed route VC, then replace
  //     sets the section as the root — depth stays 1, so no native VC stacks.
  //     Genuine drill-downs (e.g. /detail) still use router.push → a native VC.
  items.forEach((el) =>
    el.addEventListener("click", () => {
      const route = routeForSection(el.dataset.id!);
      const r = Window.current().router;
      if (Platform.isIOS) {
        r.popToRoot();      // collapse any drill-down back to the section root
        r.replace(route);   // set this section as the (lateral) root route
        Window.current().sidebar?.showContent(); // reveal the content column
      } else {
        r.push(route);
      }
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
