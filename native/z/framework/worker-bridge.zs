import json from "std/json";
import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeCapabilityFailure,
  bridgeFailure,
  bridgeSuccess,
} from "./bridge.zs";
import {
  ApplicationWorkerDispatch,
  ApplicationWorkers,
} from "./worker/application-workers.zs";

readonly struct FrontendApplicationWorkerSend {
  workerId: String;
  channel: String;
  payload: String;
}

readonly struct ApplicationWorkerBridgeError {
  code: String;
  message: String;
  operation: String;
  workerId: String;
}

function workerFailure(
  id: u64,
  code: String,
  workerId: String,
  message: String
): BridgeResponse {
  const error = ApplicationWorkerBridgeError({
    code: move code,
    message: move message,
    operation: "send",
    workerId: move workerId,
  });
  return BridgeResponse({ id, ok: false, payload: json.encode(in error) });
}

export enum ApplicationWorkerBridgeRoute {
  response BridgeResponse,
  unhandled,
}

export function routeApplicationWorkerBridgeMessage(
  in message: BridgeMessage,
  capabilities: CapabilitySelection,
  workers: ApplicationWorkers
): ApplicationWorkerBridgeRoute on thread.main {
  if (message.kind != BridgeMessageKind.invoke) {
    return ApplicationWorkerBridgeRoute.unhandled;
  }
  if (message.method != "__zapp:application-worker-send") {
    return ApplicationWorkerBridgeRoute.unhandled;
  }
  const decoded = attempt json.decode<FrontendApplicationWorkerSend>(
    in message.arguments
  );
  return match (decoded) {
    failure(error) => ApplicationWorkerBridgeRoute.response(bridgeFailure(
      message.id,
      "INVALID_ARGUMENTS",
      `INVALID_APPLICATION_WORKER_MESSAGE: ${error.message}`
    ));
    success(request) => {
      if (request.workerId.byteLength == 0) {
        return ApplicationWorkerBridgeRoute.response(bridgeFailure(
          message.id,
          "INVALID_ARGUMENTS",
          "application worker ID must not be empty"
        ));
      }
      if (request.channel.byteLength == 0) {
        return ApplicationWorkerBridgeRoute.response(bridgeFailure(
          message.id,
          "INVALID_ARGUMENTS",
          "application worker channel must not be empty"
        ));
      }
      if (!capabilities.allowsWorker(in request.workerId)) {
        return ApplicationWorkerBridgeRoute.response(
          bridgeCapabilityFailure(
            message.id,
            `worker:${request.workerId}`
          )
        );
      }
      select match (workers.dispatch(
        in request.workerId,
        in request.channel,
        in request.payload
      )) {
        accepted => ApplicationWorkerBridgeRoute.response(
          bridgeSuccess(message.id, "null")
        );
        unavailable => ApplicationWorkerBridgeRoute.response(workerFailure(
          message.id,
          "WORKER_UNAVAILABLE",
          copy request.workerId,
          `application worker "${request.workerId}" is not running`
        ));
        saturated => ApplicationWorkerBridgeRoute.response(workerFailure(
          message.id,
          "WORKER_BUSY",
          copy request.workerId,
          `application worker "${request.workerId}" cannot accept more work`
        ));
        failed => ApplicationWorkerBridgeRoute.response(workerFailure(
          message.id,
          "WORKER_ERROR",
          copy request.workerId,
          `application worker "${request.workerId}" could not accept the message`
        ));
      };
    }
  };
}
