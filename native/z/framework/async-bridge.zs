import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  decodeBridgeMessage,
} from "./bridge.zs";
import { AsyncServices } from "./async-services.zs";
import { ServiceOutcome } from "./service-contract.zs";

function response(id: u64, ok: boolean, payload: String): BridgeResponse {
  return BridgeResponse({ id, ok, payload: move payload });
}

export async function routeMessageWithServicesAsync(
  in source: String,
  services: AsyncServices
): Option<BridgeResponse> {
  const decoded = attempt decodeBridgeMessage(in source);
  match (decoded) {
    failure(error) => return Option.some(
      response(0, false, copy error.message)
    );
    success(message) => return await dispatchWithServicesAsync(
      move message,
      services
    );
  }
}

async function dispatchWithServicesAsync(
  message: BridgeMessage,
  services: AsyncServices
): Option<BridgeResponse> {
  const kind = message.kind;
  if (kind != BridgeMessageKind.invoke) return Option.none;
  if (message.method == "__zapp:ping") {
    return Option.some(
      response(message.id, true, copy message.arguments)
    );
  }
  const invoked = await services.invoke(
    copy message.method,
    copy message.arguments
  );
  return match (invoked) {
    success(payload) => Option.some(
      response(message.id, true, move payload)
    );
    failure(error) => Option.some(
      response(message.id, false, move error)
    );
  };
}
