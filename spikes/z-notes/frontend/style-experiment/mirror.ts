import { rebaseStyleURLs } from "./css-urls";
import { createStylesheetReadiness } from "./readiness";

// PRIVATE SPIKE. Head-owned DOM styles only; no public option/default, theme
// copying, script replay, CSSOM observation, or factory-readiness change.
type Source = HTMLStyleElement | HTMLLinkElement;
type Sheet = { source: Source; kind: "style" | "link"; attrs: [string, string][]; text: string };
type Target = { head?: HTMLHeadElement; end?: Comment; nodes: Map<Source, Source>; readiness: ReturnType<typeof createStylesheetReadiness> };
const attributes = ["media", "type", "title", "nonce", "disabled", "crossorigin", "integrity", "referrerpolicy"];
export function createStyleMirror(sourceDocument: Document) {
  let owner: Document | undefined = sourceDocument;
  let observer: MutationObserver | undefined;
  let error: unknown;
  const targets = new Set<Target>();
  const counters = { passes: 0, writes: 0, created: 0, removed: 0 };
  function read(): Sheet[] {
    if (!owner) return [];
    return [...owner.head.querySelectorAll<Source>('style, link[rel~="stylesheet"]')].map(source => {
      const kind = source.localName as "style" | "link";
      if (kind === "link" && (source as HTMLLinkElement).relList.contains("alternate")) {
        throw new Error("Style experiment: alternate stylesheet selection needs a separate contract");
      }
      const attrs: [string, string][] = [];
      for (const name of attributes) if (source.hasAttribute(name)) attrs.push([name, source.getAttribute(name)!]);
      if (kind === "link") {
        attrs.push(["rel", "stylesheet"], ["href", new URL(source.getAttribute("href") ?? "", source.baseURI).href]);
      }
      return { source, kind, attrs, text: kind === "style" ? rebaseStyleURLs(source.textContent ?? "", source.baseURI) : "" };
    });
  }
  function release(target: Target) {
    targets.delete(target);
    target.readiness.dispose();
    for (const node of target.nodes.values()) { node.remove(); counters.removed++; }
    target.nodes.clear(); target.end?.remove(); target.head = undefined; target.end = undefined;
  }
  function write(target: Target, sheets: Sheet[]) {
    if (!target.head || !target.end) return;
    const wanted = new Set(sheets.map(sheet => sheet.source));
    for (const [source, node] of target.nodes) if (!wanted.has(source)) {
      if (node.localName === 'link') target.readiness.forget(node as HTMLLinkElement);
      node.remove(); target.nodes.delete(source); counters.removed++;
    }
    for (const sheet of sheets) {
      let node = target.nodes.get(sheet.source);
      // A new link request is a new generation. Replacing that node means a
      // late load/error event from an old request cannot settle a newer wait.
      if (node && sheet.kind === 'link' && ['href', 'type', 'crossorigin', 'integrity', 'referrerpolicy'].some(name =>
        node!.getAttribute(name) !== (sheet.attrs.find(([key]) => key === name)?.[1] ?? null))) {
        target.readiness.forget(node as HTMLLinkElement); node.remove();
        target.nodes.delete(sheet.source); counters.removed++; node = undefined;
      }
      if (!node) {
        node = target.head.ownerDocument.createElement(sheet.kind);
        node.dataset.styleExperiment = "";
        target.nodes.set(sheet.source, node); counters.created++;
        if (sheet.kind === 'link') target.readiness.watch(node as HTMLLinkElement);
      }
      const wantedAttributes = new Map(sheet.attrs);
      for (const name of node.getAttributeNames()) {
        if (name !== "data-style-experiment" && !wantedAttributes.has(name)) { node.removeAttribute(name); counters.writes++; }
      }
      for (const [name, value] of sheet.attrs) if (node.getAttribute(name) !== value) { node.setAttribute(name, value); counters.writes++; }
      if (sheet.kind === "style" && node.textContent !== sheet.text) { node.textContent = sheet.text; counters.writes++; }
    }
    // Ordered segment BEFORE child-local styles. Do not move unchanged links,
    // restart their loads, or replace every sheet on an edit.
    let next: Node = target.end;
    for (let i = sheets.length - 1; i >= 0; i--) {
      const node = target.nodes.get(sheets[i].source)!;
      if (node.nextSibling !== next) { target.head.insertBefore(node, next); counters.writes++; }
      next = node;
    }
  }
  function sync() {
    if (!owner || targets.size === 0) return;
    const sheets = read(); counters.passes++;
    for (const target of targets) write(target, sheets);
  }
  function dispose() {
    observer?.disconnect(); observer = undefined;
    for (const target of targets) release(target);
    owner = undefined;
  }
  observer = new sourceDocument.defaultView!.MutationObserver(() => {
    try { sync(); } catch (failure) { error = failure; dispose(); }
  });
  observer.observe(sourceDocument.head, { subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: [...attributes, "href", "rel"] });
  return {
    attach(document: Document) {
      if (!owner) throw new Error("Style experiment: mirror disposed");
      if (document === owner) throw new Error("Style experiment: source cannot be its own target");
      if ([...targets].some(target => target.head === document.head)) throw new Error("Style experiment: duplicate target");
      const target: Target = { head: document.head, end: document.createComment("style experiment end"), nodes: new Map(), readiness: createStylesheetReadiness() };
      document.head.prepend(target.end!); targets.add(target);
      try { write(target, read()); } catch (failure) { release(target); throw failure; }
      // Retained disposer captures state whose DOM references are cleared,
      // rather than an uncleared child-document argument.
      return { dispose: () => release(target), ready: (timeoutMs: number) => target.readiness.ready(timeoutMs), readinessStats: target.readiness.stats };
    },
    stats: () => ({ ...counters, documents: targets.size, sheets: [...targets].reduce((n, target) => n + target.nodes.size, 0), observing: !!observer, error }),
    dispose,
  };
}
