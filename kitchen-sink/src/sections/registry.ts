import type { Section } from "./types";
import { sidebarSection } from "./sidebar";

// Sections appended in later tasks: inspector, toolbar, popover, multiwindow.
export const registry: Section[] = [
  sidebarSection,
];
