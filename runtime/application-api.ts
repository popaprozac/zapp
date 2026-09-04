/** Focused frontend handle for application-owned managers. */

import {
  applicationMenu,
  type ApplicationMenu,
} from "./menu-api";
import {
  applicationClipboard,
  type ClipboardManager,
} from "./clipboard-api";

export interface ApplicationHandle {
  readonly clipboard: ClipboardManager;
  readonly menu: ApplicationMenu;
}

const current: ApplicationHandle = Object.freeze({
  clipboard: applicationClipboard,
  menu: applicationMenu,
});

export const Application = {
  /** Return the frontend handle for the currently running Zapp application. */
  current(): ApplicationHandle {
    return current;
  },
};
