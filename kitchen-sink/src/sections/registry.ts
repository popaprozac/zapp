import type { Section } from "./types";
import { homeSection } from "./home";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";
import { popoverSection } from "./popover";
import { multiwindowSection } from "./multiwindow";
import { workersSection } from "./workers";
import { syncSection } from "./sync";
import { dialogsSection } from "./dialogs";
import { clipboardSection } from "./clipboard";
import { notificationsSection } from "./notifications";

export const registry: Section[] = [
  homeSection,
  sidebarSection,
  inspectorSection,
  toolbarSection,
  popoverSection,
  multiwindowSection,
  workersSection,
  syncSection,
  dialogsSection,
  clipboardSection,
  notificationsSection,
];
