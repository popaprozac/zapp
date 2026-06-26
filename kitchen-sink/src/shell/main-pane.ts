import { Window, Events, Platform, WindowEvent } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";

export function renderMainPane(app: HTMLElement) {
  // iPhone: render a static top bar that showcases in-page chrome. It hosts a
  // hamburger button wired to sidebar.toggle() (reads live native state, so
  // tap-out dismiss never desyncs it). macOS uses the real native window chrome
  // and sidebar — the top bar must NOT appear there.
  const iosTopBar = Platform.isIOS
    ? `<header class="ks-ios-topbar" aria-label="Navigation">
        <div class="ks-ios-topbar-inner">
          <button class="ks-ios-topbar-menu" data-sidebar-toggle aria-label="Toggle sidebar">☰</button>
          <span class="ks-ios-topbar-title">Kitchen Sink</span>
          <button class="ks-ios-topbar-inspector" data-inspector-toggle aria-label="Toggle inspector">⊟</button>
        </div>
      </header>`
    : "";
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-drag-region>
      <span class="drag-strip-label">⠿ Kitchen Sink — drag to move</span>
    </div>`;
  // On iOS the main-pane top padding must clear the fixed top bar instead of
  // the native titlebar. Add the --ios-offset modifier class accordingly.
  const mainPaneClass = Platform.isIOS
    ? "main-pane main-pane--ios-offset"
    : "main-pane";
  app.innerHTML = `
    ${dragStrip}
    ${iosTopBar}
    <div class="${mainPaneClass}"><div class="stage" data-stage></div></div>`;

  // iOS top bar: use sidebar.toggle() so the native split-view state is always
  // the source of truth — tap-out dismiss no longer desyncs the button.
  app
    .querySelector<HTMLButtonElement>("[data-sidebar-toggle]")
    ?.addEventListener("click", () => Window.current().sidebar?.toggle());

  // iOS top bar: inspector toggle (trailing button, iOS-only).
  app
    .querySelector<HTMLButtonElement>("[data-inspector-toggle]")
    ?.addEventListener("click", () => Window.current().inspector?.toggle());

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  let teardown: void | (() => void);

  const show = (id: string) => {
    if (typeof teardown === "function") teardown();
    teardown = undefined;
    const section = findSection(registry, id);
    if (!section) return;
    stage.innerHTML = "";
    teardown = section.render(stage);
  };

  // Only act on this window's own sidebar (ks:nav is a global emit; match windowId).
  Events.on("ks:nav", ({ id, windowId }: any) => { if (windowId === Window.current().id) show(id); });

  // SIDEBAR_* events reach the main + sidebar panes but NOT the inspector pane
  // (framework #627: zapp_pane_emit fans out to only two panes). Relay them over
  // the Events bus, windowId-scoped, so the Sidebar section's inspector — which
  // lives in the inspector pane — can reflect live sidebar state. (Set up once;
  // renderMainPane runs once per main-pane load.)
  const win = Window.current();
  win.on(WindowEvent.SIDEBAR_COLLAPSED, () => Events.emit("ks:sidebar-state", { state: "collapsed", windowId: win.id }));
  win.on(WindowEvent.SIDEBAR_EXPANDED, () => Events.emit("ks:sidebar-state", { state: "expanded", windowId: win.id }));
  win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => Events.emit("ks:sidebar-state", { state: "resized", width: d.width, windowId: win.id }));

  if (registry[0]) show(registry[0].id); // self-init to Home (race-free, in-pane)
}
