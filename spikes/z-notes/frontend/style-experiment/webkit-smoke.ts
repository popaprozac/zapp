// Loaded only by the explicit style smoke flag. No Svelte/runtime internals.
import { createRelatedWindow, RelatedWindowEvent } from "@zappdev/runtime/window";
import type { RelatedWindowHandle, WindowEventSubscription } from "@zappdev/runtime/window";
import { createStyleMirror } from "./mirror";
import styles from "./fixture.module.css";
import dotURL from "./dot.svg?no-inline";
import externalURL from "./external.css?url&no-inline";
import { verifySelectedTheme } from './theme-smoke';
import { createStylesheetReadiness } from './readiness';

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(`Style experiment: ${message}`);
}
const flush = async () => { await new Promise(resolve => setTimeout(resolve, 0)); };
export async function verifyStyleSharing(pulse: () => Promise<unknown>) {
  const deadline = performance.now() + 8_000;
  const handles: RelatedWindowHandle[] = [];
  const subscriptions: WindowEventSubscription[] = [];
  const owned: Element[] = [];
  const mirror = createStyleMirror(document);
  const add = (text: string) => {
    const node = document.createElement("style"); node.textContent = text;
    document.head.append(node); owned.push(node); return node;
  };
  async function until(check: () => boolean, label: string) {
    while (!check()) {
      if (performance.now() > deadline) throw new Error(`Style experiment timed out: ${label}`);
      assert(!mirror.stats().error, String(mirror.stats().error));
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  async function open(width: number) {
    const handle = await createRelatedWindow({ title: "Private stylesheet probe", width, height: 300, styles: "independent" });
    handles.push(handle);
    const doc = handle.document;
    const probe = doc.createElement("div"); probe.dataset.styleProbe = "";
    probe.className = styles.probe; probe.textContent = "Shared stylesheet probe";
    doc.body.append(probe);
    return { handle, doc, probe, value: (name: string) => doc.defaultView!.getComputedStyle(probe).getPropertyValue(name).trim() };
  }
  try {
    const resolvedAsset = new URL(dotURL, document.baseURI);
    // Owner lives at /index.html or /; the child is /.zapp/related.html.
    // A verbatim relative URL would therefore request the wrong asset.
    const relativeAsset = resolvedAsset.pathname.slice(1) + resolvedAsset.search;
    const firstStyle = add(`[data-style-probe]{--style-order:first;--style-width:wide;background-image:url("./${relativeAsset}")}
      @media(max-width:500px){[data-style-probe]{--style-width:narrow}}`);
    const secondStyle = add('[data-style-probe]{--style-order:second}');
    const script = document.createElement("script"); script.type = "application/json";
    script.dataset.styleProbeScript = ""; script.textContent = '{}'; document.head.append(script); owned.push(script);
    const small = await open(330), wide = await open(800), independent = await open(330);
    assert(small.doc.defaultView!.innerWidth < 500 && wide.doc.defaultView!.innerWidth > 500, "distinct native viewports");
    const attachStart = performance.now();
    const a = mirror.attach(small.doc), b = mirror.attach(wide.doc);
    const attachMs = performance.now() - attachStart;
    subscriptions.push(small.handle.subscribe(RelatedWindowEvent.INVALIDATED, () => a.dispose()),
      wide.handle.subscribe(RelatedWindowEvent.INVALIDATED, () => b.dispose()));
    assert(await a.ready(1_000) === 'ready' && await b.ready(1_000) === 'ready', 'initial stylesheet snapshots loaded');
    await until(() => small.value('--style-module') === 'yes' && wide.value('--style-module') === 'yes', 'CSS Modules');
    assert(small.value('--style-order') === 'second', 'initial cascade order');
    assert(small.value('--style-width') === 'narrow' && wide.value('--style-width') === 'wide', 'child-local media queries');
    assert(independent.value('--style-module') === '' && independent.value('--style-order') === '', 'unattached child stays independently styled');
    assert(!small.doc.querySelector('[data-style-probe-script]'), 'no script copying');
    assert(!small.doc.querySelector('base'), 'no child base URL mutation');
    const background = small.value('background-image');
    assert(background.includes(resolvedAsset.href), `relative CSS asset rebased: ${background}`);
    const image = new small.doc.defaultView!.Image(); image.src = resolvedAsset.href;
    await until(() => image.complete, 'asset decoding'); assert(image.naturalWidth === 8, 'real packaged/dev asset loads');

    // A real external stylesheet stays a link (not an eager fetch/inline copy).
    const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = externalURL;
    document.head.append(link); owned.push(link);
    await flush();
    assert(await a.ready(1_000) === 'ready' && await b.ready(1_000) === 'ready', 'linked stylesheet readiness');
    await until(() => small.value('--style-link') === 'yes' && wide.value('--style-link') === 'yes', 'linked stylesheet load');
    const childLink = [...small.doc.querySelectorAll<HTMLLinkElement>('link[data-style-experiment]')].find(node => node.href === link.href);
    assert(childLink && childLink !== link, 'independent link with original absolute URL');
    link.media = 'not all'; await until(() => small.value('--style-link') === '', 'media attribute update');
    link.media = ''; await until(() => small.value('--style-link') === 'yes', 'media restored');
    assert(childLink.isConnected, 'attribute change preserves link identity');
    link.href = externalURL + '?generation=2'; await flush();
    assert(!childLink.isConnected, 'link retarget creates a fresh request generation');
    assert(await a.ready(1_000) === 'ready', 'new link generation loads');
    const retargetedLink = [...small.doc.querySelectorAll<HTMLLinkElement>('link[data-style-experiment]')].find(node => node.href === link.href);
    assert(retargetedLink, 'retargeted link remains tracked');
    link.remove(); await flush();

    // The actual browser delivers a load error for an invalid stylesheet.
    const broken = document.createElement('link'); broken.rel = 'stylesheet';
    broken.href = 'data:text/css;base64,%%%invalid-base64'; document.head.append(broken); owned.push(broken);
    await flush(); assert(await a.ready(1_000) === 'failed', 'load failure is distinct from timeout');
    broken.remove(); await flush(); assert(await a.ready(1_000) === 'ready', 'removing failed sheet leaves a fresh ready snapshot');

    // Real DOM link, deliberately never connected: no network or indefinite
    // wait. Invalidation must terminate its waiter and remove listeners.
    const pending = createStylesheetReadiness();
    const neverConnected = small.doc.createElement('link'); neverConnected.rel = 'stylesheet';
    pending.watch(neverConnected);
    assert(await pending.ready(5) === 'timeout', 'bounded readiness timeout');
    const cancelled = pending.ready(1_000); pending.dispose();
    assert(await cancelled === 'disposed', 'disposal releases an unfinished readiness wait');
    assert(pending.stats().waits === 0 && pending.stats().listeners === 0, 'readiness handlers released');

    await verifySelectedTheme(small, wide, independent);

    const lazy = await import('./lazy'); assert(lazy.loaded, 'real lazy module import');
    await until(() => small.value('--style-lazy') === 'yes' && wide.value('--style-lazy') === 'yes', 'lazy CSS insertion');
    const beforeBurst = mirror.stats(); const updateStart = performance.now();
    for (let i = 0; i < 50; i++) secondStyle.textContent = `[data-style-probe]{--style-order:update-${i}}`;
    await flush(); const updateMs = performance.now() - updateStart;
    assert(small.value('--style-order') === 'update-49' && wide.value('--style-order') === 'update-49', 'batched text replacements reach siblings');
    assert(mirror.stats().passes === beforeBurst.passes + 1, 'one observer pass per synchronous burst');
    assert(mirror.stats().created === beforeBurst.created, 'no recreated sheets during text updates');
    assert(!retargetedLink.isConnected, 'removed linked sheet stays removed during later edits');
    document.head.insertBefore(secondStyle, firstStyle); await flush();
    assert(small.value('--style-order') === 'first', 'source reordering preserved');
    firstStyle.remove(); await flush(); assert(small.value('--style-order') === 'update-49', 'removed source disappears');
    const replacement = document.createElement('style'); replacement.textContent = '[data-style-probe]{--style-order:replacement}';
    secondStyle.replaceWith(replacement); owned.push(replacement); await flush();
    assert(small.value('--style-order') === 'replacement', 'replacement style node observed');
    replacement.firstChild!.textContent = '[data-style-probe]{--style-order:character-data}'; await flush();
    assert(small.value('--style-order') === 'character-data', 'text-node updates observed');
    const local = small.doc.createElement('style'); local.textContent = '[data-style-probe]{--style-order:local}';
    small.doc.head.append(local); assert(small.value('--style-order') === 'local', 'local rules come after mirrored rules in this experiment');

    // DOM mutation is queued, then target disposed BEFORE observer delivery.
    replacement.textContent = '[data-style-probe]{--style-order:after-detach}'; a.dispose(); a.dispose(); await flush();
    assert(!small.doc.querySelector('[data-style-experiment]'), 'queued update cannot repopulate disposed target');
    assert(local.isConnected && small.value('--style-order') === 'local', 'cleanup preserves local styles');
    assert(wide.value('--style-order') === 'after-detach', 'sibling keeps receiving updates');
    for (let i = 0; i < 20; i++) {
      const temporary = mirror.attach(small.doc); temporary.dispose();
      assert(mirror.stats().documents === 1, 'attach/detach does not accumulate target records');
    }
    wide.handle.close(); await until(() => mirror.stats().documents === 0, 'native invalidation releases target');
    assert(!wide.doc.querySelector('[data-style-experiment]'), 'native close removes mirrored sheets');
    assert(await b.ready(100) === 'disposed', 'native invalidation also disposes readiness');
    assert(b.readinessStats().links === 0 && b.readinessStats().listeners === 0 && b.readinessStats().waits === 0, 'native invalidation releases readiness resources');
    const beforeDispose = mirror.stats();
    replacement.textContent = '[data-style-probe]{--style-order:late}'; mirror.dispose(); await flush();
    const final = mirror.stats();
    assert(!final.observing && final.documents === 0 && final.sheets === 0 && final.created === final.removed, 'all tracked stylesheet ownership released');
    assert(final.passes === beforeDispose.passes, 'disconnect drops queued observer work');
    assert(!final.error, String(final.error));
    document.body.dataset.styleExperiment = 'ok';
    document.body.dataset.styleMetrics = JSON.stringify({ attachMs, updateMs, ...final });
  } finally {
    mirror.dispose(); for (const sub of subscriptions) sub.unsubscribe();
    for (const node of owned) node.remove();
    for (const handle of handles) { try { handle.close(); } catch { /* Already invalidated. */ } }
  }
}
