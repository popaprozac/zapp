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

export struct BridgeMessage {
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
            nullValue => throw decodeError("bridge message type must be an unsigned integer");
            boolean(_) => throw decodeError("bridge message type must be an unsigned integer");
            string(_) => throw decodeError("bridge message type must be an unsigned integer");
            array(_) => throw decodeError("bridge message type must be an unsigned integer");
            object(_) => throw decodeError("bridge message type must be an unsigned integer");
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
            nullValue => throw decodeError("bridge request id must be an unsigned integer");
            boolean(_) => throw decodeError("bridge request id must be an unsigned integer");
            string(_) => throw decodeError("bridge request id must be an unsigned integer");
            array(_) => throw decodeError("bridge request id must be an unsigned integer");
            object(_) => throw decodeError("bridge request id must be an unsigned integer");
          }
        };

        const methodField = fields.get("m");
        const method = match (in methodField) {
          none => "";
          some(field) => match (in field) {
            string(text) => copy text;
            nullValue => throw decodeError("bridge method must be a string");
            boolean(_) => throw decodeError("bridge method must be a string");
            number(_) => throw decodeError("bridge method must be a string");
            array(_) => throw decodeError("bridge method must be a string");
            object(_) => throw decodeError("bridge method must be a string");
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
      nullValue => throw decodeError("bridge message must be a JSON object");
      boolean(_) => throw decodeError("bridge message must be a JSON object");
      number(_) => throw decodeError("bridge message must be a JSON object");
      string(_) => throw decodeError("bridge message must be a JSON object");
      array(_) => throw decodeError("bridge message must be a JSON object");
    }
  };
}

function response(id: u64, ok: boolean, payload: String): BridgeResponse {
  return BridgeResponse({ id, ok, payload: move payload });
}

function dispatch(in message: BridgeMessage): Option<BridgeResponse> {
  return match (in message.kind) {
    invoke => {
      if (message.method == "__zapp:ping") {
        return Option.some(response(message.id, true, copy message.arguments));
      }
      select Option.some(response(message.id, false, "UNKNOWN_METHOD"));
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
    failure(error) => Option.some(response(0, false, copy error.message));
  };
}

export function routeMessageWithServices(
  in source: String,
  in services: Services
): Option<BridgeResponse> {
  const decoded = attempt decodeBridgeMessage(in source);
  match (decoded) {
    failure(error) => return Option.some(response(0, false, copy error.message));
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
        return Option.some(response(message.id, true, copy message.arguments));
      }
      const invoked = services.invoke(
        copy message.method,
        copy message.arguments
      );
      match (invoked) {
        success(payload) => return Option.some(
          response(message.id, true, move payload)
        );
        failure(error) => return Option.some(
          response(message.id, false, move error)
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
