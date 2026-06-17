import { Shortcuts } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

const ACCEL = "CmdOrCtrl+Shift+K";

export const shortcutsSection: Section = {
  id: "shortcuts",
  label: "Shortcuts",
  render(host) {
    host.appendChild(card({
      title: "Global shortcuts",
      intro:
        `Registers ${ACCEL} app-wide. Switch to another app and press it — the ` +
        "handler fires regardless of focus. Routes through __shortcuts:* on both builds.",
      buttons: [
        { act: "register", label: "Register" },
        { act: "unregister", label: "Unregister" },
        { act: "is-registered", label: "Is registered?" },
      ],
    }));
    onAct(host, "register", async () => {
      const ok = await Shortcuts.register(ACCEL, () => {
        setResult(host, `fired at ${new Date().toLocaleTimeString()}`);
      });
      setResult(host, ok ? `registered ${ACCEL} — try it from any app` : "failed (already in use?)");
    });
    onAct(host, "unregister", async () => {
      await Shortcuts.unregister(ACCEL);
      setResult(host, `unregistered ${ACCEL}`);
    });
    onAct(host, "is-registered", async () => {
      setResult(host, `isRegistered → ${await Shortcuts.isRegistered(ACCEL)}`);
    });
  },
};
