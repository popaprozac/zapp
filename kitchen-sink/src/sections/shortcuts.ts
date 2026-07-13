import { Shortcuts, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult, inspectorPanel } from "../shell/ui";

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
      note: `The <b>inspector</b> shows registration status and logs every time <code>${ACCEL}</code> fires (even from another app).`,
    }));
    onAct(host, "register", async () => {
      const ok = await Shortcuts.register(ACCEL, () => {
        setResult(host, `fired at ${new Date().toLocaleTimeString()}`);
        // The handler runs in THIS (content) pane; relay to the inspector pane.
        Events.emit("ks:shortcut", { op: "fired", accel: ACCEL });
      });
      setResult(host, ok ? `registered ${ACCEL} — try it from any app` : "failed (already in use?)");
      Events.emit("ks:shortcut", { op: "register", accel: ACCEL, registered: ok });
    });
    onAct(host, "unregister", async () => {
      await Shortcuts.unregister(ACCEL);
      setResult(host, `unregistered ${ACCEL}`);
      Events.emit("ks:shortcut", { op: "unregister", accel: ACCEL, registered: false });
    });
    onAct(host, "is-registered", async () => {
      const registered = await Shortcuts.isRegistered(ACCEL);
      setResult(host, `isRegistered → ${registered}`);
      Events.emit("ks:shortcut", { op: "check", accel: ACCEL, registered });
    });
  },

  inspector(host) {
    let fires = 0;
    const p = inspectorPanel(host, {
      title: "Shortcut state",
      fields: [
        { key: "accel", label: "Accelerator", init: ACCEL },
        { key: "status", label: "Registered", init: "no" },
        { key: "fires", label: "Fire count", init: "0" },
      ],
      log: { title: "Fires", empty: `Register, then press ${ACCEL} from any app.` },
    });
    const off = Events.on("ks:shortcut", (m: any) => {
      if (m.op === "fired") {
        fires++;
        p.set("fires", String(fires));
        p.log("fired", new Date().toLocaleTimeString(), true);
      } else if (typeof m.registered === "boolean") {
        p.set("status", m.registered ? "yes" : "no");
      }
    });
    return () => off();
  },
};
