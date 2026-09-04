import { Set } from "std/collections";
import { thread } from "std/thread";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
} from "../framework/bridge.zs";
import {
  ClipboardBridgeRoute,
  routeClipboardBridgeMessage,
} from "../framework/clipboard-bridge.zs";
import {
  ClipboardBackend,
  ClipboardClearOperation,
  ClipboardReadTextOperation,
  ClipboardWriteTextOperation,
  createClipboardManager,
} from "../framework/clipboard.zs";

class ClipboardObservation on thread.main {
  text: String;
  clears: i32;
}

function selection(
  read: boolean,
  write: boolean
): CapabilitySelection {
  let names = Array<String>("default");
  let permissions = Set<String>();
  if (read) permissions.add("clipboard:read");
  if (write) permissions.add("clipboard:write");
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
  const observation = new ClipboardObservation({ text: "seed", clears: 0 });
  const readObservation = observation;
  const readText: ClipboardReadTextOperation = move (
  ): Option<String> => Option.some(copy readObservation.text);
  const writeObservation = observation;
  const writeText: ClipboardWriteTextOperation = move (
    in text: String
  ): void => {
    writeObservation.text = copy text;
  };
  const clearObservation = observation;
  const clear: ClipboardClearOperation = move (): void => {
    clearObservation.text = "";
    clearObservation.clears = clearObservation.clears + 1;
  };
  let clipboard = createClipboardManager();
  clipboard.start(ClipboardBackend({ readText, writeText, clear }));
  const permissions = ApplicationPermissions({
    clipboardRead: true,
    clipboardWrite: true,
  });
  const capabilities = selection(true, true);

  const read = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 1,
    method: "__zapp:clipboard:read-text",
    arguments: "{}",
  });
  match (routeClipboardBridgeMessage(
    in read,
    in permissions,
    capabilities,
    clipboard
  )) {
    response(value) => if (!value.ok) return 1;
    unhandled => return 2;
  }

  const write = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 2,
    method: "__zapp:clipboard:write-text",
    arguments: "{\"text\":\"updated\"}",
  });
  match (routeClipboardBridgeMessage(
    in write,
    in permissions,
    capabilities,
    clipboard
  )) {
    response(value) => if (!value.ok) return 3;
    unhandled => return 4;
  }
  if (observation.text != "updated") return 5;

  const clearMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 3,
    method: "__zapp:clipboard:clear",
    arguments: "{}",
  });
  match (routeClipboardBridgeMessage(
    in clearMessage,
    in permissions,
    capabilities,
    clipboard
  )) {
    response(value) => if (!value.ok) return 6;
    unhandled => return 7;
  }
  if (observation.clears != 1) return 8;

  const denied = ApplicationPermissions({
    clipboardRead: false,
    clipboardWrite: false,
  });
  match (routeClipboardBridgeMessage(
    in read,
    in denied,
    capabilities,
    clipboard
  )) {
    response(value) => if (value.ok) return 9;
    unhandled => return 10;
  }

  const noCapability = selection(false, false);
  match (routeClipboardBridgeMessage(
    in read,
    in permissions,
    noCapability,
    clipboard
  )) {
    response(value) => if (value.ok) return 11;
    unhandled => return 12;
  }
  clipboard.stop();
  return 0;
}
