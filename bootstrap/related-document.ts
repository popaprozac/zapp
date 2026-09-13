// Private framework resource, not a public URL option. Native creation still
// validates the exact owner/document reservation before accepting a child.
export const RELATED_DOCUMENT_SHELL_PATH = "/.zapp/related.html";

// No app entry, bridge copy, Vite client, or framework bootstrap. WebKit injects
// the child's own bridge; the owner renders into this ordinary DOM document.
export const RELATED_DOCUMENT_SHELL_HTML =
  '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>\n';
