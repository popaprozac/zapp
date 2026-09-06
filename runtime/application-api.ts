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

export interface ApplicationHandle {
  readonly clipboard: ClipboardManager;
  readonly notifications: NotificationManager;
  readonly shell: ShellManager;
  readonly dialogs: DialogManager;
  readonly menu: ApplicationMenu;
}

const current: ApplicationHandle = Object.freeze({
  clipboard: applicationClipboard,
  notifications: applicationNotifications,
  shell: applicationShell,
  dialogs: applicationDialogs,
  menu: applicationMenu,
});

export const Application = {
  /** Return the frontend handle for the currently running Zapp application. */
  current(): ApplicationHandle {
    return current;
  },
};
