import { Events, type ToolbarItemDef } from "@zappdev/runtime";

// Filter state for the pull-down's moving checkmark (the Toolbar section
// drives this via updateItem). Module-level so main-pane (attach) and the
// Toolbar section (re-attach) share one source of truth.
let filter = "all";
export function getFilter() { return filter; }
export function setFilter(f: string) { filter = f; }

export function filterMenu(): any[] {
  return [
    { id: "kf-all",     label: "All",     checked: filter === "all" },
    { id: "kf-unread",  label: "Unread",  checked: filter === "unread" },
    { id: "kf-flagged", label: "Flagged", checked: filter === "flagged" },
  ];
}

/** The shell toolbar: toggleSidebar | tracking | Compose | flex | Filter |
 *  tracking(inspector) | toggleInspector. Compose/Filter are the items the
 *  Toolbar section mutates. */
export function shellToolbar(): ToolbarItemDef[] {
  return [
    { type: "toggleSidebar" },
    { type: "trackingSeparator" },
    { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
      style: "prominent", tintColor: "#aa3bff",
      action: () => Events.emit("ks:toolbar", { id: "compose" }) },
    { id: "inbox", icon: "sf:tray", label: "Inbox", bordered: false,
      badge: { count: 0 },
      action: () => Events.emit("ks:toolbar", { id: "inbox" }) },
    { type: "flexibleSpace" },
    { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
      indicator: false, menu: filterMenu() },
    { type: "trackingSeparator", pane: "inspector" },
    { type: "toggleInspector" },
  ];
}
