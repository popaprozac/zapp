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
  let workerIds = Array<String>();
  let profiles = Map<String, CapabilityProfile>();
  profiles.set("default", CapabilityProfile({
    permissions: permissions.freeze(),
    serviceMethods: serviceMethods.freeze(),
    workerIds: workerIds.freeze(),
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
      let workerIds = Set<String>();
      select new CapabilitySelection({
        names: names.freeze(),
        permissions: permissions.freeze(),
        serviceMethods: serviceMethods.freeze(),
        workerIds: workerIds.freeze(),
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
    response(value) => {
      if (!value.ok) return 1;
      if (value.payload != '{"windowId":"win-1"}') return 2;
    }
    handled => return 3;
    unhandled => return 3;
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
    response(value) => {
      if (!value.ok) return 4;
      if (value.payload != '{"ids":["win-1"]}') return 5;
    }
    handled => return 6;
    unhandled => return 6;
  }

  const hideMessage = BridgeMessage({
    kind: BridgeMessageKind.action,
    id: 0,
    method: "hide",
    arguments: '{"windowId":"win-1"}',
  });
  const hidden = routeWindowBridgeMessage(
    in hideMessage,
    in allowed,
    capabilities,
    inout windows
  );
  match (hidden) {
    handled => {}
    response(_) => return 26;
    unhandled => return 26;
  }
  const hiddenOptions = windows.options("win-1");
  match (hiddenOptions) {
    some(options) => if (options.visible) return 27;
    none => return 27;
  }

  const showMessage = BridgeMessage({
    kind: BridgeMessageKind.action,
    id: 0,
    method: "show",
    arguments: '{"windowId":"win-1"}',
  });
  const shown = routeWindowBridgeMessage(
    in showMessage,
    in allowed,
    capabilities,
    inout windows
  );
  match (shown) {
    handled => {}
    response(_) => return 28;
    unhandled => return 28;
  }

  const renameMessage = BridgeMessage({
    kind: BridgeMessageKind.action,
    id: 0,
    method: "setTitle",
    arguments: '{"windowId":"win-1","title":"Renamed"}',
  });
  const renamed = routeWindowBridgeMessage(
    in renameMessage,
    in allowed,
    capabilities,
    inout windows
  );
  match (renamed) {
    handled => {}
    response(_) => return 29;
    unhandled => return 29;
  }
  const renamedOptions = windows.options("win-1");
  match (renamedOptions) {
    some(options) => {
      if (!options.visible) return 30;
      if (options.title != "Renamed") return 31;
    }
    none => return 31;
  }

  const unknownActionMessage = BridgeMessage({
    kind: BridgeMessageKind.action,
    id: 0,
    method: "unsupported",
    arguments: '{}',
  });
  const unknownAction = routeWindowBridgeMessage(
    in unknownActionMessage,
    in allowed,
    capabilities,
    inout windows
  );
  match (unknownAction) {
    unhandled => {}
    response(_) => return 32;
    handled => return 32;
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
    response(value) => {
      if (value.ok) return 7;
      if (value.payload != '{"code":"INVALID_ARGUMENTS","message":"INVALID_WINDOW_OPTIONS: inject and capabilities are native application policy","permission":"","service":"","method":"","errorType":"","details":""}') {
        return 8;
      }
    }
    handled => return 9;
    unhandled => return 9;
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
    response(_) => return 11;
    handled => return 11;
    unhandled => {}
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
    handled => return 23;
    unhandled => return 23;
    response(value) => {
      if (value.ok) return 24;
      if (value.payload != '{"code":"PERMISSION_DENIED","message":"permission \\"window:create\\" is not granted to the selected window capability profiles","permission":"window:create","service":"","method":"","errorType":"","details":""}') {
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
    handled => 12;
    unhandled => 12;
    response(value) => {
      if (value.ok) return 13;
      if (value.payload != '{"code":"PERMISSION_DENIED","message":"permission \\"window:create\\" is required; add it to security.permissions in zapp.config.ts","permission":"window:create","service":"","method":"","errorType":"","details":""}') {
        return 14;
      }
      const afterDeniedCreation = windows.all();
      if (afterDeniedCreation.length != 1) return 15;
      const closeMessage = BridgeMessage({
        kind: BridgeMessageKind.action,
        id: 0,
        method: "close",
        arguments: '{"windowId":"win-1"}',
      });
      const closed = routeWindowBridgeMessage(
        in closeMessage,
        in allowed,
        capabilities,
        inout windows
      );
      match (closed) {
        handled => {}
        response(_) => return 33;
        unhandled => return 33;
      }
      const remaining = windows.all();
      if (remaining.length != 0) return 34;
      select 0;
    }
  };
}
