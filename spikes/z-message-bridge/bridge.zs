import { zapp_route_message_from_z } from "zapp_router.h";

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  zapp_route_message_from_z(message, windowId);
}
