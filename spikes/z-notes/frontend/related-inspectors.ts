import { mount, unmount } from "svelte";
import { writable } from "svelte/store";
import { createRelatedWindow, currentWindow, RelatedWindowEvent } from "@zappdev/runtime/window";
import type { RelatedWindowHandle, WindowEventSubscription } from "@zappdev/runtime/window";
import NoteInspector from "./NoteInspector.svelte";
import "./note-inspector.css";
import type { NotesModel } from "./notes-model";
import { inspectorPosition } from "./inspector-placement";

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
    let target: HTMLDivElement | undefined;
    let rollback: (() => void) | undefined;
    try {
      handle = await createRelatedWindow({
        title: "Note inspector", width: 440, height: 640, visible: false,
        resizable: false, maximizable: false, fullscreenable: false,
        titleBar: { style: "hiddenInset", titleVisible: false },
      });
      if (disposed) { handle.close(); return; }
      const windowHandle = handle;
      target = handle.document.createElement("div");
      // Ordinary CSS imports are shared by the factory. Local document layout
      // remains ours: the owner's centered page layout is not an inspector.
      handle.document.body.style.margin = "0";
      handle.document.body.style.display = "block";
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
        void unmount(component)
          .catch(error => console.error("Inspector cleanup failed", error))
          .finally(() => target?.remove());
        state.update(value => ({ ...value, count: live.size }));
      }
      rollback = cleanup;
      subscription = handle.subscribe(RelatedWindowEvent.INVALIDATED, cleanup);
      live.set(handle, cleanup);
      state.update(value => ({ ...value, count: live.size }));
      const owner = currentWindow();
      const [ownerBounds, inspectorBounds, display] = await Promise.all([
        owner.getBounds(), handle.getBounds(), owner.getDisplay(),
      ]);
      if (disposed) { handle.close(); return; }
      if (display) await handle.setPosition(inspectorPosition(ownerBounds, inspectorBounds, display.workArea));
      else await handle.center();
      handle.show();
      return handle;
    } catch (error) {
      rollback?.();
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
