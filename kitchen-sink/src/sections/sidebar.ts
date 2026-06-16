import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const sidebarSection: Section = {
  id: "sidebar",
  label: "Sidebar",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Native Sidebar",
      intro: "A real NSSplitViewItem sidebar (this window's left nav). Toggling hides the nav; the toolbar's sidebar button brings it back.",
      buttons: [
        { act: "toggle", label: "Toggle" },
        { act: "w180", label: "Width 180" },
        { act: "w320", label: "Width 320" },
      ],
    }));
    onAct(host, "toggle", () => { win.sidebar?.toggle(); setResult(host, "toggled"); });
    onAct(host, "w180", () => { win.sidebar?.setWidth(180); setResult(host, "width → 180"); });
    onAct(host, "w320", () => { win.sidebar?.setWidth(320); setResult(host, "width → 320"); });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">observing…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.SIDEBAR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.on(WindowEvent.SIDEBAR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => off.forEach((fn) => fn());
  },
};
