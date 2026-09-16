/** Internal, framework-neutral hit policy. Not a public runtime export. */
export type WindowDragIntent = "none" | "move" | "titlebar";

/** One-shot DOM half of a native mouse-down query. No hover state authorizes a
 * drag. Keep the original composed path, then recheck it before handing off. */
export function createWindowDragGesture(now = () => performance.now()) {
  let down: { path: Element[]; parents: Array<Node | null>; intent: WindowDragIntent; x: number; y: number;
    clicks: number; at: number; released: boolean } | undefined;
  return {
    clear() { down = undefined; },
    record(event: MouseEvent) {
      down = undefined;
      if (!event.isTrusted || event.button !== 0 || event.ctrlKey) return;
      const path = windowDragPath(event);
      down = { path, parents: path.map(composedParent), intent: resolveWindowDrag(path), x: event.clientX, y: event.clientY,
        clicks: event.detail, at: now(), released: false };
    },
    release() { if (down) down.released = true; },
    take(x: number, y: number, clicks: number): number {
      const snapshot = down;
      if (!snapshot) return -1; // native may query before WebKit delivers down
      if (now() - snapshot.at > 500) { down = undefined; return 0; }
      if (Math.abs(snapshot.x - x) > 1 || Math.abs(snapshot.y - y) > 1 || snapshot.clicks !== clicks) return -1;
      down = undefined;
      if (snapshot.path.some((element, index) => composedParent(element) !== snapshot.parents[index])) return 0;
      if (resolveWindowDrag(snapshot.path) !== snapshot.intent) return 0;
      if (snapshot.released && !(clicks === 2 && snapshot.intent === "titlebar")) return 0;
      return snapshot.intent === "titlebar" ? 2 : snapshot.intent === "move" ? 1 : 0;
    },
  };
}

function composedParent(element: Element): Node | null {
  return element.assignedSlot ?? element.parentNode;
}

const interactiveRoles = new Set([
  "button", "checkbox", "combobox", "grid", "gridcell", "link", "listbox",
  "menu", "menubar", "menuitem", "menuitemcheckbox", "menuitemradio", "option",
  "radio", "radiogroup", "scrollbar", "searchbox", "slider", "spinbutton",
  "switch", "tab", "tablist", "textbox", "tree", "treegrid", "treeitem",
]);

function interactive(element: Element): boolean {
  const tag = element.localName;
  if (["button", "input", "select", "textarea", "label", "summary", "iframe",
    "object", "embed"].includes(tag)) return true;
  if ((tag === "a" || tag === "area") && element.hasAttribute("href")) return true;
  if ((tag === "audio" || tag === "video") && element.hasAttribute("controls")) return true;
  if ((element as HTMLElement).isContentEditable) return true;
  if (element.hasAttribute("tabindex") && (element as HTMLElement).tabIndex >= 0) return true;
  return (element.getAttribute("role") ?? "").toLowerCase().split(/\s+/)
    .some((role) => interactiveRoles.has(role));
}

/** Use the event path, not instanceof: related documents have different realms,
 * SVG children are Elements too, and open shadow roots expose their host path. */
export function windowDragPath(event: Event): Element[] {
  if (typeof event.composedPath === "function") {
    const path = event.composedPath();
    if (path.length > 0) return path.filter((node): node is Element =>
      (node as Node).nodeType === 1);
  }
  const path: Element[] = [];
  let node = event.target as Node | null;
  while (node) {
    if (node.nodeType === 1) path.push(node as Element);
    node = node.parentNode ?? (node as ShadowRoot).host ?? null;
  }
  return path;
}

export function resolveWindowDrag(
  path: readonly Element[],
  style: (element: Element) => CSSStyleDeclaration = (element) =>
    element.ownerDocument.defaultView!.getComputedStyle(element),
): WindowDragIntent {
  let marker: WindowDragIntent = "none";
  let cssDrag = false;
  // Do not stop on a positive marker: a parent button/no-drag region still
  // excludes a nested icon/handle. CSS custom properties inherit, so a computed
  // `drag` is not evidence of an intentional override on that particular node.
  for (const element of path) {
    if (element.isConnected === false) return "none";
    if (interactive(element)) return "none";
    let value: string;
    try { value = style(element).getPropertyValue("--zapp-drag").trim(); }
    catch { return "none"; } // a retired document cannot authorize a gesture
    if (value === "no-drag") return "none";
    if (value === "drag") cssDrag = true;
    if (marker === "none") {
      if (element.hasAttribute("data-zapp-titlebar")) marker = "titlebar";
      else if (element.hasAttribute("data-zapp-drag-region")) marker = "move";
    }
  }
  // Inherited CSS drag must not downgrade a titlebar marker to move-only.
  return marker !== "none" ? marker : cssDrag ? "move" : "none";
}
