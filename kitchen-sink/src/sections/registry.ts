import type { Section } from "./types";
import { homeSection } from "./home";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";

// Sections appended in later tasks: toolbar, popover, multiwindow.
export const registry: Section[] = [
  homeSection,
  sidebarSection,
  inspectorSection,
];
