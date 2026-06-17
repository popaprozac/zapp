import { Dock } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const dockSection: Section = {
  id: "dock",
  label: "Dock",
  render(host) {
    let progressTimer: ReturnType<typeof setInterval> | undefined;
    host.appendChild(card({
      title: "Dock",
      intro:
        "The macOS Dock tile — badge, bounce, progress, hide/show. No-ops on " +
        "iOS/Windows. Routes through dock:* on both builds.",
      buttons: [
        { act: "badge", label: 'Badge "3"' },
        { act: "clear-badge", label: "Clear badge" },
        { act: "bounce", label: "Bounce (in 3s)" },
        { act: "progress", label: "Progress (animate)" },
        { act: "hide", label: "Hide icon" },
        { act: "show", label: "Show icon" },
      ],
    }));
    onAct(host, "badge", () => { Dock.setBadge("3"); setResult(host, 'badge → "3"'); });
    onAct(host, "clear-badge", () => { Dock.removeBadge(); setResult(host, "badge cleared"); });
    onAct(host, "bounce", () => {
      setResult(host, "bouncing in 3s — switch to another app to see it");
      setTimeout(() => Dock.bounce("critical"), 3000);
    });
    onAct(host, "progress", () => {
      if (progressTimer) clearInterval(progressTimer);
      let p = 0;
      setResult(host, "progress 0→100% (watch the Dock tile)");
      progressTimer = setInterval(() => {
        p += 0.1;
        if (p > 1.0001) {
          Dock.clearProgress();
          clearInterval(progressTimer!); progressTimer = undefined;
          return;
        }
        Dock.setProgress(p);
      }, 300);
    });
    onAct(host, "hide", () => { Dock.hideIcon(); setResult(host, "icon hidden"); });
    onAct(host, "show", () => { Dock.showIcon(); setResult(host, "icon shown"); });
    // Stop the animation if you navigate away mid-progress.
    return () => { if (progressTimer) clearInterval(progressTimer); };
  },
};
