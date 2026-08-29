import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeFailure,
  bridgeSuccess,
  bridgeTypedServiceFailure,
  decodeBridgeMessage,
} from "./bridge.zs";
import { AsyncServices } from "./async-services.zs";
import { ServiceOutcome } from "./service-contract.zs";

export async function routeMessageWithServicesAsync(
  source: String,
  services: AsyncServices
): Option<BridgeResponse> {
  const decoded = attempt decodeBridgeMessage(in source);
  match (decoded) {
    failure(error) => return Option.some(
      bridgeFailure(
        0,
        "INVALID_MESSAGE",
        copy error.message
      )
    );
    success(message) => return await routeDecodedMessageWithServicesAsync(
      move message,
      services
    );
  }
}

export async function routeDecodedMessageWithServicesAsync(
  message: BridgeMessage,
  services: AsyncServices
): Option<BridgeResponse> {
  const kind = message.kind;
  if (kind != BridgeMessageKind.invoke) return Option.none;
  if (message.method == "__zapp:ping") {
    return Option.some(
      bridgeSuccess(message.id, copy message.arguments)
    );
  }
  const invoked = await services.invoke(
    copy message.method,
    copy message.arguments
  );
  return match (invoked) {
    success(payload) => Option.some(
      bridgeSuccess(message.id, move payload)
    );
    failure(error) => Option.some(
      bridgeFailure(
        message.id,
        "SERVICE_ERROR",
        move error
      )
    );
    typedFailure(typedError) => Option.some(
      bridgeTypedServiceFailure(message.id, move typedError)
    );
  };
}
