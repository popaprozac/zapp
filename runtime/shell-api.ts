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
}

/** Stable shell manager used by the focused Application facade. */
export const applicationShell: ShellManager = {
  async openExternal(url: string): Promise<void> {
    ensurePermission("shell:open");
    await getBridge().invoke("__zapp:shell:open-external", { url });
  },
};
