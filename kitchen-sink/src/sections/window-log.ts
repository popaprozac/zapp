import { Window, WindowEvent, Events, AppEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct } from "../shell/ui";

const MAX = 50;

export const windowLogSection: Section = {
  id: "window-log",
  label: "Window log",
  render(host) {
    host.appendChild(card({
      title: "Window event log",
      intro:
        "A live, scrolling log of this window's geometry + lifecycle events " +
        "(resize, move, focus, blur, minimize, maximize, restore, fullscreen, " +
        "display changes). Distinct from the Events section (that's the app " +
        "pub/sub bus). Resize or move this window to see events here.",
      buttons: [{ act: "clear", label: "Clear log" }],
    }));
    const log = document.createElement("div");
    log.className = "kv";
    log.style.cssText = "max-height:320px; overflow:auto; font-family:monospace; font-size:12px; line-height:1.5;";
    log.innerHTML = `<div class="muted" data-empty>waiting for events…</div>`;
    host.appendChild(log);

    const append = (label: string, payload: unknown) => {
      log.querySelector("[data-empty]")?.remove();
      const row = document.createElement("div");
      const t = new Date().toLocaleTimeString();
      row.textContent = `${t}  ${label}  ${payload !== undefined ? JSON.stringify(payload) : ""}`.trimEnd();
      log.appendChild(row);
      while (log.childElementCount > MAX) log.firstElementChild!.remove();
      log.scrollTop = log.scrollHeight;
    };

    const win = Window.current();
    // WindowEvent members: window-scoped (filtered to this window by win.on)
    // AppEvent.SCREENS_CHANGED: app-scoped (displays added/removed/reconfigured)
    const off = [
      win.on(WindowEvent.RESIZE,      (d: any) => append("resize",      d)),
      win.on(WindowEvent.MOVE,        (d: any) => append("move",        d)),
      win.on(WindowEvent.FOCUS,       ()       => append("focus",       undefined)),
      win.on(WindowEvent.BLUR,        ()       => append("blur",        undefined)),
      win.on(WindowEvent.MINIMIZE,    ()       => append("minimize",    undefined)),
      win.on(WindowEvent.MAXIMIZE,    ()       => append("maximize",    undefined)),
      win.on(WindowEvent.RESTORE,     ()       => append("restore",     undefined)),
      win.on(WindowEvent.FULLSCREEN,  ()       => append("fullscreen",  undefined)),
      win.on(WindowEvent.UNFULLSCREEN,()       => append("unfullscreen",undefined)),
      Events.on(AppEvent.SCREENS_CHANGED, ()   => append("screens-changed", undefined)),
    ];

    onAct(host, "clear", () => {
      log.innerHTML = `<div class="muted" data-empty>waiting for events…</div>`;
    });

    return () => { off.forEach((fn) => fn()); };
  },
};
