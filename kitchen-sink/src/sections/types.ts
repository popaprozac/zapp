/** One feature showcase. Lives in src/sections/<id>.ts; registered in
 *  registry.ts. The sidebar pane renders one nav row per Section, the main
 *  pane renders render(), the inspector pane renders inspector(). render and
 *  inspector run in DIFFERENT webview panes (same bundle) and may return a
 *  teardown fn — the panes call it before switching sections so event
 *  subscriptions don't leak. */
export interface Section {
  id: string;
  label: string;
  /** Optional sf: symbol id for the sidebar nav row (cosmetic). */
  icon?: string;
  /** Paint the main pane into `host`. Optional teardown returned. */
  render(host: HTMLElement): void | (() => void);
  /** Paint the inspector pane into `host`. Optional teardown returned. */
  inspector?(host: HTMLElement): void | (() => void);
}

export function findSection(list: Section[], id: string): Section | undefined {
  return list.find((s) => s.id === id);
}
