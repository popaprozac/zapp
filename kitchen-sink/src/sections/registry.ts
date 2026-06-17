import type { Section } from "./types";
import { homeSection } from "./home";
import { sidebarSection } from "./sidebar";

// Sections appended in later tasks: inspector, toolbar, popover, multiwindow.
export const registry: Section[] = [
  homeSection,
  sidebarSection,
];
