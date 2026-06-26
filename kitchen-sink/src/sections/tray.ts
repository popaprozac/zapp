import { Tray, type TrayHandle, type MenuItemDef, Window } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// Module-scope: the tray is an app-global status item, created once and
// reused across section re-renders (nav away + back) until destroyed.
let tray: TrayHandle | undefined;

// --- ActionContext demo tray ---
// A separate tray that demonstrates ctx.update (live checkbox toggle) and
// radioGroup (auto-moving checkmark) on a tray menu.
let demotray: TrayHandle | undefined;

// Track checkbox state for the ctx.update demo.
let notifyEnabled = true;

function demoMenu(): MenuItemDef[] {
  return [
    // radioGroup: ticking one option auto-unticks the others — no ctx.update needed.
    { id: "dt-low",  label: "Low priority",    radioGroup: "dt-priority", checked: false },
    { id: "dt-med",  label: "Medium priority",  radioGroup: "dt-priority", checked: true  },
    { id: "dt-high", label: "High priority",    radioGroup: "dt-priority", checked: false },
    { type: "separator" },
    // checkbox item: ctx.update flips the checkmark without rebuilding the whole menu.
    { id: "dt-notify", label: "Notifications", type: "checkbox",
      checked: notifyEnabled,
      action: (ctx) => {
        notifyEnabled = !notifyEnabled;
        ctx?.update({ checked: notifyEnabled });
      } },
    { type: "separator" },
    { label: "Quit", role: "quit" },
  ];
}

export const traySection: Section = {
  id: "tray",
  label: "Tray",
  render(host) {
    host.appendChild(card({
      title: "Tray (menu bar)",
      intro:
        "A menu-bar status item (NSStatusItem) with an SF Symbol icon + a menu. " +
        "Set its title/tooltip, swap the menu, destroy. Routes through tray:* on " +
        "both builds (macOS; look at the top-right of the menu bar).",
      buttons: [
        { act: "create", label: "Create tray" },
        { act: "title", label: 'Set title "5"' },
        { act: "clear-title", label: "Clear title" },
        { act: "swap", label: "Swap menu" },
        { act: "destroy", label: "Destroy" },
      ],
    }));
    onAct(host, "create", () => {
      if (tray) return setResult(host, "tray exists — destroy it first");
      tray = Tray.create({
        icon: "sf:bolt.fill",
        tooltip: "Kitchen Sink",
        menu: [
          { label: "Show window", action: () => { Window.current().show(); setResult(host, "menu: show"); } },
          { type: "separator" },
          { label: "Ping", action: () => setResult(host, "menu: ping") },
          { type: "separator" },
          { label: "Quit", role: "quit" },
        ],
      });
      setResult(host, `tray created: ${tray.id}`);
    });
    onAct(host, "title", () => {
      if (!tray) return setResult(host, "create one first");
      tray.setTitle("5"); setResult(host, 'title → "5"');
    });
    onAct(host, "clear-title", () => {
      if (!tray) return setResult(host, "no tray");
      tray.setTitle(""); setResult(host, "title cleared");
    });
    onAct(host, "swap", () => {
      if (!tray) return setResult(host, "no tray");
      tray.setMenu([
        { label: "Swapped " + new Date().toLocaleTimeString(), enabled: false },
        { type: "separator" },
        { label: "Quit", role: "quit" },
      ]);
      setResult(host, "menu swapped");
    });
    onAct(host, "destroy", () => {
      if (!tray) return setResult(host, "no tray");
      tray.destroy(); tray = undefined; setResult(host, "destroyed");
    });

    // --- ActionContext demo card ---
    host.appendChild(card({
      title: "ActionContext demo (tray menu)",
      intro:
        "Demonstrates ctx.update and radioGroup on a tray menu. " +
        "The priority items use radioGroup — ticking one auto-unticks the others. " +
        "The Notifications checkbox uses ctx.update({ checked }) to flip its own checkmark live.",
      buttons: [
        { act: "demo-create",  label: "Create demo tray" },
        { act: "demo-destroy", label: "Destroy demo tray" },
      ],
    }));
    onAct(host, "demo-create", () => {
      if (demotray) return setResult(host, "demo tray exists — destroy it first");
      demotray = Tray.create({
        icon: "sf:star.fill",
        tooltip: "ActionContext demo",
        menu: demoMenu(),
      });
      setResult(host, `demo tray created: ${demotray.id} — open it in the menu bar`);
    });
    onAct(host, "demo-destroy", () => {
      if (!demotray) return setResult(host, "no demo tray");
      demotray.destroy(); demotray = undefined;
      setResult(host, "demo tray destroyed");
    });
  },
};
