import {
  Events,
  type ActionContext,
  type MenuItemDef,
  type ToolbarItemDef,
} from "@zappdev/runtime";

// Filter state for the pull-down's moving checkmark (the Toolbar section
// drives this via updateItem). Module-level so main-pane (attach) and the
// Toolbar section (re-attach) share one source of truth.
let filter = "all";
export function getFilter() {
  return filter;
}
export function setFilter(f: string) {
  filter = f;
}

const filterLabels: Record<string, string> = {
  all: "All items",
  unread: "Unread items",
  flagged: "Flagged items",
};

/** Apply a filter from a Filter pull-down item: set state, live-update the
 *  toolbar status label, and broadcast ks:filter so the Toolbar section's
 *  inspector pane (a separate webview) stays in sync. */
function applyFilter(value: string, ctx?: ActionContext) {
  setFilter(value);
  ctx?.window.toolbar.updateItem("status", { text: filterLabels[value] ?? "All items" });
  Events.emit("ks:filter", { value });
}

export function filterMenu(): MenuItemDef[] {
  return [
    { id: "kf-all", label: "All", radioGroup: "filter", checked: filter === "all",
      action: (ctx) => applyFilter("all", ctx) },
    { id: "kf-unread", label: "Unread", radioGroup: "filter", checked: filter === "unread",
      action: (ctx) => applyFilter("unread", ctx) },
    { id: "kf-flagged", label: "Flagged", radioGroup: "filter", checked: filter === "flagged",
      action: (ctx) => applyFilter("flagged", ctx) },
  ];
}

export function filterStatusText(): string {
  return filterLabels[filter] ?? "All items";
}

/** The shell toolbar: toggleSidebar | tracking | Compose | flex | Filter |
 *  tracking(inspector) | toggleInspector. Compose/Filter are the items the
 *  Toolbar section mutates. */
export function shellToolbar(): ToolbarItemDef[] {
  return [
    { type: "toggleSidebar" },
    { type: "trackingSeparator" },
    {
      id: "compose",
      icon: "sf:square.and.pencil",
      label: "Compose",
      style: "prominent",
      tintColor: "#aa3bff",
      action: () => Events.emit("ks:toolbar", { id: "compose" }),
    },
    {
      id: "inbox",
      icon: "sf:tray",
      label: "Inbox",
      bordered: false,
      action: () => Events.emit("ks:toolbar", { id: "inbox" }),
    },
    {
      type: "group",
      id: "nav",
      placement: "center",
      controlRepresentation: "automatic",
      items: [
        {
          id: "back",
          icon: "sf:chevron.left",
          label: "Back",
          action: () => Events.emit("ks:toolbar", { id: "nav:back" }),
          enabled: false, // disabled demo (like a browser with no back history)
        },
        {
          id: "fwd",
          icon: "sf:chevron.right",
          label: "Forward",
          action: () => Events.emit("ks:toolbar", { id: "nav:fwd" }),
        },
      ],
    },
    {
      type: "segmented",
      id: "view",
      placement: "center",
      selectionMode: "one",
      selected: 0,
      segments: [
        // label populates the collapsed/overflow menu (icon-only segments collapse blank)
        {
          id: "grid",
          icon: "sf:square.grid.2x2",
          label: "Grid",
          action: () => Events.emit("ks:toolbar", { id: "view:grid" }),
        },
        {
          id: "list",
          icon: "sf:list.bullet",
          label: "List",
          action: () => Events.emit("ks:toolbar", { id: "view:list" }),
        },
      ],
    },
    {
      type: "segmented",
      id: "fmt",
      placement: "center",
      selectionMode: "momentary",
      segments: [
        {
          id: "bold",
          icon: "sf:bold",
          label: "Bold",
          action: () => Events.emit("ks:toolbar", { id: "fmt:bold" }),
        },
        {
          id: "italic",
          icon: "sf:italic",
          label: "Italic",
          action: () => Events.emit("ks:toolbar", { id: "fmt:italic" }),
        },
      ],
    },
    {
      id: "filter",
      placement: "trailing",
      icon: "sf:line.3.horizontal.decrease",
      label: "Filter",
      indicator: false,
      menu: filterMenu(),
    },
    // type:"label" demo — text updates live via updateItem when the filter changes
    { type: "label", id: "status", placement: "trailing", text: filterStatusText() },
    { type: "trackingSeparator", pane: "inspector", placement: "trailing" },
    { type: "toggleInspector", placement: "trailing" },
  ];
}
