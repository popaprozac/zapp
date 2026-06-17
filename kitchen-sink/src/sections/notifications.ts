import { Notification } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const notificationsSection: Section = {
  id: "notifications",
  label: "Notifications",
  render(host) {
    // Id of the last shown notification — Update/Remove target it.
    let lastId = "";
    host.appendChild(card({
      title: "Notifications",
      intro:
        "Native system notifications. Request permission first, then Show — " +
        "Update/Remove act on the last one. Dev runs inside the .app bundle, so " +
        "the notification center is available. Works on both builds.",
      buttons: [
        { act: "perm", label: "Request permission" },
        { act: "show", label: "Show" },
        { act: "update", label: "Update last" },
        { act: "remove", label: "Remove last" },
      ],
    }));
    onAct(host, "perm", async () => {
      setResult(host, `permission: ${await Notification.requestPermission()}`);
    });
    onAct(host, "show", async () => {
      lastId = await Notification.show({ title: "Kitchen Sink", body: "Hello from Zapp!" });
      setResult(host, `sent: ${lastId}`);
    });
    onAct(host, "update", async () => {
      if (!lastId) return setResult(host, "show one first");
      await Notification.update(lastId, {
        title: "Updated",
        body: `updated at ${new Date().toLocaleTimeString()}`,
      });
      setResult(host, `updated: ${lastId}`);
    });
    onAct(host, "remove", async () => {
      if (!lastId) return setResult(host, "nothing to remove");
      await Notification.removeDelivered(lastId);
      setResult(host, `removed: ${lastId}`);
      lastId = "";
    });
  },
};
