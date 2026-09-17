// Loaded only in an explicitly requested smoke build, never ordinary Notes.
import { get } from "svelte/store";
import { tick } from "svelte";
import { createInspectorManager } from "./related-inspectors";
import type { NotesModel } from "./notes-model";
import { currentWindow } from "@zappdev/runtime/window";
import { inspectorPosition } from "./inspector-placement";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(`Svelte inspector: ${message}`);
}
export async function verifySvelteInspectors(model: NotesModel, pulse: () => Promise<unknown>) {
  document.body.dataset.sveltePhase = "waiting-for-notes";
  const deadline = Date.now() + 15_000;
  async function until(check: () => boolean, description: string) {
    while (!check()) {
      if (Date.now() > deadline) throw new Error(`Timed out: ${description}`);
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    await tick();
  }
  await until(() => document.body.dataset.cancellation === "ok"
    && document.body.dataset.roundTrip === "ok" && document.body.dataset.dynamicWindow === "ready", "normal Notes smoke");
  document.body.dataset.sveltePhase = "refreshing-notes";
  await model.refresh();
  const note = get(model.state).items[0];
  assert(note, "expected a persisted note");
  model.select(note.id);
  await tick();
  document.body.dataset.sveltePhase = "checking-owner-layout";
  // The launch harness may start behind another application. Layout assertions
  // must not depend on requestAnimationFrame running in an occluded WebView.
  currentWindow().focus();
  const mainHeader = document.querySelector<HTMLElement>(".workspace-header")!;
  const mainRootStyle = getComputedStyle(document.documentElement);
  const mainTop = parseFloat(mainRootStyle.getPropertyValue("--zapp-titlebar-height"));
  const mainLeft = parseFloat(mainRootStyle.getPropertyValue("--zapp-window-controls-inset-left"));
  assert(mainTop > 0 && mainLeft > 0, "owner uses its own inset titlebar geometry");
  assert(mainHeader.getBoundingClientRect().top === 0, "owner header starts at the viewport top");
  assert(mainHeader.getBoundingClientRect().bottom >= mainTop, "owner header clears native top chrome");
  assert(mainHeader.firstElementChild!.getBoundingClientRect().left >= mainLeft, "owner title clears traffic lights");
  const search = document.querySelector<HTMLInputElement>("#note-search")!;
  const selectedBeforeSearch = get(model.state).selectedId;
  search.value = "__no_note_matches_this_search__";
  search.dispatchEvent(new Event("input", { bubbles: true })); await tick();
  assert(document.querySelector("[data-empty-search]"), "header search filters the visible list");
  assert(!document.querySelector("#notes li"), "search hides unmatched rows");
  assert(get(model.state).selectedId === selectedBeforeSearch, "search does not change shared selection");
  search.value = "";
  search.dispatchEvent(new Event("input", { bubbles: true })); await tick();
  assert(document.querySelector("#notes li"), "clearing search restores the visible list");
  window.scrollTo(0, document.documentElement.scrollHeight);
  document.body.dataset.sveltePhase = "scrolling-owner";
  await until(() => window.scrollY > 0, "owner scroll applied");
  assert(mainHeader.getBoundingClientRect().top === 0, "header remains under native controls while diagnostics scroll");
  window.scrollTo(0, 0);
  let subscribers = 0;
  // Count only the inspector roots' subscriptions to the SAME store. The main
  // workspace keeps its own subscription; it must survive each child closing.
  const tracked = { ...model, state: { subscribe(run: Parameters<typeof model.state.subscribe>[0]) {
    subscribers++;
    const stop = model.state.subscribe(run);
    let active = true;
    return () => { if (active) { active = false; subscribers--; stop(); } };
  } } };
  const manager = createInspectorManager(tracked);
  try {
    document.body.dataset.sveltePhase = "opening-first";
    const first = await manager.open();
    document.body.dataset.sveltePhase = "opening-second";
    const second = await manager.open();
    assert(first && second, get(manager.state).error || "two windows must open");
    document.body.dataset.sveltePhase = "measuring-placement";
    const owner = currentWindow();
    const [ownerBounds, childBounds, display] = await Promise.all([owner.getBounds(), first.getBounds(), owner.getDisplay()]);
    assert(display, "visible owner has a display snapshot");
    const placement = inspectorPosition(ownerBounds, childBounds, display.workArea);
    assert(Math.abs(childBounds.x - placement.x) < 1 && Math.abs(childBounds.y - placement.y) < 1,
      "inspector is placed beside its owner and clamped to the usable display before presentation");
    assert(display.scaleFactor > 0 && display.bounds.width > 0 && display.id.length > 0, "native display measurements cross the typed bridge");
    await until(() => subscribers === 2, "two component roots");
    document.body.dataset.sveltePhase = "verifying-components";
    document.body.dataset.inspectorChrome = "pending";
    await pulse();
    await until(() => document.body.dataset.inspectorChrome === "ok", "native inspector creation policies");
    const firstDocument = first.document, secondDocument = second.document;
    const styleSelector = "[data-zapp-shared-style]";
    const firstStyle = firstDocument.querySelector(styleSelector);
    const secondStyle = secondDocument.querySelector(styleSelector);
    assert(firstStyle && secondStyle && firstStyle !== secondStyle, "shared styles have distinct child DOM ownership");
    const styleCount = firstDocument.querySelectorAll(styleSelector).length;
    assert(styleCount > 0, "factory installed shared sheets");
    assert(!document.querySelector(styleSelector), "no mirrored child node is kept in owner");
    assert(!firstDocument.querySelector('style[id^="svelte-"]'), "no Svelte injected-CSS registry path in child");
    const input = firstDocument.querySelector<HTMLInputElement>("#inspector-title");
    assert(input, "first inspector input");
    input.value = "Shared 資料 🌱";
    input.dispatchEvent(new firstDocument.defaultView!.Event("input", { bubbles: true }));
    await tick();
    assert(secondDocument.querySelector<HTMLInputElement>("#inspector-title")?.value === input.value, "child → child reactivity");
    const ownerInput = document.querySelector<HTMLInputElement>(`input[aria-label="Title for note ${note.id}"]`);
    assert(ownerInput?.value === input.value, "child → owner reactivity");
    ownerInput.value = "Owner edit";
    ownerInput.dispatchEvent(new Event("input", { bubbles: true }));
    await tick();
    assert(input.value === "Owner edit", "owner → child reactivity");
    const panel = firstDocument.querySelector<HTMLElement>("[data-note-inspector]");
    await until(() => !!panel && firstDocument.defaultView!.getComputedStyle(panel).getPropertyValue("--inspector-style-ready").trim() === "yes", "ordinary imported CSS in child document");
    const rootStyle = firstDocument.defaultView!.getComputedStyle(firstDocument.documentElement);
    const topInset = parseFloat(rootStyle.getPropertyValue("--zapp-titlebar-height"));
    const leftInset = parseFloat(rootStyle.getPropertyValue("--zapp-window-controls-inset-left"));
    assert(topInset > 0 && leftInset > 0, "child-local native chrome measurements arrive before inspector presentation");
    const header = firstDocument.querySelector<HTMLElement>("header")!;
    assert(header.getBoundingClientRect().bottom >= topInset, "inspector content clears native top chrome");
    assert(header.firstElementChild!.getBoundingClientRect().left >= leftInset, "inspector heading clears traffic lights");
    assert(input.getBoundingClientRect().top >= topInset, "editable content is below the native chrome");
    assert(!firstDocument.querySelector("[data-svelte-notes]"), "child must not bootstrap the owner workspace");
    assert(!firstDocument.querySelector('script[src*="app.js"]'), "child must not load an application entrypoint");
    const save = [...firstDocument.querySelectorAll("button")].find(button => button.textContent?.includes("Save through"));
    assert(save && !save.disabled, "dirty inspector save button"); save.click();
    await until(() => !get(model.state).busy && get(model.state).items[0]?.title === "Owner edit", "save through the owner's generated service");
    assert(get(model.state).error === "", "no native save failure");
    first.close();
    await until(() => subscribers === 1 && get(manager.state).count === 1, "first root unmounted");
    assert(!firstDocument.querySelector("[data-note-inspector]"), "first root DOM removed");
    assert(!firstStyle.isConnected && !firstDocument.querySelector(styleSelector), "closed child's stylesheet removed");
    assert(secondStyle.isConnected, "closing one inspector preserves sibling styles");
    model.setTitle(note.id, "Still live"); await tick();
    assert(secondDocument.querySelector<HTMLInputElement>("#inspector-title")?.value === "Still live", "surviving root stays reactive");
    const close = [...secondDocument.querySelectorAll("button")].find(button => button.textContent === "Close inspector");
    assert(close, "child close button"); close.click();
    await until(() => subscribers === 0 && get(manager.state).count === 0, "all inspector subscriptions released");
    assert(!secondStyle.isConnected && !secondDocument.querySelector(styleSelector), "second stylesheet removed");
    const reopened = await manager.open();
    assert(reopened, "inspector reopens after cleanup");
    await until(() => subscribers === 1, "reopened component subscribed");
    const reopenedDocument = reopened.document;
    const reopenedStyle = reopenedDocument.querySelector(styleSelector);
    assert(reopenedStyle && reopenedStyle !== firstStyle && reopenedStyle !== secondStyle, "reopened child owns a fresh stylesheet");
    assert(reopenedDocument.querySelectorAll(styleSelector).length === styleCount, "no duplicate styles on reopen");
    reopened.close();
    await until(() => subscribers === 0 && get(manager.state).count === 0, "reopened inspector cleaned up");
    assert(!reopenedStyle.isConnected, "reopened stylesheet removed");
    // Restore persisted seed data so this probe composes with launch tests.
    model.setTitle(note.id, note.title); await model.save(note.id);
    assert(!get(model.state).error, "restoring the seed title");
    if (import.meta.env.VITE_ZAPP_STYLE_SMOKE === "1") {
      const { verifyStyleSharing } = await import("./style-experiment/webkit-smoke");
      await verifyStyleSharing(pulse);
      const { verifyPublicStyling } = await import("./style-experiment/public-smoke");
      await verifyPublicStyling(pulse);
    }
    document.body.dataset.svelteInspector = "ok";
    document.body.dataset.sveltePhase = "complete";
  } finally { manager.dispose(); }
}
