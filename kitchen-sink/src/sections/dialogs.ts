import { Dialog, App, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult, inspectorPanel } from "../shell/ui";

const baseName = (p: string) => p.split(/[\\/]/).pop() || p;

export const dialogsSection: Section = {
  id: "dialogs",
  label: "Dialogs",
  render(host) {
    // Last picked/saved path — Reveal + Open act on it. Closure-scoped; a
    // re-render (nav away + back) resets it, which is fine for a demo.
    let lastPath = "";
    host.appendChild(card({
      title: "Dialogs",
      intro:
        "Native file open/save and message dialogs. Open/Save return absolute " +
        "paths; Reveal/Open act on the last picked path. Works the same on the " +
        "zc and Nim builds.",
      buttons: [
        { act: "open", label: "Open file" },
        { act: "save", label: "Save file" },
        { act: "message", label: "Message" },
        { act: "reveal", label: "Reveal last in Finder" },
        { act: "open-path", label: "Open last with default app" },
      ],
      note: "The <b>inspector</b> tracks the last picked path and logs each dialog result (button, path, cancellation).",
    }));
    const emit = (op: string, extra: Record<string, unknown> = {}) =>
      Events.emit("ks:dialog", { op, ...extra });
    onAct(host, "open", async () => {
      const r = await Dialog.openFile({ title: "Pick a file" });
      const picked = r.paths?.[0];
      if (r.cancelled || !picked) { setResult(host, "cancelled"); return emit("open", { cancelled: true }); }
      lastPath = picked;
      setResult(host, `opened: ${lastPath}`);
      emit("open", { path: lastPath, count: r.paths?.length ?? 1 });
    });
    onAct(host, "save", async () => {
      const r = await Dialog.saveFile({ title: "Save as", defaultName: "untitled.txt" });
      if (r.cancelled || !r.path) { setResult(host, "cancelled"); return emit("save", { cancelled: true }); }
      lastPath = r.path;
      setResult(host, `save path: ${lastPath}`);
      emit("save", { path: lastPath });
    });
    onAct(host, "message", async () => {
      const r = await Dialog.message({
        title: "Kitchen Sink",
        message: "A native message dialog.",
        buttons: ["OK", "Cancel"],
      });
      setResult(host, `button: ${r.button}`);
      emit("message", { button: r.button });
    });
    onAct(host, "reveal", () => {
      if (!lastPath) return setResult(host, "pick or save a file first");
      App.showItemInFolder(lastPath);
      setResult(host, `revealed: ${lastPath}`);
      emit("reveal", { path: lastPath });
    });
    onAct(host, "open-path", () => {
      if (!lastPath) return setResult(host, "pick or save a file first");
      App.openPath(lastPath);
      setResult(host, `opened with default app: ${lastPath}`);
      emit("open-path", { path: lastPath });
    });
  },

  inspector(host) {
    const p = inspectorPanel(host, {
      title: "Dialog state",
      fields: [{ key: "last", label: "Last path", init: "—" }],
      log: { title: "Results", empty: "Open/save a file or show a message to see results here." },
    });
    const off = Events.on("ks:dialog", (m: any) => {
      if (m.path) p.set("last", baseName(m.path));
      if (m.op === "open") p.log("open", m.cancelled ? "cancelled" : `${m.count} file(s) · ${baseName(m.path)}`, true);
      else if (m.op === "save") p.log("save", m.cancelled ? "cancelled" : baseName(m.path), true);
      else if (m.op === "message") p.log("message", `button: ${m.button}`, true);
      else if (m.op === "reveal") p.log("reveal", baseName(m.path));
      else if (m.op === "open-path") p.log("open with default", baseName(m.path));
    });
    return () => off();
  },
};
