import AppKit from "AppKit/AppKit.h";
import objc from "std/objc";
import { TextBuffer } from "std/text";
import { thread } from "std/thread";
import {
  ApplicationMenuBackend,
  ApplicationMenuSetOperation,
  ApplicationMenuStopOperation,
} from "../../application-menu.zs";
import {
  Command,
  Menu,
  MenuError,
  MenuItem,
  MenuRole,
} from "../../menu.zs";
import { EventSubscription } from "../../events.zs";

struct MacOSMenuShortcut {
  key: String;
  modifiers: AppKit.NSEventModifierFlags;
}

function normalizedShortcutKey(
  in value: String
): String throws MenuError {
  if (value.byteLength != 1) {
    throw MenuError({
      message: "menu shortcut keys must contain one ASCII character",
    });
  }
  const byte = value.byteAt(0);
  if (byte >= 65 && byte <= 90) {
    let output = TextBuffer();
    output.appendAscii(byte + 32);
    return output.finish();
  }
  return value.copyBytes(0, value.byteLength);
}

function parseMacOSMenuShortcut(
  in value: String
): MacOSMenuShortcut throws MenuError {
  let modifiers: AppKit.NSEventModifierFlags = 0;
  let start: usize = 0;
  let cursor: usize = 0;
  while (cursor <= value.byteLength) {
    const atEnd = cursor == value.byteLength;
    if (!atEnd && value.byteAt(cursor) != 43) {
      cursor = cursor + 1;
      continue;
    }
    if (cursor == start) {
      throw MenuError({ message: `invalid menu shortcut "${value}"` });
    }
    const part = value.copyBytes(start, cursor);
    if (atEnd) {
      const key = try normalizedShortcutKey(in part);
      return MacOSMenuShortcut({
        key,
        modifiers,
      });
    }
    if (part == "Primary" || part == "Command") {
      modifiers = modifiers | AppKit.NSEventModifierFlagCommand;
    } else if (part == "Shift") {
      modifiers = modifiers | AppKit.NSEventModifierFlagShift;
    } else if (part == "Option" || part == "Alt") {
      modifiers = modifiers | AppKit.NSEventModifierFlagOption;
    } else if (part == "Control") {
      modifiers = modifiers | AppKit.NSEventModifierFlagControl;
    } else {
      throw MenuError({
        message: `unknown menu shortcut modifier "${part}"`,
      });
    }
    start = cursor + 1;
    cursor = start;
  }
  throw MenuError({ message: `invalid menu shortcut "${value}"` });
}

// AppKit's responder chain is selector-based. The typed Z role is narrowed to
// a private integer only at this raw boundary; no native identity crosses it.
function performMacOSMenuRole(
  role: i32
): void on thread.main = raw objc {
  switch (role) {
    case 3: [NSApp orderFrontStandardAboutPanel:nil]; break;
    case 5: [NSApp hide:nil]; break;
    case 6: [NSApp hideOtherApplications:nil]; break;
    case 7: [NSApp unhideAllApplications:nil]; break;
    case 8: [NSApp terminate:nil]; break;
    case 9: [NSApp sendAction:@selector(undo:) to:nil from:nil]; break;
    case 10: [NSApp sendAction:@selector(redo:) to:nil from:nil]; break;
    case 11: [NSApp sendAction:@selector(cut:) to:nil from:nil]; break;
    case 12: [NSApp sendAction:@selector(copy:) to:nil from:nil]; break;
    case 13: [NSApp sendAction:@selector(paste:) to:nil from:nil]; break;
    case 14: [NSApp sendAction:@selector(selectAll:) to:nil from:nil]; break;
    case 15: [[NSApp keyWindow] performMiniaturize:nil]; break;
    case 16: [[NSApp keyWindow] performZoom:nil]; break;
    case 17: [[NSApp keyWindow] performClose:nil]; break;
    case 18: [[NSApp keyWindow] toggleFullScreen:nil]; break;
    default: break;
  }
}

function nativeRoleCode(role: MenuRole): i32 {
  return match (role) {
    application => 0;
    edit => 1;
    window => 2;
    about => 3;
    services => 4;
    hide => 5;
    hideOthers => 6;
    showAll => 7;
    quit => 8;
    undo => 9;
    redo => 10;
    cut => 11;
    copy => 12;
    paste => 13;
    selectAll => 14;
    minimize => 15;
    zoom => 16;
    close => 17;
    toggleFullScreen => 18;
  };
}

function roleLabel(role: MenuRole): String {
  return match (role) {
    about => "About";
    services => "Services";
    hide => "Hide";
    hideOthers => "Hide Others";
    showAll => "Show All";
    quit => "Quit";
    undo => "Undo";
    redo => "Redo";
    cut => "Cut";
    copy => "Copy";
    paste => "Paste";
    selectAll => "Select All";
    minimize => "Minimize";
    zoom => "Zoom";
    close => "Close Window";
    toggleFullScreen => "Toggle Full Screen";
    application => "Application";
    edit => "Edit";
    window => "Window";
  };
}

function roleShortcut(role: MenuRole): String {
  return match (role) {
    hide => "Primary+H";
    hideOthers => "Primary+Option+H";
    quit => "Primary+Q";
    undo => "Primary+Z";
    redo => "Primary+Shift+Z";
    cut => "Primary+X";
    copy => "Primary+C";
    paste => "Primary+V";
    selectAll => "Primary+A";
    minimize => "Primary+M";
    close => "Primary+W";
    toggleFullScreen => "Control+Primary+F";
    _ => "";
  };
}

function configureMacOSMenuItemShortcut(
  in item: AppKit.NSMenuItem,
  in shortcut: String
): void throws MenuError on thread.main {
  if (shortcut.byteLength == 0) return;
  const parsed = try parseMacOSMenuShortcut(in shortcut);
  item.keyEquivalent = copy parsed.key;
  item.keyEquivalentModifierMask = parsed.modifiers;
}

function createMacOSActionItem(
  label: String,
  shortcut: String,
  action: () => void on thread.main,
  inout connections: Array<objc.Connection>
): AppKit.NSMenuItem throws MenuError on thread.main {
  const item = AppKit.NSMenuItem.alloc().init();
  item.title = move label;
  try configureMacOSMenuItemShortcut(in item, in shortcut);
  const connection = objc.connect(item, move (): void => action());
  connections.push(connection);
  return item;
}

function createMacOSCommandItem(
  command: Command,
  inout connections: Array<objc.Connection>,
  inout subscriptions: Array<EventSubscription>
): AppKit.NSMenuItem throws MenuError on thread.main {
  const retainedCommand = command;
  const item = try createMacOSActionItem(
    copy command.label,
    copy command.shortcut,
    move (): void => retainedCommand.invoke(),
    inout connections
  );
  item.enabled = command.isEnabled();
  const retainedItem = item;
  const subscription = try command.subscribeEnabled(
    move (in enabled: boolean): void => {
      retainedItem.enabled = enabled;
    }
  );
  subscriptions.push(subscription);
  return item;
}

function createMacOSRoleActionItem(
  role: MenuRole,
  inout connections: Array<objc.Connection>
): AppKit.NSMenuItem throws MenuError on thread.main {
  const code = nativeRoleCode(role);
  return try createMacOSActionItem(
    roleLabel(role),
    roleShortcut(role),
    move (): void => performMacOSMenuRole(code),
    inout connections
  );
}

function createMacOSRoleGroup(
  role: MenuRole,
  inout connections: Array<objc.Connection>
): AppKit.NSMenuItem throws MenuError on thread.main {
  const submenu = AppKit.NSMenu.alloc().initWithTitle(roleLabel(role));
  match (role) {
    application => {
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.about,
        inout connections
      ));
      submenu.addItem(AppKit.NSMenuItem.separatorItem());
      submenu.addItem(try createMacOSRoleGroup(
        MenuRole.services,
        inout connections
      ));
      submenu.addItem(AppKit.NSMenuItem.separatorItem());
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.hide,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.hideOthers,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.showAll,
        inout connections
      ));
      submenu.addItem(AppKit.NSMenuItem.separatorItem());
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.quit,
        inout connections
      ));
    }
    edit => {
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.undo,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.redo,
        inout connections
      ));
      submenu.addItem(AppKit.NSMenuItem.separatorItem());
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.cut,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.copy,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.paste,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.selectAll,
        inout connections
      ));
    }
    window => {
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.minimize,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.zoom,
        inout connections
      ));
      submenu.addItem(AppKit.NSMenuItem.separatorItem());
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.close,
        inout connections
      ));
      submenu.addItem(try createMacOSRoleActionItem(
        MenuRole.toggleFullScreen,
        inout connections
      ));
    }
    services => {}
    _ => return try createMacOSRoleActionItem(role, inout connections);
  }
  if (role == MenuRole.services) {
    AppKit.NSApplication.sharedApplication.servicesMenu = submenu;
  }
  const root = AppKit.NSMenuItem.alloc().init();
  root.title = roleLabel(role);
  root.submenu = submenu;
  if (role == MenuRole.window) {
    AppKit.NSApplication.sharedApplication.windowsMenu = submenu;
  }
  return root;
}

function createMacOSMenu(
  in items: Array<MenuItem>,
  inout connections: Array<objc.Connection>,
  inout subscriptions: Array<EventSubscription>
): AppKit.NSMenu throws MenuError on thread.main {
  const menu = AppKit.NSMenu.alloc().initWithTitle("");
  for (const item of items) {
    match (in item) {
      command(command) => menu.addItem(
        try createMacOSCommandItem(
          command,
          inout connections,
          inout subscriptions
        )
      );
      submenu(group) => {
        const submenu = try createMacOSMenu(
          in group.items,
          inout connections,
          inout subscriptions
        );
        const root = AppKit.NSMenuItem.alloc().init();
        root.title = group.label;
        root.submenu = submenu;
        menu.addItem(root);
      }
      separator => menu.addItem(AppKit.NSMenuItem.separatorItem());
      role(role) => menu.addItem(
        try createMacOSRoleGroup(role, inout connections)
      );
    }
  }
  return menu;
}

readonly class MacOSApplicationMenuRuntime on thread.main {
  menu: AppKit.NSMenu;
  connections: Array<objc.Connection>;
  subscriptions: Array<EventSubscription>;
}

class MacOSApplicationMenuBackendState on thread.main {
  readonly application: AppKit.NSApplication;
  current: MacOSApplicationMenuRuntime;

  function set(
    inout this,
    in definition: Menu
  ): void throws MenuError {
    let connections = Array<objc.Connection>();
    let subscriptions = Array<EventSubscription>();
    const menu = try createMacOSMenu(
      in definition.items,
      inout connections,
      inout subscriptions
    );
    this.application.mainMenu = menu;
    this.current = new MacOSApplicationMenuRuntime({
      menu,
      connections: move connections,
      subscriptions: move subscriptions,
    });
  }

  function stop(inout this): void {
    this.application.mainMenu = null;
    this.current = new MacOSApplicationMenuRuntime({
      menu: AppKit.NSMenu.alloc().initWithTitle(""),
      connections: Array<objc.Connection>(),
      subscriptions: Array<EventSubscription>(),
    });
  }
}

internal function macOSApplicationMenuBackend(
): ApplicationMenuBackend on thread.main {
  const state = new MacOSApplicationMenuBackendState({
    application: AppKit.NSApplication.sharedApplication,
    current: new MacOSApplicationMenuRuntime({
      menu: AppKit.NSMenu.alloc().initWithTitle(""),
      connections: Array<objc.Connection>(),
      subscriptions: Array<EventSubscription>(),
    }),
  });
  const setter = state;
  const set: ApplicationMenuSetOperation = move (
    in menu: Menu
  ): void => {
    try setter.set(in menu);
  };
  const stopper = state;
  const stop: ApplicationMenuStopOperation = move (): void => {
    stopper.stop();
  };
  return ApplicationMenuBackend({ set, stop });
}
