import { renderSidebarPane } from "./sidebar-pane";
import { renderMainPane } from "./main-pane";
import { renderInspectorPane } from "./inspector-pane";

export function routeShell(app: HTMLElement) {
  switch (location.hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    // "#popover-pane" added in a later task.
    default:                void renderMainPane(app); break;
  }
}
