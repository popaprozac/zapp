import { Window, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const sidebarSection: Section = {
  id: "sidebar",
  label: "Sidebar",
  render(host) {
    const win = Window.current();
    let collapsible = true;
    let resizable = true;
    host.appendChild(
      card({
        title: "Native Sidebar",
        intro:
          "A real NSSplitViewItem sidebar (this window's left nav). Toggling hides the nav; the toolbar's sidebar button brings it back. Collapse/resize gating controls whether the user can collapse it or drag the divider (set at create time too, via sidebar.collapsible / sidebar.resizable).",
        buttons: [
          { act: "toggle", label: "Toggle" },
          { act: "w180", label: "Width 180" },
          { act: "w320", label: "Width 320" },
          { act: "collapsible", label: "Collapsible: on" },
          { act: "resizable", label: "Resizable: on" },
        ],
      }),
    );
    onAct(host, "toggle", () => {
      win.sidebar?.toggle();
      setResult(host, "toggled");
    });
    onAct(host, "w180", () => {
      win.sidebar?.setWidth(180);
      setResult(host, "width → 180");
    });
    onAct(host, "w320", () => {
      win.sidebar?.setWidth(320);
      setResult(host, "width → 320");
    });
    onAct(host, "collapsible", () => {
      collapsible = !collapsible;
      win.sidebar?.setCollapsible(collapsible);
      const btn = host.querySelector<HTMLButtonElement>(
        '[data-act="collapsible"]',
      );
      if (btn) btn.textContent = `Collapsible: ${collapsible ? "on" : "off"}`;
      setResult(host, `collapsible → ${collapsible}`);
    });
    onAct(host, "resizable", () => {
      resizable = !resizable;
      win.sidebar?.setResizable(resizable);
      const btn = host.querySelector<HTMLButtonElement>(
        '[data-act="resizable"]',
      );
      if (btn) btn.textContent = `Resizable: ${resizable ? "on" : "off"}`;
      setResult(host, `resizable → ${resizable} (try dragging the divider)`);
    });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">Live — collapse, expand, or drag the sidebar to see state.</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    // SIDEBAR_* events don't reach the inspector pane directly (framework #627:
    // zapp_pane_emit fans out to main + sidebar panes only). The main pane relays
    // them over the Events bus as ks:sidebar-state; match windowId so other
    // windows don't cross-drive this inspector.
    const off = Events.on("ks:sidebar-state", ({ state: s, width, windowId }: any) => {
      if (windowId !== win.id) return;
      state.textContent = s === "resized" ? `width ${width}` : s; // "collapsed" | "expanded"
    });
    return () => off();
  },
};
