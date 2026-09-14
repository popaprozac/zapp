// Public factory integration; no private mirroring helper creates these styles.
import { createWindow, createRelatedWindow, RelatedWindowEvent } from "@zappdev/runtime/window";
import type { WindowHandle } from "@zappdev/runtime/window";
import styles from "./fixture.module.css";
import dotURL from "./dot.svg?no-inline";
import externalURL from "./external.css?url&no-inline";
import { verifyWindowDragPolicy } from "./drag-smoke";
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
function assert(value: unknown, label: string): asserts value { if (!value) throw new Error(`Public styling: ${label}`); }

export async function verifyPublicStyling(pulse: () => Promise<unknown>) {
  verifyWindowDragPolicy(document);
  const deadline = performance.now() + 8_000;
  const handles: WindowHandle[] = [];
  const nodes: Element[] = [];
  const owner = document.documentElement;
  const original = owner.getAttribute("data-zapp-test-theme");
  const originalClass = owner.classList.contains("zapp-test-dark");
  const originalVariable = owner.style.getPropertyValue("--zapp-test-accent");
  const originalPriority = owner.style.getPropertyPriority("--zapp-test-accent");
  async function until(check: () => boolean, label: string) {
    while (!check()) {
      if (performance.now() >= deadline) throw new Error(`Public styling timed out: ${label}`);
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  const add = (text: string) => {
    const node = document.createElement("style"); node.textContent = text; document.head.append(node); nodes.push(node); return node;
  };
  async function open(name: string, width: number, independent = false) {
    const handle = await createRelatedWindow({ title: `Public style ${name}`, width, height: 300, visible: false,
      titleBar: { style: independent ? "hidden" : name === "small" ? "hiddenInset" : "default", titleVisible: !independent },
      ...(independent ? { styles: "independent" as const } : {}),
      ...(!independent ? { theme: { attributes: ["data-zapp-test-theme"], classes: ["zapp-test-dark"], variables: ["--zapp-test-accent"] } } : {}),
    });
    handles.push(handle);
    const doc = handle.document, probe = doc.createElement("div");
    probe.dataset.styleProbe = ""; probe.className = styles.probe; doc.body.append(probe);
    return { handle, doc, value: (name: string) => doc.defaultView!.getComputedStyle(probe).getPropertyValue(name).trim() };
  }
  try {
    owner.setAttribute("data-zapp-test-theme", "dark"); owner.classList.add("zapp-test-dark");
    owner.style.setProperty("--zapp-test-accent", "chosen", "important");
    const asset = new URL(dotURL, document.baseURI);
    const relative = asset.pathname.slice(1) + asset.search;
    const sheet = add(`[data-style-probe]{--public-order:owner;--public-width:wide;background-image:image-set("./${relative}" 1x)}
      @media(max-width:500px){[data-style-probe]{--public-width:narrow}}
      [data-zapp-test-theme=dark] [data-style-probe]{--public-theme:dark}
      .zapp-test-dark [data-style-probe]{--public-class:dark}`);
    sheet.nonce = "private-styling-test";
    const a = await open("small", 330), b = await open("wide", 800), c = await open("independent", 330, true);
    for (const child of [a, b, c]) verifyWindowDragPolicy(child.doc);
    const ordinary = await createWindow({ title: "Public style ordinary", visible: false,
      titleBar: { style: "hiddenInset", titleVisible: false } });
    handles.push(ordinary);
    ordinary.setTitle("Public style ordinary updated");
    document.body.dataset.publicStylePhase = "hidden"; await pulse();
    await until(() => document.body.dataset.publicStyleNative === "hidden", "native windows stay hidden after publication");
    for (const child of [a, b]) {
      await until(() => child.value("--style-module") === "yes", "CSS Modules via public sharing");
      assert(child.value("--public-theme") === "dark" && child.value("--public-class") === "dark", "selected root theme installed");
      assert(child.doc.documentElement.style.getPropertyValue("--zapp-test-accent") === "chosen", "selected inline variable");
      assert([...child.doc.querySelectorAll<HTMLStyleElement>("style[data-zapp-shared-style]")].some(node => node.nonce === "private-styling-test"), `nonce IDL property preserved: source=${sheet.nonce}/${sheet.getAttribute("nonce")}/${sheet.hasAttribute("nonce")}; child=${JSON.stringify([...child.doc.querySelectorAll<HTMLStyleElement>("style[data-zapp-shared-style]")].map(node => ({nonce:node.nonce, attribute:node.getAttribute("nonce"), text:node.textContent?.slice(0,60)})))}`);
      assert(child.value("background-image").includes(asset.href), `image-set URL rebasing: expected=${asset.href}; actual=${child.value("background-image")}`);
    }
    assert(a.value("--public-width") === "narrow" && b.value("--public-width") === "wide", "separate viewport media queries");
    assert(c.value("--style-module") === "" && !c.doc.querySelector("[data-zapp-shared-style]") && !c.doc.documentElement.hasAttribute("data-zapp-test-theme"), "independent child has neither sheets nor implicit theme");
    a.handle.show();
    document.body.dataset.publicStylePhase = "shown"; await pulse();
    await until(() => document.body.dataset.publicStyleNative === "shown", "show reveals just the selected native window");
    const local = a.doc.createElement("style"); local.textContent = "[data-style-probe]{--public-order:local}"; a.doc.head.append(local);
    assert(a.value("--public-order") === "local" && b.value("--public-order") === "owner", "local styles follow shared styles");
    owner.removeAttribute("data-zapp-test-theme"); owner.classList.remove("zapp-test-dark"); owner.style.removeProperty("--zapp-test-accent");
    await flush();
    assert(!a.doc.documentElement.hasAttribute("data-zapp-test-theme") && !b.doc.documentElement.classList.contains("zapp-test-dark"), "theme removal reaches siblings");
    a.doc.documentElement.setAttribute("data-zapp-test-theme", "child-conflict"); await flush();
    assert(!a.doc.documentElement.hasAttribute("data-zapp-test-theme"), "selected names remain owner-authoritative");
    const link = document.createElement("link"); link.rel = "stylesheet"; link.href = externalURL;
    document.head.append(link); nodes.push(link);
    await until(() => a.value("--style-link") === "yes" && b.value("--style-link") === "yes", "real external sheet added after creation");
    link.remove(); await until(() => a.value("--style-link") === "", "external sheet removal");
    let hmr;
    if (import.meta.env.DEV) {
      const { verifyFileHmr } = await import("./hmr-smoke");
      hmr = await verifyFileHmr([a, b], pulse, until);
    }
    let invalidated = false;
    a.handle.subscribe(RelatedWindowEvent.INVALIDATED, () => invalidated = true);
    a.handle.close(); await until(() => invalidated, "native close invalidates public styling");
    assert(!a.doc.querySelector("[data-zapp-shared-style]") && local.isConnected, "close releases only framework-owned sheets");
    sheet.textContent = "[data-style-probe]{--public-order:updated}"; await flush();
    assert(b.value("--public-order") === "updated" && !a.doc.querySelector("[data-zapp-shared-style]"), "closed child stays detached and sibling updates");
    document.body.dataset.publicStyleMetrics = JSON.stringify({ hmr });
    document.body.dataset.publicStyles = "ok";
  } finally {
    delete document.body.dataset.publicStylePhase;
    for (const handle of handles) { try { handle.close(); } catch {} }
    for (const node of nodes) node.remove();
    if (original === null) owner.removeAttribute("data-zapp-test-theme"); else owner.setAttribute("data-zapp-test-theme", original);
    owner.classList.toggle("zapp-test-dark", originalClass);
    if (originalVariable) owner.style.setProperty("--zapp-test-accent", originalVariable, originalPriority); else owner.style.removeProperty("--zapp-test-accent");
  }
}
