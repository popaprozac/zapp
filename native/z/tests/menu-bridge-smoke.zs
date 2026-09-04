import { Set } from "std/collections";
import { thread } from "std/thread";
import { ApplicationMenu } from "../framework/application-menu.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
} from "../framework/bridge.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import {
  FrontendMenuCommandDispatch,
  routeMenuBridgeMessage,
} from "../framework/menu-bridge.zs";

class MenuBridgeObservation on thread.main {
  count: i32;
  owner: String;
  command: String;
}

function selection(allowsMenu: boolean): CapabilitySelection {
  let names = Array<String>("default");
  let permissions = Set<String>();
  if (allowsMenu) permissions.add("menu");
  let services = Set<String>();
  let workers = Set<String>();
  return new CapabilitySelection({
    names: names.freeze(),
    permissions: permissions.freeze(),
    serviceMethods: services.freeze(),
    workerIds: workers.freeze(),
  });
}

function main(): i32 on thread.main {
  const observation = new MenuBridgeObservation({
    count: 0,
    owner: "",
    command: "",
  });
  const retained = observation;
  const dispatch: FrontendMenuCommandDispatch = move (
    nativeWindowId: i32,
    in ownerToken: String,
    in commandId: String
  ): void => {
    if (nativeWindowId == 7) retained.count = retained.count + 1;
    retained.owner = copy ownerToken;
    retained.command = copy commandId;
  };
  let menu = new ApplicationMenu();
  const allowed = ApplicationPermissions({ menu: true });
  const capabilities = selection(true);
  const install = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 1,
    method: "__zapp:menu:set",
    arguments: "{\"ownerToken\":\"owner-1\",\"items\":[{\"kind\":\"role\",\"role\":\"application\"},{\"kind\":\"submenu\",\"label\":\"File\",\"items\":[{\"kind\":\"command\",\"commandId\":\"command-1\",\"label\":\"New Note\",\"shortcut\":\"Primary+N\",\"enabled\":true},{\"kind\":\"command\",\"commandId\":\"command-1\",\"label\":\"New Note\",\"shortcut\":\"Primary+N\",\"enabled\":true},{\"kind\":\"separator\"}]},{\"kind\":\"role\",\"role\":\"edit\"}]}",
  });
  const installed = routeMenuBridgeMessage(
    in install,
    in allowed,
    capabilities,
    7,
    "win-7",
    dispatch,
    menu
  );
  match (installed) {
    response(value) => if (!value.ok) return 1;
    unhandled => return 2;
  }
  if (menu.state.frontendCommands.length != 1) return 3;
  const found = menu.state.frontendCommands.get("command-1");
  match (in found) {
    some(command) => command.invoke();
    none => return 4;
  }
  if (observation.count != 1) return 5;
  if (observation.owner != "owner-1") return 6;
  if (observation.command != "command-1") return 7;

  const disable = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 2,
    method: "__zapp:menu:set-enabled",
    arguments: "{\"ownerToken\":\"owner-1\",\"commandId\":\"command-1\",\"enabled\":false}",
  });
  const disabled = routeMenuBridgeMessage(
    in disable,
    in allowed,
    capabilities,
    7,
    "win-7",
    dispatch,
    menu
  );
  match (disabled) {
    response(value) => if (!value.ok) return 8;
    unhandled => return 9;
  }
  match (in found) {
    some(command) => command.invoke();
    none => return 10;
  }
  if (observation.count != 1) return 11;

  const stale = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 3,
    method: "__zapp:menu:set-enabled",
    arguments: "{\"ownerToken\":\"old-owner\",\"commandId\":\"command-1\",\"enabled\":true}",
  });
  const staleResult = routeMenuBridgeMessage(
    in stale,
    in allowed,
    capabilities,
    7,
    "win-7",
    dispatch,
    menu
  );
  match (staleResult) {
    response(value) => if (value.ok) return 12;
    unhandled => return 13;
  }

  const wrongWindow = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 4,
    method: "__zapp:menu:set-enabled",
    arguments: "{\"ownerToken\":\"owner-1\",\"commandId\":\"command-1\",\"enabled\":true}",
  });
  const wrongWindowResult = routeMenuBridgeMessage(
    in wrongWindow,
    in allowed,
    capabilities,
    8,
    "win-8",
    dispatch,
    menu
  );
  match (wrongWindowResult) {
    response(value) => if (value.ok) return 14;
    unhandled => return 15;
  }

  let invalidated = menu;
  invalidated.invalidateFrontendOwner("win-7");
  if (menu.state.frontendCommands.length != 0) return 16;
  return 0;
}
