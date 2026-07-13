import { Clipboard, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult, inspectorPanel } from "../shell/ui";

export const clipboardSection: Section = {
  id: "clipboard",
  label: "Clipboard",
  render(host) {
    host.appendChild(card({
      title: "Clipboard",
      intro:
        "Read and write the system clipboard — text and images. Copy an image " +
        "somewhere first to exercise the image path. Works the same on the zc " +
        "and Nim builds.",
      buttons: [
        { act: "write", label: "Write text" },
        { act: "read", label: "Read text" },
        { act: "has-image", label: "Has image?" },
        { act: "read-image", label: "Read image (PNG bytes)" },
        { act: "clear", label: "Clear" },
      ],
      note: "The <b>inspector</b> tracks the last operation, a text preview, and the last image size.",
    }));
    const emit = (op: string, extra: Record<string, unknown> = {}) =>
      Events.emit("ks:clip", { op, ...extra });
    onAct(host, "write", async () => {
      const text = `Hello from Kitchen Sink at ${new Date().toLocaleTimeString()}`;
      await Clipboard.writeText(text);
      setResult(host, `wrote: ${text}`);
      emit("write", { text });
    });
    onAct(host, "read", async () => {
      const text = await Clipboard.readText();
      setResult(host, `read: ${text || "(empty)"}`);
      emit("read", { text });
    });
    onAct(host, "has-image", async () => {
      const hasImage = await Clipboard.has("image");
      setResult(host, `has("image") → ${hasImage}`);
      emit("has-image", { hasImage });
    });
    onAct(host, "read-image", async () => {
      const bytes = await Clipboard.readImage();
      setResult(host, bytes ? `got ${bytes.length}-byte PNG` : "no image on clipboard");
      emit("read-image", { imageBytes: bytes ? bytes.length : 0 });
    });
    onAct(host, "clear", async () => {
      await Clipboard.clear();
      setResult(host, "(cleared)");
      emit("clear");
    });
  },

  inspector(host) {
    const p = inspectorPanel(host, {
      title: "Clipboard state",
      fields: [
        { key: "text", label: "Text", init: "—" },
        { key: "image", label: "Last image", init: "—" },
      ],
      log: { title: "Operations", empty: "Read/write the clipboard to see operations here." },
    });
    const preview = (t: string) => (t.length > 48 ? t.slice(0, 48) + "…" : t);
    const off = Events.on("ks:clip", (m: any) => {
      switch (m.op) {
        case "write":
          p.set("text", `“${preview(m.text)}”`);
          p.log("write", `${m.text.length} chars`);
          break;
        case "read":
          p.set("text", m.text ? `“${preview(m.text)}”` : "(empty)");
          p.log("read", m.text ? `${m.text.length} chars` : "(empty)", true);
          break;
        case "has-image":
          p.log("has image?", String(m.hasImage), true);
          break;
        case "read-image":
          p.set("image", m.imageBytes ? `${m.imageBytes.toLocaleString()} bytes (PNG)` : "none");
          p.log("read image", m.imageBytes ? `${m.imageBytes.toLocaleString()} bytes` : "none", true);
          break;
        case "clear":
          p.set("text", "(cleared)");
          p.set("image", "—");
          p.log("clear", "");
          break;
      }
    });
    return () => off();
  },
};
