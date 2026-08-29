import { thread } from "std/thread";
import { Map, Set } from "std/collections";
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
import {
  ApplicationCapabilities,
  CapabilityProfile,
  CapabilitySelection,
} from "../framework/application-capabilities.zs";
import { authorizeServiceInvocation } from "../framework/async-bridge.zs";

function testCapabilities(
  windowCreate: boolean,
  notesCreate: boolean
): ApplicationCapabilities {
  let permissions = Array<String>();
  if (windowCreate) permissions.push("window:create");
  let serviceMethods = Array<String>();
  if (notesCreate) serviceMethods.push("notes.create");
  let profiles = Map<String, CapabilityProfile>();
  profiles.set("default", CapabilityProfile({
    permissions: permissions.freeze(),
    serviceMethods: serviceMethods.freeze(),
  }));
  return new ApplicationCapabilities({ profiles: profiles.freeze() });
}

function testSelection(
  windowCreate: boolean,
  notesCreate: boolean
): CapabilitySelection {
  const capabilities = testCapabilities(windowCreate, notesCreate);
  const profiles = Array<String>("default");
  const selected = capabilities.resolveProfiles(in profiles);
  return match (selected) {
    some(selection) => selection;
    none => {
      let names = Array<String>();
      let permissions = Set<String>();
      let serviceMethods = Set<String>();
      select new CapabilitySelection({
        names: names.freeze(),
        permissions: permissions.freeze(),
        serviceMethods: serviceMethods.freeze(),
      });
    }
  };
}

function main(): i32 on thread.main {
  let windows = createWindowManager();
  const allowed = ApplicationPermissions({ windowCreate: true });
  const capabilities = testSelection(true, true);
  const createMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 1,
    method: "__window:create",
    arguments: '{"title":"Diagnostics","url":"/diagnostics","width":480,"height":320}',
  });
  const created = routeWindowBridgeMessage(
    in createMessage,
    in allowed,
    capabilities,
    inout windows
  );
  match (created) {
    some(response) => {
      if (!response.ok) return 1;
      if (response.payload != '{"windowId":"win-1"}') return 2;
    }
    none => return 3;
  }
  const inherited = windows.options("win-1");
  match (inherited) {
    none => return 16;
    some(options) => {
      if (options.capabilities.length != 1) return 17;
      if (options.capabilities[0] != "default") return 18;
    }
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
    capabilities,
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
    capabilities,
    inout windows
  );
  match (rejected) {
    some(response) => {
      if (response.ok) return 7;
      if (response.payload != '{"code":"INVALID_ARGUMENTS","message":"INVALID_WINDOW_OPTIONS: inject and capabilities are native application policy","permission":"","service":"","method":"","errorType":"","details":""}') {
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
    capabilities,
    inout windows
  );
  match (forwarded) {
    some(_) => return 11;
    none => {}
  }
  const allowedService = authorizeServiceInvocation(
    in serviceMessage,
    capabilities
  );
  match (allowedService) {
    some(_) => return 19;
    none => {}
  }
  const serviceDeniedCapabilities = testSelection(true, false);
  const deniedService = authorizeServiceInvocation(
    in serviceMessage,
    serviceDeniedCapabilities
  );
  match (deniedService) {
    none => return 20;
    some(response) => {
      if (response.ok) return 21;
      if (response.payload != '{"code":"PERMISSION_DENIED","message":"permission \\"service:notes.create\\" is not granted to the selected window capability profiles","permission":"service:notes.create","service":"","method":"","errorType":"","details":""}') {
        return 22;
      }
    }
  }

  const forgedMessage = BridgeMessage({
    kind: BridgeMessageKind.invoke,
    id: 5,
    method: "__window:create",
    arguments: '{"title":"Bypass"}',
  });
  const profileDeniedCapabilities = testSelection(false, true);
  const deniedByProfile = routeWindowBridgeMessage(
    in forgedMessage,
    in allowed,
    profileDeniedCapabilities,
    inout windows
  );
  match (deniedByProfile) {
    none => return 23;
    some(response) => {
      if (response.ok) return 24;
      if (response.payload != '{"code":"PERMISSION_DENIED","message":"permission \\"window:create\\" is not granted to the selected window capability profiles","permission":"window:create","service":"","method":"","errorType":"","details":""}') {
        return 25;
      }
    }
  }

  const deniedPermissions = ApplicationPermissions({ windowCreate: false });
  const denied = routeWindowBridgeMessage(
    in forgedMessage,
    in deniedPermissions,
    capabilities,
    inout windows
  );
  return match (denied) {
    none => 12;
    some(response) => {
      if (response.ok) return 13;
      if (response.payload != '{"code":"PERMISSION_DENIED","message":"permission \\"window:create\\" is required; add it to security.permissions in zapp.config.ts","permission":"window:create","service":"","method":"","errorType":"","details":""}') {
        return 14;
      }
      const afterDeniedCreation = windows.all();
      if (afterDeniedCreation.length != 1) return 15;
      select 0;
    }
  };
}
