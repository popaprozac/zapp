import type { Section } from "./types";
import { homeSection } from "./home";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";

// Sections appended in later tasks: popover, multiwindow.
export const registry: Section[] = [
  homeSection,
  sidebarSection,
  inspectorSection,
  toolbarSection,
];
