import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";
import { shellToolbar, filterMenu, getFilter, setFilter } from "../shell/toolbar-def";

let composeEnabled = true;
let inboxCount = 0;

export const toolbarSection: Section = {
  id: "toolbar",
  label: "Toolbar",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Dynamic Toolbar",
      intro: "Mutates the native toolbar above. The Filter button's checkmark moves via updateItem; remove/attach changes the titlebar height.",
      buttons: [
        { act: "toggle-compose", label: "Toggle Compose enabled" },
        { act: "cycle-filter", label: "Cycle filter (moving checkmark)" },
        { act: "remove", label: "Remove toolbar" },
        { act: "attach", label: "Attach toolbar" },
        { act: "badge-inc", label: "Inbox badge +1" },
        { act: "badge-clear", label: "Clear inbox badge" },
      ],
    }));
    onAct(host, "toggle-compose", () => {
      composeEnabled = !composeEnabled;
      win.toolbar.updateItem("compose", { enabled: composeEnabled });
      setResult(host, `compose enabled: ${composeEnabled}`);
    });
    onAct(host, "cycle-filter", () => {
      const order = ["all", "unread", "flagged"];
      setFilter(order[(order.indexOf(getFilter()) + 1) % order.length]);
      win.toolbar.updateItem("filter", { menu: filterMenu() });
      setResult(host, `filter → ${getFilter()} (reopen the Filter menu to see the checkmark move)`);
    });
    onAct(host, "remove", () => {
      win.toolbar.remove();
      setResult(host, "toolbar removed — watch the titlebar shrink");
    });
    onAct(host, "attach", () => {
      composeEnabled = true;
      win.toolbar.setItems(shellToolbar());
      setResult(host, "toolbar attached — titlebar grows back");
    });
    onAct(host, "badge-inc", () => {
      inboxCount += 1;
      win.toolbar.updateItem("inbox", { badge: { count: inboxCount } });
      setResult(host, `inbox badge → ${inboxCount}`);
    });
    onAct(host, "badge-clear", () => {
      inboxCount = 0;
      win.toolbar.updateItem("inbox", { badge: null });
      setResult(host, "inbox badge cleared");
    });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Toolbar</b><div data-state class="muted">click a toolbar item…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = win.on(WindowEvent.TOOLBAR_CLICKED, (p: any) => { state.textContent = `clicked: ${p.id}`; });
    return () => off();
  },
};
