import { Events } from "@zappdev/runtime";
import { registry } from "../sections/registry";

export function renderSidebarPane(app: HTMLElement) {
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="sidebar-pane">
      <div class="sidebar-title">KITCHEN SINK</div>
      <nav>${registry.map((s) =>
        `<button class="nav-item" data-id="${s.id}">${s.label}</button>`).join("")}</nav>
    </div>`;
  const items = app.querySelectorAll<HTMLButtonElement>(".nav-item");
  items.forEach((el) =>
    el.addEventListener("click", () => {
      items.forEach((i) => i.classList.toggle("active", i === el));
      Events.emit("ks:nav", { id: el.dataset.id! });
    }));
}
