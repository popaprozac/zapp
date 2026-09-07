/** Focused frontend handle for application-owned managers. */

import {
  applicationMenu,
  type ApplicationMenu,
} from "./menu-api";
import {
  applicationClipboard,
  type ClipboardManager,
} from "./clipboard-api";
import {
  applicationNotifications,
  type NotificationManager,
} from "./notifications-api";
import {
  applicationShell,
  type ShellManager,
} from "./shell-api";
import {
  applicationDialogs,
  type DialogManager,
} from "./dialog-api";
import {
  applicationFiles,
  type FileManager,
} from "./files-api";
import { getBridge } from "./bridge";
import { ensurePermission } from "./permissions";

/** Read-only native decision, not a JavaScript shutdown veto or cleanup hook. */
export interface ApplicationQuitRequestedEvent {
  readonly cancelled: boolean;
}

export interface ApplicationEventSubscription {
  unsubscribe(): void;
}

export interface ApplicationEvents {
  readonly quitRequested: {
    subscribe(
      handler: (event: ApplicationQuitRequestedEvent) => void,
    ): ApplicationEventSubscription;
  };
}

const events: ApplicationEvents = Object.freeze({
  quitRequested: Object.freeze({
    subscribe(handler: (event: ApplicationQuitRequestedEvent) => void) {
      let active = true;
      const cleanup = getBridge().on("application:quit-requested", (value) => {
        if (!active || typeof value !== "object" || value === null) return;
        const cancelled = (value as Record<string, unknown>).cancelled;
        if (typeof cancelled !== "boolean") return;
        handler(Object.freeze({ cancelled }));
      });
      return {
        unsubscribe(): void {
          if (!active) return;
          active = false;
          cleanup();
        },
      };
    },
  }),
});

function quit(): void {
  ensurePermission("application:quit");
  const bridge = getBridge() as ReturnType<typeof getBridge> & {
    post?: (message: string) => void;
  };
  if (bridge.post) {
    bridge.post(JSON.stringify({ t: 4, m: "__zapp:application:quit", a: {} }));
    return;
  }
  bridge.emit("__zapp:application:quit", {});
}

export interface ApplicationHandle {
  /** Best-effort observation; accepted shutdown may destroy this WebView. */
  readonly events: ApplicationEvents;
  /** Request shutdown. Requires application:quit; native listeners may cancel.
   * This one-way call does not acknowledge acceptance or process exit.
   */
  quit(): void;
  readonly clipboard: ClipboardManager;
  readonly notifications: NotificationManager;
  readonly shell: ShellManager;
  readonly dialogs: DialogManager;
  readonly files: FileManager;
  readonly menu: ApplicationMenu;
}

const current: ApplicationHandle = Object.freeze({
  events,
  quit,
  clipboard: applicationClipboard,
  notifications: applicationNotifications,
  shell: applicationShell,
  dialogs: applicationDialogs,
  files: applicationFiles,
  menu: applicationMenu,
});

export const Application = {
  /** Return the frontend handle for the currently running Zapp application. */
  current(): ApplicationHandle {
    return current;
  },
};
