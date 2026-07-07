// cef-hello — the render+bridge smoke target for the CEF `webEngine:"chromium"`
// production slice. One button, one service call: click → `greet` round-trips
// through Services.invoke (webview → Nim router → back), same bridge path
// WKWebView uses today, on whatever engine `zapp.config.ts`'s `webEngine`
// resolves to.
import { Events, Services, Window } from "@zappdev/runtime";

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
which.textContent = isSidebar
  ? `SIDEBAR pane (window ${Window.current().id})`
  : `HOST pane (window ${Window.current().id})`;
if (isSidebar) document.body.style.background = "#f0f4ff";

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

// C1 sub-cycle Task 2 gate: HOST pane only (the sidebar pane has no sidebar
// of its own). Click -> darwin_window_get_by_numeric_id resolves the CEF
// window's NSWindow (window.m's new ZAPP_HAS_CEF fallback) -> zapp_sidebar_
// for_slot finds the split registry -> the sidebar collapses/expands. Before
// this task the resolver returned NULL for a CEF slot and this button
// would silently no-op.
if (!isSidebar) {
  document.querySelector<HTMLButtonElement>("#toggle-sb")!
    .addEventListener("click", () => Window.current().sidebar?.toggle());
}
