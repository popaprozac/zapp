import { Screen } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const screenSection: Section = {
  id: "screen",
  label: "Screen",
  render(host) {
    host.appendChild(card({
      title: "Screen / displays",
      intro:
        "Enumerate connected displays + geometry (top-left global coords). " +
        "Read-only; routes through __screen:* on both builds.",
      buttons: [
        { act: "all", label: "List displays" },
        { act: "primary", label: "Primary" },
        { act: "cursor", label: "Cursor point" },
      ],
    }));
    onAct(host, "all", async () => {
      const all = await Screen.getAll();
      const summary = all
        .map((d) => `${d.name} ${d.bounds.width}×${d.bounds.height}${d.isPrimary ? " (primary)" : ""}`)
        .join(" · ");
      setResult(host, `${all.length} display(s): ${summary}`);
    });
    onAct(host, "primary", async () => {
      const p = await Screen.getPrimary();
      setResult(host, p ? `primary: ${p.name} ${p.bounds.width}×${p.bounds.height} @${p.scaleFactor}x` : "none");
    });
    onAct(host, "cursor", async () => {
      const c = await Screen.getCursorPoint();
      setResult(host, `cursor @ ${c.x},${c.y} on ${c.display?.name ?? "?"}`);
    });
  },
};
