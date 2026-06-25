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

// Shared toolbar items for the three toolbar-style showcase windows.
const showcaseToolbarItems = () => [
  { id: "tb-back",    icon: "sf:chevron.left",  label: "Back" },
  { id: "tb-forward", icon: "sf:chevron.right", label: "Forward" },
  { id: "tb-refresh", icon: "sf:arrow.clockwise", label: "Refresh" },
];

export const multiwindowSection: Section = {
  id: "multiwindow",
  label: "Multi-window",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Windows & Sheets",
      intro: "Open additional windows. Works on both builds now (the WindowManager port landed on Nim). \"Sidebar shell\" opens a second full native-chrome window — the chrome-on-Nim demo.",
      buttons: [
        { act: "plain", label: "New window" },
        { act: "small", label: "New window (small)" },
        { act: "vibrant", label: "Vibrancy (sidebar)" },
        { act: "shell", label: "New window (sidebar shell)" },
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
    // A second full native-chrome shell (sidebar + inspector panes, same bundle
    // branched on the hash). Mounts native chrome on the Nim build too — the
    // chrome-on-Nim demo reachable from kitchen-sink itself.
    onAct(host, "shell", () => open(host, "sidebar-shell window", () =>
      Window.create({
        title: "Kitchen Sink — Shell 2", width: 1000, height: 680,
        // Match the main window's chrome so the 2nd shell looks identical:
        // hidden-inset unified titlebar (so the toolbar merges into it without a
        // height "readjust") + the native sidebar glass.
        titleBarStyle: "hiddenInset", vibrancy: "sidebar",
        sidebar: { url: "#sidebar-pane", width: 240 },
        inspector: { url: "#inspector-pane", width: 300, collapsed: true },
      })));
    onAct(host, "sheet-page", () => open(host, "page sheet", () =>
      Window.create({ title: "Settings", width: 480, height: 600, asSheetOf: win, presentation: "page", grabber: true })));
    onAct(host, "sheet-form", () => open(host, "form sheet", () =>
      Window.create({ title: "Quick Add", width: 400, height: 300, asSheetOf: win, presentation: "form", grabber: true })));
    onAct(host, "sheet-bottom", () => open(host, "bottom sheet", () =>
      Window.create({ title: "Drawer", asSheetOf: win, presentation: "bottomSheet", detents: ["medium", "large"], grabber: true })));

    // ── Background extension showcase ────────────────────────────────────────
    host.appendChild(card({
      title: "Background extension",
      intro: "Open demo windows that show backgroundExtension in action. Each window has a full-bleed gradient so the glass effect is clearly visible. macOS 26+ only; earlier versions show a plain sidebar.",
      buttons: [
        { act: "bg-mirror", label: "Background — Mirror" },
        { act: "bg-extend", label: "Background — Extend" },
      ],
    }));
    onAct(host, "bg-mirror", () => open(host, "bg-mirror window", () =>
      Window.create({
        title: "Background — Mirror",
        url: "#bg-demo=mirror",
        width: 900, height: 600,
        backgroundExtension: "mirror",
        sidebar: { url: "#sidebar-pane", width: 240 },
        titleBarStyle: "hiddenInset",
      })));
    onAct(host, "bg-extend", () => open(host, "bg-extend window", () =>
      Window.create({
        title: "Background — Extend",
        url: "#bg-demo=extend",
        width: 900, height: 600,
        backgroundExtension: "extend",
        sidebar: { url: "#sidebar-pane", width: 240 },
        titleBarStyle: "hiddenInset",
      })));

    // ── Title bar & toolbar showcase ─────────────────────────────────────────
    host.appendChild(card({
      title: "Title bar & toolbar",
      intro: "Launch five windows with distinct title-bar / toolbar configurations so they can be compared side by side. Each window names its own config.",
      buttons: [
        { act: "tb-standard",       label: "1. Standard title bar" },
        { act: "tb-hidden",         label: "2. Hidden title bar" },
        { act: "tb-unified",        label: "3. Unified toolbar" },
        { act: "tb-unified-compact", label: "4. Unified compact" },
        { act: "tb-expanded",       label: "5. Expanded toolbar" },
      ],
    }));

    // 1. Standard title bar — titleBarStyle: "default", no toolbar.
    onAct(host, "tb-standard", () => open(host, "standard title bar", () =>
      Window.create({
        title: "Standard title bar",
        url: "#titlebar-showcase/standard",
        titleBarStyle: "default",
        width: 460, height: 300,
      })));

    // 2. Hidden title bar — titleBarStyle: "hidden", no toolbar.
    onAct(host, "tb-hidden", () => open(host, "hidden title bar", () =>
      Window.create({
        title: "Hidden title bar",
        url: "#titlebar-showcase/hidden",
        titleBarStyle: "hidden",
        width: 460, height: 300,
      })));

    // 3. Unified toolbar — toolbar style "unified", 3 SF-symbol items.
    onAct(host, "tb-unified", () => open(host, "unified toolbar", () =>
      Window.create({
        title: "Unified toolbar",
        url: "#titlebar-showcase/unified",
        width: 460, height: 300,
        toolbar: { style: "unified", items: showcaseToolbarItems() },
      })));

    // 4. Unified compact — titleBarStyle "hiddenInset" + toolbar style "unifiedCompact".
    onAct(host, "tb-unified-compact", () => open(host, "unified compact", () =>
      Window.create({
        title: "Unified compact",
        url: "#titlebar-showcase/unified-compact",
        titleBarStyle: "hiddenInset",
        width: 460, height: 300,
        toolbar: { style: "unifiedCompact", items: showcaseToolbarItems() },
      })));

    // 5. Expanded toolbar — toolbar style "expanded" (icon + label row below title bar).
    onAct(host, "tb-expanded", () => open(host, "expanded toolbar", () =>
      Window.create({
        title: "Expanded toolbar",
        url: "#titlebar-showcase/expanded",
        width: 460, height: 300,
        toolbar: { style: "expanded", items: showcaseToolbarItems() },
      })));
  },
};
