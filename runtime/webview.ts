// Embedded webview — the <zapp-webview> custom element + Webview factory.
// Runs in the webview (DOM) context. A native child WKWebView (darwin_panel_*)
// is glued to this element's rect via a reflow-free tracker (IntersectionObserver
// re-arm + ResizeObserver), reading entry.boundingClientRect rather than polling
// getBoundingClientRect in a scroll handler. See pretext (github.com/chenglou/
// pretext) for the "avoid forced sync layout" rationale.
import { getBridge } from "./bridge";
import { ensurePermission } from "./permissions";
import { toNativeRect, rectsEqual, isVisibleRect, type NativeRect } from "./webview-geometry";

export type PanelEvent = "did-navigate" | "title-change" | "load-finished" | "load-failed" | "message";

export interface WebviewCreateOptions {
  src: string;
  bridge?: boolean;     // v1: plumbed but inert (no __zappBridge injection)
  partition?: string;   // v1: plumbed but inert (shared store)
}

let panelSeq = 0;
function nextPanelId(): string {
  panelSeq = (panelSeq + 1) & 0xffff;
  return "panel-" + Date.now().toString(36) + "-" + panelSeq.toString(36);
}

function currentWindowId(): string | null {
  return (globalThis as any)[Symbol.for("zapp.windowId")] ?? null;
}

// Fire-and-forget post on the t:4 action channel (same as window actions).
function panelPost(action: string, args: Record<string, unknown>): void {
  const bridge = getBridge() as any;
  const msg = JSON.stringify({ t: 4, m: action, a: args });
  if (bridge.post) bridge.post(msg);
  else bridge.emit("__panel:" + action, args);
}

// Module-level registry of live panel elements. Used by the pagehide handler
// to teardown panels on full-page navigation (which fires pagehide instead of
// disconnectedCallback, causing panels to leak without explicit teardown).
const _livePanels = new Set<ZappWebviewElement>();

// Install the pagehide listener ONCE (module load, DOM context only). On
// full-page navigation the browser fires pagehide before unloading; we iterate
// the registry and destroy every live panel so native child WKWebViews are
// removed even when disconnectedCallback never fires. NOT `{ once: true }`:
// pagehide can fire repeatedly (bfcache restore re-populates _livePanels via
// connectedCallback, then a later nav fires pagehide again). The handler is
// idempotent — clear() on an already-empty set is harmless.
if (typeof window !== "undefined") {
  window.addEventListener("pagehide", () => {
    for (const el of _livePanels) {
      panelPost("panelDestroy", { panelId: (el as any)._panelId });
    }
    _livePanels.clear();
  }, { capture: true });
}

// Base class: the real HTMLElement in a DOM/webview context, or a no-op
// stand-in when there is no DOM (e.g. a zjs worker that imports
// @zappdev/runtime — webview.ts gets pulled in by its top-level
// customElements.define side effect). The `extends` clause is evaluated at
// module-load time, so it must reference a defined value or the worker's
// module fails to compile. The element is only registered/used in a DOM
// context (the customElements guard at the bottom of this file).
const HostElement: typeof HTMLElement =
  typeof HTMLElement !== "undefined"
    ? HTMLElement
    : (class {} as unknown as typeof HTMLElement);

export class ZappWebviewElement extends HostElement {
  static get observedAttributes() { return ["src"]; }

  private _panelId = nextPanelId();
  private _created = false;
  private _lastRect: NativeRect | null = null;
  private _io: IntersectionObserver | null = null;
  private _ro: ResizeObserver | null = null;
  private _rafPending = false;
  private _listeners = new Map<PanelEvent, Set<(data: unknown) => void>>();
  private _unsub: (() => void) | null = null;

  connectedCallback(): void {
    if (this._created) return;
    // Placeholder box; the native webview overlays it. Default to block so it
    // participates in layout and getBoundingClientRect returns real geometry.
    if (!this.style.display) this.style.display = "block";
    const src = this.getAttribute("src") ?? "";
    const bridge = this.hasAttribute("bridge");
    const partition = this.getAttribute("partition") ?? "";
    ensurePermission("embed");
    panelPost("panelCreate", {
      windowId: currentWindowId(), panelId: this._panelId, url: src, bridge, partition,
    });
    this._created = true;
    _livePanels.add(this); // track for pagehide teardown
    this._subscribe();
    this._startTracking();
  }

  disconnectedCallback(): void {
    if (!this._created) return;
    this._stopTracking();
    if (this._unsub) { this._unsub(); this._unsub = null; }
    panelPost("panelDestroy", { panelId: this._panelId });
    _livePanels.delete(this); // SPA removal: remove from pagehide registry
    this._created = false;
    this._lastRect = null;
  }

  attributeChangedCallback(name: string, _old: string | null, val: string | null): void {
    if (name === "src" && this._created && val != null) this.loadURL(val);
  }

  // --- public API ---
  loadURL(url: string): void { panelPost("panelLoadUrl", { panelId: this._panelId, url }); }
  execJS(code: string): void { panelPost("panelExecJs", { panelId: this._panelId, code }); }
  postMessage(data: unknown): void {
    panelPost("panelPostMessage", { panelId: this._panelId, data: JSON.stringify(data ?? null) });
  }
  reload(): void { panelPost("panelReload", { panelId: this._panelId }); }
  goBack(): void { panelPost("panelBack", { panelId: this._panelId }); }
  goForward(): void { panelPost("panelForward", { panelId: this._panelId }); }
  destroy(): void { this.remove(); } // triggers disconnectedCallback

  on(event: PanelEvent, cb: (data: unknown) => void): () => void {
    let set = this._listeners.get(event);
    if (!set) { set = new Set(); this._listeners.set(event, set); }
    set.add(cb);
    return () => { set!.delete(cb); };
  }

  // --- events ---
  private _subscribe(): void {
    this._unsub = getBridge().on("panel:" + this._panelId, (payload: unknown) => {
      const p = payload as { event?: PanelEvent; data?: unknown };
      if (!p?.event) return;
      const set = this._listeners.get(p.event);
      if (set) for (const cb of set) cb(p.data);
      this.dispatchEvent(new CustomEvent(p.event, { detail: p.data }));
    });
  }

  // --- reflow-free tracking ---
  private _startTracking(): void {
    this._sync();
    this._ro = new ResizeObserver(() => this._schedule());
    this._ro.observe(this);
    // Attach the scroll/resize listeners FIRST so they always register even if
    // _armIO throws (a bad rootMargin would otherwise skip them — that left an
    // embed stuck/untracked). capture-phase scroll catches scrolling in ANY
    // ancestor; it's the correctness backstop for the IO re-arm.
    window.addEventListener("resize", this._onWinChange, { passive: true });
    window.addEventListener("scroll", this._onWinChange, { passive: true, capture: true });
    // Track pinch-zoom via visualViewport (iOS/desktop zoom changes the scale
    // of getBoundingClientRect values relative to the native layer). Guard for
    // environments that don't expose visualViewport (e.g. workers, older Safari).
    if (typeof window !== "undefined" && window.visualViewport) {
      window.visualViewport.addEventListener("resize", this._onWinChange, { passive: true });
      window.visualViewport.addEventListener("scroll", this._onWinChange, { passive: true });
    }
    try { this._armIO(); } catch { /* IO is an optimization; listeners cover correctness */ }
  }
  private _stopTracking(): void {
    if (this._io) { this._io.disconnect(); this._io = null; }
    if (this._ro) { this._ro.disconnect(); this._ro = null; }
    window.removeEventListener("resize", this._onWinChange);
    window.removeEventListener("scroll", this._onWinChange, { capture: true } as any);
    if (typeof window !== "undefined" && window.visualViewport) {
      window.visualViewport.removeEventListener("resize", this._onWinChange);
      window.visualViewport.removeEventListener("scroll", this._onWinChange);
    }
  }
  private _onWinChange = (): void => this._schedule();

  // Coalesce many triggers in a frame into one sync.
  private _schedule(): void {
    if (this._rafPending) return;
    this._rafPending = true;
    requestAnimationFrame(() => { this._rafPending = false; this._sync(); });
  }

  // Re-arm an IntersectionObserver whose rootMargins bound the element tightly,
  // so it re-fires the moment the element moves a pixel relative to the viewport
  // — reflow-free movement detection (entry.boundingClientRect is browser-computed).
  private _armIO(): void {
    if (this._io) this._io.disconnect();
    const r = this.getBoundingClientRect();
    const mTop = Math.floor(r.top);
    const mLeft = Math.floor(r.left);
    const mBottom = Math.floor(window.innerHeight - r.bottom);
    const mRight = Math.floor(window.innerWidth - r.right);
    this._io = new IntersectionObserver((entries) => {
      const rect = entries[0]?.boundingClientRect;
      this._sync(rect ?? undefined);
      this._armIO(); // re-arm at the new position
    }, { threshold: [0, 0.0001, 1], rootMargin: `${-mTop}px ${-mRight}px ${-mBottom}px ${-mLeft}px` });
    this._io.observe(this);
  }

  private _sync(domRect?: DOMRectReadOnly): void {
    const r = domRect ?? this.getBoundingClientRect();
    if (!isVisibleRect(r)) {
      if (this._lastRect !== null) panelPost("panelHide", { panelId: this._panelId });
      this._lastRect = null;
      return;
    }
    const native = toNativeRect(r);
    if (rectsEqual(native, this._lastRect)) return;
    const firstShow = this._lastRect === null;
    this._lastRect = native;
    panelPost("panelSetBounds", { panelId: this._panelId, ...native });
    if (firstShow) panelPost("panelShow", { panelId: this._panelId });
  }
}

export const Webview = {
  /** Programmatically create + insert a <zapp-webview>. Append it where you want it. */
  create(opts: WebviewCreateOptions): ZappWebviewElement {
    ensurePermission("embed");
    const el = document.createElement("zapp-webview") as ZappWebviewElement;
    if (opts.bridge) el.setAttribute("bridge", "");
    if (opts.partition) el.setAttribute("partition", opts.partition);
    el.setAttribute("src", opts.src);
    return el;
  },
};

// Register the element once, in webview/DOM contexts only (no-op in workers/SSR).
if (typeof customElements !== "undefined" && !customElements.get("zapp-webview")) {
  customElements.define("zapp-webview", ZappWebviewElement);
}
