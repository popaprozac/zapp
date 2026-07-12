import { Notification, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// Category with an action button + text reply, so clicking an action (or
// replying) produces rich response metadata (actionId, userText) that the
// inspector pane logs.
const CATEGORY_ID = "ks-demo";

// Cross-pane channel: render() and inspector() run in SEPARATE webviews, so the
// render pane broadcasts lifecycle events (Events.emit → native t:3 → every
// pane) and the inspector subscribes. Clicks/actions arrive natively (broadcast
// to all panes), so the inspector reads those straight from Notification.on.
const esc = (s: unknown) => String(s).replace(/[<&]/g, (c) => (c === "<" ? "&lt;" : "&amp;"));
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
    host.innerHTML = `
      <div class="kv">
        <b>Notification state</b>
        <div class="muted" data-perm>Permission: …</div>
        <div class="muted" data-last>Last: —</div>
      </div>
      <div class="kv" style="margin-top:14px">
        <b>Response log</b>
        <div class="notif-log" data-log>
          <p class="muted" data-empty>Show a notification, then click it (or an action) to see the metadata here.</p>
        </div>
      </div>`;
    const perm = host.querySelector<HTMLElement>("[data-perm]")!;
    const last = host.querySelector<HTMLElement>("[data-last]")!;
    const log = host.querySelector<HTMLElement>("[data-log]")!;

    const append = (label: string, detail: string, hit = false) => {
      log.querySelector("[data-empty]")?.remove();
      const row = document.createElement("div");
      row.className = "notif-row" + (hit ? " notif-row--hit" : "");
      const t = new Date().toLocaleTimeString();
      row.innerHTML =
        `<span class="notif-t">${t}</span> <b>${esc(label)}</b>` +
        (detail ? ` <span class="muted">${detail}</span>` : "");
      log.insertBefore(row, log.firstChild);
      while (log.childElementCount > 40) log.lastElementChild!.remove();
    };

    // Current permission (async authoritative snapshot).
    Notification.getPermissionStatus()
      .then((s) => (perm.textContent = `Permission: ${s}`))
      .catch(() => (perm.textContent = "Permission: unavailable"));

    // Lifecycle from the render pane (separate webview, via Events broadcast).
    const offLc = Events.on("ks:notif", (p: any) => {
      if (p.kind === "permission") {
        perm.textContent = `Permission: ${p.status}`;
      } else if (p.kind === "shown") {
        last.textContent =
          `Last: ${short(p.id)} — ${p.title}` + (p.categoryId ? ` [${p.categoryId}]` : "");
        append("shown", short(p.id));
      } else if (p.kind === "updated") {
        last.textContent = `Last: ${short(p.id)} — ${p.title} (updated)`;
        append("updated", short(p.id));
      } else if (p.kind === "removed") {
        append("removed", short(p.id));
      }
    });

    // FLAGSHIP: notification clicks/actions broadcast natively to every pane.
    // Log the full response metadata whenever the user interacts with one.
    const offResp = Notification.on("response", (r: any) => {
      const isAction = r.actionId && r.actionId !== "DEFAULT";
      const label = isAction ? `action · ${r.actionId}` : "clicked";
      const parts = [`id ${short(r.id)}`];
      if (r.userText) parts.push(`reply “${esc(r.userText)}”`);
      if (r.categoryId) parts.push(`cat ${r.categoryId}`);
      append(label, parts.join(" · "), true);
    });

    return () => {
      offLc();
      offResp();
    };
  },
};
