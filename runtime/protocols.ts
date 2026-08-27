/**
 * Custom URL protocols (G19) — webview-internal scheme handlers.
 *
 * Apps declare schemes in `zapp.config.ts` (e.g. `webview: {
 * protocols: ["asset", "media"] }`) and register a handler at runtime with
 * `Protocols.register("asset", handler)`. Whenever the webview
 * navigates to or fetches `asset://...`, the handler runs and
 * returns the response body + content type.
 *
 * **Different from `application.deepLinks`** — those are system-wide
 * (`myapp://...` from another app fires `App.on(AppEvent.OPEN_URL,
 * ...)`). Protocols are webview-internal: they only intercept
 * requests inside Zapp's own WebViews.
 *
 * @example
 * ```ts
 * // zapp.config.ts:  webview: { protocols: ["asset"] }
 *
 * import { Protocols } from "@zappdev/runtime";
 *
 * Protocols.register("asset", async (req) => {
 *   const id = new URL(req.url).pathname.slice(1);     // /thumb-123 → thumb-123
 *   const bytes = await loadAssetBytes(id);            // your storage
 *   return { body: bytes, contentType: "image/jpeg" };
 * });
 *
 * // Then anywhere in your HTML / CSS:
 * //   <img src="asset://thumb-123" />
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";
import { Services } from "./services";

export interface ProtocolRequest {
  /** Full URL of the request, e.g. `"asset://thumb-123"`. */
  url: string;
  /** HTTP method. Most webview requests are `GET`. */
  method: string;
}

export interface ProtocolResponse {
  /**
   * Response body. `Uint8Array` for binary content (images, audio,
   * etc.); `string` is encoded as UTF-8.
   */
  body: Uint8Array | string;
  /** MIME type. Defaults to `"application/octet-stream"`. */
  contentType?: string;
  /** HTTP status. Defaults to `200`. */
  status?: number;
}

export type ProtocolHandler =
  (request: ProtocolRequest) => ProtocolResponse | Promise<ProtocolResponse>;

// --- base64 (no DOM dependency required) ---
const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function bytesToBase64(bytes: Uint8Array): string {
  if (typeof btoa === "function") {
    let s = "";
    // 32K chunk avoids "Maximum call stack" on large blobs from String.fromCharCode(...arr).
    for (let i = 0; i < bytes.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + 0x8000)));
    }
    return btoa(s);
  }
  // Plain workers / no DOM fallback.
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const t = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_CHARS[(t >> 18) & 63] + B64_CHARS[(t >> 12) & 63]
         + B64_CHARS[(t >> 6)  & 63] + B64_CHARS[ t        & 63];
  }
  if (i < bytes.length) {
    const t = (bytes[i] << 16) | ((i + 1 < bytes.length ? bytes[i + 1] << 8 : 0));
    out += B64_CHARS[(t >> 18) & 63] + B64_CHARS[(t >> 12) & 63];
    out += i + 1 < bytes.length ? B64_CHARS[(t >> 6) & 63] : "=";
    out += "=";
  }
  return out;
}

// --- registry ---

interface InternalRegistration {
  scheme: string;
  handler: ProtocolHandler;
  unsubscribe: () => void;
}

const registry = new Map<string, InternalRegistration>();

export const Protocols = {
  /**
   * Register a handler for an in-webview URL scheme. The scheme
   * must be declared in `zapp.config.ts` `webview.protocols` —
   * WKWebView's scheme registration is config-time only, so adding
   * a scheme that wasn't declared at build time has no effect (no
   * handler will fire because no scheme is intercepted).
   *
   * Returns an unsubscribe function. Calling it removes the handler;
   * the scheme stays registered with WKWebView so a later call to
   * `Protocols.register` for the same scheme reattaches.
   */
  register(scheme: string, handler: ProtocolHandler): () => void {
    // Drop any existing registration so subsequent re-registers don't
    // accumulate listeners.
    const existing = registry.get(scheme);
    if (existing) existing.unsubscribe();

    const off = Events.on("__protocol:request", async (data: any) => {
      const d = typeof data === "string" ? JSON.parse(data) : data;
      if (!d || d.scheme !== scheme || !d.id) return;

      let response: ProtocolResponse;
      try {
        response = await handler({ url: d.url, method: d.method ?? "GET" });
      } catch (err) {
        // Reply 500 so WebKit cancels the request cleanly instead of
        // hanging waiting for a response.
        await Services.invoke("__protocol:respond", {
          id: d.id,
          body: "",
          contentType: "text/plain",
          status: 500,
        });
        console.error(`[zapp] Protocols("${scheme}") handler threw:`, err);
        return;
      }

      const bodyBytes = typeof response.body === "string"
        ? new TextEncoder().encode(response.body)
        : response.body;
      await Services.invoke("__protocol:respond", {
        id: d.id,
        body: bytesToBase64(bodyBytes),
        contentType: response.contentType ?? "application/octet-stream",
        status: response.status ?? 200,
      });
    });

    registry.set(scheme, { scheme, handler, unsubscribe: off });
    return () => {
      off();
      registry.delete(scheme);
    };
  },
};
