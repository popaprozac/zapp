import { Tray, type TrayHandle, Window } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// Module-scope: the tray is an app-global status item, created once and
// reused across section re-renders (nav away + back) until destroyed.
let tray: TrayHandle | undefined;

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
  },
};
