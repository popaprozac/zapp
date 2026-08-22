import { BridgeResponse, routeMessage } from "./bridge.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import { Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";

class Application on thread.main {
  readonly name: String;
}

const application = Once<Application>();

function initializeApplication(): OnceLifetime<Application> on thread.main {
  const value = new Application({ name: "Zapp" });
  return application.initialize(move value);
}

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const current = application.get();
  const response = routeMessage(in message);
  zapp_deliver_response_from_z(
    response.payload,
    response.id,
    response.ok,
    windowId
  );
}
