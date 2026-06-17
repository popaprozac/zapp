import type { Section } from "./types";
import { homeSection } from "./home";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";
import { popoverSection } from "./popover";
import { multiwindowSection } from "./multiwindow";

export const registry: Section[] = [
  homeSection,
  sidebarSection,
  inspectorSection,
  toolbarSection,
  popoverSection,
  multiwindowSection,
];
