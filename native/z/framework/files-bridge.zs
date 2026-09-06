import json from "std/json";
import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
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
  FileError,
  FileManager,
  FileOperation,
} from "./files.zs";

readonly struct FrontendFilePath {
  path: String;
}

readonly struct FrontendWriteText {
  path: String;
  contents: String;
}

readonly struct FileBridgeError {
  code: String;
  message: String;
  operation: String;
  path: String;
}

function fileOperationName(operation: FileOperation): String {
  return match (operation) {
    readText => "readText";
    writeText => "writeText";
  };
}

function fileFailure(id: u64, in error: FileError): BridgeResponse {
  const payload = FileBridgeError({
    code: "FILE_ERROR",
    message: copy error.message,
    operation: fileOperationName(error.operation),
    path: copy error.path,
  });
  return BridgeResponse({
    id,
    ok: false,
    payload: json.encode(in payload),
  });
}

function textPayload(in source: String): String {
  const payload = json.JsonValue.string(copy source);
  return json.stringify(in payload);
}

function isFileMethod(in method: String): boolean {
  return method == "__zapp:files:read-text"
    || method == "__zapp:files:write-text";
}

internal function isFileBridgeMessage(in message: BridgeMessage): boolean {
  return message.kind == BridgeMessageKind.invoke
    && isFileMethod(in message.method);
}

function filePermission(in method: String): String {
  if (method == "__zapp:files:read-text") return "fs:read";
  return "fs:write";
}

function applicationAllowsFilePermission(
  in permissions: ApplicationPermissions,
  in permission: String
): boolean {
  if (permission == "fs:read") return permissions.fsRead;
  return permissions.fsWrite;
}

async function readTextFile(
  message: BridgeMessage,
  files: FileManager
): BridgeResponse on thread.main {
  const decoded = attempt json.decode<FrontendFilePath>(in message.arguments);
  const request = match (decoded) {
    success(value) => value;
    failure(error) => return bridgeFailure(
      message.id,
      "INVALID_FILE_REQUEST",
      `invalid readText request: ${error.message}`
    );
  };
  const path = copy request.path;
  const read = attempt await files.readText(in path);
  const response = match (read) {
    success(source) => bridgeSuccess(
      message.id,
      textPayload(in source)
    );
    failure(error) => fileFailure(message.id, in error);
  };
  return response;
}

async function writeTextFile(
  message: BridgeMessage,
  files: FileManager
): BridgeResponse on thread.main {
  const decoded = attempt json.decode<FrontendWriteText>(in message.arguments);
  const request = match (decoded) {
    success(value) => value;
    failure(error) => return bridgeFailure(
      message.id,
      "INVALID_FILE_REQUEST",
      `invalid writeText request: ${error.message}`
    );
  };
  const path = copy request.path;
  const contents = copy request.contents;
  const written = attempt await files.writeText(
    in path,
    in contents
  );
  const response = match (written) {
    success => bridgeSuccess(message.id, "null");
    failure(error) => fileFailure(message.id, in error);
  };
  return response;
}

internal async function routeFileBridgeMessage(
  message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  files: FileManager
): BridgeResponse on thread.main {
  const permission = filePermission(in message.method);
  if (!applicationAllowsFilePermission(in permissions, in permission)) {
    return bridgePermissionFailure(
      message.id,
      copy permission
    );
  }
  if (!capabilities.allowsPermission(in permission)) {
    return bridgeCapabilityFailure(
      message.id,
      move permission
    );
  }
  if (message.method == "__zapp:files:read-text") {
    return await readTextFile(move message, files);
  }
  return await writeTextFile(move message, files);
}
