import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const inspectorSection: Section = {
  id: "inspector",
  label: "Inspector",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Native Inspector",
      intro: "A trailing NSSplitViewItem inspector. This section drives the very pane it reports into (right).",
      buttons: [
        { act: "toggle", label: "Toggle" },
        { act: "w360", label: "Width 360" },
      ],
    }));
    onAct(host, "toggle", () => { win.inspector?.toggle(); setResult(host, "toggled"); });
    onAct(host, "w360", () => { win.inspector?.setWidth(360); setResult(host, "width → 360"); });
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
