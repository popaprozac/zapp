import { Screen, App, AppEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult, inspectorPanel } from "../shell/ui";

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
      note:
        "The <b>inspector</b> lists every display live and auto-refreshes on " +
        "<code>app:screens-changed</code> (plug/unplug a monitor or change resolution).",
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

  inspector(host) {
    const p = inspectorPanel(host, {
      title: "Displays",
      fields: [{ key: "count", label: "Connected", init: "…" }],
      log: { title: "Topology changes", empty: "Displays refresh here; changes are logged on app:screens-changed." },
    });

    // Render the current display list into a small table below the fields.
    const table = document.createElement("div");
    table.className = "insp-log";
    table.style.marginTop = "8px";
    host.querySelector(".kv")!.appendChild(table);

    const refresh = async (reason?: string) => {
      const all = await Screen.getAll().catch(() => []);
      p.set("count", String(all.length));
      table.innerHTML = all
        .map(
          (d) =>
            `<div class="insp-row"><b>${d.name}</b> <span class="muted">` +
            `${d.bounds.width}×${d.bounds.height} @${d.scaleFactor}x` +
            `${d.isPrimary ? " · primary" : ""} · (${d.bounds.x},${d.bounds.y})</span></div>`,
        )
        .join("");
      if (reason) p.log(reason, `${all.length} display(s)`, true);
    };
    refresh();

    // Auto-refresh when the display topology changes (the app event we dispatch
    // from WM_DISPLAYCHANGE on Windows / NSApplication.didChangeScreenParameters).
    const off = App.on(AppEvent.SCREENS_CHANGED, () => refresh("screens-changed"));
    return () => off();
  },
};
