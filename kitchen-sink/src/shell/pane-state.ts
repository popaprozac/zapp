// #666: pane-section toggle state survives route navs. The sections fully
// re-render per route (single-bundle SPA — `render(host)` reruns from scratch
// each time the user navigates back to a section), so any `let`-bound local
// inside the render closure resets. The runtime already tracks collapsed/width
// live (win.sidebar.collapsed / win.sidebar.width, seeded from create-time
// options and updated via *-collapsed/-expanded/-resized events) — this store
// only covers what the runtime does NOT expose: collapsible/resizable, which
// are set-only (native has no getter), so the demo mirrors what it last SET
// (defaults = create-time config).
type PaneFlags = { collapsible: boolean; resizable: boolean };
type WindowPaneState = { sidebar: PaneFlags; inspector: PaneFlags };

const state = new Map<string, WindowPaneState>();

const defaults = (): WindowPaneState => ({
  sidebar: { collapsible: true, resizable: true },
  inspector: { collapsible: true, resizable: true },
});

export const paneState = {
  get(windowId: string): WindowPaneState {
    let s = state.get(windowId);
    if (!s) {
      s = defaults();
      state.set(windowId, s);
    }
    return s;
  },
  set(windowId: string, patch: Partial<WindowPaneState>): void {
    const s = paneState.get(windowId);
    if (patch.sidebar) Object.assign(s.sidebar, patch.sidebar);
    if (patch.inspector) Object.assign(s.inspector, patch.inspector);
  },
};
