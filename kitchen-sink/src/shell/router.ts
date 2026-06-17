import { renderSidebarPane } from "./sidebar-pane";
import { renderMainPane } from "./main-pane";
import { renderInspectorPane } from "./inspector-pane";
import { renderPopoverPane } from "./popover-pane";

export function routeShell(app: HTMLElement) {
  switch (location.hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    case "#popover-pane":   renderPopoverPane(app); break;
    default:                void renderMainPane(app); break;
  }
}
