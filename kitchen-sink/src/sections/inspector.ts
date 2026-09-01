import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";
import { paneState } from "../shell/pane-state";

export const inspectorSection: Section = {
  id: "inspector",
  label: "Inspector",
  render(host) {
    const win = Window.current();
    const pane = paneState.get(win.id).inspector;
    host.appendChild(card({
      title: "Native Inspector",
      intro: "A trailing NSSplitViewItem inspector. This section drives the very pane it reports into (right). Collapse/resize gating toggles whether the user can collapse it or drag the divider.",
      buttons: [
        { act: "toggle", label: "Toggle" },
        { act: "w360", label: "Width 360" },
        { act: "collapsible", label: `Collapsible: ${pane.collapsible ? "on" : "off"}` },
        { act: "resizable", label: `Resizable: ${pane.resizable ? "on" : "off"}` },
      ],
    }));
    onAct(host, "toggle", () => { win.inspector?.toggle(); setResult(host, "toggled"); });
    onAct(host, "w360", () => { win.inspector?.setWidth(360); setResult(host, "width → 360"); });
    onAct(host, "collapsible", () => {
      pane.collapsible = !pane.collapsible;
      win.inspector?.setCollapsible(pane.collapsible);
      const btn = host.querySelector<HTMLButtonElement>('[data-act="collapsible"]');
      if (btn) btn.textContent = `Collapsible: ${pane.collapsible ? "on" : "off"}`;
      setResult(host, `collapsible → ${pane.collapsible}`);
    });
    onAct(host, "resizable", () => {
      pane.resizable = !pane.resizable;
      win.inspector?.setResizable(pane.resizable);
      const btn = host.querySelector<HTMLButtonElement>('[data-act="resizable"]');
      if (btn) btn.textContent = `Resizable: ${pane.resizable ? "on" : "off"}`;
      setResult(host, `resizable → ${pane.resizable} (try dragging the divider)`);
    });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Inspector</b><div data-state class="muted">Live — collapse, expand, or drag the inspector to see state.</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const subscriptions = [
      win.subscribe(WindowEvent.INSPECTOR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.subscribe(WindowEvent.INSPECTOR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.subscribe(WindowEvent.INSPECTOR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => subscriptions.forEach((subscription) => subscription.unsubscribe());
  },
};
