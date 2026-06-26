import { renderSidebarPane } from "./sidebar-pane";
import { renderMainPane } from "./main-pane";
import { renderInspectorPane } from "./inspector-pane";
import { renderPopoverPane } from "./popover-pane";
import { renderTitlebarShowcasePane } from "./titlebar-showcase-pane";
import { renderBgDemoPane, renderBgSidebarPane } from "./bg-demo-pane";
import { renderSheetPane } from "./sheet-pane";

export function routeShell(app: HTMLElement) {
  const hash = location.hash;
  if (hash.startsWith("#titlebar-showcase")) { renderTitlebarShowcasePane(app); return; }
  if (hash.startsWith("#bg-demo")) { renderBgDemoPane(app); return; }
  if (hash.startsWith("#sheet=")) { renderSheetPane(app); return; }
  switch (hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#bg-sidebar":     renderBgSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    case "#popover-pane":   renderPopoverPane(app); break;
    default:                void renderMainPane(app); break;
  }
}
