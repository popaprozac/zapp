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

export interface ApplicationHandle {
  readonly clipboard: ClipboardManager;
  readonly notifications: NotificationManager;
  readonly menu: ApplicationMenu;
}

const current: ApplicationHandle = Object.freeze({
  clipboard: applicationClipboard,
  notifications: applicationNotifications,
  menu: applicationMenu,
});

export const Application = {
  /** Return the frontend handle for the currently running Zapp application. */
  current(): ApplicationHandle {
    return current;
  },
};
