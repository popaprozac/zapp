import { thread } from "std/thread";
import {
  BridgeMessage,
  BridgeMessageKind,
} from "../framework/bridge.zs";
import {
  routeWindowBridgeMessage,
} from "../framework/window-bridge.zs";
import {
  ApplicationPermissions,
} from "../framework/application-permissions.zs";
import { createWindowManager } from "../framework/window.zs";

function main(): i32 on thread.main {
  let windows = createWindowManager();
  const allowed = ApplicationPermissions({ windowCreate: true });
  const createMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 1,
    method: "__window:create",
    arguments: '{"title":"Diagnostics","url":"/diagnostics","width":480,"height":320}',
  });
  const created = routeWindowBridgeMessage(
    in createMessage,
    in allowed,
    inout windows
  );
  match (created) {
    some(response) => {
      if (!response.ok) return 1;
      if (response.payload != '{"windowId":"win-1"}') return 2;
    }
    none => return 3;
  }

  const listMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 2,
    method: "__zapp:windows-list",
    arguments: "{}",
  });
  const listed = routeWindowBridgeMessage(
    in listMessage,
    in allowed,
    inout windows
  );
  match (listed) {
    some(response) => {
      if (!response.ok) return 4;
      if (response.payload != '{"ids":["win-1"]}') return 5;
    }
    none => return 6;
  }

  const injectionMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 3,
    method: "__window:create",
    arguments: '{"title":"Unsafe","inject":["diagnostics"]}',
  });
  const rejected = routeWindowBridgeMessage(
    in injectionMessage,
    in allowed,
    inout windows
  );
  match (rejected) {
    some(response) => {
      if (response.ok) return 7;
      if (response.payload != '{"code":"INVALID_ARGUMENTS","message":"INVALID_WINDOW_OPTIONS: inject is native application policy","permission":""}') {
        return 8;
      }
    }
    none => return 9;
  }
  const afterRejectedInjection = windows.all();
  if (afterRejectedInjection.length != 1) return 10;

  const serviceMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 4,
    method: "notes.create",
    arguments: "{}",
  });
  const forwarded = routeWindowBridgeMessage(
    in serviceMessage,
    in allowed,
    inout windows
  );
  match (forwarded) {
    some(_) => return 11;
    none => {}
  }

  const deniedPermissions = ApplicationPermissions({ windowCreate: false });
  const forgedMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 5,
    method: "__window:create",
    arguments: '{"title":"Bypass"}',
  });
  const denied = routeWindowBridgeMessage(
    in forgedMessage,
    in deniedPermissions,
    inout windows
  );
  return match (denied) {
    none => 12;
    some(response) => {
      if (response.ok) return 13;
      if (response.payload != '{"code":"PERMISSION_DENIED","message":"permission \\"window:create\\" is required; add it to security.permissions in zapp.config.ts","permission":"window:create"}') {
        return 14;
      }
      const afterDeniedCreation = windows.all();
      if (afterDeniedCreation.length != 1) return 15;
      select 0;
    }
  };
}
