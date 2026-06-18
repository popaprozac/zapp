import { Workers, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// The headless worker declared in zapp.config.ts (key "greeter") boots with
// the app and is addressed by id "h-greeter".
const WORKER_ID = "h-greeter";

export const workersSection: Section = {
  id: "workers",
  label: "Workers",
  render(host) {
    host.appendChild(card({
      title: "Headless JS worker",
      intro:
        "A background JS thread (zjs) that booted with the app — Zapp's marquee " +
        "feature. Send it messages, and — the differentiator — have it call a " +
        "native service from the worker thread via Services.invokeSync (C-call " +
        "speed, no event-loop hop). Replies come back over the Events bus. Runs " +
        "the same on the zc and Nim builds.",
      buttons: [
        { act: "ping", label: "Send ping" },
        { act: "service", label: "Invoke greet (from worker)" },
        { act: "open-window", label: "Open window from worker" },
        { act: "list", label: "Workers.list()" },
      ],
    }));
    onAct(host, "ping", () => {
      Workers.send(WORKER_ID, "ping", { from: "main", ts: Date.now() });
      setResult(host, "ping sent…");
    });
    onAct(host, "service", () => {
      Workers.send(WORKER_ID, "invoke-service", { name: "Kitchen Sink" });
      setResult(host, "asked worker to invoke greet…");
    });
    onAct(host, "open-window", () => {
      Workers.send(WORKER_ID, "open-window", {});
      setResult(host, "asked worker to open a window via async Services.invoke…");
    });
    onAct(host, "list", async () => {
      const list = await Workers.list();
      setResult(host, `Workers.list() → ${JSON.stringify(list)}`);
    });

    // Worker → main: the worker broadcasts its replies over the Events bus
    // (worker→webview fan-out). Unsubscribe on nav so handlers don't leak.
    const off = [
      Events.on("greeter:pong", (d: any) => setResult(host, `pong → ${JSON.stringify(d)}`)),
      Events.on("greeter:service-result", (d: any) =>
        setResult(host, `service-result → ${JSON.stringify(d)}`)),
      Events.on("greeter:open-window-result", (d: any) =>
        setResult(host, `open-window-result → ${JSON.stringify(d)}`)),
    ];
    return () => off.forEach((fn) => fn());
  },
};
