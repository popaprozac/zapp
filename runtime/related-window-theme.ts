import type { RelatedWindowThemeOptions } from "./related-window-contract";
import { rebaseStyleURLs } from "./related-window-style-urls";

/** Snapshot and validate before the first native allocation or await. */
export function normalizeRelatedWindowTheme(value: unknown): RelatedWindowThemeOptions | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).some(key => !["attributes", "classes", "variables"].includes(key))) {
    throw new TypeError("Related window theme accepts attributes, classes, and variables lists.");
  }
  const result: Record<string, string[]> = {};
  for (const key of ["attributes", "classes", "variables"] as const) {
    const names: unknown = (value as any)[key];
    if (names === undefined) continue;
    if (!Array.isArray(names) || names.some(name => typeof name !== "string"
      || (key === "attributes" ? !/^data-[a-z0-9_.:-]+$/.test(name)
        : key === "classes" ? !name || /[\t\n\f\r \0]/.test(name)
        : !/^--[a-zA-Z_\u0080-\uffff][\w\u0080-\uffff-]*$/.test(name)))) {
      throw new TypeError(`Invalid related window theme ${key}; use data-* attribute names, class tokens, or --custom-property names.`);
    }
    result[key] = [...new Set(names)];
    if (key === "variables" && (names as string[]).some(name => name === "--zapp-titlebar-height" || name === "--zapp-window-controls-inset-left")) {
      throw new TypeError("Native window chrome variables are document-local and cannot be shared as theme state.");
    }
  }
  return result;
}

/** Synchronize selected root state only. Never copy event-handler attributes,
 * IDs, style text, arbitrary DOM, or computed values. The owner is authoritative. */
export function shareRelatedWindowTheme(source: HTMLElement, target: HTMLElement,
  options: RelatedWindowThemeOptions, active: () => boolean): () => void {
  let owner: HTMLElement | undefined = source, child: HTMLElement | undefined = target;
  const attributes = options.attributes ?? [], classes = options.classes ?? [], variables = options.variables ?? [];
  if (!attributes.length && !classes.length && !variables.length) return () => {};
  type State = { attributes: (string | null)[]; classes: boolean[]; variables: [string, string][] };
  const read = (root: HTMLElement): State => ({
    attributes: attributes.map(name => root.getAttribute(name)),
    classes: classes.map(name => root.classList.contains(name)),
    variables: variables.map(name => [root.style.getPropertyValue(name), root.style.getPropertyPriority(name)]),
  });
  const initial = read(target);
  let last = initial;
  const write = (root: HTMLElement, state: State) => {
    attributes.forEach((name, i) => {
      const value = state.attributes[i];
      if (root.getAttribute(name) === value) return;
      if (value === null) root.removeAttribute(name); else root.setAttribute(name, value);
    });
    classes.forEach((name, i) => {
      if (root.classList.contains(name) !== state.classes[i]) root.classList.toggle(name, state.classes[i]);
    });
    variables.forEach((name, i) => {
      const [value, priority] = state.variables[i];
      if (root.style.getPropertyValue(name) === value && root.style.getPropertyPriority(name) === priority) return;
      if (value) root.style.setProperty(name, value, priority); else root.style.removeProperty(name);
    });
  };
  let observer: MutationObserver | undefined;
  function dispose() {
    observer?.disconnect(); observer = undefined;
    if (!child) return;
    // Avoid clobbering a newer edit made just before synchronous disposal.
    const current = read(child);
    current.attributes = current.attributes.map((value, i) => value === last.attributes[i] ? initial.attributes[i] : value);
    current.classes = current.classes.map((value, i) => value === last.classes[i] ? initial.classes[i] : value);
    current.variables = current.variables.map((value, i) => value[0] === last.variables[i][0] && value[1] === last.variables[i][1] ? initial.variables[i] : value);
    write(child, current); owner = undefined; child = undefined;
    active = () => false;
  }
  const apply = () => {
    if (!active()) { dispose(); return; }
    if (owner && child) {
      const next = read(owner);
      next.variables = next.variables.map(([value, priority]) => [rebaseStyleURLs(value, owner!.baseURI), priority]);
      last = next; write(child, last);
    }
  };
  let lastError = "";
  observer = new source.ownerDocument.defaultView!.MutationObserver(() => {
    try { apply(); lastError = ""; }
    catch (error) {
      if (String(error) !== lastError) console.error("[zapp] theme synchronization failed", error);
      lastError = String(error);
    }
  });
  const filter = [...attributes, ...(classes.length ? ["class"] : []), ...(variables.length ? ["style"] : [])];
  observer.observe(source, { attributes: true, attributeFilter: filter });
  observer.observe(target, { attributes: true, attributeFilter: filter });
  try { apply(); } catch (error) { dispose(); throw error; }
  return dispose;
}
