/** Focused frontend API for explicit operating-system shell handoffs. */

import { getBridge } from "./bridge";
import { ensurePermission } from "./permissions";

export { ShellError } from "./shell-errors";
export type {
  ShellErrorPayload,
  ShellOperation,
} from "./shell-errors";

export interface ShellManager {
  /**
   * Open an absolute URL with the operating system's registered application.
   * Native policy requires both `shell:open` and a scheme listed by the
   * originating window's selected `security.navigation` profile.
   */
  openExternal(url: string): Promise<void>;

  /** Open an allowlisted filesystem path with its registered application. */
  openPath(path: string): Promise<void>;

  /** Reveal and select an allowlisted filesystem path in the OS file manager. */
  reveal(path: string): Promise<void>;

  /** Move an allowlisted filesystem path to the operating system's Trash. */
  trash(path: string): Promise<void>;
}

/** Stable shell manager used by the focused Application facade. */
export const applicationShell: ShellManager = {
  async openExternal(url: string): Promise<void> {
    ensurePermission("shell:open");
    await getBridge().invoke("__zapp:shell:open-external", { url });
  },

  async openPath(path: string): Promise<void> {
    ensurePermission("shell:open");
    await getBridge().invoke("__zapp:shell:open-path", { path });
  },

  async reveal(path: string): Promise<void> {
    ensurePermission("shell:reveal");
    await getBridge().invoke("__zapp:shell:reveal", { path });
  },

  async trash(path: string): Promise<void> {
    ensurePermission("shell:trash");
    await getBridge().invoke("__zapp:shell:trash", { path });
  },
};
