import json from "std/json";
import { ServiceOutcome } from "./service-contract.zs";
import { Services } from "./services.zs";

export enum BridgeMessageKind {
  invoke,
  emit,
  action,
  worker,
  sync,
  cancel,
}

export readonly struct BridgeMessage {
  kind: BridgeMessageKind;
  id: u64;
  method: String;
  arguments: String;
}

export struct BridgeDecodeError {
  message: String;
}

export struct BridgeResponse {
  id: u64;
  ok: boolean;
  payload: String;
}

export readonly struct BridgeError {
  code: String;
  message: String;
  permission: String = "";
}

function decodeError(message: String): BridgeDecodeError {
  return BridgeDecodeError({ message: move message });
}

function messageKind(tag: u64): BridgeMessageKind throws BridgeDecodeError {
  if (tag == 1) return BridgeMessageKind.invoke;
  if (tag == 3) return BridgeMessageKind.emit;
  if (tag == 4) return BridgeMessageKind.action;
  if (tag == 5) return BridgeMessageKind.worker;
  if (tag == 6) return BridgeMessageKind.sync;
  if (tag == 7) return BridgeMessageKind.cancel;
  throw decodeError(`unsupported bridge message type ${tag}`);
}

export function decodeBridgeMessage(
  in source: String
): BridgeMessage throws BridgeDecodeError {
  return match (attempt json.parse(source)) {
    failure(error) => throw decodeError(copy error.message);
    success(value) => match (value) {
      object(fields) => {
        const zero: u64 = 0;
        const typeField = fields.get("t");
        const tag = match (in typeField) {
          none => zero;
          some(field) => match (in field) {
            number(number) => {
              const converted = attempt number.toU64();
              select match (converted) {
                success(integer) => integer;
                failure(_) => throw decodeError(
                  "bridge message type is outside the u64 range"
                );
              };
            }
            _ => throw decodeError("bridge message type must be an unsigned integer");
          }
        };

        const idField = fields.get("id");
        const id = match (in idField) {
          none => zero;
          some(field) => match (in field) {
            number(number) => {
              const converted = attempt number.toU64();
              select match (converted) {
                success(integer) => integer;
                failure(_) => throw decodeError(
                  "bridge request id is outside the u64 range"
                );
              };
            }
            _ => throw decodeError("bridge request id must be an unsigned integer");
          }
        };

        const methodField = fields.get("m");
        const method = match (in methodField) {
          none => "";
          some(field) => match (in field) {
            string(text) => copy text;
            _ => throw decodeError("bridge method must be a string");
          }
        };

        const argumentsField = fields.get("a");
        const arguments = match (in argumentsField) {
          some(field) => json.stringify(in field);
          none => "null";
        };
        const kind = try messageKind(tag);
        select BridgeMessage({
          kind,
          id,
          method: move method,
          arguments: move arguments,
        });
      }
      _ => throw decodeError("bridge message must be a JSON object");
    }
  };
}

export function bridgeSuccess(
  id: u64,
  payload: String
): BridgeResponse {
  return BridgeResponse({ id, ok: true, payload: move payload });
}

export function bridgeFailure(
  id: u64,
  code: String,
  message: String
): BridgeResponse {
  const error = BridgeError({
    code: move code,
    message: move message,
  });
  return BridgeResponse({ id, ok: false, payload: json.encode(in error) });
}

export function bridgePermissionFailure(
  id: u64,
  permission: String
): BridgeResponse {
  const message = `permission "${permission}" is required; add it to security.permissions in zapp.config.ts`;
  const error = BridgeError({
    code: "PERMISSION_DENIED",
    message: move message,
    permission: move permission,
  });
  return BridgeResponse({ id, ok: false, payload: json.encode(in error) });
}

function dispatch(in message: BridgeMessage): Option<BridgeResponse> {
  return match (in message.kind) {
    invoke => {
      if (message.method == "__zapp:ping") {
        return Option.some(bridgeSuccess(message.id, copy message.arguments));
      }
      select Option.some(bridgeFailure(
        message.id,
        "UNKNOWN_METHOD",
        `unknown bridge method "${message.method}"`
      ));
    }
    emit => Option.none;
    action => Option.none;
    worker => Option.none;
    sync => Option.none;
    cancel => Option.none;
  };
}

export function routeMessage(in source: String): Option<BridgeResponse> {
  const decoded = attempt decodeBridgeMessage(in source);
  return match (decoded) {
    success(message) => dispatch(in message);
    failure(error) => Option.some(bridgeFailure(
      0,
      "INVALID_MESSAGE",
      copy error.message
    ));
  };
}

export function routeMessageWithServices(
  in source: String,
  in services: Services
): Option<BridgeResponse> {
  const decoded = attempt decodeBridgeMessage(in source);
  match (decoded) {
    failure(error) => return Option.some(bridgeFailure(
      0,
      "INVALID_MESSAGE",
      copy error.message
    ));
    success(message) => return dispatchWithServices(in message, in services);
  }
}

function dispatchWithServices(
  in message: BridgeMessage,
  in services: Services
): Option<BridgeResponse> {
  match (in message.kind) {
    invoke => {
      if (message.method == "__zapp:ping") {
        return Option.some(bridgeSuccess(message.id, copy message.arguments));
      }
      const invoked = services.invoke(
        copy message.method,
        copy message.arguments
      );
      match (invoked) {
        success(payload) => return Option.some(
          bridgeSuccess(message.id, move payload)
        );
        failure(error) => return Option.some(
          bridgeFailure(
            message.id,
            "SERVICE_ERROR",
            move error
          )
        );
      }
    }
    emit => return Option.none;
    action => return Option.none;
    worker => return Option.none;
    sync => return Option.none;
    cancel => return Option.none;
  }
}
