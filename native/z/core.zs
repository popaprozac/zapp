import { routeMessage } from "./bridge.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const response = routeMessage(in message);
  zapp_deliver_response_from_z(
    response.payload,
    response.id,
    response.ok,
    windowId
  );
}
