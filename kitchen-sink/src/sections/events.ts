import { Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const eventsSection: Section = {
  id: "events",
  label: "Events",
  render(host) {
    let n = 0;
    host.appendChild(card({
      title: "Events bus",
      intro:
        "App-wide pub/sub over the native bridge — Events.emit/on. The same bus " +
        "the sidebar nav and popovers ride; emits fan out to every window/pane. " +
        "Emit here; the handler below (and any other open window) receives it.",
      buttons: [{ act: "emit", label: "Emit ks:demo-event" }],
    }));
    const off = Events.on("ks:demo-event", (d: any) =>
      setResult(host, `received → ${JSON.stringify(d)}`));
    onAct(host, "emit", () => {
      n++;
      Events.emit("ks:demo-event", { n, ts: Date.now() });
    });
    return () => off();
  },
};
