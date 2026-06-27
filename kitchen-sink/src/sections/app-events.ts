import { App, AppEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct } from "../shell/ui";

const MAX = 50;

export const appEventsSection: Section = {
  id: "app-events",
  label: "App Events",
  render(host) {
    host.appendChild(card({
      title: "App lifecycle & system events",
      intro:
        "A live log of APP-level events via App.on(...): theme change, " +
        "active/inactive, device lock/unlock, display changes, power/battery, " +
        "reopen, and open-url. Distinct from the Window log (window-scoped) and " +
        "the Events bus (app pub/sub). Toggle system dark mode, lock the device, " +
        "or change power to see events here.",
      buttons: [{ act: "clear", label: "Clear log" }],
      note:
        "<b>Platform note:</b> some events are platform-specific — " +
        "<code>will-sleep</code>/<code>did-wake</code> and <code>before-quit</code> " +
        "are macOS-only; <code>reopen</code> is macOS (dock click). On iOS, lock/unlock " +
        "fire only on devices with a passcode, and screens-changed needs an external display.",
    }));

    const power = document.createElement("div");
    power.className = "kv";
    power.style.cssText = "font-family:monospace; font-size:12px; margin:8px 0;";
    host.appendChild(power);
    const renderPower = () => {
      const p = App.getPowerState();
      power.textContent = `power: source=${p.source} charging=${p.charging} ` +
        `percent=${p.percent ?? "?"} lowPowerMode=${p.lowPowerMode}`;
    };
    renderPower();

    const log = document.createElement("div");
    log.className = "kv";
    log.style.cssText = "max-height:320px; overflow:auto; font-family:monospace; font-size:12px; line-height:1.5;";
    log.innerHTML = `<div class="muted" data-empty>waiting for app events…</div>`;
    host.appendChild(log);

    const append = (label: string, payload: unknown) => {
      log.querySelector("[data-empty]")?.remove();
      const row = document.createElement("div");
      const t = new Date().toLocaleTimeString();
      row.textContent = `${t}  ${label}  ${payload !== undefined && payload !== null ? JSON.stringify(payload) : ""}`.trimEnd();
      log.appendChild(row);
      while (log.childElementCount > MAX) log.firstElementChild!.remove();
      log.scrollTop = log.scrollHeight;
    };

    const sub = (ev: AppEvent, label: string) =>
      App.on(ev, (d?: any) => { append(label, d); });

    const off = [
      sub(AppEvent.THEME_CHANGED, "theme-changed"),
      sub(AppEvent.DID_BECOME_ACTIVE, "active"),
      sub(AppEvent.DID_RESIGN_ACTIVE, "inactive"),
      sub(AppEvent.SCREEN_LOCKED, "screen-locked"),
      sub(AppEvent.SCREEN_UNLOCKED, "screen-unlocked"),
      sub(AppEvent.SCREENS_CHANGED, "screens-changed"),
      sub(AppEvent.REOPEN, "reopen"),
      sub(AppEvent.OPEN_URL, "open-url"),
      App.on(AppEvent.POWER_STATE_CHANGED, (d?: any) => { append("power-state-changed", d); renderPower(); }),
      App.on(AppEvent.BATTERY_LEVEL_CHANGED, (d?: any) => { append("battery-level-changed", d); renderPower(); }),
    ];

    onAct(host, "clear", () => {
      log.innerHTML = `<div class="muted" data-empty>waiting for app events…</div>`;
    });

    return () => { off.forEach((fn) => fn()); };
  },
};
