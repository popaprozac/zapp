/** Standalone pane for the "Title bar & toolbar showcase" windows.
 *
 * Opened via Window.create({ url: "#titlebar-showcase/<config>" }) from the
 * Multi-window section. Each config is self-describing so windows are easy
 * to compare side by side.
 */

const CONFIGS: Record<string, { name: string; desc: string }> = {
  standard: {
    name: "Standard title bar",
    desc: "titleBarStyle: \"default\" — the classic macOS opaque title bar. Title text is centred in the bar; traffic-light buttons sit in the left inset.",
  },
  hidden: {
    name: "Hidden title bar",
    desc: "titleBarStyle: \"hidden\" — the title bar chrome is invisible; web content fills the full window height from the top edge. Traffic lights float over the content.",
  },
  unified: {
    name: "Unified toolbar",
    desc: "toolbar style: \"unified\" — toolbar merges into the title bar producing a single band. Standard height. Items: Back, Forward, Refresh.",
  },
  "unified-compact": {
    name: "Unified compact toolbar",
    desc: "titleBarStyle: \"hiddenInset\" + toolbar style: \"unifiedCompact\" — a shorter merged toolbar/title-bar band. Great for utility windows.",
  },
  expanded: {
    name: "Expanded toolbar",
    desc: "toolbar style: \"expanded\" — toolbar is separate from (below) the title bar; items show icon + label text. Same look as Finder in icon view.",
  },
};

export function renderTitlebarShowcasePane(app: HTMLElement) {
  // Extract config key from hash: "#titlebar-showcase/unified-compact" → "unified-compact"
  const hash = location.hash; // e.g. "#titlebar-showcase/unified-compact"
  const key = hash.split("/")[1] ?? "standard";
  const cfg = CONFIGS[key] ?? CONFIGS["standard"]!;

  app.innerHTML = `
    <div style="
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      min-height: 100vh; padding: 32px 40px; box-sizing: border-box; text-align: center;
      background: var(--bg); color: var(--text);
    ">
      <div style="
        font-size: 22px; font-weight: 700; color: var(--text-h); margin-bottom: 14px;
        line-height: 1.3;
      ">${cfg.name}</div>
      <div style="
        font-size: 13px; line-height: 1.6; color: var(--text);
        max-width: 340px; opacity: 0.85;
      ">${cfg.desc}</div>
      <div style="
        margin-top: 28px; font-size: 11px; opacity: 0.4; font-family: monospace; letter-spacing: 0.03em;
      ">config: ${key}</div>
    </div>`;
}
