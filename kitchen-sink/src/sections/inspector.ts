import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const inspectorSection: Section = {
  id: "inspector",
  label: "Inspector",
  render(host) {
    const win = Window.current();
    let collapsible = true;
    let resizable = true;
    host.appendChild(card({
      title: "Native Inspector",
      intro: "A trailing NSSplitViewItem inspector. This section drives the very pane it reports into (right). Collapse/resize gating toggles whether the user can collapse it or drag the divider.",
      buttons: [
        { act: "toggle", label: "Toggle" },
        { act: "w360", label: "Width 360" },
        { act: "collapsible", label: "Collapsible: on" },
        { act: "resizable", label: "Resizable: on" },
      ],
    }));
    onAct(host, "toggle", () => { win.inspector?.toggle(); setResult(host, "toggled"); });
    onAct(host, "w360", () => { win.inspector?.setWidth(360); setResult(host, "width → 360"); });
    onAct(host, "collapsible", () => {
      collapsible = !collapsible;
      win.inspector?.setCollapsible(collapsible);
      const btn = host.querySelector<HTMLButtonElement>('[data-act="collapsible"]');
      if (btn) btn.textContent = `Collapsible: ${collapsible ? "on" : "off"}`;
      setResult(host, `collapsible → ${collapsible}`);
    });
    onAct(host, "resizable", () => {
      resizable = !resizable;
      win.inspector?.setResizable(resizable);
      const btn = host.querySelector<HTMLButtonElement>('[data-act="resizable"]');
      if (btn) btn.textContent = `Resizable: ${resizable ? "on" : "off"}`;
      setResult(host, `resizable → ${resizable} (try dragging the divider)`);
    });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Inspector</b><div data-state class="muted">observing…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.INSPECTOR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.on(WindowEvent.INSPECTOR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.on(WindowEvent.INSPECTOR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => off.forEach((fn) => fn());
  },
};
