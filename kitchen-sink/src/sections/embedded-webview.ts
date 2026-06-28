import { Webview } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct } from "../shell/ui";

const DEFAULT_URL = "https://example.com";

export const embeddedWebviewSection: Section = {
  id: "embedded-webview",
  label: "Embedded Webview",
  render(host) {
    // NOTE: card() renders title/intro as innerHTML, so the literal element
    // name MUST be HTML-escaped (&lt;zapp-webview&gt;). An unescaped
    // "<zapp-webview>" here would be parsed as a real custom element — a
    // phantom embed that spins up its own native panel.
    host.appendChild(card({
      title: "Embedded &lt;zapp-webview&gt;",
      intro:
        "A native embedded web view (&lt;zapp-webview&gt;) hosted inside this page — " +
        "a real WKWebView panel on macOS/iOS, positioned to track the box below. " +
        "Set a URL or reload to drive it.",
      buttons: [
        { act: "load", label: "Load URL" },
        { act: "reload", label: "Reload" },
      ],
    }));

    const input = document.createElement("input");
    input.type = "text";
    input.value = DEFAULT_URL;
    // font-size:16px (not smaller) so iOS does NOT auto-zoom the page on focus
    // — auto-zoom shifts the visual viewport and desyncs the native panel.
    input.style.cssText = "width:100%; box-sizing:border-box; margin:8px 0; font-family:monospace; font-size:16px; padding:6px;";
    host.appendChild(input);

    const frame = document.createElement("div");
    frame.style.cssText = "width:100%; height:360px; border:1px solid var(--border); border-radius:8px; overflow:hidden;";
    host.appendChild(frame);

    const wv = Webview.create({ src: DEFAULT_URL });
    wv.style.cssText = "width:100%; height:100%; display:block;";
    frame.appendChild(wv);

    onAct(host, "load", () => { const u = input.value.trim(); if (u) wv.loadURL(u); });
    onAct(host, "reload", () => wv.reload());

    return () => { wv.remove(); };
  },
};
