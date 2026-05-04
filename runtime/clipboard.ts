/**
 * Clipboard — read/write the system clipboard (NSPasteboard on macOS).
 *
 * Works in webviews, dedicated workers, and headless workers. Workers
 * use a sync host-object fast path (`__zappBridge.clipboard`); webviews
 * round-trip through the bridge IPC.
 *
 * @example
 * ```ts
 * import { Clipboard } from "@zappdev/runtime";
 *
 * await Clipboard.writeText("hello");
 * const text = await Clipboard.readText();
 *
 * if (await Clipboard.has("image")) {
 *   const png = await Clipboard.readImage();   // Uint8Array | null
 * }
 * ```
 */

import { getBridge } from "./bridge";

export type ClipboardFormat = "text" | "html" | "image" | "files";

// Sync host fast path — present in worker contexts. When available we
// skip the IPC round-trip and call the host directly. Returns the raw
// JS value the dispatcher produced (string / boolean / undefined).
function clipboardHost(): ((action: string, args?: unknown) => unknown) | null {
  const host = (globalThis as any).__zappBridge;
  return host?.clipboard ?? null;
}

// --- base64 helpers (PNG bytes wire format) ---
//
// The bridge is JSON-only, so PNG bytes cross as base64 strings. Browsers
// have atob/btoa; workers (JSC plain context, txiki) may not — fall back
// to manual encoding.
const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function bytesToBase64(bytes: Uint8Array): string {
  if (typeof btoa === "function") {
    let bin = "";
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
  }
  // Manual fallback (worker contexts without btoa).
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_CHARS[(n >> 18) & 63] + B64_CHARS[(n >> 12) & 63]
         + B64_CHARS[(n >> 6) & 63] + B64_CHARS[n & 63];
  }
  if (i < bytes.length) {
    const n1 = bytes[i] << 16 | (i + 1 < bytes.length ? bytes[i + 1] << 8 : 0);
    out += B64_CHARS[(n1 >> 18) & 63] + B64_CHARS[(n1 >> 12) & 63];
    out += i + 1 < bytes.length ? B64_CHARS[(n1 >> 6) & 63] : "=";
    out += "=";
  }
  return out;
}

function base64ToBytes(b64: string): Uint8Array {
  if (typeof atob === "function") {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  // Manual fallback.
  const lookup = new Uint8Array(256);
  for (let i = 0; i < B64_CHARS.length; i++) lookup[B64_CHARS.charCodeAt(i)] = i;
  const clean = b64.replace(/=+$/, "");
  const out = new Uint8Array((clean.length * 3) >> 2);
  let j = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const n = (lookup[clean.charCodeAt(i)] << 18)
            | (lookup[clean.charCodeAt(i + 1)] << 12)
            | ((i + 2 < clean.length ? lookup[clean.charCodeAt(i + 2)] : 0) << 6)
            | (i + 3 < clean.length ? lookup[clean.charCodeAt(i + 3)] : 0);
    out[j++] = (n >> 16) & 0xff;
    if (i + 2 < clean.length) out[j++] = (n >> 8) & 0xff;
    if (i + 3 < clean.length) out[j++] = n & 0xff;
  }
  return out.slice(0, j);
}

export const Clipboard = {
  /** Read clipboard text. Resolves to `""` when no text is present. */
  async readText(): Promise<string> {
    const host = clipboardHost();
    if (host) return Promise.resolve(host("readText") as string ?? "");
    const r = await getBridge().invoke("__clipboard:readText") as unknown;
    return typeof r === "string" ? r : "";
  },

  /** Write text to the clipboard, replacing existing contents. */
  async writeText(text: string): Promise<void> {
    const host = clipboardHost();
    if (host) { host("writeText", { text }); return; }
    await getBridge().invoke("__clipboard:writeText", { text });
  },

  /** Read clipboard HTML (if any). Resolves to `""` when absent. */
  async readHtml(): Promise<string> {
    const host = clipboardHost();
    if (host) return Promise.resolve(host("readHtml") as string ?? "");
    const r = await getBridge().invoke("__clipboard:readHtml") as unknown;
    return typeof r === "string" ? r : "";
  },

  /** Write HTML to the clipboard. */
  async writeHtml(html: string): Promise<void> {
    const host = clipboardHost();
    if (host) { host("writeHtml", { html }); return; }
    await getBridge().invoke("__clipboard:writeHtml", { html });
  },

  /**
   * Read clipboard image as PNG bytes. Resolves to `null` when no image
   * is present. Decodes Apple-deposited TIFF (Preview's Copy, screenshot
   * tools) into PNG transparently on the native side.
   */
  async readImage(): Promise<Uint8Array | null> {
    const host = clipboardHost();
    let b64 = "";
    if (host) {
      b64 = String(host("readImage") ?? "");
    } else {
      const r = await getBridge().invoke("__clipboard:readImagePng") as unknown;
      b64 = typeof r === "string" ? r : "";
    }
    if (!b64) return null;
    return base64ToBytes(b64);
  },

  /** Write a PNG image to the clipboard. Bytes must be valid PNG data. */
  async writeImage(png: Uint8Array): Promise<void> {
    const data = bytesToBase64(png);
    const host = clipboardHost();
    if (host) { host("writeImage", { data }); return; }
    await getBridge().invoke("__clipboard:writeImagePng", { data });
  },

  /**
   * Read file paths from the clipboard (e.g. files copied from Finder).
   * Resolves to `[]` when the clipboard has no file references.
   */
  async readFiles(): Promise<string[]> {
    const host = clipboardHost();
    let json = "[]";
    if (host) {
      json = String(host("readFiles") ?? "[]");
    } else {
      const r = await getBridge().invoke("__clipboard:readFiles") as unknown;
      json = typeof r === "string" ? r : "[]";
    }
    try {
      const parsed = JSON.parse(json);
      return Array.isArray(parsed) ? parsed.filter((p) => typeof p === "string") : [];
    } catch { return []; }
  },

  /** Test whether the clipboard contains a given format. */
  async has(format: ClipboardFormat): Promise<boolean> {
    const host = clipboardHost();
    if (host) return Promise.resolve(Boolean(host("has", { format })));
    const r = await getBridge().invoke("__clipboard:has", { format }) as unknown;
    return r === true;
  },

  /** Clear the clipboard's contents. */
  async clear(): Promise<void> {
    const host = clipboardHost();
    if (host) { host("clear"); return; }
    await getBridge().invoke("__clipboard:clear");
  },
};
