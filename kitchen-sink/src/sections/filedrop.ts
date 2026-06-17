import { Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, setResult } from "../shell/ui";

// Native file-drop events carry absolute paths as strings (DOM File objects
// don't expose paths). Payloads may arrive as an object or a JSON string.
function paths(d: any): string[] {
  const o = typeof d === "string" ? JSON.parse(d) : d;
  return o?.paths ?? [];
}

export const filedropSection: Section = {
  id: "filedrop",
  label: "File Drop",
  render(host) {
    host.appendChild(card({
      title: "File drop",
      intro:
        "Drag a file from Finder into this window. Native emits " +
        "file-drop-enter / file-drop-leave / file-drop window events with " +
        "absolute paths. Works on both builds (macOS).",
      buttons: [],
    }));
    const zone = document.createElement("div");
    zone.className = "result";
    zone.style.cssText =
      "min-height: 70px; border: 2px dashed currentColor; border-radius: 8px; " +
      "padding: 16px; text-align: center; opacity: 0.8; transition: background-color 0.15s;";
    zone.textContent = "Drop files anywhere in this window";
    host.appendChild(zone);

    const off = [
      Events.on("file-drop-enter", (d: any) => {
        zone.style.backgroundColor = "rgba(0,122,255,0.12)";
        zone.textContent = `dragging ${paths(d).length} file(s)…`;
      }),
      Events.on("file-drop-leave", () => {
        zone.style.backgroundColor = "";
        zone.textContent = "Drop files anywhere in this window";
      }),
      Events.on("file-drop", (d: any) => {
        const p = paths(d);
        zone.style.backgroundColor = "";
        zone.textContent = p.length === 1 ? p[0] : `${p.length} files`;
        setResult(host, `dropped: ${p.join(", ")}`);
      }),
    ];
    return () => off.forEach((fn) => fn());
  },
};
