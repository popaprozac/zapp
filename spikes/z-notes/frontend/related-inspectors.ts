import { mount, unmount } from "svelte";
import { writable } from "svelte/store";
import { createRelatedWindow, RelatedWindowEvent } from "@zappdev/runtime/window";
import type { RelatedWindowHandle, WindowEventSubscription } from "@zappdev/runtime/window";
import NoteInspector from "./NoteInspector.svelte";
import inspectorCss from "./note-inspector.css?inline";
import type { NotesModel } from "./notes-model";

// Application code, not a framework adapter: one owner mounts components into
// related documents and releases them on terminal invalidation.
export function createInspectorManager(model: NotesModel) {
  const state = writable({ count: 0, opening: false, error: "" });
  const live = new Map<RelatedWindowHandle, () => void>();
  let disposed = false;
  let opening = false;
  async function open() {
    if (disposed || opening) return;
    opening = true;
    state.update(value => ({ ...value, opening: true, error: "" }));
    let handle: RelatedWindowHandle | undefined;
    let style: HTMLStyleElement | undefined;
    let target: HTMLDivElement | undefined;
    let rollback: (() => void) | undefined;
    try {
      handle = await createRelatedWindow({ title: "Note inspector", width: 440, height: 600 });
      if (disposed) { handle.close(); return; }
      const windowHandle = handle;
      target = handle.document.createElement("div");
      style = handle.document.createElement("style");
      style.dataset.noteInspectorStyle = "";
      style.textContent = inspectorCss;
      // ?inline returns CSS text without Vite/Svelte registering a child DOM
      // node. This closure owns the one style element until invalidation.
      handle.document.head.append(style);
      handle.document.body.style.margin = "0";
      handle.document.body.append(target);
      // Callbacks retain the OWNER's execution/bridge provenance. Passing a DOM
      // target does not rebind global window/document or native service calls.
      const component = mount(NoteInspector, { target, props: { model, close: () => windowHandle.close() } });
      let stopped = false;
      let subscription: WindowEventSubscription | undefined;
      function cleanup() {
        if (stopped) return;
        stopped = true;
        subscription?.unsubscribe();
        live.delete(windowHandle);
        style?.remove();
        void unmount(component)
          .catch(error => console.error("Inspector cleanup failed", error))
          .finally(() => target?.remove());
        state.update(value => ({ ...value, count: live.size }));
      }
      rollback = cleanup;
      subscription = handle.subscribe(RelatedWindowEvent.INVALIDATED, cleanup);
      live.set(handle, cleanup);
      state.update(value => ({ ...value, count: live.size }));
      return handle;
    } catch (error) {
      rollback?.();
      style?.remove();
      target?.remove();
      try { handle?.close(); } catch { /* Already invalidated. */ }
      state.update(value => ({ ...value, error: error instanceof Error ? error.message : String(error) }));
    } finally {
      opening = false;
      state.update(value => ({ ...value, opening: false }));
    }
  }
  function closeAll() {
    for (const [handle, cleanup] of live) {
      try { handle.close(); } catch { cleanup(); }
    }
  }
  return { state: { subscribe: state.subscribe }, open, closeAll,
    dispose() {
      disposed = true;
      closeAll();
      for (const cleanup of live.values()) cleanup();
    },
  };
}
export type InspectorManager = ReturnType<typeof createInspectorManager>;
