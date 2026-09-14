import { thread } from "std/thread";
import { Set } from "std/collections";
import { TitleBarOptions, TitleBarStyle, WindowOptions } from "../api/zapp/window.zs";
import { createWindowManager } from "../framework/window.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import { routeWindowBridgeMessage } from "../framework/window-bridge.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";

function main(): i32 on thread.main {
  const defaults = WindowOptions();
  if (defaults.titleBar.style != TitleBarStyle.default || !defaults.titleBar.titleVisible) return 1;
  let windows = createWindowManager();
  const owner = match (attempt windows.create(WindowOptions())) { success(value) => value; failure(_) => return 2; };
  let permissionNames = Set<String>(); permissionNames.add("window:create");
  const names = Array<String>("default");
  const methods = Set<String>();
  const workers = Set<String>();
  const capabilities = new CapabilitySelection({ names: names.freeze(), permissions: permissionNames.freeze(),
    serviceMethods: methods.freeze(), workerIds: workers.freeze() });
  const permissions = ApplicationPermissions({ windowCreate: true });
  const cases = Array<String>(
    '{}', '{"titleBar":{}}', '{"titleBar":{"style":"hidden"}}',
    '{"titleBar":{"style":"hiddenInset"}}',
    '{"title":"Secret","visible":false,"titleBar":{"style":"hiddenInset","titleVisible":false}}'
  );
  for (const source of cases) {
    const message = BridgeMessage({ kind: BridgeMessageKind.invoke, id: 1, method: "__window:create", arguments: copy source });
    match (routeWindowBridgeMessage(in message, in permissions, in owner.id, capabilities, inout windows)) {
      response(value) => { if (!value.ok) return 3; }
      _ => return 4;
    }
  }
  const all = windows.all();
  if (all.length != 6) return 5;
  const hidden = match (windows.options("win-4")) { some(value) => value; none => return 6; };
  if (hidden.titleBar.style != TitleBarStyle.hidden || !hidden.titleBar.titleVisible) return 7;
  const inset = match (windows.options("win-5")) { some(value) => value; none => return 8; };
  if (inset.titleBar.style != TitleBarStyle.hiddenInset || !inset.titleBar.titleVisible) return 9;
  const last = match (windows.get("win-6")) { some(value) => value; none => return 10; };
  last.setTitle("Changed");
  const updated = match (windows.options("win-6")) { some(value) => value; none => return 11; };
  if (updated.title != "Changed" || updated.visible || updated.titleBar.titleVisible) return 12;
  const invalid = Array<String>(
    '{"titleBar":null}', '{"titleBar":[]}', '{"titleBar":"hidden"}',
    '{"titleBar":{"style":"other"}}', '{"titleBar":{"style":false}}',
    '{"titleBar":{"titleVisible":0}}', '{"titleBar":{"titleVisible":null}}',
    '{"titleBar":{"titleVisibile":false}}', '{"titleBar":{"style":"hidden","controls":false}}',
    '{"titleBar":{"style":"hidden","style":"default"}}'
  );
  for (const source of invalid) {
    const message = BridgeMessage({ kind: BridgeMessageKind.invoke, id: 1, method: "__window:create", arguments: copy source });
    match (routeWindowBridgeMessage(in message, in permissions, in owner.id, capabilities, inout windows)) {
      response(value) => { if (value.ok) return 13; }
      _ => return 14;
    }
  }
  const after = windows.all();
  if (after.length != 6) return 15;
  return 0;
}
