import { thread } from "std/thread";
import { Menu, MenuError, MenuItem } from "./menu.zs";

// Public placement shape; window presentation is wired in the next checkpoint.
export readonly struct ContextMenuOptions {
  x: f64;
  y: f64;
}

internal function validateContextMenuOptions(
  in options: ContextMenuOptions
): void throws MenuError {
  // Comparisons reject NaN; subtracting a coordinate from itself rejects
  // infinity without imposing an arbitrary finite coordinate limit.
  if (
    !(options.x >= 0.0)
    || !(options.y >= 0.0)
    || options.x - options.x != 0.0
    || options.y - options.y != 0.0
  ) {
    throw MenuError({ message: "context menu coordinates must be finite and nonnegative" });
  }
}

internal function validateContextMenuItems(
  in items: Array<MenuItem>
): void throws MenuError on thread.main {
  for (const item of items) {
    match (in item) {
      command(command) => {
        if (command.label.byteLength == 0) {
          throw MenuError({ message: "context menu command labels cannot be empty" });
        }
      }
      submenu(group) => {
        if (group.label.byteLength == 0) {
          throw MenuError({ message: "context submenu labels cannot be empty" });
        }
        try validateContextMenuItems(in group.items);
      }
      separator => {}
      role(_) => throw MenuError({
        message: "native menu roles are not supported by context menus yet; use a Command",
      });
    }
  }
}

internal type ContextMenuDismissOperation = () => void on thread.main;

function ignoreContextMenuDismiss(): void on thread.main {}

// A platform adapter retains this identity while the native menu tracks. It
// must keep its objc connections/subscriptions alive for the same interval.
// Retirement invalidates selection before invoking any reentrant native code.
internal class ContextMenuSession on thread.main {
  readonly generation: u64;
  readonly windowId: String;
  accepting: boolean;
  dismissRequested: boolean;
  selectedCommandId: String;
  dismiss: ContextMenuDismissOperation;

  function setDismiss(
    inout this,
    operation: ContextMenuDismissOperation
  ): void {
    this.dismiss = operation;
    if (!this.accepting) this.dismiss();
  }

  // Selection records an opaque adapter-local ID. Frontend callbacks are
  // invoked from the eventual response; native adapters invoke their Command
  // only if this gate succeeds. Dismissal never invents a selection.
  function selectCommand(
    inout this,
    in commandId: String
  ): boolean {
    if (!this.accepting || commandId.byteLength == 0) return false;
    this.accepting = false;
    this.selectedCommandId = copy commandId;
    return true;
  }

  function invalidate(inout this): void {
    const shouldDismiss = !this.dismissRequested;
    this.dismissRequested = true;
    this.accepting = false;
    this.selectedCommandId = "";
    if (shouldDismiss) this.dismiss();
  }

  function finish(inout this): String {
    this.accepting = false;
    this.dismissRequested = true;
    // Release captured platform state even if a retired session is retained
    // temporarily by an already queued native callback.
    this.dismiss = ignoreContextMenuDismiss;
    const selected = copy this.selectedCommandId;
    this.selectedCommandId = "";
    return selected;
  }
}

// One active native tracking loop per application in the first tier. A
// selected-but-not-yet-unwound session still occupies the slot, so command
// reentrancy cannot replace ownership underneath a native popup call.
internal class ContextMenuSessions on thread.main {
  current: Option<ContextMenuSession>;
  nextGeneration: u64;

  function activeSession(): Option<ContextMenuSession> {
    return match (in this.current) {
      some(session) => Option<ContextMenuSession>.some(session);
      none => Option<ContextMenuSession>.none;
    };
  }

  function begin(
    inout this,
    windowId: String,
    in menu: Menu,
    options: ContextMenuOptions
  ): ContextMenuSession throws MenuError {
    match (in this.current) {
      some(_) => throw MenuError({ message: "another context menu is already open" });
      none => {}
    }
    if (windowId.byteLength == 0) {
      throw MenuError({ message: "context menus require an owning window" });
    }
    try validateContextMenuOptions(in options);
    try validateContextMenuItems(in menu.items);
    const session = new ContextMenuSession({
      generation: this.nextGeneration,
      windowId: move windowId,
      accepting: true,
      dismissRequested: false,
      selectedCommandId: "",
      dismiss: ignoreContextMenuDismiss,
    });
    this.nextGeneration = this.nextGeneration + 1;
    this.current = Option<ContextMenuSession>.some(session);
    return session;
  }

  function invalidateWindow(inout this, in windowId: String): void {
    const retained = this.activeSession();
    match (retained) {
      some(session) => {
        if (session.windowId == windowId) session.invalidate();
      }
      none => {}
    }
  }

  function invalidateAll(inout this): void {
    const retained = this.activeSession();
    match (retained) {
      some(session) => session.invalidate();
      none => {}
    }
  }

  function finish(
    inout this,
    session: ContextMenuSession
  ): String {
    const retained = this.activeSession();
    match (retained) {
      some(current) => {
        if (current.generation != session.generation) return "";
        this.current = Option<ContextMenuSession>.none;
        return session.finish();
      }
      none => return "";
    }
  }
}

internal function createContextMenuSessions(): ContextMenuSessions on thread.main {
  return new ContextMenuSessions({
    current: Option<ContextMenuSession>.none,
    nextGeneration: 1,
  });
}
