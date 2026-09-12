import AppKit from "AppKit/AppKit.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { Map } from "std/collections";
import { Command, Menu, MenuError, MenuItem } from "../../menu.zs";
import { ContextMenuOptions, ContextMenuSession } from "../../context-menu.zs";
import { EventSubscription } from "../../events.zs";
import { currentMacOSApplication } from "./application-runtime.zs";
import { createMacOSCommandItemWithAction } from "./menu-backend.zs";

function createContextMenu(
  in items: Array<MenuItem>,
  session: ContextMenuSession,
  inout commands: Map<String, Command>,
  inout connections: Array<objc.Connection>,
  inout subscriptions: Array<EventSubscription>
): AppKit.NSMenu throws MenuError on thread.main {
  const menu = AppKit.NSMenu.alloc().initWithTitle("");
  menu.autoenablesItems = false;
  for (const item of items) {
    match (in item) {
      command(command) => {
        const id = `item-${commands.length}`;
        commands.set(copy id, command);
        const selected = session;
        const retainedCommand = command;
        const action: () => void on thread.main = move (): void => {
          if (retainedCommand.isEnabled()) selected.selectCommand(in id);
        };
        menu.addItem(try createMacOSCommandItemWithAction(
          command, action, inout connections, inout subscriptions
        ));
      }
      submenu(group) => {
        const submenu = try createContextMenu(
          in group.items, session, inout commands, inout connections, inout subscriptions
        );
        const root = AppKit.NSMenuItem.alloc().init();
        root.title = copy group.label;
        root.submenu = submenu;
        menu.addItem(root);
      }
      separator => menu.addItem(AppKit.NSMenuItem.separatorItem());
      role(_) => throw MenuError({ message: "context menus currently accept commands, submenus, and separators" });
    }
  }
  return menu;
}

// The owning window and callback connections remain retained across AppKit's
// nested tracking loop. Actions run only after that loop and session unwind.
internal function showMacOSContextMenu(
  in id: String,
  in definition: Menu,
  options: ContextMenuOptions
): void throws MenuError on thread.main {
  const runtime = currentMacOSApplication();
  const found = runtime.nativeWindow(in id);
  const window = match (found) {
    some(value) => value;
    none => throw MenuError({ message: "context menu window is no longer available" });
  };
  if (!window.window.visible) {
    throw MenuError({ message: "context menus require a visible window" });
  }
  const bounds = window.webView.bounds;
  if (options.x > bounds.size.width || options.y > bounds.size.height) {
    throw MenuError({ message: "context menu coordinates must be inside the window content" });
  }
  const sessions = runtime.contextMenus;
  const session = try sessions.begin(copy id, in definition, options);
  let commands = Map<String, Command>();
  let connections = Array<objc.Connection>();
  let subscriptions = Array<EventSubscription>();
  const created = attempt createContextMenu(
    in definition.items, session, inout commands, inout connections, inout subscriptions
  );
  match (created) {
    failure(error) => {
      const discardedSelection = sessions.finish(session);
      throw error;
    }
    success(menu) => {
      const tracked = menu;
      session.setDismiss(move (): void => tracked.cancelTrackingWithoutAnimation());
      let y = options.y;
      if (!window.webView.flipped) y = bounds.size.height - y;
      const location = AppKit.NSMakePoint(bounds.origin.x + options.x, bounds.origin.y + y);
      menu.popUpMenuPositioningItem(null, atLocation: location, inView: window.webView);
    }
  }
  const selected = sessions.finish(session);
  const command = commands.get(selected);
  match (in command) {
    some(value) => value.invoke();
    none => {}
  }
}

internal function showMacOSFrontendContextMenu(
  in id: String,
  in menu: Menu,
  options: ContextMenuOptions
): void throws MenuError on thread.main {
  const application = currentMacOSApplication();
  const found = application.nativeWindow(in id);
  const zoom = match (found) {
    some(window) => window.webView.pageZoom;
    none => throw MenuError({ message: "context menu window is no longer available" });
  };
  try showMacOSContextMenu(in id, in menu, ContextMenuOptions({
    x: options.x * zoom,
    y: options.y * zoom,
  }));
}
