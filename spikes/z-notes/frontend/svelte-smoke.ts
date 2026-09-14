// Loaded only in an explicitly requested smoke build, never ordinary Notes.
import { get } from "svelte/store";
import { tick } from "svelte";
import { createInspectorManager } from "./related-inspectors";
import type { NotesModel } from "./notes-model";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(`Svelte inspector: ${message}`);
}
export async function verifySvelteInspectors(model: NotesModel, pulse: () => Promise<unknown>) {
  const deadline = Date.now() + 15_000;
  async function until(check: () => boolean, description: string) {
    while (!check()) {
      if (Date.now() > deadline) throw new Error(`Timed out: ${description}`);
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    await tick();
  }
  await until(() => document.body.dataset.cancellation === "ok", "normal Notes smoke");
  await model.refresh();
  const note = get(model.state).items[0];
  assert(note, "expected a persisted note");
  model.select(note.id);
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
    const first = await manager.open(); const second = await manager.open();
    assert(first && second, get(manager.state).error || "two windows must open");
    await until(() => subscribers === 2, "two component roots");
    const firstDocument = first.document, secondDocument = second.document;
    const styleSelector = "style[data-note-inspector-style]";
    const firstStyle = firstDocument.querySelector(styleSelector);
    const secondStyle = secondDocument.querySelector(styleSelector);
    assert(firstStyle && secondStyle && firstStyle !== secondStyle, "independently owned child styles");
    assert(firstDocument.querySelectorAll(styleSelector).length === 1, "one stylesheet per inspector");
    assert(!document.querySelector(styleSelector), "child stylesheet is not injected into owner");
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
    assert(panel && firstDocument.defaultView!.getComputedStyle(panel).getPropertyValue("--inspector-style-ready").trim() === "yes", "owned CSS in child document");
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
    assert(reopenedDocument.querySelectorAll(styleSelector).length === 1, "no duplicate styles on reopen");
    reopened.close();
    await until(() => subscribers === 0 && get(manager.state).count === 0, "reopened inspector cleaned up");
    assert(!reopenedStyle.isConnected, "reopened stylesheet removed");
    // Restore persisted seed data so this probe composes with launch tests.
    model.setTitle(note.id, note.title); await model.save(note.id);
    assert(!get(model.state).error, "restoring the seed title");
    if (import.meta.env.VITE_ZAPP_STYLE_SMOKE === "1") {
      const { verifyStyleSharing } = await import("./style-experiment/webkit-smoke");
      await verifyStyleSharing(pulse);
    }
    document.body.dataset.svelteInspector = "ok";
  } finally { manager.dispose(); }
}
