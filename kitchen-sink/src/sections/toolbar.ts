import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";
import { shellToolbar, filterMenu, filterStatusText, getFilter, setFilter } from "../shell/toolbar-def";

let composeEnabled = true;
let inboxCount = 0;

export const toolbarSection: Section = {
  id: "toolbar",
  label: "Toolbar",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Dynamic Toolbar",
      intro: "Mutates the native toolbar above. The Filter pull-down uses radioGroup — the checkmark moves automatically. The status label updates live via updateItem({text}). Remove/attach changes the titlebar height.",
      buttons: [
        { act: "toggle-compose", label: "Toggle Compose enabled" },
        { act: "cycle-filter", label: "Cycle filter (auto-radio checkmark + label update)" },
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
      // radioGroup auto-moves the checkmark; we still refresh the menu so
      // the initial checked states are correct on re-open after a manual cycle.
      win.toolbar.updateItem("filter", { menu: filterMenu() });
      // Live-update the label item text.
      win.toolbar.updateItem("status", { text: filterStatusText() });
      setResult(host, `filter → ${getFilter()} (radioGroup moved the checkmark; label updated)`);
    });
    onAct(host, "remove", () => {
      win.toolbar.remove();
      setResult(host, "toolbar removed — watch the titlebar shrink");
    });
    onAct(host, "attach", () => {
      composeEnabled = true;
      inboxCount = 0;
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
    host.innerHTML = `<div class="kv"><b>Toolbar</b><div data-state class="muted">click a toolbar item…</div><div data-group class="muted">group: —</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const group = host.querySelector<HTMLElement>("[data-group]")!;
    const offClick = win.on(WindowEvent.TOOLBAR_CLICKED, (p: any) => { state.textContent = `clicked: ${p.id}`; });
    const offGroup = win.on(WindowEvent.TOOLBAR_GROUP_SELECTED, (p: any) => {
      group.textContent = `group: id=${p.id} index=${p.index} selected=${JSON.stringify(p.selected)}`;
    });
    return () => { offClick(); offGroup(); };
  },
};
