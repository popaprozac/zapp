import { Clipboard } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

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
    }));
    onAct(host, "write", async () => {
      const text = `Hello from Kitchen Sink at ${new Date().toLocaleTimeString()}`;
      await Clipboard.writeText(text);
      setResult(host, `wrote: ${text}`);
    });
    onAct(host, "read", async () => {
      const text = await Clipboard.readText();
      setResult(host, `read: ${text || "(empty)"}`);
    });
    onAct(host, "has-image", async () => {
      setResult(host, `has("image") → ${await Clipboard.has("image")}`);
    });
    onAct(host, "read-image", async () => {
      const bytes = await Clipboard.readImage();
      setResult(host, bytes ? `got ${bytes.length}-byte PNG` : "no image on clipboard");
    });
    onAct(host, "clear", async () => {
      await Clipboard.clear();
      setResult(host, "(cleared)");
    });
  },
};
