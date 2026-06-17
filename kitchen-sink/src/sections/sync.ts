import { Sync } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// Sync is a one-shot rendezvous — like a condition variable, but the payoff
// is *cross-context*: a wait in this window resolves when any other window
// (or worker, or the backend) notifies the same key through native. Within a
// single webview you'd just use a Promise; Sync's value is that it crosses
// contexts.
export const syncSection: Section = {
  id: "sync",
  label: "Sync",
  render(host) {
    host.appendChild(card({
      title: "Sync — cross-context wait / notify",
      intro:
        "A one-shot rendezvous across windows/workers, routed through native. " +
        "Open a 2nd window first (Multi-window → \"New window (sidebar shell)\"), " +
        "click Wait here, then Notify in the other window — the wait resolves. " +
        "notifyAll wakes every waiter at once.",
      buttons: [
        { act: "wait", label: 'Wait for "demo" (10s)' },
        { act: "notify", label: 'Notify "demo" (one)' },
        { act: "notify-all", label: 'Notify "demo" (all)' },
      ],
    }));
    onAct(host, "wait", async () => {
      setResult(host, 'waiting for "demo"…');
      const r = await Sync.wait("demo", 10000);
      setResult(host, `resolved → ${r}`);
    });
    onAct(host, "notify", () => {
      Sync.notify("demo");
      setResult(host, 'notified "demo" (one)');
    });
    onAct(host, "notify-all", () => {
      Sync.notifyAll("demo");
      setResult(host, 'notified "demo" (all)');
    });
  },
};
