import json from "std/json";
import { thread } from "std/thread";
import { WindowSize } from "../../events.zs";
import { WindowSizeLimits, checkedWindowSize } from "../../window-sizing.zs";
import { BridgeMessage, BridgeMessageKind, BridgeResponse, bridgeSuccess, encodeBridgeResponse,
  bridgePermissionFailure, bridgeCapabilityFailure } from "../../bridge.zs";
import { ApplicationPermissions } from "../../application-permissions.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";
import { RelatedCreationReply } from "../../related-window-creations.zs";
import { WindowBridgeRoute } from "../../window-bridge.zs";
import { MacOSWindowRegistry } from "./window-registry.zs";
import { FrontendTitleBarOptions, validTitleBarFields, checkedTitleBar } from "../../window-titlebar-bridge.zs";

readonly struct RelatedOptions {
  title: String = "";
  width: u32 = 900;
  height: u32 = 640;
  minWidth: Option<u32> = Option<u32>.none;
  minHeight: Option<u32> = Option<u32>.none;
  maxWidth: Option<u32> = Option<u32>.none;
  maxHeight: Option<u32> = Option<u32>.none;
  visible: boolean = true;
  resizable: boolean = true;
  maximizable: boolean = true;
  fullscreenable: boolean = true;
  titleBar: FrontendTitleBarOptions = FrontendTitleBarOptions();
}
readonly struct RelatedPrepared {
  address: String;
  windowId: String;
  nativeId: i32;
  documentToken: String;
}
readonly struct RelatedCorrelation { nativeId: i32; documentToken: String; }
readonly struct CreationError { code: String; operation: String; message: String; }

function creationFailure(id: u64, message: String): BridgeResponse {
  const error = CreationError({ code: "WINDOW_ERROR", operation: "create", message });
  return encodeBridgeResponse(id, false, in error);
}

function validOptions(in source: String): boolean {
  const value = match (attempt json.parse(in source)) { success(value) => value; failure(_) => return false; };
  return match (in value) {
    object(fields) => {
      for (const field of fields) {
        if (field.key != "title" && field.key != "width" && field.key != "height" && field.key != "visible"
          && field.key != "minWidth" && field.key != "minHeight" && field.key != "maxWidth" && field.key != "maxHeight"
          && field.key != "resizable" && field.key != "maximizable" && field.key != "fullscreenable" && field.key != "titleBar") return false;
      }
      select true;
    }
    _ => false;
  };
}

// Private protocol, reached only after native frame/document authentication.
// A related child inherits policy; no renderer-supplied owner or profile exists.
internal function routeRelatedWindowBridgeMessage(
  in message: BridgeMessage, in permissions: ApplicationPermissions,
  in owner: RelatedDocumentIdentity, windows: MacOSWindowRegistry
): WindowBridgeRoute on thread.main {
  if (message.kind != BridgeMessageKind.invoke) return WindowBridgeRoute.unhandled;
  if (message.method == "__window:abort-related" || message.method == "__window:publish-related") {
    const correlation = match (attempt json.decode<RelatedCorrelation>(in message.arguments)) {
      success(value) => value;
      failure(_) => return WindowBridgeRoute.response(creationFailure(message.id, "Invalid related window identity."));
    };
    if (message.method == "__window:abort-related") {
      windows.related.abortPrepared(in owner, correlation.nativeId, in correlation.documentToken);
      return WindowBridgeRoute.response(bridgeSuccess(message.id, "null"));
    }
    if (!windows.related.publishPrepared(in owner, correlation.nativeId, in correlation.documentToken)) {
      return WindowBridgeRoute.response(creationFailure(message.id, "The related document was retired before publication."));
    }
    return WindowBridgeRoute.response(bridgeSuccess(message.id, "null"));
  }
  if (message.method != "__window:prepare-related") return WindowBridgeRoute.unhandled;
  if (!permissions.windowCreate) return WindowBridgeRoute.response(bridgePermissionFailure(message.id, "window:create"));
  const capabilities = match (windows.documents.capabilitiesFor(in owner)) {
    some(value) => value;
    none => return WindowBridgeRoute.response(creationFailure(message.id, "The owning document is no longer active."));
  };
  if (!capabilities.allowsPermission("window:create")) return WindowBridgeRoute.response(bridgeCapabilityFailure(message.id, "window:create"));
  if (!validOptions(in message.arguments) || !validTitleBarFields(in message.arguments)) return WindowBridgeRoute.response(creationFailure(message.id, "Invalid related window options: expected title, width, height, minWidth, minHeight, maxWidth, maxHeight, visible, resizable, maximizable, fullscreenable, or titleBar (style, titleVisible)."));
  const options = match (attempt json.decode<RelatedOptions>(in message.arguments)) {
    success(value) => value;
    failure(_) => return WindowBridgeRoute.response(creationFailure(message.id, "Invalid related window dimensions or title."));
  };
  if (options.width == 0 || options.height == 0) return WindowBridgeRoute.response(creationFailure(message.id, "Related window dimensions must be positive."));
  const limits = WindowSizeLimits({ minWidth: options.minWidth, minHeight: options.minHeight,
    maxWidth: options.maxWidth, maxHeight: options.maxHeight });
  const size = match (attempt checkedWindowSize(WindowSize({ width: options.width, height: options.height }), limits)) {
    success(value) => value;
    failure(error) => return WindowBridgeRoute.response(creationFailure(message.id, copy error.message));
  };
  const titleBar = match (attempt checkedTitleBar(in options.titleBar)) {
    success(value) => value;
    failure(error) => return WindowBridgeRoute.response(creationFailure(message.id, move error));
  };
  const weakWindows = weak windows;
  const identity = copy owner;
  const reply: RelatedCreationReply = move (result): void => {
    match (result) {
      ready(child) => match (attempt weakWindows.upgrade()) {
        success(windows) => windows.deliverRelatedCreation(in identity, in child);
        failure(_) => {}
      }
      // The existing rollback sends terminal invalidation after native cleanup.
      failed(_) => {}
    }
  };
  const reservation = match (windows.prepareRelatedWindow(in owner, copy options.title, size.width, size.height, reply)) {
    some(value) => value;
    none => return WindowBridgeRoute.response(creationFailure(message.id, "Related window creation could not be prepared."));
  };
  windows.related.deferPublication(in reservation, options.visible, titleBar, options.resizable, options.maximizable, options.fullscreenable);
  windows.related.configureSizeLimits(in reservation, limits);
  const address = match (windows.related.address(in reservation)) {
    some(value) => value;
    none => { windows.related.fail(in reservation); return WindowBridgeRoute.response(creationFailure(message.id, "Related window shell is unavailable.")); }
  };
  const result = RelatedPrepared({ address, windowId: `related-${reservation.child.windowId}`,
    nativeId: reservation.child.windowId, documentToken: `${reservation.child.token}` });
  return WindowBridgeRoute.response(encodeBridgeResponse(message.id, true, in result));
}
