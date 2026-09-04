/** Focused frontend API for the application-owned system clipboard. */

import { getBridge } from "./bridge";
import { ClipboardError } from "./clipboard-errors";
import { ensurePermission } from "./permissions";

export { ClipboardError } from "./clipboard-errors";
export type {
  ClipboardErrorPayload,
  ClipboardOperation,
} from "./clipboard-errors";

export interface ClipboardManager {
  /** Read UTF-8 text, or `null` when the clipboard has no text. */
  readText(): Promise<string | null>;
  /** Replace the clipboard with UTF-8 text. */
  writeText(text: string): Promise<void>;
  /** Remove all clipboard contents. */
  clear(): Promise<void>;
}

function clipboardResult(value: unknown): string | null {
  if (value === null || typeof value === "string") return value;
  throw new ClipboardError({
    operation: "readText",
    message: "native Zapp returned an invalid clipboard text value",
  });
}

/** @internal Shared by the focused Application facade. */
export const applicationClipboard: ClipboardManager = {
  async readText(): Promise<string | null> {
    ensurePermission("clipboard:read");
    return clipboardResult(await getBridge().invoke(
      "__zapp:clipboard:read-text",
      {},
    ));
  },

  async writeText(text: string): Promise<void> {
    ensurePermission("clipboard:write");
    await getBridge().invoke("__zapp:clipboard:write-text", { text });
  },

  async clear(): Promise<void> {
    ensurePermission("clipboard:write");
    await getBridge().invoke("__zapp:clipboard:clear", {});
  },
};
