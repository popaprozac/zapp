import { ContextMenu, type MenuItemDef } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, setResult } from "../shell/ui";

// Module state — context menus are rebuilt on each show, so the menu reflects
// these. (ctx.update is a no-op on context menus: they're dismissed on click.)
let sortBy = "name";
let showHidden = false;

function buildMenu(host: HTMLElement): MenuItemDef[] {
  return [
    { id: "cm-new", label: "New Item", action: () => setResult(host, "action: New Item") },
    { id: "cm-dup", label: "Duplicate", action: () => setResult(host, "action: Duplicate") },
    { type: "separator" },
    { id: "cm-sort-name", label: "Sort by Name", radioGroup: "cm-sort", checked: sortBy === "name",
      action: () => { sortBy = "name"; setResult(host, "sort → name"); } },
    { id: "cm-sort-date", label: "Sort by Date", radioGroup: "cm-sort", checked: sortBy === "date",
      action: () => { sortBy = "date"; setResult(host, "sort → date"); } },
    { id: "cm-sort-size", label: "Sort by Size", radioGroup: "cm-sort", checked: sortBy === "size",
      action: () => { sortBy = "size"; setResult(host, "sort → size"); } },
    { type: "separator" },
    { id: "cm-hidden", label: "Show Hidden", type: "checkbox", checked: showHidden,
      action: () => { showHidden = !showHidden; setResult(host, `show hidden → ${showHidden}`); } },
    { type: "separator" },
    { id: "cm-more", label: "More",
      submenu: [
        { id: "cm-export", label: "Export…", action: () => setResult(host, "action: Export") },
        { id: "cm-settings", label: "Settings…", action: () => setResult(host, "action: Settings") },
      ] },
  ];
}

export const contextMenuSection: Section = {
  id: "contextmenu",
  label: "Context menu",
  render(host) {
    host.appendChild(card({
      title: "Context menu (ContextMenu.show)",
      intro:
        "Right-click the area below (or use the button) to open a native context " +
        "menu. It's rebuilt on each show, so the radioGroup checkmark + checkbox " +
        "reflect the current state. Context menus are ephemeral — ctx.update is a " +
        "no-op here; the app holds the state and rebuilds.",
      buttons: [{ act: "show", label: "Show context menu (at button)" }],
    }));

    const target = document.createElement("div");
    target.textContent = "Right-click anywhere in this box";
    target.style.cssText =
      "margin-top:12px; padding:32px; border:1px dashed var(--border,#888); border-radius:10px; text-align:center; user-select:none; opacity:0.85;";
    host.appendChild(target);

    const onCtx = (e: MouseEvent) => { e.preventDefault(); ContextMenu.show(buildMenu(host), { event: e }); };
    target.addEventListener("contextmenu", onCtx);

    const btn = host.querySelector<HTMLButtonElement>('[data-act="show"]')!;
    const onBtn = (e: MouseEvent) => ContextMenu.show(buildMenu(host), { event: e });
    btn.addEventListener("click", onBtn);

    return () => { target.removeEventListener("contextmenu", onCtx); btn.removeEventListener("click", onBtn); };
  },
};
