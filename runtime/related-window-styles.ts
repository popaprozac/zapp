import { rebaseStyleURLs } from "./related-window-style-urls";

type Source = HTMLStyleElement | HTMLLinkElement;
type Sheet = { source: Source; kind: "style" | "link"; attrs: Map<string, string>; text: string; disabled: boolean };
type Target = { head?: HTMLHeadElement; end?: Comment; nodes: Map<Source, Source>; active: () => boolean };
const attributes = ["media", "type", "title", "nonce", "disabled", "crossorigin", "integrity", "referrerpolicy"];
const hubs = new WeakMap<Document, StyleHub>();

/** Internal DOM-sheet synchronization. No scripts, CSSOM polling, base element,
 * computed-style copying, fetch proxy, or additional browser registry. */
class StyleHub {
  private owner: Document | undefined;
  private observer: MutationObserver | undefined;
  private readonly targets = new Set<Target>();
  private readonly textCache = new WeakMap<Source, { source: string; base: string; text: string }>();
  private lastError = "";

  constructor(owner: Document) {
    this.owner = owner;
    this.observer = new owner.defaultView!.MutationObserver(() => {
      // Invalidation is synchronous; public cleanup notifications are queued.
      // Check liveness before any pending style mutation touches a dead child.
      for (const target of this.targets) if (!target.active()) this.release(target);
      if (!this.owner) return;
      try {
        const sheets = this.read();
        for (const target of this.targets) this.write(target, sheets);
        this.lastError = "";
      } catch (error) {
        // An unsupported hot edit keeps the last successfully shared snapshot.
        // A later supported edit can recover; never silently detach all children.
        const message = String(error);
        if (message !== this.lastError) console.error("[zapp] stylesheet synchronization failed", error);
        this.lastError = message;
      }
    });
    this.observer.observe(owner.head, { subtree: true, childList: true, characterData: true,
      attributes: true, attributeFilter: [...attributes, "href", "rel"] });
  }

  private read(): Sheet[] {
    return [...this.owner!.head.querySelectorAll<Source>('style, link[rel~="stylesheet"]')].map(source => {
      const kind = source.localName as "style" | "link";
      if (kind === "link" && (source as HTMLLinkElement).relList.contains("alternate")) {
        throw new Error('Related window styles: alternate stylesheet selection requires styles: "independent".');
      }
      const attrs = new Map<string, string>();
      // WebKit can retain the nonce IDL value with no content attribute at all.
      // Its presence must not be gated by hasAttribute()/getAttribute().
      if (source.nonce) attrs.set("nonce", source.nonce);
      for (const name of attributes) if (name !== "nonce" && source.hasAttribute(name)) attrs.set(name, source.getAttribute(name)!);
      let text = "";
      if (kind === "link") {
        attrs.set("rel", "stylesheet");
        attrs.set("href", new URL(source.getAttribute("href") ?? "", source.baseURI).href);
      } else {
        const raw = source.textContent ?? "", base = source.baseURI;
        let cached = this.textCache.get(source);
        if (!cached || cached.source !== raw || cached.base !== base) {
          cached = { source: raw, base, text: rebaseStyleURLs(raw, base) };
          this.textCache.set(source, cached);
        }
        text = cached.text;
      }
      return { source, kind, attrs, text, disabled: source.disabled };
    });
  }

  private write(target: Target, sheets: Sheet[]) {
    if (!target.head || !target.end || !target.active()) return;
    const wanted = new Set(sheets.map(sheet => sheet.source));
    for (const [source, node] of target.nodes) if (!wanted.has(source)) {
      node.remove(); target.nodes.delete(source);
    }
    for (const sheet of sheets) {
      let node = target.nodes.get(sheet.source);
      if (node && sheet.kind === "link" && ["href", "type", "crossorigin", "integrity", "referrerpolicy"].some(name =>
        node!.getAttribute(name) !== (sheet.attrs.get(name) ?? null))) {
        node.remove(); target.nodes.delete(sheet.source); node = undefined;
      }
      if (!node) {
        node = target.head.ownerDocument.createElement(sheet.kind);
        node.dataset.zappSharedStyle = "";
        target.nodes.set(sheet.source, node);
      }
      for (const name of node.getAttributeNames()) {
        if (name !== "data-zapp-shared-style" && !sheet.attrs.has(name)) node.removeAttribute(name);
      }
      for (const [name, value] of sheet.attrs) {
        if (name === "nonce") { if (node.nonce !== value) node.nonce = value; }
        else if (node.getAttribute(name) !== value) node.setAttribute(name, value);
      }
      if (node.nonce && !sheet.attrs.has("nonce")) node.nonce = "";
      if (sheet.kind === "style" && node.textContent !== sheet.text) node.textContent = sheet.text;
    }
    // Keep one ordered segment before local styles. Unchanged sheets are not
    // removed/reinserted on every mutation (which can restart network loads).
    let next: Node = target.end;
    for (let i = sheets.length - 1; i >= 0; i--) {
      const node = target.nodes.get(sheets[i].source)!;
      if (node.nextSibling !== next) target.head.insertBefore(node, next);
      node.disabled = sheets[i].disabled;
      next = node;
    }
  }

  attach(document: Document, active: () => boolean): () => void {
    const target: Target = { head: document.head, end: document.createComment("zapp shared styles end"), nodes: new Map(), active };
    document.head.prepend(target.end!); this.targets.add(target);
    try { this.write(target, this.read()); }
    catch (error) { this.release(target); throw error; }
    return () => this.release(target);
  }

  private release(target: Target) {
    this.targets.delete(target);
    for (const node of target.nodes.values()) node.remove();
    target.nodes.clear(); target.end?.remove(); target.head = undefined; target.end = undefined;
    target.active = () => false;
    if (this.targets.size === 0) {
      this.observer?.disconnect(); this.observer = undefined;
      if (this.owner) hubs.delete(this.owner);
      this.owner = undefined;
    }
  }
}

/** Internal attachment; disposed on rollback or terminal invalidation. */
export function shareRelatedWindowStyles(owner: Document, child: Document, active: () => boolean): () => void {
  let hub = hubs.get(owner);
  if (!hub) { hub = new StyleHub(owner); hubs.set(owner, hub); }
  return hub.attach(child, active);
}
