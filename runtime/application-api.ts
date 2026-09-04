/** Focused frontend handle for application-owned managers. */

import {
  applicationMenu,
  type ApplicationMenu,
} from "./menu-api";

export interface ApplicationHandle {
  readonly menu: ApplicationMenu;
}

const current: ApplicationHandle = Object.freeze({
  menu: applicationMenu,
});

export const Application = {
  /** Return the frontend handle for the currently running Zapp application. */
  current(): ApplicationHandle {
    return current;
  },
};
