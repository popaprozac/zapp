import { Window, WindowEvent } from "@zappdev/runtime";
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
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">observing…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.SIDEBAR_COLLAPSED, () => {
        state.textContent = "collapsed";
      }),
      win.on(WindowEvent.SIDEBAR_EXPANDED, () => {
        state.textContent = "expanded";
      }),
      win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => {
        state.textContent = `width ${d.width}`;
      }),
    ];
    return () => off.forEach((fn) => fn());
  },
};
