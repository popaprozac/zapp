import type { Section } from "./types";
import { homeSection } from "./home";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";
import { popoverSection } from "./popover";
import { contextMenuSection } from "./contextmenu";
import { multiwindowSection } from "./multiwindow";
import { workersSection } from "./workers";
import { syncSection } from "./sync";
import { dialogsSection } from "./dialogs";
import { clipboardSection } from "./clipboard";
import { notificationsSection } from "./notifications";
import { screenSection } from "./screen";
import { shortcutsSection } from "./shortcuts";
import { dockSection } from "./dock";
import { eventsSection } from "./events";
import { windowLogSection } from "./window-log";
import { appEventsSection } from "./app-events";
import { filedropSection } from "./filedrop";
import { traySection } from "./tray";

export const registry: Section[] = [
  homeSection,
  sidebarSection,
  inspectorSection,
  toolbarSection,
  popoverSection,
  contextMenuSection,
  multiwindowSection,
  workersSection,
  syncSection,
  dialogsSection,
  clipboardSection,
  notificationsSection,
  screenSection,
  shortcutsSection,
  dockSection,
  eventsSection,
  windowLogSection,
  appEventsSection,
  filedropSection,
  traySection,
];
