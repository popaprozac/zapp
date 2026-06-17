import { Window } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// Each trigger try/catches: on the Nim build (no WindowManager yet) Window.create
// rejects — surface that as a clear note instead of a silent failure.
async function open(host: HTMLElement, label: string, fn: () => Promise<{ id: string }>) {
  try {
    const w = await fn();
    setResult(host, `${label} → ${w.id}`);
  } catch (e) {
    setResult(host, `${label} failed — likely needs WindowManager (zc build for now): ${e}`);
  }
}

export const multiwindowSection: Section = {
  id: "multiwindow",
  label: "Multi-window",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Windows & Sheets",
      intro: "Open additional windows. On the Nim build these are gated on the WindowManager port — the result line says so.",
      buttons: [
        { act: "plain", label: "New window" },
        { act: "small", label: "New window (small)" },
        { act: "vibrant", label: "Vibrancy (sidebar)" },
        { act: "sheet-page", label: "Sheet (page)" },
        { act: "sheet-form", label: "Sheet (form)" },
        { act: "sheet-bottom", label: "Bottom sheet" },
      ],
    }));
    onAct(host, "plain", () => open(host, "window", () =>
      Window.create({ title: "Kitchen Sink — Window", width: 800, height: 600, backgroundColor: "#1e1e1e" })));
    onAct(host, "small", () => open(host, "small window", () =>
      Window.create({ title: "Small", width: 400, height: 300 })));
    onAct(host, "vibrant", () => open(host, "vibrant window", () =>
      Window.create({ title: "Vibrancy", width: 480, height: 360, vibrancy: "sidebar", titleBarStyle: "hiddenInset" })));
    onAct(host, "sheet-page", () => open(host, "page sheet", () =>
      Window.create({ title: "Settings", width: 480, height: 600, asSheetOf: win, presentation: "page", grabber: true })));
    onAct(host, "sheet-form", () => open(host, "form sheet", () =>
      Window.create({ title: "Quick Add", width: 400, height: 300, asSheetOf: win, presentation: "form", grabber: true })));
    onAct(host, "sheet-bottom", () => open(host, "bottom sheet", () =>
      Window.create({ title: "Drawer", asSheetOf: win, presentation: "bottomSheet", detents: ["medium", "large"], grabber: true })));
  },
};
