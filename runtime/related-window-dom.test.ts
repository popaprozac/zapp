// Minimal deterministic DOM for lifecycle/ordering tests. Real parsing, loading,
// cascade, HMR and cross-document behavior are gated separately in WebKit.
export function styleDOM() {
  const observers = new Set<Observer>();
  class Observer {
    constructor(readonly callback: () => void) {}
    observe(_node: unknown, _options: unknown) { observers.add(this); }
    disconnect() { observers.delete(this); }
  }
  class Node {
    readonly attrs = new Map<string, string>();
    children: Node[] = [];
    parent: Node | undefined;
    textContent = "";
    disabled = false;
    private nonceValue = "";
    readonly dataset: Record<string, string> = {};
    readonly variables = new Map<string, [string, string]>();
    readonly style = {
      getPropertyValue: (name: string) => this.variables.get(name)?.[0] ?? "",
      getPropertyPriority: (name: string) => this.variables.get(name)?.[1] ?? "",
      setProperty: (name: string, value: string, priority = "") => { this.variables.set(name, [value, priority]); },
      removeProperty: (name: string) => { this.variables.delete(name); },
    };
    readonly classList = {
      contains: (name: string) => (this.attrs.get("class") ?? "").split(/\s+/).includes(name),
      toggle: (name: string, present: boolean) => {
        const names = new Set((this.attrs.get("class") ?? "").split(/\s+/).filter(Boolean));
        if (present) names.add(name); else names.delete(name);
        this.attrs.set("class", [...names].join(" "));
      },
    };
    readonly relList = { contains: (name: string) => (this.attrs.get("rel") ?? "").split(/\s+/).includes(name) };
    constructor(readonly localName: string, readonly ownerDocument: Doc) {}
    get baseURI() { return this.ownerDocument.baseURI; }
    get nonce() { return this.nonceValue; }
    set nonce(value: string) { this.nonceValue = value; }
    get nextSibling() { const siblings = this.parent?.children; return siblings?.[(siblings.indexOf(this) + 1)] ?? null; }
    get isConnected() { return !!this.parent; }
    getAttribute(name: string) { return this.attrs.get(name) ?? null; }
    hasAttribute(name: string) { return this.attrs.has(name); }
    setAttribute(name: string, value: string) { this.attrs.set(name, value); }
    removeAttribute(name: string) { this.attrs.delete(name); }
    getAttributeNames() { return [...this.attrs.keys()]; }
    remove() {
      if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1);
      this.parent = undefined;
    }
    insertBefore(node: Node, next: Node | null) {
      node.remove(); node.parent = this;
      this.children.splice(next ? this.children.indexOf(next) : this.children.length, 0, node);
    }
    prepend(node: Node) { this.insertBefore(node, this.children[0] ?? null); }
    append(node: Node) { this.insertBefore(node, null); }
    querySelectorAll(_selector: string): Node[] {
      return this.children.flatMap(node => [
        ...(node.localName === "style" || (node.localName === "link" && node.relList.contains("stylesheet")) ? [node] : []),
        ...node.querySelectorAll(_selector),
      ]);
    }
  }
  class Doc {
    readonly head = new Node("head", this);
    readonly body = new Node("body", this);
    readonly documentElement = new Node("html", this);
    readonly defaultView = { MutationObserver: Observer };
    constructor(readonly baseURI: string) {}
    createElement(name: string) { return new Node(name, this); }
    createComment(text: string) { const node = new Node("#comment", this); node.textContent = text; return node; }
  }
  return {
    document: (url = "https://example.test/app/index.html") => new Doc(url) as unknown as Document,
    flush: () => { for (const observer of [...observers]) if (observers.has(observer)) observer.callback(); },
    observers: () => observers.size,
  };
}
