# Window visibility and focus

Z windows are application-owned handles. Their UI operations run on
`thread.main`; keeping a handle does not keep a closed native window alive.

```zs
window.show();   // Reveal without explicitly requesting app activation/key focus.
window.focus();  // Reveal/restore, then request foreground keyboard focus.
window.hide();   // Hide without closing or destroying the window.
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

## Requests are not notifications

`focus()` returns `void`, like `show()` and `hide()`. It requests activation;
it does not promise that keyboard focus has already changed. Subscribe to
`window.events.focused` / `blurred` when you need actual native notifications.
Repeated requests need not produce repeated events.

The current macOS backend uses `NSApplication.activate()`, whose success is
[subject to macOS activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activate()).
It does not use the deprecated ignoring-other-apps activation route. The
Windows and Linux backends for this Z API remain future work.

Before `app.run()`, a focus request also marks that window visible. The latest
pending request is applied after the registered windows are realized. Hiding
or closing that window cancels its pending request. Closed/expired handles
are harmless no-ops, consistent with the other window control operations.

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

Contributor checks:

```sh
bun native/z/testing/window-focus.ts
bun native/z/testing/window-focus.ts --native
```

Both compilers are checked at `-O0`/`-O2` with UBSan and process deadlines.
The native probe checks visibility and minimized-window restoration, reporting
actual key/activation state without assuming unattended processes can take
focus. User-initiated foreground activation still needs the visual check above.
