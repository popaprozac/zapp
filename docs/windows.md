# Window visibility, focus, and minimization

Z windows are application-owned handles. Their UI operations run on
`thread.main`; keeping a handle does not keep a closed native window alive.

```zs
window.show();   // Reveal without explicitly requesting app activation/key focus.
window.focus();  // Reveal/restore, then request foreground keyboard focus.
window.hide();   // Hide without closing or destroying the window.
window.minimize();   // Minimize through the platform's normal window behavior.
window.unminimize(); // Undo minimization; no explicit activation/focus request.
window.close();  // Follow the cancellable closeRequested lifecycle.
```

Use `focus()` for a tray **Show Application** action, a user-requested reopen,
or a command that should bring an existing window forward. It restores a
minimized window and reveals a hidden application/window. It does not create a
replacement window when the handle has already closed. Use `app.windows.all()`
or `get(id)` to select an existing handle, and `create(...)` when none remain.
Do not create another window merely because the existing one is hidden.

`show()` does not explicitly activate the application or make the window key.
For minimized-window restoration and foreground interaction, use `focus()`.
Ordinary visible window creation retains its existing startup behavior.

`unminimize()` does nothing when the window is not minimized. It does not reveal
an ordinarily hidden window: use `show()` for that, or `focus()` to bring it back
for interaction. The operating system still controls its normal restoration
and focus policy. Hiding and minimizing keep the native window, WebView, and
window-owned work alive; neither counts as closing the last window.

Maximize/zoom and fullscreen are not aliases for these operations and remain
separate API-design work.

## TypeScript window handles

The same controls are available from the focused window package:

```ts
import { currentWindow, WindowEvent } from "@zappdev/runtime/window";

const window = currentWindow();
window.minimize();
window.unminimize();
window.focus();

const subscription = window.subscribe(WindowEvent.MINIMIZED, event => {
  console.log("Minimized", event.windowId);
});
// Later, stop only this subscription:
subscription.unsubscribe();
```

These methods send requests and return `void`, consistent with `show()` and
`hide()`. They are not animation-completion promises. The bridge routes them
through the same native window-control path; source WebView identity and its
live capability selection are resolved natively, not accepted from a payload.

## Requests are not notifications

`focus()` returns `void`, like `show()` and `hide()`. It requests activation;
it does not promise that keyboard focus has already changed. Subscribe to
`window.events.focused` / `blurred` when you need actual native notifications.
Repeated requests need not produce repeated events.

Minimization is also observational. Native Z exposes
`window.events.minimized`, `window.events.unminimized`, and matching cases on
`window.events.all`. TypeScript exposes `WindowEvent.MINIMIZED` and
`WindowEvent.UNMINIMIZED`. Both payloads contain `windowId`. The macOS backend
publishes them from AppKit's
[minimized](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidminiaturize(_:))
and [unminimized](https://developer.apple.com/documentation/appkit/nswindow/diddeminiaturizenotification)
notifications, not optimistically from method calls. Notifications describe
native state; they are not a promise that every compositor animation has ended.

The current macOS backend uses `NSApplication.activate()`, whose success is
[subject to macOS activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activate()).
It does not use the deprecated ignoring-other-apps activation route. The
Windows and Linux backends for this Z API remain future work.

Before `app.run()`, a focus request also marks that window visible. The latest
pending request is applied after the registered windows are realized. Hiding
or closing that window cancels its pending request. Closed/expired handles
are harmless no-ops, consistent with the other window control operations.

Pre-start `minimize()` requests coalesce until native realization.
`unminimize()` cancels that pending request; `focus()` also cancels it and marks
the window visible. A later `minimize()` cancels pending focus. Closing the
window discards both. Native callbacks may synchronously close their window:
no request restores a stale registry record afterward.

Native focus callbacks may synchronously look up, hide, or close their own
window. The manager keeps the logical record available while calling the
backend and does not restore stale state after the callback returns.

## Try it in Z Notes

Run `bun run spike:z-notes:dev` from the repository root, then choose **Show Z
Notes** in its tray menu after each of these:

1. Put another application in front of Z Notes.
2. Hide Z Notes with Command-H.
3. Minimize its window using the yellow titlebar button.
4. Close all Z Notes windows using the red button.

The first three reuse and focus an existing window. The last creates and
focuses a fresh one. **Quit Z Notes** ends the application and dev server.

The **Native window actions** section also includes **Focus in 2 seconds**,
**Minimize for 2 seconds**, and **Minimize, then focus**. The latter two make the
distinction between restoration and an explicit focus request visible. Watch
the minimized/unminimized counters, and also try the native yellow button and
Dock restoration. Demo timers run in the WebView and may be throttled while
backgrounded; the tray's **Show Z Notes** action remains a native way back.

Contributor checks:

```sh
bun native/z/testing/window-focus.ts
bun native/z/testing/window-focus.ts --native
```

Both compilers are checked at `-O0`/`-O2` with UBSan and process deadlines.
The registry suite covers deferred/cancelled requests, callback reentrancy,
malformed and stale bridge targets, and native-only event publication. The
AppKit probe also checks repeated minimization requests and actual delegate
notifications. It separates animation cycles instead of treating notification
delivery as compositor completion.
The native probe checks visibility and minimized-window restoration, reporting
actual key/activation state without assuming unattended processes can take
focus. User-initiated foreground activation still needs the visual check above.
