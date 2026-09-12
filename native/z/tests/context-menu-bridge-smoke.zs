import { Set } from "std/collections";
import { thread } from "std/thread";
import { ApplicationMenu } from "../framework/application-menu.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import { ContextMenuOptions } from "../framework/context-menu.zs";
import { Menu, MenuError } from "../framework/menu.zs";
import { routeContextMenuBridgeMessage } from "../framework/menu-bridge.zs";
import { WindowContextMenuOperation } from "../framework/window.zs";

class Observation on thread.main { calls: i32; shouldSelect: boolean; }

function capability(allowed: boolean): CapabilitySelection {
  let permissions = Set<String>();
  if (allowed) permissions.add("menu");
  let names = Array<String>("default");
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
  const menu = new ApplicationMenu();
  const observed = new Observation({ calls: 0, shouldSelect: true });
  const show: WindowContextMenuOperation = move (
    in id: String, in definition: Menu, options: ContextMenuOptions
  ): void => {
    observed.calls = observed.calls + 1;
    if (id != "origin" || options.x != 12.5 || options.y != 40.0) {
      observed.calls = -100;
      return;
    }
    if (observed.shouldSelect) {
      match (in definition.items[0]) {
        command(command) => command.invoke();
        _ => observed.calls = -100;
      }
    }
  };
  const request = BridgeMessage({
    kind: BridgeMessageKind.invoke, id: 12, method: "__zapp:menu:popup",
    arguments: "{\"ownerToken\":\"popup\",\"windowId\":\"origin\",\"x\":12.5,\"y\":40,\"items\":[{\"kind\":\"command\",\"commandId\":\"edit\",\"label\":\"Edit\"}]}",
  });
  const allowed = ApplicationPermissions({ menu: true });
  const selected = routeContextMenuBridgeMessage(in request, in allowed, capability(true), 7, "origin", menu, show);
  match (selected) {
    response(value) => if (!value.ok || value.payload != "{\"commandId\":\"edit\"}") return 1;
    unhandled => return 2;
  }
  observed.shouldSelect = false;
  const dismissed = routeContextMenuBridgeMessage(in request, in allowed, capability(true), 7, "origin", menu, show);
  match (dismissed) {
    response(value) => if (!value.ok || value.payload != "{\"commandId\":\"\"}") return 3;
    unhandled => return 4;
  }
  const wrong = routeContextMenuBridgeMessage(in request, in allowed, capability(true), 8, "other", menu, show);
  match (wrong) {
    response(value) => if (value.ok) return 5;
    unhandled => return 6;
  }
  const denied = routeContextMenuBridgeMessage(in request, in allowed, capability(false), 7, "origin", menu, show);
  match (denied) {
    response(value) => if (value.ok) return 7;
    unhandled => return 8;
  }
  const disabled = ApplicationPermissions({ menu: false });
  const disabledResult = routeContextMenuBridgeMessage(in request, in disabled, capability(true), 7, "origin", menu, show);
  match (disabledResult) {
    response(value) => if (value.ok) return 9;
    unhandled => return 10;
  }
  if (observed.calls != 2) return 11;
  return 0;
}
