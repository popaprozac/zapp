import { thread } from "std/thread";
import {
  BridgeMessage,
  BridgeMessageKind,
} from "../framework/bridge.zs";
import {
  routeWindowBridgeMessage,
} from "../framework/window-bridge.zs";
import { createWindowManager } from "../framework/window.zs";

function main(): i32 on thread.main {
  let windows = createWindowManager();
  const createMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 1,
    method: "__window:create",
    arguments: '{"title":"Diagnostics","url":"/diagnostics","width":480,"height":320}',
  });
  const created = routeWindowBridgeMessage(
    in createMessage,
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
    inout windows
  );
  match (rejected) {
    some(response) => {
      if (response.ok) return 7;
      if (response.payload != "INVALID_WINDOW_OPTIONS: inject is native application policy") {
        return 8;
      }
    }
    none => return 9;
  }
  if (windows.all().length != 1) return 10;

  const serviceMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 4,
    method: "notes.create",
    arguments: "{}",
  });
  const forwarded = routeWindowBridgeMessage(
    in serviceMessage,
    inout windows
  );
  return match (forwarded) {
    some(_) => 11;
    none => 0;
  };
}
