import { renderSidebarPane } from "./sidebar-pane";
import { renderMainPane } from "./main-pane";
import { renderInspectorPane } from "./inspector-pane";
import { renderPopoverPane } from "./popover-pane";
import { renderTitlebarShowcasePane } from "./titlebar-showcase-pane";
import { renderBgDemoPane } from "./bg-demo-pane";

export function routeShell(app: HTMLElement) {
  const hash = location.hash;
  if (hash.startsWith("#titlebar-showcase")) { renderTitlebarShowcasePane(app); return; }
  if (hash.startsWith("#bg-demo")) { renderBgDemoPane(app); return; }
  switch (hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    case "#popover-pane":   renderPopoverPane(app); break;
    default:                void renderMainPane(app); break;
  }
}
