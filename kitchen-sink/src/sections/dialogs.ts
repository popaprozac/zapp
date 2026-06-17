import { Dialog, App } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

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
    }));
    onAct(host, "open", async () => {
      const r = await Dialog.openFile({ title: "Pick a file" });
      const picked = r.paths?.[0];
      if (r.cancelled || !picked) return setResult(host, "cancelled");
      lastPath = picked;
      setResult(host, `opened: ${lastPath}`);
    });
    onAct(host, "save", async () => {
      const r = await Dialog.saveFile({ title: "Save as", defaultName: "untitled.txt" });
      if (r.cancelled || !r.path) return setResult(host, "cancelled");
      lastPath = r.path;
      setResult(host, `save path: ${lastPath}`);
    });
    onAct(host, "message", async () => {
      const r = await Dialog.message({
        title: "Kitchen Sink",
        message: "A native message dialog.",
        buttons: ["OK", "Cancel"],
      });
      setResult(host, `button: ${r.button}`);
    });
    onAct(host, "reveal", () => {
      if (!lastPath) return setResult(host, "pick or save a file first");
      App.showItemInFolder(lastPath);
      setResult(host, `revealed: ${lastPath}`);
    });
    onAct(host, "open-path", () => {
      if (!lastPath) return setResult(host, "pick or save a file first");
      App.openPath(lastPath);
      setResult(host, `opened with default app: ${lastPath}`);
    });
  },
};
