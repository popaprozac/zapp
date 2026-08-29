import {
  bridgeTypedServiceFailure,
  routeMessageWithServices,
} from "../../../native/z/framework/bridge.zs";
import { ServiceOutcome } from "../../../native/z/framework/service-contract.zs";
import { createSyncNotesService } from "./sync-notes-service.zs";
import {
  Services,
  createServices,
} from "../../../native/z/framework/services.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import { Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";

class Application {
  readonly name: String;
  readonly services: Services;
  runtimeMarker: i32 on thread.main;
}

const application = Once<Application>();

function initializeApplication(): OnceLifetime<Application> on thread.main {
  let services = createServices();
  services.register("notes", createSyncNotesService());
  const value = new Application({
    name: "Zapp",
    services: services.freeze(),
    runtimeMarker: 1,
  });
  return application.initialize(move value);
}

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const current = application.get();
  const services = current.services;
  const routed = routeMessageWithServices(in message, in services);
  match (routed) {
    some(response) => zapp_deliver_response_from_z(
      response.payload,
      response.id,
      response.ok,
      windowId
    );
    none => {}
  }
}

export c function zapp_invoke_service_owned(
  method: String,
  arguments: String,
  requestId: u64,
  contextId: i32
): void {
  const current = application.get();
  const services = current.services;
  const invoked = services.invoke(move method, move arguments);
  match (invoked) {
    success(payload) => zapp_deliver_response_from_z(
      payload,
      requestId,
      true,
      contextId
    );
    failure(error) => zapp_deliver_response_from_z(
      error,
      requestId,
      false,
      contextId
    );
    typedFailure(error) => {
      const response = bridgeTypedServiceFailure(requestId, move error);
      zapp_deliver_response_from_z(
        response.payload,
        response.id,
        response.ok,
        contextId
      );
    }
  }
}
