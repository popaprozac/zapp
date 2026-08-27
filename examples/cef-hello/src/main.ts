// cef-hello — the render+bridge smoke target for CEF via `webview.engine: "chromium"`
// production slice. One button, one service call: click → `greet` round-trips
// through Services.invoke (webview → Nim router → back), same bridge path
// WKWebView uses today, on whatever engine `zapp.config.ts`'s `webEngine`
// resolves to.
import { ContextMenu, Events, Services, Webview, Window, WindowEvent, type MenuItemDef } from "@zappdev/runtime";

const goButton = document.querySelector<HTMLButtonElement>("#go")!;
const out = document.querySelector<HTMLPreElement>("#out")!;
const tick = document.querySelector<HTMLPreElement>("#tick")!;
const which = document.querySelector<HTMLPreElement>("#which")!;

// Sub-cycle B: the page is shared by both CEF windows (same bundle), so the
// ONE thing that differs per-window at the JS layer is the native windowId
// carrier (Symbol.for('zapp.windowId'), injected per-browser at doc-start —
// see zapp_cef_host.m's bootstrap builder). Rendering it here is the visual
// proof (alongside the title bar) that each window has its OWN bridge/router
// identity, not a shared one.
//
// Sub-cycle C1: window 1's sidebar pane loads this SAME bundle at
// `zapp://index.html#sidebar-pane` (window.m's CEF pane-mounting branch), so
// `location.hash` is the only signal distinguishing the sidebar pane from the
// host pane — both panes share the host's window id (win-<host>), per the
// CEF branch's identity note.
const isSidebar = location.hash === "#sidebar-pane";
const isInspector = location.hash === "#inspector-pane";
// Popover-on-CEF Task 1: the popover's content is this SAME bundle at
// `zapp://index.html#popover-pane` (popover.m's CEF content branch, mirroring
// window.m's pane-mounting), distinguished the same way the sidebar/inspector
// panes are — by location.hash alone.
const isPopover = location.hash === "#popover-pane";
which.textContent = isInspector
  ? `INSPECTOR pane (window ${Window.current().id})`
  : isSidebar
    ? `SIDEBAR pane (window ${Window.current().id})`
    : isPopover
      ? `POPOVER pane (window ${Window.current().id})`
      : `HOST pane (window ${Window.current().id})`;
if (isSidebar) document.body.style.background = "#f0f4ff";
if (isInspector) document.body.style.background = "#fff4f0"; // distinct tint from the sidebar
if (isPopover) document.body.style.background = "#f5f0ff"; // distinct tint — identifies the popover content on sight

// Sub-cycle A gate: the ticker worker broadcasts `tick` every second; render it.
// If this increments on a chromium build, the worker→CEF broadcast edge works.
// Sub-cycle B gate: BOTH windows must tick (broadcast fans into every live
// CEF browser, not just the first).
// Sub-cycle C1 gate: BOTH panes of window 1 (host + sidebar) must tick too —
// same broadcast, proving it fans into every live CEF browser, not just the
// first pane registered per window.
Events.on("tick", (data: { n: number }) => {
  tick.textContent = `worker tick #${data.n}`;
});

goButton.addEventListener("click", async () => {
  out.textContent = "...";
  try {
    out.textContent = await Services.invoke<string, { name: string }>("greet", { name: "CEF" });
  } catch (e) {
    out.textContent = `error: ${e}`;
  }
});

// Sub-cycle B close-guard gate: toggling this sets the native per-window close
// guard (Window.setCloseGuard → router → windowShouldClose:). With it ON, the
// red close button is VETOED (the window stays open; console logs
// `[zapp-cef] windowShouldClose VETOED`) — proving a CEF window honors the SAME
// close guard WKWebView windows do, checked BEFORE the defer-pattern teardown.
const guard = document.querySelector<HTMLInputElement>("#guard")!;
const guardStatus = document.querySelector<HTMLPreElement>("#guardstatus")!;
guard.addEventListener("change", () => {
  Window.current().setCloseGuard(guard.checked);
  guardStatus.textContent = `close guard: ${guard.checked ? "ON — close is blocked" : "off"}`;
});

// C1/C2 gate: HOST pane only (accessory panes don't toggle themselves). Each
// click -> darwin_window_get_by_numeric_id resolves the CEF window's NSWindow
// (C1's ZAPP_HAS_CEF resolver fallback) -> zapp_{sidebar,inspector}_for_slot
// finds the split registry -> the pane collapses/expands. Before C1's resolver
// these no-op'd on CEF; before C2's inspector arm there was no inspector pane.
if (!isSidebar && !isInspector && !isPopover) {
  document.querySelector<HTMLButtonElement>("#toggle-sb")!
    .addEventListener("click", () => Window.current().sidebar?.toggle());
  document.querySelector<HTMLButtonElement>("#toggle-insp")!
    .addEventListener("click", () => Window.current().inspector?.toggle());

  // Sub-cycle D gate: DevTools-on-CEF. HOST pane only (same guard as the
  // toggles above — accessory panes don't need their own trigger; Cmd-Opt-I
  // already opens DevTools for whichever pane is focused, see
  // CefKeyboardHandler). Click -> Window.current().openDevTools() -> router
  // -> zapp_cef_show_dev_tools (own window, dev-gated on `inspectable`) ->
  // a Chromium DevTools window opens showing this pane's live html/css/console.
  document.querySelector<HTMLButtonElement>("#open-devtools")!
    .addEventListener("click", () => Window.current().openDevTools());

  // Popover-on-CEF Task 1 gate: click -> lazy-create the popover (once) ->
  // show it anchored to the button. The popover's own content pane (this same
  // bundle, loaded at #popover-pane) is where popover.m's CEF content branch
  // (pane_role=2) is exercised; `pop.show` anchors to a CEF pane's own NSView
  // via the ZAPP_HAS_CEF fallback in darwin_popover_show.
  // Type spelled via Awaited<ReturnType<...>> since PopoverHandle isn't
  // exported from @zappdev/runtime's public surface (v1).
  let pop: Awaited<ReturnType<ReturnType<typeof Window.current>["createPopover"]>> | undefined;
  document.querySelector<HTMLButtonElement>("#show-popover")!.addEventListener("click", async (e) => {
    // Capture BEFORE the await — currentTarget is nulled once dispatch ends
    // (normalizeAnchor's own warning, runtime/window.ts).
    const btn = e.currentTarget as HTMLElement;
    if (!pop) pop = await Window.current().createPopover({ url: "#popover-pane", width: 240, height: 160 });
    pop.show(btn, { edge: "bottom" }); // Anchor accepts an Element directly (normalizeAnchor measures it).
  });

  // Breakage #3 gate: embedded <zapp-webview> positioning on CEF. The native
  // panel must track this bordered frame's box. Window 1 is PANED (sidebar +
  // inspector), so this exercises the inset case that was mis-positioning.
  const embedFrame = document.createElement("div");
  embedFrame.style.cssText =
    "width:220px; height:140px; margin-top:12px; border:2px solid #c33; border-radius:6px; overflow:hidden;";
  document.body.appendChild(embedFrame);
  const embedWv = Webview.create({
    src: "data:text/html,<body style='margin:0;background:%23148;color:%23fff;font:14px system-ui;display:grid;place-items:center'>embedded webview</body>",
  });
  embedWv.style.cssText = "width:100%; height:100%; display:block;";
  embedFrame.appendChild(embedWv);
}
if (isSidebar || isInspector || isPopover) {
  // These are HOST-scoped controls: toggle sidebar/inspector, Open DevTools,
  // and Show popover all act on the host window via the window-scoped API
  // (every pane shares the host's windowId), so they're only WIRED in the
  // host pane. They render in every pane's shared HTML — hide the dead copies
  // here so the accessory panes don't show inert buttons. (Per-pane DevTools
  // is Cmd-Opt-I, which targets whichever pane is focused — see the
  // CefKeyboardHandler.)
  for (const id of ["toggle-sb", "toggle-insp", "open-devtools", "show-popover"]) {
    document.querySelector<HTMLElement>("#" + id)?.style.setProperty("display", "none");
  }
}

// C3 SPIKE (cef-toolbar): probe whether NSToolbar works with `webview.engine: "chromium"`
// window. The toolbar itself is attached create-time from Nim (app.nim's
// `toolbar:` field) — HOST pane only, since that's where the native NSToolbar
// lives (window.m's darwin_toolbar_attach is engine-agnostic and per-window,
// not per-pane). `Window.current().on(WindowEvent.TOOLBAR_CLICKED, ...)` is
// the raw bridge subscription (window.ts's WindowHandle.on — filters by
// windowId, independent of whether the clicked item was registered via a JS
// `toolbar.setItems({action})` closure). We use this raw form deliberately:
// the toolbar here is Nim-authored (no JS-side action closures registered),
// so the internal `toolbarActions` map (populated only by setItems) would
// never fire for it — this is the only way to observe the click from JS.
const tbclick = document.querySelector<HTMLPreElement>("#tbclick")!;
const tbheight = document.querySelector<HTMLPreElement>("#tbheight")!;
if (!isSidebar && !isInspector) {
  Window.current().on(WindowEvent.TOOLBAR_CLICKED, (payload: any) => {
    tbclick.textContent = `toolbar click: ${JSON.stringify(payload)}`;
  });
}

// Breakage #2 gate: native context menu on CEF. Right-click anywhere in the
// host pane -> ContextMenu.show -> router (showContextMenu) ->
// darwin_menu_show_context, which (with the CEF anchor-view fallback) pops a
// native NSMenu at the cursor. Clicking an item routes its action back to JS.
const ctxStatus = document.querySelector<HTMLPreElement>("#ctxstatus")!;
const ctxMenu: MenuItemDef[] = [
  { label: "Context: log a line", action: () => { ctxStatus.textContent = "context menu: item A clicked"; } },
  { type: "separator" },
  { label: "Context: item B", action: () => { ctxStatus.textContent = "context menu: item B clicked"; } },
];
document.addEventListener("contextmenu", (e) => {
  if (isSidebar || isInspector || isPopover) return;   // host pane only
  e.preventDefault();
  ContextMenu.show(ctxMenu, { event: e });
});

// Host window events must reach CEF windows + panes (host-event fan-out fix).
// Every pane subscribes; resizing/focusing window 1 should update ALL THREE.
const winevt = document.querySelector<HTMLPreElement>("#winevt")!;
Window.current().on(WindowEvent.RESIZE, (p) => {
  winevt.textContent = `window event: resize ${p.size.width}×${p.size.height}`;
});
Window.current().on(WindowEvent.FOCUS, () => { winevt.textContent = "window event: focus"; });
Window.current().on(WindowEvent.BLUR,  () => { winevt.textContent = "window event: blur"; });

// Render whatever --zapp-toolbar-height computes to — this is the WK-only
// zapp_toolbar_inject_metrics CSS var (zapp_webview_for_slot → WKWebView).
// On CEF this is expected to read "" (empty) unless C3 wires an equivalent
// injection path for CEF browsers. Re-read on toolbar click too, in case the
// value only becomes available/observable after some native round-trip.
function renderToolbarHeightVar(): void {
  const v = getComputedStyle(document.documentElement).getPropertyValue("--zapp-toolbar-height");
  tbheight.textContent = `--zapp-toolbar-height: "${v}" (${v.trim() === "" ? "EMPTY/absent" : "present"})`;
}
renderToolbarHeightVar();
setTimeout(renderToolbarHeightVar, 500); // re-check after CEF/native settle
