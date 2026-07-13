import { Notification, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult, inspectorPanel } from "../shell/ui";

// Category with an action button + text reply, so clicking an action (or
// replying) produces rich response metadata (actionId, userText) that the
// inspector pane logs.
const CATEGORY_ID = "ks-demo";

// Cross-pane channel: render() and inspector() run in SEPARATE webviews, so the
// render pane broadcasts lifecycle events (Events.emit → native t:3 → every
// pane) and the inspector subscribes. Clicks/actions arrive natively (broadcast
// to all panes), so the inspector reads those straight from Notification.on.
const short = (id: string) => (id ? id.slice(0, 8) : "—");

export const notificationsSection: Section = {
  id: "notifications",
  label: "Notifications",
  render(host) {
    // Id of the last shown notification — Update/Remove target it.
    let lastId = "";
    let lastMeta: { title: string; body: string; categoryId?: string } = { title: "", body: "" };

    // Register the demo category up front (best-effort — not every platform
    // supports actions; the plain Show path always works).
    Notification.registerCategory({
      id: CATEGORY_ID,
      actions: [{ id: "archive", title: "Archive" }],
      hasReplyField: true,
      replyPlaceholder: "Reply…",
      replyButtonTitle: "Send",
    }).catch(() => {});

    host.appendChild(card({
      title: "Notifications",
      intro:
        "Native system notifications. Request permission first, then Show — " +
        '"Show with actions" adds a Reply field + Archive button. Update/Remove ' +
        "act on the last one. Dev runs inside the .app bundle, so the " +
        "notification center is available. Works on both builds.",
      buttons: [
        { act: "perm", label: "Request permission" },
        { act: "show", label: "Show" },
        { act: "show-actions", label: "Show with actions" },
        { act: "update", label: "Update last" },
        { act: "remove", label: "Remove last" },
      ],
      note:
        "<b>Click a notification</b> (or use its Reply / Archive action) — the " +
        "<b>inspector</b> logs the full response metadata: id, actionId, reply text.",
    }));

    onAct(host, "perm", async () => {
      const status = await Notification.requestPermission();
      setResult(host, `permission: ${status}`);
      Events.emit("ks:notif", { kind: "permission", status });
    });
    onAct(host, "show", async () => {
      lastMeta = { title: "Kitchen Sink", body: "Hello from Zapp!" };
      lastId = await Notification.show({ ...lastMeta, data: { via: "show" } });
      setResult(host, `sent: ${lastId}`);
      Events.emit("ks:notif", { kind: "shown", id: lastId, ...lastMeta });
    });
    onAct(host, "show-actions", async () => {
      lastMeta = {
        title: "Kitchen Sink",
        body: "Reply or Archive to see action metadata",
        categoryId: CATEGORY_ID,
      };
      lastId = await Notification.show({ ...lastMeta, data: { via: "show-actions" } });
      setResult(host, `sent (with actions): ${lastId}`);
      Events.emit("ks:notif", { kind: "shown", id: lastId, ...lastMeta });
    });
    onAct(host, "update", async () => {
      if (!lastId) return setResult(host, "show one first");
      const body = `updated at ${new Date().toLocaleTimeString()}`;
      lastMeta = { ...lastMeta, title: "Updated", body };
      await Notification.update(lastId, { title: "Updated", body });
      setResult(host, `updated: ${lastId}`);
      Events.emit("ks:notif", { kind: "updated", id: lastId, ...lastMeta });
    });
    onAct(host, "remove", async () => {
      if (!lastId) return setResult(host, "nothing to remove");
      await Notification.removeDelivered(lastId);
      setResult(host, `removed: ${lastId}`);
      Events.emit("ks:notif", { kind: "removed", id: lastId });
      lastId = "";
    });
  },

  inspector(host) {
    const p = inspectorPanel(host, {
      title: "Notification state",
      fields: [
        { key: "perm", label: "Permission", init: "…" },
        { key: "last", label: "Last", init: "—" },
      ],
      log: {
        title: "Response log",
        empty: "Show a notification, then click it (or an action) to see the metadata here.",
      },
    });

    // Current permission (async authoritative snapshot).
    Notification.getPermissionStatus()
      .then((s) => p.set("perm", s))
      .catch(() => p.set("perm", "unavailable"));

    // Lifecycle from the render pane (separate webview, via Events broadcast).
    const offLc = Events.on("ks:notif", (m: any) => {
      if (m.kind === "permission") {
        p.set("perm", m.status);
      } else if (m.kind === "shown") {
        p.set("last", `${short(m.id)} — ${m.title}` + (m.categoryId ? ` [${m.categoryId}]` : ""));
        p.log("shown", short(m.id));
      } else if (m.kind === "updated") {
        p.set("last", `${short(m.id)} — ${m.title} (updated)`);
        p.log("updated", short(m.id));
      } else if (m.kind === "removed") {
        p.log("removed", short(m.id));
      }
    });

    // FLAGSHIP: notification clicks/actions broadcast natively to every pane.
    // Log the full response metadata whenever the user interacts with one.
    const offResp = Notification.on("response", (r: any) => {
      const isAction = r.actionId && r.actionId !== "DEFAULT";
      const label = isAction ? `action · ${r.actionId}` : "clicked";
      const parts = [`id ${short(r.id)}`];
      if (r.userText) parts.push(`reply “${r.userText}”`);
      if (r.categoryId) parts.push(`cat ${r.categoryId}`);
      p.log(label, parts.join(" · "), true);
    });

    return () => {
      offLc();
      offResp();
    };
  },
};
