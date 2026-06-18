import { Dock } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const dockSection: Section = {
  id: "dock",
  label: "Dock",
  render(host) {
    let progressTimer: ReturnType<typeof setInterval> | undefined;
    const stopProgress = () => {
      if (progressTimer) {
        clearInterval(progressTimer);
        progressTimer = undefined;
      }
    };
    host.appendChild(
      card({
        title: "Dock",
        intro:
          "The macOS Dock tile — badge, bounce, progress, hide/show. Watch the " +
          "Dock icon (not the window) for the progress modes. No-ops on iOS/Windows. " +
          "Routes through dock:* on both builds.",
        buttons: [
          { act: "badge", label: 'Badge "3"' },
          { act: "clear-badge", label: "Clear badge" },
          { act: "bounce", label: "Bounce (in 3s)" },
          { act: "prog-normal", label: "Progress 0→100" },
          { act: "prog-indeterminate", label: "Indeterminate" },
          { act: "prog-error", label: "Error (60%)" },
          { act: "prog-paused", label: "Paused (40%)" },
          { act: "prog-clear", label: "Clear progress" },
          { act: "hide", label: "Hide icon" },
          { act: "show", label: "Show icon" },
        ],
      }),
    );
    onAct(host, "badge", () => {
      Dock.setBadge("3");
      setResult(host, 'badge → "3"');
    });
    onAct(host, "clear-badge", () => {
      Dock.removeBadge();
      setResult(host, "badge cleared");
    });
    onAct(host, "bounce", () => {
      setResult(host, "bouncing in 3s — switch to another app to see it");
      setTimeout(() => Dock.bounce("critical"), 3000);
    });
    // Normal: the app drives the fraction up — a determinate accent bar 0→100.
    onAct(host, "prog-normal", () => {
      stopProgress();
      let pct = 0;
      Dock.setProgress(0);
      setResult(host, "progress (normal) — animating 0→100 on the Dock icon");
      progressTimer = setInterval(() => {
        pct += 5;
        if (pct > 100) {
          Dock.clearProgress();
          stopProgress();
          setResult(host, "progress complete (cleared)");
          return;
        }
        Dock.setProgress(pct / 100);
      }, 200);
    });
    // Indeterminate: fraction ignored; native renders an animated sweep.
    onAct(host, "prog-indeterminate", () => {
      stopProgress();
      Dock.setProgress(0, { mode: "indeterminate" });
      setResult(host, "progress (indeterminate) — animated sweep on the Dock icon");
    });
    onAct(host, "prog-error", () => {
      stopProgress();
      Dock.setProgress(0.6, { mode: "error" });
      setResult(host, "progress (error) — red bar at 60%");
    });
    onAct(host, "prog-paused", () => {
      stopProgress();
      Dock.setProgress(0.4, { mode: "paused" });
      setResult(host, "progress (paused) — orange bar at 40%");
    });
    onAct(host, "prog-clear", () => {
      stopProgress();
      Dock.clearProgress();
      setResult(host, "progress cleared");
    });
    onAct(host, "hide", () => {
      Dock.hideIcon();
      setResult(host, "icon hidden");
    });
    onAct(host, "show", () => {
      Dock.showIcon();
      setResult(host, "icon shown");
    });
    // Stop the animation if you navigate away mid-progress.
    return () => {
      stopProgress();
    };
  },
};
