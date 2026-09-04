import json from "std/json";
import { Map } from "std/collections";
import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import { ApplicationMenu } from "./application-menu.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeCapabilityFailure,
  bridgeFailure,
  bridgePermissionFailure,
  bridgeSuccess,
} from "./bridge.zs";
import {
  Command,
  CommandAction,
  CommandOptions,
  Menu,
  MenuError,
  MenuGroup,
  MenuItem,
  MenuRole,
} from "./menu.zs";

export type FrontendMenuCommandDispatch = (
  nativeWindowId: i32,
  in ownerToken: String,
  in commandId: String
) => void on thread.main;

readonly struct FrontendMenuItem {
  kind: String;
  commandId: String = "";
  label: String = "";
  shortcut: String = "";
  enabled: boolean = true;
  role: String = "";
  items: Array<FrontendMenuItem> = Array<FrontendMenuItem>();
}

readonly struct FrontendMenuDefinition {
  ownerToken: String;
  items: Array<FrontendMenuItem>;
}

readonly struct FrontendMenuCommandUpdate {
  ownerToken: String;
  commandId: String;
  enabled: boolean;
}

export enum MenuBridgeRoute {
  response BridgeResponse,
  unhandled,
}

function frontendMenuError(message: String): MenuError {
  return MenuError({ message: move message });
}

function frontendMenuFailure(
  id: u64,
  in error: MenuError
): BridgeResponse {
  return bridgeFailure(id, "MENU_ERROR", copy error.message);
}

function menuRole(in name: String): MenuRole throws MenuError {
  if (name == "application") return MenuRole.application;
  if (name == "edit") return MenuRole.edit;
  if (name == "window") return MenuRole.window;
  if (name == "about") return MenuRole.about;
  if (name == "services") return MenuRole.services;
  if (name == "hide") return MenuRole.hide;
  if (name == "hideOthers") return MenuRole.hideOthers;
  if (name == "showAll") return MenuRole.showAll;
  if (name == "quit") return MenuRole.quit;
  if (name == "undo") return MenuRole.undo;
  if (name == "redo") return MenuRole.redo;
  if (name == "cut") return MenuRole.cut;
  if (name == "copy") return MenuRole.copy;
  if (name == "paste") return MenuRole.paste;
  if (name == "selectAll") return MenuRole.selectAll;
  if (name == "minimize") return MenuRole.minimize;
  if (name == "zoom") return MenuRole.zoom;
  if (name == "close") return MenuRole.close;
  if (name == "toggleFullScreen") return MenuRole.toggleFullScreen;
  throw frontendMenuError(`unknown frontend menu role "${name}"`);
}

function frontendCommand(
  in item: FrontendMenuItem,
  nativeWindowId: i32,
  in ownerToken: String,
  dispatch: FrontendMenuCommandDispatch,
  inout commands: Map<String, Command>
): Command throws MenuError on thread.main {
  if (item.commandId.byteLength == 0) {
    throw frontendMenuError("frontend menu commands require an opaque identity");
  }
  const existing = commands.get(item.commandId);
  match (in existing) {
    some(command) => return command;
    none => {}
  }
  const retainedOwner = copy ownerToken;
  const retainedCommand = copy item.commandId;
  const action: CommandAction = move (): void => dispatch(
    nativeWindowId,
    in retainedOwner,
    in retainedCommand
  );
  const command = new Command(
    CommandOptions({
      label: copy item.label,
      shortcut: copy item.shortcut,
      enabled: item.enabled,
    }),
    action
  );
  commands.set(copy item.commandId, command);
  return command;
}

function frontendMenuItems(
  in input: Array<FrontendMenuItem>,
  nativeWindowId: i32,
  in ownerToken: String,
  dispatch: FrontendMenuCommandDispatch,
  inout commands: Map<String, Command>
): Array<MenuItem> throws MenuError on thread.main {
  let output = Array<MenuItem>();
  for (const item of input) {
    if (item.kind == "command") {
      output.push(MenuItem.command(try frontendCommand(
        in item,
        nativeWindowId,
        in ownerToken,
        dispatch,
        inout commands
      )));
    } else if (item.kind == "submenu") {
      output.push(MenuItem.submenu(MenuGroup({
        label: copy item.label,
        items: try frontendMenuItems(
          in item.items,
          nativeWindowId,
          in ownerToken,
          dispatch,
          inout commands
        ),
      })));
    } else if (item.kind == "separator") {
      output.push(MenuItem.separator);
    } else if (item.kind == "role") {
      output.push(MenuItem.role(try menuRole(in item.role)));
    } else {
      throw frontendMenuError(`unknown frontend menu item kind "${item.kind}"`);
    }
  }
  return output;
}

function setFrontendMenu(
  in message: BridgeMessage,
  nativeWindowId: i32,
  in logicalWindowId: String,
  dispatch: FrontendMenuCommandDispatch,
  menu: ApplicationMenu
): BridgeResponse on thread.main {
  const decoded = attempt json.decode<FrontendMenuDefinition>(
    in message.arguments
  );
  return match (decoded) {
    failure(error) => bridgeFailure(
      message.id,
      "MENU_ERROR",
      `invalid frontend menu: ${error.message}`
    );
    success(definition) => {
      let commands = Map<String, Command>();
      const converted = attempt frontendMenuItems(
        in definition.items,
        nativeWindowId,
        in definition.ownerToken,
        dispatch,
        inout commands
      );
      select match (converted) {
        failure(error) => frontendMenuFailure(message.id, in error);
        success(items) => {
          let current = menu;
          const installed = attempt current.setFrontend(
            Menu({ items: move items }),
            copy definition.ownerToken,
            copy logicalWindowId,
            move commands
          );
          select match (installed) {
            success => bridgeSuccess(message.id, "null");
            failure(error) => frontendMenuFailure(message.id, in error);
          };
        }
      };
    }
  };
}

function setFrontendCommandEnabled(
  in message: BridgeMessage,
  in logicalWindowId: String,
  menu: ApplicationMenu
): BridgeResponse on thread.main {
  const decoded = attempt json.decode<FrontendMenuCommandUpdate>(
    in message.arguments
  );
  return match (decoded) {
    failure(error) => bridgeFailure(
      message.id,
      "MENU_ERROR",
      `invalid frontend menu command update: ${error.message}`
    );
    success(update) => {
      let current = menu;
      const changed = attempt current.setFrontendCommandEnabled(
        in update.ownerToken,
        in logicalWindowId,
        in update.commandId,
        update.enabled
      );
      select match (changed) {
        success => bridgeSuccess(message.id, "null");
        failure(error) => frontendMenuFailure(message.id, in error);
      };
    }
  };
}

export function routeMenuBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  nativeWindowId: i32,
  in logicalWindowId: String,
  dispatch: FrontendMenuCommandDispatch,
  menu: ApplicationMenu
): MenuBridgeRoute on thread.main {
  if (message.kind != BridgeMessageKind.invoke) {
    return MenuBridgeRoute.unhandled;
  }
  if (
    message.method != "__zapp:menu:set"
    && message.method != "__zapp:menu:set-enabled"
  ) return MenuBridgeRoute.unhandled;
  if (!permissions.menu) {
    return MenuBridgeRoute.response(bridgePermissionFailure(
      message.id,
      "menu"
    ));
  }
  if (!capabilities.allowsPermission("menu")) {
    return MenuBridgeRoute.response(bridgeCapabilityFailure(
      message.id,
      "menu"
    ));
  }
  if (message.method == "__zapp:menu:set") {
    return MenuBridgeRoute.response(setFrontendMenu(
      in message,
      nativeWindowId,
      in logicalWindowId,
      dispatch,
      menu
    ));
  }
  return MenuBridgeRoute.response(setFrontendCommandEnabled(
    in message,
    in logicalWindowId,
    menu
  ));
}
